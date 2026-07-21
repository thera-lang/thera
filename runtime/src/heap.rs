//! The runtime object heap and its garbage collector.
//!
//! Heap objects ([`Obj`]) live here, addressed by the `u32` handle inside a
//! [`Value::Ref`]. The heap is a slab of slots; a freed slot becomes a hole on a
//! free list and is reused by a later [`alloc`]. Collection is a precise,
//! **non-moving mark-sweep** ([`collect`]): handles are stable across a
//! collection, so nothing outside this module moves.
//!
//! **Roots and safepoints.** The collector never runs inside [`alloc`] — only at
//! the interpreter's safepoint ([`maybe_collect`], called at the top of
//! `run_loop`), where the only live values are those in the call-frame stack.
//! The interpreter hands those in as the root set; everything reachable from a
//! root via [`Obj::child_values`] survives, the rest is swept. Mid-instruction
//! temporaries held only in Rust locals are never exposed (the safepoint sits
//! between instructions), so they can't be collected out from under us.
//!
//! **When to collect.** [`alloc`] keeps a running byte estimate and, when it
//! crosses the threshold, sets a cheap `GC_PENDING` flag; the per-instruction
//! safepoint is then just two `Cell` reads (`pending? && !paused?`), so
//! non-allocating instructions pay almost nothing. A collection retargets the
//! threshold to a multiple of the surviving bytes — normally 2×, but **4× when a
//! collection reclaimed less than a quarter of the heap** (the program is
//! memory-hungry; re-marking a large live set to free a sliver is thrashing).
//! `live_bytes` is summed *during the mark walk*, so [`Obj::heap_bytes`] is
//! touched once per live object as part of a traversal we already do — never in
//! a separate pass, never for garbage.
//!
//! The heap is a thread-local so the value constructors and `==` stay free of an
//! explicit heap parameter (the runtime is single-threaded; each thread — e.g. a
//! test thread — gets its own heap). Access is closure-scoped: a reader must not
//! re-enter the heap while it holds a borrow, so helpers that compare or recurse
//! (`values_eq`, and the collection mutators) **clone the object out first** and
//! operate on the copy — cheap, since `Value` is `Copy`.

use std::cell::{Cell, RefCell};

use crate::value::{Obj, Value};

/// Collection floor: never set the next-collection threshold below this many
/// bytes, so small programs (and tests) don't collect constantly.
const MIN_GC_BYTES: usize = 1 << 20; // 1 MiB

/// Default ceiling on the **live** heap: when a collection still leaves more
/// than this many bytes reachable, the program is out of memory and the
/// interpreter traps (`Trap::OutOfMemory`) instead of growing until the OS
/// kills the process. Overridable per run via `THERA_MAX_HEAP_MB`.
const DEFAULT_MAX_HEAP_BYTES: usize = 1 << 30; // 1 GiB

/// The slab: object slots plus the bookkeeping a mark-sweep needs.
struct Heap {
    /// Object slots. `None` is a free hole (its index is on `free`).
    slots: Vec<Option<Obj>>,
    /// Indices of free holes, reused before growing `slots`.
    free: Vec<u32>,
    /// Estimated bytes occupied (live + not-yet-collected). [`alloc`] adds to it;
    /// a collection resets it to the surviving bytes.
    heap_bytes: usize,
    /// Collect once `heap_bytes` reaches this; recomputed after each sweep.
    next_gc_bytes: usize,
    /// The mark bitmap, kept across collections so its allocation is reused
    /// (resized + cleared per collection rather than freshly allocated).
    marked: Vec<bool>,
}

impl Heap {
    /// Live objects: occupied slots (total slots minus free holes).
    fn live(&self) -> usize {
        self.slots.len() - self.free.len()
    }
}

thread_local! {
    static HEAP: RefCell<Heap> = const {
        RefCell::new(Heap {
            slots: Vec::new(),
            free: Vec::new(),
            heap_bytes: 0,
            next_gc_bytes: MIN_GC_BYTES,
            marked: Vec::new(),
        })
    };

    /// Set by [`alloc`] when `heap_bytes` crosses the threshold; read (and
    /// cleared) at the interpreter safepoint. A plain `Cell` so the
    /// per-instruction check needs no `RefCell` borrow.
    static GC_PENDING: Cell<bool> = const { Cell::new(false) };

    /// Nonzero while collection is suspended (the re-entrant `debug`/`display`
    /// fallback). A `Cell`, like `GC_PENDING`, for a borrow-free safepoint check.
    static GC_PAUSED: Cell<usize> = const { Cell::new(0) };

    /// Ceiling on the live heap in bytes (see [`over_ceiling`]). Thread-local
    /// like the heap it bounds; initialized from `THERA_MAX_HEAP_MB`, tests set
    /// it directly via [`set_max_heap`].
    static MAX_HEAP: Cell<usize> = Cell::new(max_heap_from_env());
}

/// The heap ceiling `THERA_MAX_HEAP_MB` requests, or the default. An unparsable
/// value falls back to the default rather than erroring — the ceiling is a
/// safety net, not configuration the program's correctness depends on.
fn max_heap_from_env() -> usize {
    std::env::var("THERA_MAX_HEAP_MB")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .map(|mb| mb.saturating_mul(1 << 20))
        .unwrap_or(DEFAULT_MAX_HEAP_BYTES)
}

/// Set the live-heap ceiling in bytes. For tests and embedders; the CLI path
/// configures it via the `THERA_MAX_HEAP_MB` environment variable.
pub fn set_max_heap(bytes: usize) {
    MAX_HEAP.set(bytes);
}

/// The live bytes and the ceiling, when the live set exceeds it — the signal
/// the interpreter turns into `Trap::OutOfMemory`. `None` while the heap fits.
/// Meaningful right after a [`collect`] (between collections `heap_bytes`
/// includes garbage that a sweep may yet reclaim).
pub fn over_ceiling() -> Option<(usize, usize)> {
    let limit = MAX_HEAP.get();
    let live = HEAP.with(|h| h.borrow().heap_bytes);
    (live > limit).then_some((live, limit))
}

thread_local! {
    /// Interned string *constants* (the `const.str` opcode): content -> the one
    /// heap string for it. Permanent GC roots ([`collect`] marks them), so a
    /// literal is allocated once and every later use of it is allocation-free.
    static INTERN: RefCell<std::collections::HashMap<String, Value>> =
        RefCell::new(std::collections::HashMap::new());

    /// Module globals (top-level `let` slots; see docs/bytecode.md), indexed
    /// by `global.get`/`global.set`. A permanent GC root set ([`collect`] marks
    /// every slot), so a global's value lives for the run regardless of what is
    /// on any frame stack. Sized once by [`set_globals`] before the program-init
    /// thunk runs.
    static GLOBALS: RefCell<Vec<Value>> = const { RefCell::new(Vec::new()) };
}

/// Allocate the module-globals vector with `count` slots, each `Unit`. Called
/// once at load, before the program-init thunk fills the slots via `global.set`.
/// Resets any vector from a prior run on this thread.
pub fn set_globals(count: usize) {
    GLOBALS.with(|g| {
        let mut g = g.borrow_mut();
        g.clear();
        g.resize(count, Value::Unit);
    });
}

/// Read the module global at `idx` (the `global.get` opcode). `None` if `idx` is
/// out of range — a malformed-bytecode condition the interpreter turns into a
/// trap rather than a panic.
pub fn global_get(idx: u32) -> Option<Value> {
    GLOBALS.with(|g| g.borrow().get(idx as usize).copied())
}

/// Write the module global at `idx` (the `global.set` opcode). `None` (a no-op)
/// if `idx` is out of range; see [`global_get`].
pub fn global_set(idx: u32, v: Value) -> Option<()> {
    GLOBALS.with(|g| {
        let mut g = g.borrow_mut();
        let slot = g.get_mut(idx as usize)?;
        *slot = v;
        Some(())
    })
}

/// The interned heap string for constant `s`: allocate-and-remember on first use,
/// return the cached handle thereafter. For program *constants* only — strings
/// are immutable, so sharing one handle across every use of a literal is safe,
/// and the bounded set of literals stays permanently live without bloating the
/// heap with a fresh copy per execution. (Transient strings — concatenation,
/// interpolation — go through [`Value::new_str`] and are collected normally.)
pub fn intern_str(s: &str) -> Value {
    if let Some(v) = INTERN.with(|i| i.borrow().get(s).copied()) {
        return v;
    }
    let v = Value::new_str(s.to_string());
    INTERN.with(|i| {
        i.borrow_mut().insert(s.to_string(), v);
    });
    v
}

/// Allocate `obj` and return a handle to it, reusing a free hole when one is
/// available. Allocation never collects — that is the safepoint's job
/// ([`maybe_collect`]) — so a handle handed back here is always live. It does
/// account the new bytes and arm `GC_PENDING` once the heap crosses threshold.
pub fn alloc(obj: Obj) -> Value {
    crate::profile::on_alloc();
    HEAP.with(|h| {
        let mut heap = h.borrow_mut();
        heap.heap_bytes += obj.heap_bytes();
        // Arm at the adaptive threshold, or at the hard ceiling — the latter so
        // a heap past its limit collects at the next safepoint even when the
        // threshold sits above the ceiling (the safepoint then traps if the
        // *live* set is what's over; see `over_ceiling`).
        if heap.heap_bytes >= heap.next_gc_bytes || heap.heap_bytes >= MAX_HEAP.get() {
            GC_PENDING.set(true);
        }
        let handle = match heap.free.pop() {
            Some(i) => {
                heap.slots[i as usize] = Some(obj);
                i
            }
            None => {
                heap.slots.push(Some(obj));
                (heap.slots.len() - 1) as u32
            }
        };
        Value::Ref(handle)
    })
}

/// Read the object at `handle` through `f`. `f` must not allocate or otherwise
/// re-enter the heap (it holds a borrow); extract what you need (clone a string,
/// copy a handle) and return it. Panics on a dangling handle (a use-after-free
/// is a collector or producer bug, never a program-level fault).
pub fn with_obj<R>(handle: u32, f: impl FnOnce(&Obj) -> R) -> R {
    HEAP.with(|h| {
        f(h.borrow().slots[handle as usize]
            .as_ref()
            .expect("live handle"))
    })
}

/// Mutate the object at `handle` through `f`. Like [`with_obj`], `f` must not
/// re-enter the heap — fine for stores of (already-allocated) handles, but a
/// mutation that compares keys must clone-out first (see the map/set mutators).
pub fn with_obj_mut<R>(handle: u32, f: impl FnOnce(&mut Obj) -> R) -> R {
    HEAP.with(|h| {
        f(h.borrow_mut().slots[handle as usize]
            .as_mut()
            .expect("live handle"))
    })
}

/// Move the object at `handle` out of its slot, returning ownership and leaving
/// the slot empty — so the caller can mutate it while freely re-entering the heap
/// (a map/set mutation compares and hashes keys, which `borrow()` the heap), then
/// [`restore_obj`] it. O(1) where [`clone_obj`] would be O(n).
///
/// The slot is empty between the two calls, so this handle must not be read and
/// no collection may run in between: callers are natives, which run to completion
/// between GC safepoints, and a mutation only touches *other* handles (its keys).
pub fn take_obj(handle: u32) -> Obj {
    HEAP.with(|h| {
        h.borrow_mut().slots[handle as usize]
            .take()
            .expect("live handle")
    })
}

/// Put an object taken by [`take_obj`] back into its slot.
pub fn restore_obj(handle: u32, obj: Obj) {
    HEAP.with(|h| {
        h.borrow_mut().slots[handle as usize] = Some(obj);
    });
}

/// A clone of the object at `handle`, with the heap borrow released — so the
/// caller can recurse or compare (which re-enter the heap) freely. Cheap for
/// the common shapes: cloning a `Vec<Value>` copies handles.
pub fn clone_obj(handle: u32) -> Obj {
    HEAP.with(|h| {
        h.borrow().slots[handle as usize]
            .clone()
            .expect("live handle")
    })
}

/// Structural equality, the default `Eq` (and what `==`/`!=` lower to). For heap
/// references it compares the pointed-to objects by content; clones them out so
/// the recursion into nested handles never holds a heap borrow.
pub fn values_eq(a: Value, b: Value) -> bool {
    match (a, b) {
        (Value::Int(x), Value::Int(y)) => x == y,
        (Value::Double(x), Value::Double(y)) => x == y,
        (Value::Bool(x), Value::Bool(y)) => x == y,
        (Value::Unit, Value::Unit) => true,
        (Value::Ref(x), Value::Ref(y)) => {
            x == y || {
                let (oa, ob) = HEAP.with(|h| {
                    let heap = h.borrow();
                    (clone_at(&heap, x), clone_at(&heap, y))
                });
                // `Obj: PartialEq` recurses into `Value::eq` (→ `values_eq`) for
                // nested handles, with no borrow held here.
                oa == ob
            }
        }
        _ => false,
    }
}

fn clone_at(heap: &Heap, handle: u32) -> Obj {
    heap.slots[handle as usize].clone().expect("live handle")
}

/// Pause/resume collection. While paused, [`maybe_collect`] does nothing — used
/// to make the re-entrant `debug`/`display` fallback atomic with respect to the
/// GC, the way a native is (its in-flight values live in Rust locals, not in a
/// rooted frame). Calls nest; resume what you pause.
pub fn pause_gc() {
    GC_PAUSED.set(GC_PAUSED.get() + 1);
}

pub fn resume_gc() {
    GC_PAUSED.set(GC_PAUSED.get() - 1);
}

/// The interpreter safepoint: collect if [`alloc`] has flagged the heap past its
/// threshold and collection isn't paused, tracing from `roots`. Called at the
/// top of `run_loop`, where `roots` — every active frame's locals and operand
/// stack — is the complete live set. The common-path check is two `Cell` reads
/// (no heap borrow, `roots` left unconsumed), so it is cheap per instruction.
pub fn maybe_collect(roots: impl Iterator<Item = Value>) {
    if should_collect() {
        collect(roots);
    }
}

/// Whether the safepoint should collect now (pending and not paused). Lets a
/// caller gather roots only when a collection will actually happen — used by the
/// interpreter, which must walk every fiber's frames to collect.
pub fn should_collect() -> bool {
    GC_PENDING.get() && GC_PAUSED.get() == 0
}

/// A precise, non-moving mark-sweep over `roots`. Marks everything reachable
/// from a root via [`Obj::child_values`] (summing the live bytes as it goes),
/// frees the unmarked slots onto the free list, and retargets the
/// next-collection threshold — 2× the survivors, or 4× when this collection
/// reclaimed less than a quarter of the heap (anti-thrash).
pub fn collect(roots: impl Iterator<Item = Value>) {
    HEAP.with(|h| {
        let mut heap = h.borrow_mut();

        // Reuse the mark bitmap's allocation across collections.
        let mut marked = std::mem::take(&mut heap.marked);
        marked.clear();
        marked.resize(heap.slots.len(), false);
        let mut worklist: Vec<u32> = Vec::new();

        // Mark roots, then transitively everything they reach, totalling the
        // live bytes during the same walk (so `heap_bytes` is read once per live
        // object — never for garbage, never in a separate pass).
        for v in roots {
            mark(&mut marked, &mut worklist, v);
        }
        // Interned string constants are permanent roots — never swept.
        INTERN.with(|i| {
            for v in i.borrow().values() {
                mark(&mut marked, &mut worklist, *v);
            }
        });
        // Module globals are permanent roots too (see docs/bytecode.md).
        GLOBALS.with(|g| {
            for v in g.borrow().iter() {
                mark(&mut marked, &mut worklist, *v);
            }
        });
        let mut live_bytes = 0usize;
        while let Some(handle) = worklist.pop() {
            if let Some(obj) = &heap.slots[handle as usize] {
                live_bytes += obj.heap_bytes();
                obj.for_each_child(|child| mark(&mut marked, &mut worklist, child));
            }
        }

        // Sweep: free every occupied slot that wasn't marked. Split the borrow
        // so the slab and the free list are mutated independently.
        let Heap { slots, free, .. } = &mut *heap;
        for (i, slot) in slots.iter_mut().enumerate() {
            if slot.is_some() && !marked[i] {
                *slot = None;
                free.push(i as u32);
            }
        }

        // Retarget the threshold from the surviving bytes (anti-thrash growth).
        heap.next_gc_bytes = next_threshold(heap.heap_bytes, live_bytes, MIN_GC_BYTES);
        heap.heap_bytes = live_bytes;

        heap.marked = marked; // restore for reuse next time
        GC_PENDING.set(false);
    });
}

/// The next-collection threshold given the bytes occupied before this sweep
/// (`heap_bytes`) and the bytes that survived it (`live_bytes`). Normally 2× the
/// survivors, but **4× when the collection reclaimed less than a quarter of the
/// heap** — a memory-hungry program should be re-marked less often rather than
/// thrashed for little gain — and never below `floor`.
fn next_threshold(heap_bytes: usize, live_bytes: usize, floor: usize) -> usize {
    let reclaimed = heap_bytes.saturating_sub(live_bytes);
    let grow = if heap_bytes > 0 && reclaimed * 4 < heap_bytes {
        4
    } else {
        2
    };
    (live_bytes * grow).max(floor)
}

/// Mark `v`'s handle (if it is one) grey: record it and enqueue it for tracing.
fn mark(marked: &mut [bool], worklist: &mut Vec<u32>, v: Value) {
    if let Value::Ref(h) = v
        && !marked[h as usize]
    {
        marked[h as usize] = true;
        worklist.push(h);
    }
}

/// The number of live (reachable-as-of-the-last-sweep, or never-swept) objects.
/// For tests and diagnostics.
pub fn object_count() -> usize {
    HEAP.with(|h| h.borrow().live())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::value::Value;

    /// Force the next allocation to arm a collection (test convenience).
    fn lower_threshold_to_zero() {
        HEAP.with(|h| h.borrow_mut().next_gc_bytes = 0);
    }

    #[test]
    fn alloc_grows_and_handles_are_distinct() {
        let before = object_count();
        let a = Value::new_str("x");
        let b = Value::new_str("x");
        // Two fresh allocations, two more live objects.
        assert_eq!(object_count(), before + 2);
        // Distinct handles for distinct allocations...
        assert!(matches!((a, b), (Value::Ref(x), Value::Ref(y)) if x != y));
        // ...but structurally equal, compared through the heap.
        assert!(values_eq(a, b));
    }

    #[test]
    fn structural_equality_recurses_through_the_heap() {
        let a = Value::new_list(vec![Value::new_str("hi"), Value::Int(1)]);
        let b = Value::new_list(vec![Value::new_str("hi"), Value::Int(1)]);
        let c = Value::new_list(vec![Value::new_str("ho"), Value::Int(1)]);
        assert!(values_eq(a, b)); // distinct handles, equal contents
        assert!(!values_eq(a, c));
    }

    #[test]
    fn child_values_is_the_trace_primitive() {
        let s = Value::new_str("k");
        let n = Value::Int(7);
        let list = Value::new_list(vec![s, n]);
        // A list traces to its elements; a string (a leaf) holds no handles.
        if let Value::Ref(h) = list {
            assert_eq!(with_obj(h, |o| o.child_values()), vec![s, n]);
        }
        if let Value::Ref(h) = s {
            assert!(with_obj(h, |o| o.child_values()).is_empty());
        }
    }

    #[test]
    fn collect_reclaims_unreachable_objects() {
        let before = object_count();
        // A small reachable graph: a list holding a string, kept as a root.
        let kept = Value::new_list(vec![Value::new_str("live")]);
        // Garbage: strings nothing will point at.
        for i in 0..50 {
            let _ = Value::new_str(format!("garbage-{i}"));
        }
        assert_eq!(object_count(), before + 52); // list + 1 string + 50 garbage

        collect([kept].into_iter());

        // The list and its string survive (reachable from the root); the 50
        // loose strings are swept. (`before` objects from earlier tests on this
        // thread are unreachable too, so they go as well — hence `<=`.)
        assert!(
            object_count() <= 2,
            "live after collect: {}",
            object_count()
        );
        // The survivor is intact and still traversable.
        if let Value::Ref(h) = kept {
            let children = with_obj(h, |o| o.child_values());
            assert_eq!(children.len(), 1);
            assert!(values_eq(children[0], Value::new_str("live")));
        }
    }

    #[test]
    fn freed_slots_are_reused() {
        // Fill, drop, collect — then new allocations reuse the holes rather than
        // growing the slab without bound.
        for i in 0..30 {
            let _ = Value::new_str(format!("x-{i}"));
        }
        collect(std::iter::empty()); // everything is garbage
        assert_eq!(object_count(), 0);
        // Reallocating reuses freed slots; live count tracks allocations again.
        let a = Value::new_str("a");
        let b = Value::new_str("b");
        assert_eq!(object_count(), 2);
        assert!(values_eq(a, Value::new_str("a")));
        assert!(!values_eq(a, b));
    }

    #[test]
    fn alloc_arms_collection_at_the_byte_threshold() {
        // With a zero threshold the next allocation arms `GC_PENDING`, and the
        // safepoint then sweeps the (unrooted) garbage.
        lower_threshold_to_zero();
        let _garbage = Value::new_str("dead");
        assert!(
            GC_PENDING.get(),
            "alloc past threshold should arm collection"
        );
        maybe_collect(std::iter::empty());
        assert_eq!(object_count(), 0);
        assert!(!GC_PENDING.get(), "collection clears the pending flag");
    }

    #[test]
    fn threshold_growth_is_adaptive() {
        // Floor of 0 to isolate the multiplier from the clamp.
        // Reclaimed a sliver (100 of 1000, < 25%) → 4× the survivors.
        assert_eq!(next_threshold(1000, 900, 0), 3600);
        // Reclaimed most (600 of 1000, ≥ 25%) → 2× the survivors.
        assert_eq!(next_threshold(1000, 400, 0), 800);
        // Boundary: exactly 25% reclaimed is not "less than", so 2×.
        assert_eq!(next_threshold(1000, 750, 0), 1500);
        // The floor wins when the live set is tiny.
        assert_eq!(next_threshold(1000, 10, 1024), 1024);
        // A first collection of an empty heap stays at the floor.
        assert_eq!(next_threshold(0, 0, 1024), 1024);
    }

    #[test]
    fn globals_are_permanent_roots() {
        // A value reachable only through a module-global slot survives a
        // collection whose explicit root set is empty.
        set_globals(2);
        let kept = Value::new_list(vec![Value::new_str("alive")]);
        assert!(global_set(0, kept).is_some());
        let _garbage = Value::new_str("dead");

        collect(std::iter::empty()); // only INTERN + GLOBALS root the survivors

        let g = global_get(0).expect("slot 0");
        if let Value::Ref(h) = g {
            let children = with_obj(h, |o| o.child_values());
            assert_eq!(children.len(), 1);
            assert!(values_eq(children[0], Value::new_str("alive")));
        } else {
            panic!("global slot 0 should still hold a list");
        }
        // Out-of-range access is reported, not a panic.
        assert!(global_get(99).is_none());
        assert!(global_set(99, Value::Unit).is_none());

        set_globals(0); // tidy up for later work on this thread
    }

    #[test]
    fn ceiling_arms_collection_and_reports_the_live_overage() {
        set_max_heap(1); // one byte: any allocation is over the ceiling
        let _garbage = Value::new_str("data");
        assert!(
            GC_PENDING.get(),
            "an alloc past the ceiling should arm collection"
        );
        // The over-allocation was garbage: a collection brings the live set
        // back under the ceiling, so no overage is reported.
        collect(std::iter::empty());
        assert!(over_ceiling().is_none());
        // A *live* overage survives its collection and is reported.
        let kept = Value::new_str("data");
        collect([kept].into_iter());
        let (live, limit) = over_ceiling().expect("live bytes exceed the ceiling");
        assert!(live > limit);
        set_max_heap(usize::MAX); // unconstrain later tests on this thread
        GC_PENDING.set(false);
    }

    #[test]
    fn paused_collection_is_a_noop() {
        let kept = Value::new_str("keep");
        let _ = Value::new_str("drop");
        GC_PENDING.set(true); // pretend a collection is due
        pause_gc();
        maybe_collect(std::iter::empty()); // would sweep everything, but paused
        resume_gc();
        // Nothing was collected while paused.
        assert!(values_eq(kept, Value::new_str("keep")));
        GC_PENDING.set(false); // tidy up for any later work on this thread
    }
}
