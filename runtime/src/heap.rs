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
}

/// Allocate `obj` and return a handle to it, reusing a free hole when one is
/// available. Allocation never collects — that is the safepoint's job
/// ([`maybe_collect`]) — so a handle handed back here is always live. It does
/// account the new bytes and arm `GC_PENDING` once the heap crosses threshold.
pub fn alloc(obj: Obj) -> Value {
    HEAP.with(|h| {
        let mut heap = h.borrow_mut();
        heap.heap_bytes += obj.heap_bytes();
        if heap.heap_bytes >= heap.next_gc_bytes {
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
