//! The Hawk runtime: a Tier-0 bytecode interpreter (and, later, a Cranelift
//! JIT and GC). See docs/bytecode.md for the design.

pub mod builder;
pub mod disasm;
pub mod instr;
pub mod interp;
pub mod module;
pub mod value;
