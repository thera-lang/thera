//! A small assembler for building [`Function`]s by hand.
//!
//! Hand-writing `Vec<Instr>` has two sharp edges: jump targets are absolute
//! instruction indices (brittle when you insert or remove an instruction), and
//! `local_count` must be counted by hand. [`FnBuilder`] fixes both — jumps
//! reference [`Label`]s that are resolved to addresses at [`FnBuilder::finish`],
//! and `local_count` is tracked from the slots that `load`/`store` touch.
//!
//! This is developer tooling (tests, demos, and eventually a textual assembly
//! format); it is also the shape the Hawk front-end's emit step will take.

use crate::instr::{Addr, Instr, Slot};
use crate::module::Function;

/// A position in the instruction stream, created by [`FnBuilder::label`] and
/// fixed with [`FnBuilder::bind`]. A label may be referenced before it is bound
/// (forward jumps) and by several jumps; it must be bound exactly once.
#[derive(Clone, Copy, Debug)]
pub struct Label(usize);

pub struct FnBuilder {
    name: String,
    param_count: u16,
    local_count: u16,
    code: Vec<Instr>,
    /// `label_addrs[id]` is the bound address of label `id`, or `None`.
    label_addrs: Vec<Option<Addr>>,
    /// `(code index of a jump, label id it targets)`, resolved at `finish`.
    fixups: Vec<(usize, usize)>,
}

impl FnBuilder {
    /// Start a function with `param_count` parameters. `local_count` starts at
    /// `param_count` and grows as `load`/`store` reference higher slots.
    pub fn new(name: impl Into<String>, param_count: u16) -> Self {
        Self {
            name: name.into(),
            param_count,
            local_count: param_count,
            code: Vec::new(),
            label_addrs: Vec::new(),
            fixups: Vec::new(),
        }
    }

    /// Resolve all label references and produce the [`Function`].
    ///
    /// Panics if a referenced label was never bound — a bug in the calling
    /// (test/dev) code, surfaced loudly rather than silently miscompiled.
    pub fn finish(mut self) -> Function {
        for (code_idx, label_id) in &self.fixups {
            let addr = self.label_addrs[*label_id].unwrap_or_else(|| {
                panic!("FnBuilder: label {label_id} referenced but never bound")
            });
            match &mut self.code[*code_idx] {
                Instr::Jump(t) | Instr::JumpIfTrue(t) | Instr::JumpIfFalse(t) => *t = addr,
                other => panic!("FnBuilder: fixup target is not a jump: {other:?}"),
            }
        }
        Function::new(self.name, self.param_count, self.local_count, self.code)
    }

    // --- labels ---

    /// Create a fresh, unbound label.
    pub fn label(&mut self) -> Label {
        let id = self.label_addrs.len();
        self.label_addrs.push(None);
        Label(id)
    }

    /// Bind `label` to the current position (the next instruction emitted).
    pub fn bind(&mut self, label: Label) -> &mut Self {
        let here = self.code.len();
        let slot = &mut self.label_addrs[label.0];
        assert!(slot.is_none(), "FnBuilder: label {} bound twice", label.0);
        *slot = Some(here);
        self
    }

    // --- emit helpers ---

    fn emit(&mut self, i: Instr) -> &mut Self {
        self.code.push(i);
        self
    }

    fn emit_jump(&mut self, i: Instr, target: Label) -> &mut Self {
        self.fixups.push((self.code.len(), target.0));
        self.emit(i)
    }

    fn bump_locals(&mut self, slot: Slot) {
        self.local_count = self.local_count.max(slot.saturating_add(1));
    }

    // --- constants ---
    pub fn const_int(&mut self, n: i64) -> &mut Self {
        self.emit(Instr::ConstInt(n))
    }
    pub fn const_double(&mut self, x: f64) -> &mut Self {
        self.emit(Instr::ConstDouble(x))
    }
    pub fn const_bool(&mut self, b: bool) -> &mut Self {
        self.emit(Instr::ConstBool(b))
    }
    pub fn const_unit(&mut self) -> &mut Self {
        self.emit(Instr::ConstUnit)
    }
    pub fn const_str(&mut self, s: impl Into<String>) -> &mut Self {
        self.emit(Instr::ConstStr(s.into()))
    }

    // --- locals ---
    pub fn load(&mut self, slot: Slot) -> &mut Self {
        self.bump_locals(slot);
        self.emit(Instr::Load(slot))
    }
    pub fn store(&mut self, slot: Slot) -> &mut Self {
        self.bump_locals(slot);
        self.emit(Instr::Store(slot))
    }

    // --- integer arithmetic ---
    pub fn add_i64(&mut self) -> &mut Self {
        self.emit(Instr::AddI64)
    }
    pub fn sub_i64(&mut self) -> &mut Self {
        self.emit(Instr::SubI64)
    }
    pub fn mul_i64(&mut self) -> &mut Self {
        self.emit(Instr::MulI64)
    }
    pub fn div_i64(&mut self) -> &mut Self {
        self.emit(Instr::DivI64)
    }
    pub fn mod_i64(&mut self) -> &mut Self {
        self.emit(Instr::ModI64)
    }
    pub fn neg_i64(&mut self) -> &mut Self {
        self.emit(Instr::NegI64)
    }

    // --- float arithmetic ---
    pub fn add_f64(&mut self) -> &mut Self {
        self.emit(Instr::AddF64)
    }
    pub fn sub_f64(&mut self) -> &mut Self {
        self.emit(Instr::SubF64)
    }
    pub fn mul_f64(&mut self) -> &mut Self {
        self.emit(Instr::MulF64)
    }
    pub fn div_f64(&mut self) -> &mut Self {
        self.emit(Instr::DivF64)
    }
    pub fn neg_f64(&mut self) -> &mut Self {
        self.emit(Instr::NegF64)
    }

    // --- integer comparison ---
    pub fn eq_i64(&mut self) -> &mut Self {
        self.emit(Instr::EqI64)
    }
    pub fn ne_i64(&mut self) -> &mut Self {
        self.emit(Instr::NeI64)
    }
    pub fn lt_i64(&mut self) -> &mut Self {
        self.emit(Instr::LtI64)
    }
    pub fn le_i64(&mut self) -> &mut Self {
        self.emit(Instr::LeI64)
    }
    pub fn gt_i64(&mut self) -> &mut Self {
        self.emit(Instr::GtI64)
    }
    pub fn ge_i64(&mut self) -> &mut Self {
        self.emit(Instr::GeI64)
    }

    // --- float comparison ---
    pub fn eq_f64(&mut self) -> &mut Self {
        self.emit(Instr::EqF64)
    }
    pub fn ne_f64(&mut self) -> &mut Self {
        self.emit(Instr::NeF64)
    }
    pub fn lt_f64(&mut self) -> &mut Self {
        self.emit(Instr::LtF64)
    }
    pub fn le_f64(&mut self) -> &mut Self {
        self.emit(Instr::LeF64)
    }
    pub fn gt_f64(&mut self) -> &mut Self {
        self.emit(Instr::GtF64)
    }
    pub fn ge_f64(&mut self) -> &mut Self {
        self.emit(Instr::GeF64)
    }

    // --- boolean & conversions ---
    pub fn not(&mut self) -> &mut Self {
        self.emit(Instr::Not)
    }
    pub fn i64_to_f64(&mut self) -> &mut Self {
        self.emit(Instr::I64ToF64)
    }
    pub fn f64_to_i64(&mut self) -> &mut Self {
        self.emit(Instr::F64ToI64)
    }

    // --- stack manipulation ---
    pub fn pop(&mut self) -> &mut Self {
        self.emit(Instr::Pop)
    }
    pub fn dup(&mut self) -> &mut Self {
        self.emit(Instr::Dup)
    }

    // --- calls ---
    pub fn call(&mut self, func: u32, argc: u8) -> &mut Self {
        self.emit(Instr::Call { func, argc })
    }
    pub fn call_native(&mut self, native: u32, argc: u8) -> &mut Self {
        self.emit(Instr::CallNative { native, argc })
    }

    // --- enums ---
    pub fn enum_new(&mut self, ty: u32, variant: u16, field_count: u8) -> &mut Self {
        self.emit(Instr::EnumNew {
            ty,
            variant,
            field_count,
        })
    }
    pub fn enum_tag(&mut self) -> &mut Self {
        self.emit(Instr::EnumTag)
    }
    pub fn enum_get(&mut self, idx: u16) -> &mut Self {
        self.emit(Instr::EnumGet(idx))
    }

    // --- control ---
    pub fn jump(&mut self, target: Label) -> &mut Self {
        self.emit_jump(Instr::Jump(0), target)
    }
    pub fn jump_if_true(&mut self, target: Label) -> &mut Self {
        self.emit_jump(Instr::JumpIfTrue(0), target)
    }
    pub fn jump_if_false(&mut self, target: Label) -> &mut Self {
        self.emit_jump(Instr::JumpIfFalse(0), target)
    }
    pub fn ret(&mut self) -> &mut Self {
        self.emit(Instr::Return)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interp::run;
    use crate::module::Module;
    use crate::value::Value;

    #[test]
    fn labels_resolve_forward_and_backward() {
        // max(a, b): if a < b { b } else { a }
        let mut b = FnBuilder::new("max", 2);
        let else_ = b.label();
        b.load(0);
        b.load(1);
        b.lt_i64();
        b.jump_if_false(else_);
        b.load(1); // a < b → b
        b.ret();
        b.bind(else_);
        b.load(0); // else → a
        b.ret();
        let module = Module::new(vec![b.finish()]);

        assert_eq!(
            run(&module, 0, &[Value::Int(3), Value::Int(7)]),
            Ok(Value::Int(7))
        );
        assert_eq!(
            run(&module, 0, &[Value::Int(9), Value::Int(2)]),
            Ok(Value::Int(9))
        );
    }

    #[test]
    fn local_count_tracks_highest_slot() {
        // Uses slot 3 as scratch though there are no params.
        let mut b = FnBuilder::new("f", 0);
        b.const_int(5);
        b.store(3);
        b.load(3);
        b.ret();
        let f = b.finish();
        assert_eq!(f.local_count, 4); // slots 0..=3
        assert_eq!(f.param_count, 0);
    }

    #[test]
    fn backward_jump_loop() {
        // sum 0..5 via a builder loop  → 10
        let mut b = FnBuilder::new("sum", 0);
        let head = b.label();
        let done = b.label();
        b.const_int(0);
        b.store(1); // sum
        b.const_int(0);
        b.store(0); // i
        b.bind(head);
        b.load(0);
        b.const_int(5);
        b.lt_i64();
        b.jump_if_false(done);
        b.load(1);
        b.load(0);
        b.add_i64();
        b.store(1);
        b.load(0);
        b.const_int(1);
        b.add_i64();
        b.store(0);
        b.jump(head);
        b.bind(done);
        b.load(1);
        b.ret();
        let module = Module::new(vec![b.finish()]);
        assert_eq!(run(&module, 0, &[]), Ok(Value::Int(10)));
    }

    #[test]
    #[should_panic(expected = "never bound")]
    fn unbound_label_panics() {
        let mut b = FnBuilder::new("bad", 0);
        let target = b.label();
        b.jump(target); // never bound
        let _ = b.finish();
    }
}
