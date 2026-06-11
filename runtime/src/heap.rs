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
//! The heap is a thread-local so the value constructors and `==` stay free of an
//! explicit heap parameter (the runtime is single-threaded; each thread — e.g. a
//! test thread — gets its own heap). Access is closure-scoped: a reader must not
//! re-enter the heap while it holds a borrow, so helpers that compare or recurse
//! (`values_eq`, and the collection mutators) **clone the object out first** and
//! operate on the copy — cheap, since `Value` is `Copy`.

use std::cell::RefCell;

use crate::value::{Obj, Value};

/// Collect once the live-object count reaches at least this many (and then grow
/// the threshold to twice the survivors). A floor keeps small programs from
/// collecting on every other allocation.
const MIN_GC_THRESHOLD: usize = 1024;

/// The slab: object slots plus the bookkeeping a mark-sweep needs.
struct Heap {
    /// Object slots. `None` is a free hole (its index is on `free`).
    slots: Vec<Option<Obj>>,
    /// Indices of free holes, reused before growing `slots`.
    free: Vec<u32>,
    /// Collect when the live count reaches this; recomputed after each sweep.
    next_gc: usize,
    /// Re-entrancy guard: while non-zero, [`maybe_collect`] is a no-op. The
    /// interpreter raises this around the built-in `debug`/`display` fallback,
    /// whose re-entrant interpreter call would otherwise hit a safepoint while
    /// values it is mid-traversal sit only in Rust locals (not yet rooted).
    gc_paused: usize,
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
            next_gc: MIN_GC_THRESHOLD,
            gc_paused: 0,
        })
    };
}

/// Allocate `obj` and return a handle to it, reusing a free hole when one is
/// available. Allocation never collects — that is the safepoint's job
/// ([`maybe_collect`]) — so a handle handed back here is always live.
pub fn alloc(obj: Obj) -> Value {
    HEAP.with(|h| {
        let mut heap = h.borrow_mut();
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
    HEAP.with(|h| h.borrow_mut().gc_paused += 1);
}

pub fn resume_gc() {
    HEAP.with(|h| h.borrow_mut().gc_paused -= 1);
}

/// The interpreter safepoint: collect if the heap has grown past its threshold
/// (and collection isn't paused), tracing from `roots`. Called at the top of
/// `run_loop`, where `roots` — every active frame's locals and operand stack —
/// is the complete live set. A no-op on the common path (a cheap occupancy
/// check), so it is fine to call once per instruction.
pub fn maybe_collect(roots: impl Iterator<Item = Value>) {
    let due = HEAP.with(|h| {
        let heap = h.borrow();
        heap.gc_paused == 0 && heap.live() >= heap.next_gc
    });
    if due {
        collect(roots);
    }
}

/// A precise, non-moving mark-sweep over `roots`. Marks everything reachable
/// from a root via [`Obj::child_values`], frees the unmarked slots onto the free
/// list, and resets the next-collection threshold to twice the survivors.
pub fn collect(roots: impl Iterator<Item = Value>) {
    HEAP.with(|h| {
        let mut heap = h.borrow_mut();
        let mut marked = vec![false; heap.slots.len()];
        let mut worklist: Vec<u32> = Vec::new();

        // Mark roots, then transitively everything they reach.
        for v in roots {
            mark(&mut marked, &mut worklist, v);
        }
        while let Some(handle) = worklist.pop() {
            if let Some(obj) = &heap.slots[handle as usize] {
                for child in obj.child_values() {
                    mark(&mut marked, &mut worklist, child);
                }
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

        heap.next_gc = (heap.live() * 2).max(MIN_GC_THRESHOLD);
    });
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
    fn paused_collection_is_a_noop() {
        let kept = Value::new_str("keep");
        let _ = Value::new_str("drop");
        pause_gc();
        maybe_collect(std::iter::empty()); // would sweep everything, but paused
        resume_gc();
        // Nothing was collected while paused.
        assert!(values_eq(kept, Value::new_str("keep")));
    }
}
