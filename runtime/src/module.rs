//! Compiled program structures the interpreter executes.
//!
//! A [`Module`] is the unit of execution; it owns a table of [`Function`]s.
//! This is the increment-3 subset of the container format in docs/bytecode.md —
//! the constant pool and type table arrive with later increments.

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

/// A collection of functions, indexed by position in [`Module::functions`].
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Module {
    pub functions: Vec<Function>,
}

impl Module {
    pub fn new(functions: Vec<Function>) -> Self {
        Self { functions }
    }
}
