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

/// A collection of functions and type definitions, each indexed by position.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Module {
    pub functions: Vec<Function>,
    pub types: Vec<TypeDef>,
}

impl Module {
    /// A module with no type definitions.
    pub fn new(functions: Vec<Function>) -> Self {
        Self {
            functions,
            types: Vec::new(),
        }
    }

    pub fn with_types(functions: Vec<Function>, types: Vec<TypeDef>) -> Self {
        Self { functions, types }
    }

    /// Index of the function named `name`, if any.
    pub fn function_index(&self, name: &str) -> Option<usize> {
        self.functions.iter().position(|f| f.name == name)
    }
}
