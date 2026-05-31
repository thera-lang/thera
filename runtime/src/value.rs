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

    /// Construct an enum value (e.g. `Result`/`Option`) on the heap.
    pub fn new_enum(ty: u32, variant: u16, fields: Vec<Value>) -> Value {
        Value::Ref(Rc::new(RefCell::new(Obj::Enum(EnumObj {
            ty,
            variant,
            fields,
        }))))
    }
}

/// A heap-allocated object. Strings and enums exist so far; collections,
/// structs, and closures arrive in later increments.
#[derive(Clone, Debug, PartialEq)]
pub enum Obj {
    /// UTF-8 text.
    Str(String),
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

// Fixed variant tags shared by all bytecode producers (docs/bytecode.md).
pub const TAG_OK: u16 = 0;
pub const TAG_ERR: u16 = 1;
pub const TAG_SOME: u16 = 0;
pub const TAG_NONE: u16 = 1;
