//! Runtime values for the Tier-0 interpreter.
//!
//! Per docs/bytecode.md ("The first interpreter"), the draft uses a *tagged*
//! `Value` — simpler to build and debug than the untagged 64-bit slots of the
//! durable format. Heap-backed values (String, collections, structs, enums,
//! closures) arrive in a later increment.

/// A value on the operand stack or in a local slot.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Int(i64),
    Double(f64),
    Bool(bool),
    /// The unit value (`Void` / `()`). A `Void` function returns this, so every
    /// call yields exactly one stack value.
    Unit,
}
