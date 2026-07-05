//! Runtime values for the Tier-0 interpreter.
//!
//! Per docs/bytecode.md ("The first interpreter"), the draft uses a *tagged*
//! `Value` — simpler to build and debug than the untagged 64-bit slots of the
//! durable format.
//!
//! Heap-backed values are **handles** into a runtime-owned heap (see
//! [`crate::heap`]): [`Value::Ref`] is an index, so a `Value` is `Copy` and
//! carries reference semantics (copying a value copies the handle, not the
//! object). The heap is an interim, never-freed arena — the placeholder a
//! precise mark-sweep collector replaces (see docs/architecture.md). Structural
//! equality and field mutation go through the heap.

use crate::heap;
use crate::map::MapObj;

/// A value on the operand stack or in a local slot. `Copy`: heap objects are
/// referenced by a small handle, not an owning pointer.
#[derive(Clone, Copy, Debug)]
pub enum Value {
    Int(i64),
    Double(f64),
    Bool(bool),
    /// The unit value (`Void` / `()`). A `Void` function returns this, so every
    /// call yields exactly one stack value.
    Unit,
    /// A handle to a heap object (an index into [`crate::heap`]).
    Ref(u32),
}

/// Render a `Double` to its Hawk string form. Unlike Rust's `f64::to_string`
/// (which prints `1.0` as `"1"`), an integral `Double` keeps a trailing `.0`, so
/// `Double` output is always visibly distinct from `Int` — `1.0` → `"1.0"`,
/// `3.14` → `"3.14"`, `-2.0` → `"-2.0"`. Non-finite values (`inf`/`NaN`) and any
/// value Rust already prints with a `.`/exponent pass through unchanged. Shared
/// by the `Display`, error-message, and `Debug` renderers.
pub fn format_double(x: f64) -> String {
    let s = x.to_string();
    if x.is_finite() && !s.contains(['.', 'e', 'E']) {
        format!("{s}.0")
    } else {
        s
    }
}

/// Structural equality — the default `Eq`. For heap references it compares the
/// pointed-to objects by content (recursing through the heap), matching the
/// reference semantics the old `Rc<RefCell<Obj>>` representation gave for free.
impl PartialEq for Value {
    fn eq(&self, other: &Value) -> bool {
        heap::values_eq(*self, *other)
    }
}

impl Value {
    /// Construct a heap string.
    pub fn new_str(s: impl Into<String>) -> Value {
        heap::alloc(Obj::Str(s.into()))
    }

    /// Construct an immutable byte buffer.
    pub fn new_bytes(bytes: Vec<u8>) -> Value {
        heap::alloc(Obj::Bytes(bytes))
    }

    /// Construct an empty mutable byte accumulator.
    pub fn new_bytes_builder() -> Value {
        heap::alloc(Obj::BytesBuilder(Vec::new()))
    }

    /// Construct a heap list.
    pub fn new_list(items: Vec<Value>) -> Value {
        heap::alloc(Obj::List(items))
    }

    /// Construct a heap map from insertion-ordered key/value pairs (later keys
    /// overwrite earlier duplicates, a map literal's semantics).
    pub fn new_map(entries: Vec<(Value, Value)>) -> Value {
        heap::alloc(Obj::Map(MapObj::from_pairs(entries)))
    }

    /// Construct a struct value of the given type on the heap.
    pub fn new_struct(ty: u32, fields: Vec<Value>) -> Value {
        heap::alloc(Obj::Struct { ty, fields })
    }

    /// Construct an enum value (e.g. `Result`/`Option`) on the heap.
    pub fn new_enum(ty: u32, variant: u16, fields: Vec<Value>) -> Value {
        heap::alloc(Obj::Enum(EnumObj {
            ty,
            variant,
            fields,
        }))
    }

    /// Construct a closure value: the index of the lifted function plus the
    /// captured environment values (see docs/bytecode.md, "Closures / lambdas").
    pub fn new_closure(func: u32, captures: Vec<Value>) -> Value {
        heap::alloc(Obj::Closure { func, captures })
    }

    /// `Some(v)` / `None` constructors for the built-in `Option` type.
    pub fn some(v: Value) -> Value {
        Value::new_enum(TY_OPTION, TAG_SOME, vec![v])
    }
    pub fn none() -> Value {
        Value::new_enum(TY_OPTION, TAG_NONE, vec![])
    }

    /// `Ok(v)` / `Err(e)` constructors for the built-in `Result` type.
    pub fn ok(v: Value) -> Value {
        Value::new_enum(TY_RESULT, TAG_OK, vec![v])
    }
    pub fn err(e: Value) -> Value {
        Value::new_enum(TY_RESULT, TAG_ERR, vec![e])
    }
}

/// A heap-allocated object. Stored in [`crate::heap`]; addressed by a
/// [`Value::Ref`] handle.
#[derive(Clone, Debug, PartialEq)]
pub enum Obj {
    /// UTF-8 text.
    Str(String),
    /// An immutable byte buffer (the `Bytes` core type).
    Bytes(Vec<u8>),
    /// A mutable byte accumulator (`BytesBuilder`), frozen into [`Obj::Bytes`]
    /// by `finish`.
    BytesBuilder(Vec<u8>),
    /// An ordered, growable sequence.
    List(Vec<Value>),
    /// A key/value store: insertion-ordered, with a hash index above a size
    /// threshold (see [`crate::map`]).
    Map(MapObj),
    /// A struct instance: its type id and field values (addressed by index).
    Struct {
        ty: u32,
        fields: Vec<Value>,
    },
    Enum(EnumObj),
    /// A closure: the lifted function's index plus its captured environment.
    /// `call.indirect` prepends `captures` to the call's arguments to form the
    /// callee's leading local slots (see docs/bytecode.md).
    Closure {
        func: u32,
        captures: Vec<Value>,
    },
}

impl Obj {
    /// Apply `f` to each heap handle this object holds — the trace primitive a
    /// mark-sweep collector follows from a marked object to its children.
    /// Allocation-free: the mark walk visits every live object, so collecting
    /// each one's children into a throwaway `Vec` (the old `child_values`) made
    /// GC allocate proportionally to the whole live set. (Primitives in
    /// `List`/`Map`/fields are `Value::Int`/etc. and carry no handle.)
    pub fn for_each_child(&self, mut f: impl FnMut(Value)) {
        match self {
            Obj::Str(_) | Obj::Bytes(_) | Obj::BytesBuilder(_) => {}
            Obj::List(items) => items.iter().for_each(|&v| f(v)),
            Obj::Map(m) => m.entries().iter().for_each(|&(k, v)| {
                f(k);
                f(v);
            }),
            Obj::Struct { fields, .. } => fields.iter().for_each(|&v| f(v)),
            Obj::Enum(e) => e.fields.iter().for_each(|&v| f(v)),
            Obj::Closure { captures, .. } => captures.iter().for_each(|&v| f(v)),
        }
    }

    /// The heap handles this object holds, as a `Vec`. Convenience over
    /// [`for_each_child`](Self::for_each_child) for tests; the collector uses the
    /// allocation-free form.
    #[cfg(test)]
    pub fn child_values(&self) -> Vec<Value> {
        let mut out = Vec::new();
        self.for_each_child(|v| out.push(v));
        out
    }

    /// An estimate of the bytes this object occupies: the in-slab slot (one
    /// `Obj`) plus its heap-allocated payload (a string's buffer, a collection's
    /// backing store). Approximate — capacity, not length — which is what the
    /// GC's byte-budget heuristic wants. Used to size the collection threshold.
    pub fn heap_bytes(&self) -> usize {
        use std::mem::size_of;
        let payload = match self {
            Obj::Str(s) => s.capacity(),
            Obj::Bytes(b) | Obj::BytesBuilder(b) => b.capacity(),
            Obj::List(items) => items.capacity() * size_of::<Value>(),
            Obj::Map(m) => m.heap_bytes(),
            Obj::Struct { fields, .. } => fields.capacity() * size_of::<Value>(),
            Obj::Enum(e) => e.fields.capacity() * size_of::<Value>(),
            Obj::Closure { captures, .. } => captures.capacity() * size_of::<Value>(),
        };
        size_of::<Obj>() + payload
    }
}

/// A tagged-union value: the `variant` selected from type `ty`, with its
/// payload `fields`. `ty` is an opaque type id (it will index the module's
/// type table once that exists); it makes structural equality reject values of
/// different enum types.
#[derive(Clone, Debug, PartialEq)]
pub struct EnumObj {
    pub ty: u32,
    pub variant: u16,
    pub fields: Vec<Value>,
}

// Well-known type ids for the built-in enums (no type table yet, so these are
// fixed conventions shared by the runtime and bytecode producers).
pub const TY_RESULT: u32 = 0;
pub const TY_OPTION: u32 = 1;
pub const TY_ORDERING: u32 = 2;

// Fixed variant tags shared by all bytecode producers (docs/bytecode.md).
pub const TAG_OK: u16 = 0;
pub const TAG_ERR: u16 = 1;
pub const TAG_SOME: u16 = 0;
pub const TAG_NONE: u16 = 1;
pub const TAG_LESS: u16 = 0;
pub const TAG_EQUAL: u16 = 1;
pub const TAG_GREATER: u16 = 2;

/// Build the built-in `Ordering` enum value from a Rust comparison result.
pub fn ordering(o: std::cmp::Ordering) -> Value {
    let tag = match o {
        std::cmp::Ordering::Less => TAG_LESS,
        std::cmp::Ordering::Equal => TAG_EQUAL,
        std::cmp::Ordering::Greater => TAG_GREATER,
    };
    Value::new_enum(TY_ORDERING, tag, vec![])
}
