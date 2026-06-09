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

/// One row of the dynamic-dispatch table: the implementation of interface
/// method `selector` for the concrete type `ty` (a `Module::types` index for
/// structs/enums) is `Module::functions[func]`. `call.virtual <selector>` reads
/// the receiver's type id and looks the target up here. See docs/interfaces.md
/// ("Dynamic dispatch").
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
}

impl Module {
    /// A module with no type definitions.
    pub fn new(functions: Vec<Function>) -> Self {
        Self {
            functions,
            types: Vec::new(),
            dispatch: Vec::new(),
        }
    }

    pub fn with_types(functions: Vec<Function>, types: Vec<TypeDef>) -> Self {
        Self {
            functions,
            types,
            dispatch: Vec::new(),
        }
    }

    /// Index of the function named `name`, if any.
    pub fn function_index(&self, name: &str) -> Option<usize> {
        self.functions.iter().position(|f| f.name == name)
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
