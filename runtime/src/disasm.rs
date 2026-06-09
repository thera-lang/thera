//! A textual disassembler for [`Module`]s — a debugging aid and, later, the
//! readable oracle for verifying the serialized format round-trips.

use std::fmt::Write as _;

use crate::instr::Instr;
use crate::module::Module;

/// Width of the mnemonic column before operands.
const MNEMONIC_WIDTH: usize = 14;

/// Render every function in `module`.
pub fn disassemble(module: &Module) -> String {
    let mut s = String::new();
    for i in 0..module.functions.len() {
        if i > 0 {
            s.push('\n');
        }
        s.push_str(&disassemble_function(module, i));
    }
    s
}

/// Render a single function (by index, so `call` targets resolve to names).
pub fn disassemble_function(module: &Module, index: usize) -> String {
    let f = &module.functions[index];
    let mut s = format!(
        "fn {}  (params={}, locals={})\n",
        f.name, f.param_count, f.local_count
    );
    for (pc, instr) in f.code.iter().enumerate() {
        // writing to a String is infallible
        let _ = writeln!(s, "  {pc:04}  {}", fmt_instr(instr, module));
    }
    s
}

fn fmt_instr(instr: &Instr, module: &Module) -> String {
    // mnemonic + operand text; bare mnemonics carry no operand.
    let with = |mnemonic: &str, operand: String| format!("{mnemonic:<MNEMONIC_WIDTH$}{operand}");

    match instr {
        Instr::ConstInt(n) => with("const.i64", n.to_string()),
        Instr::ConstDouble(x) => with("const.f64", x.to_string()),
        Instr::ConstBool(b) => with("const.bool", b.to_string()),
        Instr::ConstUnit => "const.unit".to_string(),
        Instr::ConstStr(s) => with("const.str", format!("{s:?}")),

        Instr::Load(slot) => with("load", slot.to_string()),
        Instr::Store(slot) => with("store", slot.to_string()),

        Instr::AddI64 => "add.i64".to_string(),
        Instr::SubI64 => "sub.i64".to_string(),
        Instr::MulI64 => "mul.i64".to_string(),
        Instr::DivI64 => "div.i64".to_string(),
        Instr::ModI64 => "mod.i64".to_string(),
        Instr::NegI64 => "neg.i64".to_string(),

        Instr::AddF64 => "add.f64".to_string(),
        Instr::SubF64 => "sub.f64".to_string(),
        Instr::MulF64 => "mul.f64".to_string(),
        Instr::DivF64 => "div.f64".to_string(),
        Instr::NegF64 => "neg.f64".to_string(),

        Instr::EqI64 => "eq.i64".to_string(),
        Instr::NeI64 => "ne.i64".to_string(),
        Instr::LtI64 => "lt.i64".to_string(),
        Instr::LeI64 => "le.i64".to_string(),
        Instr::GtI64 => "gt.i64".to_string(),
        Instr::GeI64 => "ge.i64".to_string(),

        Instr::EqF64 => "eq.f64".to_string(),
        Instr::NeF64 => "ne.f64".to_string(),
        Instr::LtF64 => "lt.f64".to_string(),
        Instr::LeF64 => "le.f64".to_string(),
        Instr::GtF64 => "gt.f64".to_string(),
        Instr::GeF64 => "ge.f64".to_string(),

        Instr::Not => "not".to_string(),
        Instr::I64ToF64 => "i64.to_f64".to_string(),
        Instr::F64ToI64 => "f64.to_i64".to_string(),

        Instr::Pop => "pop".to_string(),
        Instr::Dup => "dup".to_string(),

        Instr::Call { func, argc } => {
            let name = module
                .functions
                .get(*func as usize)
                .map_or("?", |f| f.name.as_str());
            with("call", format!("fn#{func} {name}, argc={argc}"))
        }
        Instr::CallNative { native, argc } => {
            with("call.native", format!("native#{native}, argc={argc}"))
        }
        Instr::CallIndirect { argc } => with("call.indirect", format!("argc={argc}")),
        Instr::CallVirtual { selector, argc } => {
            with("call.virtual", format!("{selector}, argc={argc}"))
        }

        Instr::EnumNew {
            ty,
            variant,
            field_count,
        } => with(
            "enum.new",
            format!("ty={ty}, variant={variant}, fields={field_count}"),
        ),
        Instr::EnumTag => "enum.tag".to_string(),
        Instr::EnumGet(idx) => with("enum.get", idx.to_string()),

        Instr::StructNew { ty } => {
            let name = module
                .types
                .get(*ty as usize)
                .map_or("?", |t| t.name.as_str());
            with("struct.new", format!("ty={ty} {name}"))
        }
        Instr::FieldGet(idx) => with("field.get", idx.to_string()),
        Instr::FieldSet(idx) => with("field.set", idx.to_string()),

        Instr::ListNew { count } => with("list.new", count.to_string()),

        Instr::ClosureNew { func, captures } => {
            let name = module
                .functions
                .get(*func as usize)
                .map_or("?", |f| f.name.as_str());
            with(
                "closure.new",
                format!("fn#{func} {name}, captures={captures}"),
            )
        }

        Instr::Jump(t) => with("jump", format!("-> {t:04}")),
        Instr::JumpIfTrue(t) => with("jump_if_true", format!("-> {t:04}")),
        Instr::JumpIfFalse(t) => with("jump_if_false", format!("-> {t:04}")),
        Instr::Return => "return".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::builder::FnBuilder;
    use crate::module::{Function, Module};

    fn factorial_module() -> Module {
        let mut b = FnBuilder::new("fact", 1);
        let recurse = b.label();
        b.load(0);
        b.const_int(1);
        b.le_i64();
        b.jump_if_false(recurse);
        b.const_int(1);
        b.ret();
        b.bind(recurse);
        b.load(0);
        b.load(0);
        b.const_int(1);
        b.sub_i64();
        b.call(0, 1);
        b.mul_i64();
        b.ret();
        Module::new(vec![b.finish()])
    }

    /// Compare with whitespace runs collapsed, so the test is robust to the
    /// exact column widths while still pinning content and order.
    fn normalized(s: &str) -> String {
        s.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn disassembles_factorial() {
        let text = disassemble(&factorial_module());
        let norm = normalized(&text);

        assert!(norm.contains("fn fact (params=1, locals=1)"));
        assert!(norm.contains("0000 load 0"));
        assert!(norm.contains("0002 le.i64"));
        assert!(norm.contains("0003 jump_if_false -> 0006"));
        assert!(norm.contains("0010 call fn#0 fact, argc=1"));
        assert!(norm.contains("0012 return"));
    }

    #[test]
    fn header_and_line_count() {
        let text = disassemble(&factorial_module());
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], "fn fact  (params=1, locals=1)");
        // header + 13 instructions
        assert_eq!(lines.len(), 14);
    }

    #[test]
    fn disassembles_closure_ops() {
        // A `closure.new` of `adder` plus an indirect call.
        let adder = Function::new("adder", 2, 2, vec![Instr::Return]);
        let main = Function::new(
            "main",
            0,
            0,
            vec![
                Instr::ConstInt(10),
                Instr::ClosureNew {
                    func: 1,
                    captures: 1,
                },
                Instr::ConstInt(5),
                Instr::CallIndirect { argc: 1 },
                Instr::Return,
            ],
        );
        let norm = normalized(&disassemble(&Module::new(vec![main, adder])));
        assert!(norm.contains("closure.new fn#1 adder, captures=1"));
        assert!(norm.contains("call.indirect argc=1"));
    }
}
