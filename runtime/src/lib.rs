//! The Thera runtime: a Tier-0 bytecode interpreter (and, later, a Cranelift
//! JIT and GC). See docs/bytecode.md for the design.

pub mod builder;
pub mod codec;
pub mod disasm;
pub mod heap;
pub mod instr;
pub mod interp;
pub mod map;
pub mod module;
pub mod profile;
pub mod serialize;
pub mod value;
