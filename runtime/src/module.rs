//! Compiled program structures the interpreter executes.
//!
//! A [`Module`] is the unit of execution; it owns a table of [`Function`]s and
//! a table of [`TypeDef`]s. See the container format in docs/bytecode.md.

use crate::instr::Instr;

/// A single function: its arity, frame size, and instruction stream.
#[derive(Clone, Debug, PartialEq)]
pub struct Function {
    pub name: String,
    /// Number of parameters. They occupy local slots `[0, param_count)`.
    pub param_count: u16,
    /// Total local slots, including parameters (`local_count >= param_count`).
    pub local_count: u16,
    pub code: Vec<Instr>,
}

impl Function {
    pub fn new(
        name: impl Into<String>,
        param_count: u16,
        local_count: u16,
        code: Vec<Instr>,
    ) -> Self {
        Self {
            name: name.into(),
            param_count,
            local_count,
            code,
        }
    }
}

/// A type-table entry. Currently describes a struct's layout; enum layouts will
/// join the table when enums migrate off their inline field counts (see
/// docs/bytecode.md). `struct.new <ty>` indexes [`Module::types`].
#[derive(Clone, Debug, PartialEq)]
pub struct TypeDef {
    pub name: String,
    /// Number of fields, popped by `struct.new` and addressed by `field.get`.
    pub field_count: u16,
}

impl TypeDef {
    pub fn new(name: impl Into<String>, field_count: u16) -> Self {
        Self {
            name: name.into(),
            field_count,
        }
    }
}

/// Struct and enum type ids occupy separate numeric spaces (struct ids index
/// `Module::types`; enum ids are the reserved Result/Option 0/1 plus sequential
/// user ids), so enum ids are offset by this bit in the dispatch table to keep
/// the `(ty, selector)` key unambiguous. The front-end emitter applies the same
/// offset (`enumDispatchBase` in the Dart bytecode layer).
pub const ENUM_DISPATCH_BASE: u32 = 1 << 31;

/// One row of the dynamic-dispatch table: the implementation of interface
/// method `selector` for the concrete type `ty` (a `Module::types` index for a
/// struct; `ENUM_DISPATCH_BASE | ty` for an enum) is `Module::functions[func]`.
/// `call.virtual <selector>` reads the receiver's type id and looks the target
/// up here. See docs/language.md ("Dynamic dispatch").
#[derive(Clone, Debug, PartialEq)]
pub struct DispatchEntry {
    pub ty: u32,
    pub selector: String,
    pub func: u32,
}

impl DispatchEntry {
    pub fn new(ty: u32, selector: impl Into<String>, func: u32) -> Self {
        Self {
            ty,
            selector: selector.into(),
            func,
        }
    }
}

/// A collection of functions and type definitions, each indexed by position.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Module {
    pub functions: Vec<Function>,
    pub types: Vec<TypeDef>,
    /// The virtual-dispatch table consulted by `call.virtual` (empty until the
    /// front-end emits interface dispatch).
    pub dispatch: Vec<DispatchEntry>,
    /// Number of module-global slots (top-level `let` bindings). The runtime
    /// allocates a vector this size before running the program-init thunk; both
    /// `global.get`/`global.set` index into it. See docs/bytecode.md.
    pub global_count: u32,
    /// The entry function (`main`), from the Entry section — so the runtime need
    /// not consult function names, which the Symbols section makes strippable.
    /// `None` when the module declares no entry (e.g. a library).
    pub entry: Option<u32>,
    /// The program-init thunk (`<init>`), from the Entry section. `None` when the
    /// module has no module-`let` initializers.
    pub init: Option<u32>,
}

impl Module {
    /// A module with no type definitions.
    pub fn new(functions: Vec<Function>) -> Self {
        Self {
            functions,
            types: Vec::new(),
            dispatch: Vec::new(),
            global_count: 0,
            entry: None,
            init: None,
        }
    }

    pub fn with_types(functions: Vec<Function>, types: Vec<TypeDef>) -> Self {
        Self {
            functions,
            types,
            dispatch: Vec::new(),
            global_count: 0,
            entry: None,
            init: None,
        }
    }

    /// Index of the function named `name`, if any.
    pub fn function_index(&self, name: &str) -> Option<usize> {
        self.functions.iter().position(|f| f.name == name)
    }

    /// The entry function index: the explicit Entry-section value, falling back
    /// to a `main` lookup by name (legacy modules, or before the Entry section
    /// existed). Names are still present by default, so the fallback works until
    /// the Symbols section is stripped.
    pub fn entry_index(&self) -> Option<usize> {
        self.entry
            .map(|i| i as usize)
            .or_else(|| self.function_index("main"))
    }

    /// The program-init thunk index: the explicit Entry-section value, falling
    /// back to a `<init>` lookup by name. Mirrors [`entry_index`](Self::entry_index).
    pub fn init_index(&self) -> Option<usize> {
        self.init
            .map(|i| i as usize)
            .or_else(|| self.function_index("<init>"))
    }

    /// The function implementing `selector` for type id `ty`, if any — the
    /// `call.virtual` lookup.
    pub fn dispatch_target(&self, ty: u32, selector: &str) -> Option<u32> {
        self.dispatch
            .iter()
            .find(|e| e.ty == ty && e.selector == selector)
            .map(|e| e.func)
    }
}
