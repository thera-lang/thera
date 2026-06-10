//! The runtime object heap.
//!
//! Heap objects ([`Obj`]) live here, addressed by the `u32` handle inside a
//! [`Value::Ref`]. This is an **interim, never-freed arena**: `alloc` only ever
//! grows the store, so it is trivially correct but leaks. It is the placeholder
//! a precise, non-moving mark-sweep collector replaces (docs/architecture.md) —
//! the structure is in place (one `alloc` point; [`Obj::child_values`] is the
//! trace primitive; the interpreter's explicit frame stack is the root set), so
//! adding collection is the remaining step.
//!
//! The heap is a thread-local so the value constructors and `==` stay free of an
//! explicit heap parameter (the runtime is single-threaded; each thread — e.g. a
//! test thread — gets its own heap). Access is closure-scoped: a reader must not
//! re-enter the heap while it holds a borrow, so helpers that compare or recurse
//! (`values_eq`, and the collection mutators) **clone the object out first** and
//! operate on the copy — cheap, since `Value` is `Copy`.

use std::cell::RefCell;

use crate::value::{Obj, Value};

thread_local! {
    static HEAP: RefCell<Vec<Obj>> = const { RefCell::new(Vec::new()) };
}

/// Allocate `obj` and return a handle to it. The single growth point — the hook
/// a collector's safepoint check will sit behind.
pub fn alloc(obj: Obj) -> Value {
    HEAP.with(|h| {
        let mut store = h.borrow_mut();
        store.push(obj);
        Value::Ref((store.len() - 1) as u32)
    })
}

/// Read the object at `handle` through `f`. `f` must not allocate or otherwise
/// re-enter the heap (it holds a borrow); extract what you need (clone a string,
/// copy a handle) and return it.
pub fn with_obj<R>(handle: u32, f: impl FnOnce(&Obj) -> R) -> R {
    HEAP.with(|h| f(&h.borrow()[handle as usize]))
}

/// Mutate the object at `handle` through `f`. Like [`with_obj`], `f` must not
/// re-enter the heap — fine for stores of (already-allocated) handles, but a
/// mutation that compares keys must clone-out first (see the map/set mutators).
pub fn with_obj_mut<R>(handle: u32, f: impl FnOnce(&mut Obj) -> R) -> R {
    HEAP.with(|h| f(&mut h.borrow_mut()[handle as usize]))
}

/// A clone of the object at `handle`, with the heap borrow released — so the
/// caller can recurse or compare (which re-enter the heap) freely. Cheap for
/// the common shapes: cloning a `Vec<Value>` copies handles.
pub fn clone_obj(handle: u32) -> Obj {
    HEAP.with(|h| h.borrow()[handle as usize].clone())
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
                    let store = h.borrow();
                    (store[x as usize].clone(), store[y as usize].clone())
                });
                // `Obj: PartialEq` recurses into `Value::eq` (→ `values_eq`) for
                // nested handles, with no borrow held here.
                oa == ob
            }
        }
        _ => false,
    }
}

/// The number of objects ever allocated (the heap never shrinks yet). For tests
/// and diagnostics.
pub fn object_count() -> usize {
    HEAP.with(|h| h.borrow().len())
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
        // The arena only ever grows (no collection yet).
        assert!(object_count() >= before + 2);
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
}
