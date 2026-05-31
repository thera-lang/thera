//! The in-memory instruction set.
//!
//! The draft interpreter runs this `enum` directly rather than a serialized
//! byte stream (see docs/bytecode.md, "Instruction encoding"). Opcode names
//! mirror the spec: `add.i64` → [`Instr::AddI64`], etc.
//!
//! This is the increment-1 subset: constants, locals, arithmetic, comparison,
//! conversions, stack manipulation, and `return`. Control flow, calls, enums,
//! and intrinsics are added in later increments.

/// A local-slot index (parameters and locals share one array).
pub type Slot = u16;

#[derive(Clone, Debug, PartialEq)]
pub enum Instr {
    // --- constants ---
    ConstInt(i64),
    ConstDouble(f64),
    ConstBool(bool),
    ConstUnit,

    // --- locals ---
    /// Push `locals[slot]`.
    Load(Slot),
    /// Pop into `locals[slot]`.
    Store(Slot),

    // --- integer arithmetic (wrapping; see docs/bytecode.md) ---
    AddI64,
    SubI64,
    MulI64,
    /// Traps on a zero divisor; otherwise truncates toward zero.
    DivI64,
    /// Traps on a zero divisor.
    ModI64,
    NegI64,

    // --- float arithmetic ---
    AddF64,
    SubF64,
    MulF64,
    DivF64,
    NegF64,

    // --- integer comparison (→ Bool) ---
    EqI64,
    NeI64,
    LtI64,
    LeI64,
    GtI64,
    GeI64,

    // --- float comparison (→ Bool) ---
    EqF64,
    NeF64,
    LtF64,
    LeF64,
    GtF64,
    GeF64,

    // --- boolean ---
    Not,

    // --- conversions ---
    I64ToF64,
    F64ToI64,

    // --- stack manipulation ---
    Pop,
    Dup,

    // --- control ---
    /// Return the top operand-stack slot (or `Unit` if the stack is empty).
    Return,
}
