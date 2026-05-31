//! The in-memory instruction set.
//!
//! The draft interpreter runs this `enum` directly rather than a serialized
//! byte stream (see docs/bytecode.md, "Instruction encoding"). Opcode names
//! mirror the spec: `add.i64` → [`Instr::AddI64`], etc.
//!
//! Current subset (increments 1–6): constants (incl. strings), locals,
//! arithmetic, comparison, conversions, stack manipulation, direct `call`,
//! native `call`, enums (`enum.new`/`tag`/`get`), `list.new`, control flow
//! (`jump` family), and `return`. Most collection operations are native calls.
//! Closures and interface dispatch arrive later.

/// A local-slot index (parameters and locals share one array).
pub type Slot = u16;

/// A jump target: an **absolute index** into the function's instruction vec.
///
/// The spec (docs/bytecode.md) describes jumps as *relative byte offsets*; that
/// is a property of the serialized form. The in-memory `Instr` vec uses
/// absolute indices instead — simpler to hand-write and debug — and the future
/// byte decoder will resolve relative offsets into these at decode time.
pub type Addr = usize;

#[derive(Clone, Debug, PartialEq)]
pub enum Instr {
    // --- constants ---
    ConstInt(i64),
    ConstDouble(f64),
    ConstBool(bool),
    ConstUnit,
    /// Push a heap string. The serialized form references a constant-pool
    /// index; the in-memory form inlines the string (cf. [`Instr::ConstInt`]).
    ConstStr(String),

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

    // --- calls ---
    /// Direct call to `module.functions[func]`. Pops `argc` arguments
    /// (pushed left-to-right) into the callee's leading local slots and pushes
    /// the callee's return value.
    Call {
        func: u32,
        argc: u8,
    },
    /// Call a native (Rust-implemented) function by index. Pops `argc`
    /// arguments and pushes the result.
    CallNative {
        native: u32,
        argc: u8,
    },

    // --- enums (tagged unions: Result, Option, user enums) ---
    /// Pop `field_count` values (pushed left-to-right) and push a new enum
    /// value, tagged `variant` of type `ty`.
    ///
    /// `field_count` is an operand for now; once the module carries a type
    /// table it comes from the enum's TypeDef (see docs/bytecode.md).
    EnumNew {
        ty: u32,
        variant: u16,
        field_count: u8,
    },
    /// Pop an enum; push its variant tag as an `Int`.
    EnumTag,
    /// Pop an enum; push its payload field at `idx`.
    EnumGet(u16),

    // --- collections ---
    /// Pop `count` values (pushed left-to-right) and push a new list. Map/Set
    /// literals and other collection ops are native calls (docs/bytecode.md).
    ListNew {
        count: u32,
    },

    // --- control ---
    /// Unconditionally continue execution at the given instruction.
    Jump(Addr),
    /// Pop a `Bool`; jump if it is `true`, otherwise fall through.
    JumpIfTrue(Addr),
    /// Pop a `Bool`; jump if it is `false`, otherwise fall through.
    JumpIfFalse(Addr),
    /// Return the top operand-stack slot (or `Unit` if the stack is empty).
    Return,
}
