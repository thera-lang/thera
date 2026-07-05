//! The in-memory instruction set.
//!
//! The draft interpreter runs this `enum` directly rather than a serialized
//! byte stream (see docs/bytecode.md, "Instruction encoding"). Opcode names
//! mirror the spec: `add.i64` → [`Instr::AddI64`], etc.
//!
//! Current subset: constants (incl. strings), locals, arithmetic, comparison,
//! conversions, stack manipulation, direct `call`, native `call`, indirect
//! `call.indirect`, enums (`enum.new`/`tag`/`get`), structs
//! (`struct.new`/`field.get`/`field.set`), `list.new`, `closure.new`, control
//! flow (`jump` family), `return`, and dynamic dispatch (`call.virtual`). Most
//! collection operations are native calls.

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

    // --- module globals (top-level `let`; see docs/bytecode.md) ---
    /// Push the module global at `idx`. A plain slot read — init order is fixed
    /// at link time, so there is no "is it initialized yet" guard.
    GlobalGet(u32),
    /// Pop into the module global at `idx`. Only emitted inside the program-init
    /// thunk (the reserved `<init>` function), which runs once before the entry.
    GlobalSet(u32),

    // --- integer arithmetic (wrapping; see docs/bytecode.md) ---
    AddI64,
    SubI64,
    MulI64,
    /// Traps on a zero divisor; otherwise truncates toward zero.
    DivI64,
    /// Traps on a zero divisor.
    ModI64,
    NegI64,

    // --- integer bitwise (on the two's-complement i64) ---
    AndI64,
    OrI64,
    XorI64,
    /// Bitwise complement (unary).
    BNotI64,
    /// Left shift; shift amount masked to 0..=63.
    ShlI64,
    /// Arithmetic (sign-preserving) right shift; amount masked to 0..=63.
    ShrI64,
    /// Logical (zero-fill) right shift; amount masked to 0..=63.
    UShrI64,

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
    /// Call a closure/function value. Pops `argc` arguments (pushed
    /// left-to-right) and, beneath them, the closure value; the callee's frame
    /// is `[captures..., args...]`. Pushes the return value.
    CallIndirect {
        argc: u8,
    },
    /// Dynamic dispatch: call the implementation of `selector` for the
    /// receiver's concrete type. Pops `argc` arguments (pushed left-to-right);
    /// the first is the receiver, whose type id selects the target function via
    /// the module's dispatch table (see [`crate::module::DispatchEntry`]).
    /// Pushes the return value. The serialized form references `selector` by
    /// constant-pool index; the in-memory form inlines it (cf. [`Instr::ConstStr`]).
    CallVirtual {
        selector: String,
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

    // --- structs ---
    /// Pop the fields (pushed left-to-right) and push a new struct of type
    /// `ty`. The field count comes from `module.types[ty]`.
    StructNew {
        ty: u32,
    },
    /// Pop a struct; push its field at `idx`.
    FieldGet(u16),
    /// Pop a struct and a value (`struct value →`) and store the value into
    /// field `idx`. For `mut` fields.
    FieldSet(u16),

    // --- collections ---
    /// Pop `count` values (pushed left-to-right) and push a new list. Map/Set
    /// literals and keyed lookups are native calls (docs/bytecode.md).
    ListNew {
        count: u32,
    },
    /// Pop an index (`Int`) and a list (`list index →`); push the element at
    /// `index`, trapping if out of range. The faulting `list[i]` read — a
    /// primitive (cf. `FieldGet`) so the JIT can lower it inline. Map indexing
    /// stays a native (a keyed lookup, not an O(1) slot load).
    ListGet,
    /// Pop a value, an index (`Int`), and a list (`list index value →`); store
    /// the value at `index`, trapping if out of range. Pushes nothing (like
    /// `FieldSet`). The `list[i] = v` write.
    ListSet,
    /// Pop a list; push its length as an `Int`. The `list.len()` read, lowered to
    /// a primitive (cf. `ListGet`) rather than a `call.native` — it is by far the
    /// hottest native (every `for x in list` re-checks it each iteration), and the
    /// native round-trip (dispatch + a heap thread-local + the GC/park checks)
    /// dwarfs the O(1) length read itself.
    ListLen,

    // --- closures ---
    /// Pop `captures` values (pushed left-to-right) and push a closure value
    /// `{ func, captures }`. The captures become the lifted function's leading
    /// local slots when the closure is later called via `call.indirect`.
    ClosureNew {
        func: u32,
        captures: u8,
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
