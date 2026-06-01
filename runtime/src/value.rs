//! Runtime values for the Tier-0 interpreter.
//!
//! Per docs/bytecode.md ("The first interpreter"), the draft uses a *tagged*
//! `Value` — simpler to build and debug than the untagged 64-bit slots of the
//! durable format.
//!
//! Heap-backed values are shared references with reference semantics (see the
//! value model in docs/bytecode.md): [`Value::Ref`] is an `Rc<RefCell<Obj>>`,
//! so copying a value copies the pointer, not the object. `RefCell` is uniform
//! across all heap objects to support the mutable collections that arrive in a
//! later increment, even though enums themselves are immutable.

use std::cell::RefCell;
use std::rc::Rc;

/// A value on the operand stack or in a local slot.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Int(i64),
    Double(f64),
    Bool(bool),
    /// The unit value (`Void` / `()`). A `Void` function returns this, so every
    /// call yields exactly one stack value.
    Unit,
    /// A shared reference to a heap object.
    Ref(Rc<RefCell<Obj>>),
}

impl Value {
    /// Construct a heap string.
    pub fn new_str(s: impl Into<String>) -> Value {
        Value::Ref(Rc::new(RefCell::new(Obj::Str(s.into()))))
    }

    /// Construct a heap list.
    pub fn new_list(items: Vec<Value>) -> Value {
        Value::Ref(Rc::new(RefCell::new(Obj::List(items))))
    }

    /// Construct a heap map from insertion-ordered key/value pairs.
    pub fn new_map(entries: Vec<(Value, Value)>) -> Value {
        Value::Ref(Rc::new(RefCell::new(Obj::Map(entries))))
    }

    /// Construct a struct value of the given type on the heap.
    pub fn new_struct(ty: u32, fields: Vec<Value>) -> Value {
        Value::Ref(Rc::new(RefCell::new(Obj::Struct { ty, fields })))
    }

    /// Construct an enum value (e.g. `Result`/`Option`) on the heap.
    pub fn new_enum(ty: u32, variant: u16, fields: Vec<Value>) -> Value {
        Value::Ref(Rc::new(RefCell::new(Obj::Enum(EnumObj {
            ty,
            variant,
            fields,
        }))))
    }

    /// `Some(v)` / `None` constructors for the built-in `Option` type.
    pub fn some(v: Value) -> Value {
        Value::new_enum(TY_OPTION, TAG_SOME, vec![v])
    }
    pub fn none() -> Value {
        Value::new_enum(TY_OPTION, TAG_NONE, vec![])
    }
}

/// A heap-allocated object. Structs and closures arrive in later increments.
#[derive(Clone, Debug, PartialEq)]
pub enum Obj {
    /// UTF-8 text.
    Str(String),
    /// An ordered, growable sequence.
    List(Vec<Value>),
    /// A key/value store. Insertion-ordered; lookups are a linear scan keyed by
    /// structural equality (simple and dependency-free for the draft).
    Map(Vec<(Value, Value)>),
    /// A struct instance: its type id and field values (addressed by index).
    Struct {
        ty: u32,
        fields: Vec<Value>,
    },
    Enum(EnumObj),
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

// Fixed variant tags shared by all bytecode producers (docs/bytecode.md).
pub const TAG_OK: u16 = 0;
pub const TAG_ERR: u16 = 1;
pub const TAG_SOME: u16 = 0;
pub const TAG_NONE: u16 = 1;
