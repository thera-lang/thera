//! The Tier-0 evaluator.
//!
//! [`exec`] runs a single function's instruction stream against a locals array,
//! maintaining an operand stack, until a [`Instr::Return`]. A `pc` (program
//! counter) indexes the instruction vec; the `jump` family redirects it.
//!
//! Calls use native Rust recursion: [`Instr::Call`] resolves the callee in the
//! [`Module`] and re-enters [`exec`]. An explicit frame stack will replace this
//! when fibers need to pause and resume frames; for the draft, recursion is the
//! simplest thing that works.

use std::io::Write;

use crate::instr::Instr;
use crate::module::Module;
use crate::value::{Obj, Value};

/// A runtime fault that aborts execution (see docs/language.md, "Runtime
/// faults"). Variants that describe malformed bytecode ([`Trap::Bug`]) indicate
/// a producer error rather than a program-level fault; valid bytecode never
/// raises them.
#[derive(Clone, Debug, PartialEq)]
pub enum Trap {
    /// Integer or float division/modulo by zero.
    DivByZero,
    /// List index outside `0..len` (the faulting case of `list[i]`).
    IndexOutOfBounds { index: i64, len: usize },
    /// Map indexed with `map[key]` where `key` is absent.
    MissingKey,
    /// The bytecode was malformed (stack underflow, type mismatch, bad slot).
    /// Valid bytecode from a correct producer never triggers this.
    Bug(String),
}

pub(crate) fn bug(msg: impl Into<String>) -> Trap {
    Trap::Bug(msg.into())
}

mod natives;
pub use natives::{
    NATIVE_LIST_GET, NATIVE_LIST_INDEX, NATIVE_LIST_LEN, NATIVE_LIST_SET, NATIVE_MAP_GET,
    NATIVE_MAP_HAS, NATIVE_MAP_INDEX, NATIVE_MAP_LEN, NATIVE_MAP_NEW, NATIVE_MAP_SET, NATIVE_PRINT,
    NATIVE_PRINTLN, NATIVE_STR_CONCAT, NATIVE_STRINGIFY, NativeFn, default_natives, native_index,
    native_name,
};

/// The interpreter's execution context: where output goes and what native
/// functions are available. Later increments grow this with the heap/GC and the
/// fiber scheduler.
pub struct Vm<'a> {
    out: &'a mut dyn Write,
    natives: Vec<NativeFn>,
}

/// Run `module`'s function at index `func` with `args`, writing output to
/// stdout. Convenience over [`Vm`].
pub fn run(module: &Module, func: usize, args: &[Value]) -> Result<Value, Trap> {
    let mut out = std::io::stdout();
    Vm::new(&mut out).run(module, func, args)
}

/// Evaluate a bare instruction stream with no enclosing module (so `call` is
/// unavailable) and discard output. A convenience for testing snippets.
pub fn eval(code: &[Instr], locals: &mut [Value]) -> Result<Value, Trap> {
    let module = Module::default();
    let mut sink = std::io::sink();
    Vm::new(&mut sink).exec(&module, code, locals)
}

impl<'a> Vm<'a> {
    /// Create a VM that writes output to `out`, with the default native table.
    pub fn new(out: &'a mut dyn Write) -> Self {
        Self {
            out,
            natives: default_natives(),
        }
    }

    /// Run `module`'s function at index `func` with `args`.
    pub fn run(&mut self, module: &Module, func: usize, args: &[Value]) -> Result<Value, Trap> {
        self.call(module, func, args.to_vec())
    }

    /// Build a frame for `module.functions[func]`, placing `args` in its leading
    /// local slots, and execute it.
    fn call(&mut self, module: &Module, func: usize, args: Vec<Value>) -> Result<Value, Trap> {
        let f = module
            .functions
            .get(func)
            .ok_or_else(|| bug(format!("call: no function at index {func}")))?;
        if args.len() != f.param_count as usize {
            return Err(bug(format!(
                "call: function '{}' expects {} args, got {}",
                f.name,
                f.param_count,
                args.len()
            )));
        }
        // args already hold arg0..argN in pushed order, which is exactly
        // locals[0..param_count]; pad the rest of the frame with Unit.
        let mut locals = args;
        locals.resize(f.local_count as usize, Value::Unit);
        self.exec(module, &f.code, &mut locals)
    }

    /// Execute `code` against `locals`, resolving any `call` in `module`.
    fn exec(
        &mut self,
        module: &Module,
        code: &[Instr],
        locals: &mut [Value],
    ) -> Result<Value, Trap> {
        let mut stack: Vec<Value> = Vec::new();
        let mut pc = 0usize;

        loop {
            let instr = code
                .get(pc)
                .ok_or_else(|| bug("pc ran off the end of the instruction stream"))?;

            match instr {
                // --- constants ---
                Instr::ConstInt(n) => stack.push(Value::Int(*n)),
                Instr::ConstDouble(x) => stack.push(Value::Double(*x)),
                Instr::ConstBool(b) => stack.push(Value::Bool(*b)),
                Instr::ConstUnit => stack.push(Value::Unit),
                Instr::ConstStr(s) => stack.push(Value::new_str(s.clone())),

                // --- locals ---
                Instr::Load(slot) => {
                    let v = locals
                        .get(*slot as usize)
                        .ok_or_else(|| bug(format!("load: slot {slot} out of range")))?
                        .clone();
                    stack.push(v);
                }
                Instr::Store(slot) => {
                    let v = pop(&mut stack)?;
                    *locals
                        .get_mut(*slot as usize)
                        .ok_or_else(|| bug(format!("store: slot {slot} out of range")))? = v;
                }

                // --- integer arithmetic (wrapping) ---
                Instr::AddI64 => {
                    let (a, b) = pop_two_int(&mut stack)?;
                    stack.push(Value::Int(a.wrapping_add(b)));
                }
                Instr::SubI64 => {
                    let (a, b) = pop_two_int(&mut stack)?;
                    stack.push(Value::Int(a.wrapping_sub(b)));
                }
                Instr::MulI64 => {
                    let (a, b) = pop_two_int(&mut stack)?;
                    stack.push(Value::Int(a.wrapping_mul(b)));
                }
                Instr::DivI64 => {
                    let (a, b) = pop_two_int(&mut stack)?;
                    if b == 0 {
                        return Err(Trap::DivByZero);
                    }
                    stack.push(Value::Int(a.wrapping_div(b)));
                }
                Instr::ModI64 => {
                    let (a, b) = pop_two_int(&mut stack)?;
                    if b == 0 {
                        return Err(Trap::DivByZero);
                    }
                    stack.push(Value::Int(a.wrapping_rem(b)));
                }
                Instr::NegI64 => {
                    let a = pop_int(&mut stack)?;
                    stack.push(Value::Int(a.wrapping_neg()));
                }

                // --- float arithmetic ---
                Instr::AddF64 => {
                    let (a, b) = pop_two_double(&mut stack)?;
                    stack.push(Value::Double(a + b));
                }
                Instr::SubF64 => {
                    let (a, b) = pop_two_double(&mut stack)?;
                    stack.push(Value::Double(a - b));
                }
                Instr::MulF64 => {
                    let (a, b) = pop_two_double(&mut stack)?;
                    stack.push(Value::Double(a * b));
                }
                Instr::DivF64 => {
                    let (a, b) = pop_two_double(&mut stack)?;
                    stack.push(Value::Double(a / b));
                }
                Instr::NegF64 => {
                    let a = pop_double(&mut stack)?;
                    stack.push(Value::Double(-a));
                }

                // --- integer comparison ---
                Instr::EqI64 => cmp_int(&mut stack, |a, b| a == b)?,
                Instr::NeI64 => cmp_int(&mut stack, |a, b| a != b)?,
                Instr::LtI64 => cmp_int(&mut stack, |a, b| a < b)?,
                Instr::LeI64 => cmp_int(&mut stack, |a, b| a <= b)?,
                Instr::GtI64 => cmp_int(&mut stack, |a, b| a > b)?,
                Instr::GeI64 => cmp_int(&mut stack, |a, b| a >= b)?,

                // --- float comparison ---
                Instr::EqF64 => cmp_double(&mut stack, |a, b| a == b)?,
                Instr::NeF64 => cmp_double(&mut stack, |a, b| a != b)?,
                Instr::LtF64 => cmp_double(&mut stack, |a, b| a < b)?,
                Instr::LeF64 => cmp_double(&mut stack, |a, b| a <= b)?,
                Instr::GtF64 => cmp_double(&mut stack, |a, b| a > b)?,
                Instr::GeF64 => cmp_double(&mut stack, |a, b| a >= b)?,

                // --- boolean ---
                Instr::Not => {
                    let b = pop_bool(&mut stack)?;
                    stack.push(Value::Bool(!b));
                }

                // --- conversions ---
                Instr::I64ToF64 => {
                    let a = pop_int(&mut stack)?;
                    stack.push(Value::Double(a as f64));
                }
                Instr::F64ToI64 => {
                    let a = pop_double(&mut stack)?;
                    stack.push(Value::Int(a as i64));
                }

                // --- stack manipulation ---
                Instr::Pop => {
                    pop(&mut stack)?;
                }
                Instr::Dup => {
                    let v = stack.last().ok_or_else(|| bug("dup: empty stack"))?.clone();
                    stack.push(v);
                }

                // --- calls ---
                Instr::Call { func, argc } => {
                    let argc = *argc as usize;
                    let base = stack
                        .len()
                        .checked_sub(argc)
                        .ok_or_else(|| bug("call: operand stack underflow"))?;
                    let args = stack.split_off(base);
                    let ret = self.call(module, *func as usize, args)?;
                    stack.push(ret);
                }
                Instr::CallNative { native, argc } => {
                    let argc = *argc as usize;
                    let base = stack
                        .len()
                        .checked_sub(argc)
                        .ok_or_else(|| bug("call.native: operand stack underflow"))?;
                    let args = stack.split_off(base);
                    let f = *self
                        .natives
                        .get(*native as usize)
                        .ok_or_else(|| bug(format!("call.native: no native at index {native}")))?;
                    let ret = f(&mut *self.out, &args)?;
                    stack.push(ret);
                }

                // --- enums ---
                Instr::EnumNew {
                    ty,
                    variant,
                    field_count,
                } => {
                    let fc = *field_count as usize;
                    let base = stack
                        .len()
                        .checked_sub(fc)
                        .ok_or_else(|| bug("enum.new: operand stack underflow"))?;
                    let fields = stack.split_off(base);
                    stack.push(Value::new_enum(*ty, *variant, fields));
                }
                Instr::EnumTag => {
                    let variant = pop_enum_variant(&mut stack)?;
                    stack.push(Value::Int(variant as i64));
                }
                Instr::EnumGet(idx) => {
                    let v = pop(&mut stack)?;
                    stack.push(enum_field(&v, *idx as usize)?);
                }

                // --- collections ---
                Instr::ListNew { count } => {
                    let n = *count as usize;
                    let base = stack
                        .len()
                        .checked_sub(n)
                        .ok_or_else(|| bug("list.new: operand stack underflow"))?;
                    let items = stack.split_off(base);
                    stack.push(Value::new_list(items));
                }

                // --- control ---
                Instr::Jump(target) => {
                    pc = *target;
                    continue;
                }
                Instr::JumpIfTrue(target) => {
                    if pop_bool(&mut stack)? {
                        pc = *target;
                        continue;
                    }
                }
                Instr::JumpIfFalse(target) => {
                    if !pop_bool(&mut stack)? {
                        pc = *target;
                        continue;
                    }
                }
                Instr::Return => return Ok(stack.pop().unwrap_or(Value::Unit)),
            }

            pc += 1;
        }
    }
}

// --- operand-stack helpers ---

fn pop(stack: &mut Vec<Value>) -> Result<Value, Trap> {
    stack.pop().ok_or_else(|| bug("stack underflow"))
}

fn pop_int(stack: &mut Vec<Value>) -> Result<i64, Trap> {
    match pop(stack)? {
        Value::Int(n) => Ok(n),
        v => Err(bug(format!("expected Int, found {v:?}"))),
    }
}

fn pop_double(stack: &mut Vec<Value>) -> Result<f64, Trap> {
    match pop(stack)? {
        Value::Double(x) => Ok(x),
        v => Err(bug(format!("expected Double, found {v:?}"))),
    }
}

fn pop_bool(stack: &mut Vec<Value>) -> Result<bool, Trap> {
    match pop(stack)? {
        Value::Bool(b) => Ok(b),
        v => Err(bug(format!("expected Bool, found {v:?}"))),
    }
}

/// Pop two ints `a` (pushed first) and `b` (pushed second / on top).
fn pop_two_int(stack: &mut Vec<Value>) -> Result<(i64, i64), Trap> {
    let b = pop_int(stack)?;
    let a = pop_int(stack)?;
    Ok((a, b))
}

fn pop_two_double(stack: &mut Vec<Value>) -> Result<(f64, f64), Trap> {
    let b = pop_double(stack)?;
    let a = pop_double(stack)?;
    Ok((a, b))
}

/// Pop an enum value and return its variant tag.
fn pop_enum_variant(stack: &mut Vec<Value>) -> Result<u16, Trap> {
    match pop(stack)? {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Enum(e) => Ok(e.variant),
            Obj::Str(_) | Obj::List(_) | Obj::Map(_) => Err(bug("enum.tag: expected enum")),
        },
        v => Err(bug(format!("expected enum, found {v:?}"))),
    }
}

/// Read payload field `idx` of an enum value.
fn enum_field(v: &Value, idx: usize) -> Result<Value, Trap> {
    match v {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Enum(e) => e
                .fields
                .get(idx)
                .cloned()
                .ok_or_else(|| bug(format!("enum.get: field {idx} out of range"))),
            Obj::Str(_) | Obj::List(_) | Obj::Map(_) => Err(bug("enum.get: expected enum")),
        },
        v => Err(bug(format!("enum.get: expected enum, found {v:?}"))),
    }
}

fn cmp_int(stack: &mut Vec<Value>, f: impl Fn(i64, i64) -> bool) -> Result<(), Trap> {
    let (a, b) = pop_two_int(stack)?;
    stack.push(Value::Bool(f(a, b)));
    Ok(())
}

fn cmp_double(stack: &mut Vec<Value>, f: impl Fn(f64, f64) -> bool) -> Result<(), Trap> {
    let (a, b) = pop_two_double(stack)?;
    stack.push(Value::Bool(f(a, b)));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::builder::FnBuilder;
    use crate::module::{Function, Module};
    use crate::value::{TAG_ERR, TAG_NONE, TAG_OK, TAG_SOME};

    // Opaque type ids for the draft (no type table yet).
    const RESULT: u32 = 0;
    const OPTION: u32 = 1;

    /// Evaluate a bare snippet with no locals. (Shadows the module-level `run`
    /// for the earlier increments' tests; increment-3 tests use `super::run`.)
    fn run(code: &[Instr]) -> Result<Value, Trap> {
        eval(code, &mut [])
    }

    #[test]
    fn returns_constant() {
        assert_eq!(run(&[Instr::ConstInt(7), Instr::Return]), Ok(Value::Int(7)));
    }

    #[test]
    fn empty_return_is_unit() {
        assert_eq!(run(&[Instr::Return]), Ok(Value::Unit));
    }

    #[test]
    fn integer_arithmetic() {
        // (2 + 3) * 4 = 20
        let code = [
            Instr::ConstInt(2),
            Instr::ConstInt(3),
            Instr::AddI64,
            Instr::ConstInt(4),
            Instr::MulI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(20)));
    }

    #[test]
    fn subtraction_is_ordered() {
        // 10 - 3 = 7 (operand order matters)
        let code = [
            Instr::ConstInt(10),
            Instr::ConstInt(3),
            Instr::SubI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(7)));
    }

    #[test]
    fn division_truncates_toward_zero() {
        let code = [
            Instr::ConstInt(7),
            Instr::ConstInt(2),
            Instr::DivI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(3)));
    }

    #[test]
    fn modulo() {
        let code = [
            Instr::ConstInt(7),
            Instr::ConstInt(3),
            Instr::ModI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(1)));
    }

    #[test]
    fn integer_overflow_wraps() {
        let code = [
            Instr::ConstInt(i64::MAX),
            Instr::ConstInt(1),
            Instr::AddI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(i64::MIN)));
    }

    #[test]
    fn division_by_zero_traps() {
        let code = [
            Instr::ConstInt(1),
            Instr::ConstInt(0),
            Instr::DivI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Err(Trap::DivByZero));
    }

    #[test]
    fn modulo_by_zero_traps() {
        let code = [
            Instr::ConstInt(1),
            Instr::ConstInt(0),
            Instr::ModI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Err(Trap::DivByZero));
    }

    #[test]
    fn comparison() {
        let code = [
            Instr::ConstInt(2),
            Instr::ConstInt(3),
            Instr::LtI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Bool(true)));
    }

    #[test]
    fn float_arithmetic_and_compare() {
        let code = [
            Instr::ConstDouble(1.5),
            Instr::ConstDouble(2.0),
            Instr::AddF64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Double(3.5)));
    }

    #[test]
    fn conversions() {
        assert_eq!(
            run(&[Instr::ConstInt(3), Instr::I64ToF64, Instr::Return]),
            Ok(Value::Double(3.0))
        );
        assert_eq!(
            run(&[Instr::ConstDouble(3.9), Instr::F64ToI64, Instr::Return]),
            Ok(Value::Int(3))
        );
    }

    #[test]
    fn boolean_not() {
        assert_eq!(
            run(&[Instr::ConstBool(true), Instr::Not, Instr::Return]),
            Ok(Value::Bool(false))
        );
    }

    #[test]
    fn dup_and_pop() {
        // dup: 5 5 +  = 10
        assert_eq!(
            run(&[Instr::ConstInt(5), Instr::Dup, Instr::AddI64, Instr::Return]),
            Ok(Value::Int(10))
        );
        // pop: leaves the first value
        assert_eq!(
            run(&[
                Instr::ConstInt(1),
                Instr::ConstInt(2),
                Instr::Pop,
                Instr::Return
            ]),
            Ok(Value::Int(1))
        );
    }

    #[test]
    fn locals_store_and_load() {
        let mut locals = vec![Value::Unit];
        let code = [
            Instr::ConstInt(42),
            Instr::Store(0),
            Instr::Load(0),
            Instr::Return,
        ];
        assert_eq!(eval(&code, &mut locals), Ok(Value::Int(42)));
    }

    #[test]
    fn unconditional_jump_skips_instructions() {
        // Jump over a ConstInt(999) that would otherwise overwrite the result.
        let code = [
            Instr::ConstInt(42),
            Instr::Jump(4),
            Instr::ConstInt(999), // skipped
            Instr::Return,        // skipped
            Instr::Return,        // target
        ];
        assert_eq!(run(&code), Ok(Value::Int(42)));
    }

    /// `if a < b { 100 } else { 200 }`.
    fn branch(a: i64, b: i64) -> Result<Value, Trap> {
        let code = [
            Instr::ConstInt(a),
            Instr::ConstInt(b),
            Instr::LtI64,
            Instr::JumpIfFalse(6), // false → else branch
            Instr::ConstInt(100),  // then
            Instr::Return,
            Instr::ConstInt(200), // else (index 6)
            Instr::Return,
        ];
        run(&code)
    }

    #[test]
    fn conditional_branch_taken_and_not_taken() {
        assert_eq!(branch(2, 3), Ok(Value::Int(100))); // 2 < 3 → then
        assert_eq!(branch(3, 2), Ok(Value::Int(200))); // 3 < 2 → else
    }

    #[test]
    fn jump_if_true() {
        // if true, jump to return 1; else fall through to return 0.
        let code = [
            Instr::ConstBool(true),
            Instr::JumpIfTrue(4),
            Instr::ConstInt(0),
            Instr::Return,
            Instr::ConstInt(1), // target
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(1)));
    }

    #[test]
    fn counted_loop_sums_range() {
        // sum = 0; i = 0; while i < 5 { sum += i; i += 1 }; return sum  // = 10
        let code = [
            Instr::ConstInt(0),
            Instr::Store(1), // sum = 0
            Instr::ConstInt(0),
            Instr::Store(0), // i = 0
            // loop head (index 4):
            Instr::Load(0),
            Instr::ConstInt(5),
            Instr::LtI64,
            Instr::JumpIfFalse(17), // exit
            Instr::Load(1),
            Instr::Load(0),
            Instr::AddI64,
            Instr::Store(1), // sum += i
            Instr::Load(0),
            Instr::ConstInt(1),
            Instr::AddI64,
            Instr::Store(0), // i += 1
            Instr::Jump(4),
            // after loop (index 17):
            Instr::Load(1),
            Instr::Return,
        ];
        let mut locals = vec![Value::Unit; 2];
        assert_eq!(eval(&code, &mut locals), Ok(Value::Int(10)));
    }

    #[test]
    fn type_mismatch_is_a_bug() {
        // AddI64 on a Bool is malformed bytecode.
        let code = [
            Instr::ConstBool(true),
            Instr::ConstInt(1),
            Instr::AddI64,
            Instr::Return,
        ];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    // --- increment 3: functions & calls ---

    #[test]
    fn simple_call() {
        // double(x) = x * 2;  main() = double(21)
        let main = Function::new(
            "main",
            0,
            0,
            vec![
                Instr::ConstInt(21),
                Instr::Call { func: 1, argc: 1 },
                Instr::Return,
            ],
        );
        let double = Function::new(
            "double",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::ConstInt(2),
                Instr::MulI64,
                Instr::Return,
            ],
        );
        let module = Module::new(vec![main, double]);
        assert_eq!(super::run(&module, 0, &[]), Ok(Value::Int(42)));
    }

    #[test]
    fn argument_order_is_preserved() {
        // sub(a, b) = a - b;  sub(10, 3) = 7  (args land in locals[0], locals[1])
        let sub = Function::new(
            "sub",
            2,
            2,
            vec![Instr::Load(0), Instr::Load(1), Instr::SubI64, Instr::Return],
        );
        let module = Module::new(vec![sub]);
        assert_eq!(
            super::run(&module, 0, &[Value::Int(10), Value::Int(3)]),
            Ok(Value::Int(7))
        );
    }

    #[test]
    fn recursive_factorial() {
        // fact(n) = if n <= 1 { 1 } else { n * fact(n - 1) }  (built via FnBuilder)
        let mut b = FnBuilder::new("fact", 1);
        let recurse = b.label();
        b.load(0);
        b.const_int(1);
        b.le_i64();
        b.jump_if_false(recurse);
        b.const_int(1); // base case
        b.ret();
        b.bind(recurse);
        b.load(0);
        b.load(0);
        b.const_int(1);
        b.sub_i64();
        b.call(0, 1); // fact(n - 1)
        b.mul_i64();
        b.ret();
        let module = Module::new(vec![b.finish()]);
        assert_eq!(
            super::run(&module, 0, &[Value::Int(5)]),
            Ok(Value::Int(120))
        );
        assert_eq!(super::run(&module, 0, &[Value::Int(0)]), Ok(Value::Int(1)));
    }

    #[test]
    fn recursive_fibonacci() {
        // fib(n) = if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
        let fib = Function::new(
            "fib",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::ConstInt(2),
                Instr::LtI64,
                Instr::JumpIfFalse(6),
                Instr::Load(0), // base case: return n
                Instr::Return,
                Instr::Load(0), // index 6
                Instr::ConstInt(1),
                Instr::SubI64,
                Instr::Call { func: 0, argc: 1 }, // fib(n - 1)
                Instr::Load(0),
                Instr::ConstInt(2),
                Instr::SubI64,
                Instr::Call { func: 0, argc: 1 }, // fib(n - 2)
                Instr::AddI64,
                Instr::Return,
            ],
        );
        let module = Module::new(vec![fib]);
        assert_eq!(
            super::run(&module, 0, &[Value::Int(10)]),
            Ok(Value::Int(55))
        );
    }

    #[test]
    fn void_function_returns_unit() {
        // f() returns nothing; main() = f()
        let main = Function::new(
            "main",
            0,
            0,
            vec![Instr::Call { func: 1, argc: 0 }, Instr::Return],
        );
        let f = Function::new("f", 0, 0, vec![Instr::Return]);
        let module = Module::new(vec![main, f]);
        assert_eq!(super::run(&module, 0, &[]), Ok(Value::Unit));
    }

    #[test]
    fn unknown_function_is_a_bug() {
        let module = Module::default();
        assert!(matches!(super::run(&module, 0, &[]), Err(Trap::Bug(_))));
    }

    #[test]
    fn arity_mismatch_is_a_bug() {
        // Call passes 0 args to a function expecting 1.
        let main = Function::new(
            "main",
            0,
            0,
            vec![Instr::Call { func: 1, argc: 0 }, Instr::Return],
        );
        let g = Function::new("g", 1, 1, vec![Instr::Load(0), Instr::Return]);
        let module = Module::new(vec![main, g]);
        assert!(matches!(super::run(&module, 0, &[]), Err(Trap::Bug(_))));
    }

    // --- increment 4: enums & the heap ---

    #[test]
    fn enum_tag() {
        let ok = [
            Instr::ConstInt(42),
            Instr::EnumNew {
                ty: RESULT,
                variant: TAG_OK,
                field_count: 1,
            },
            Instr::EnumTag,
            Instr::Return,
        ];
        assert_eq!(run(&ok), Ok(Value::Int(0)));

        let none = [
            Instr::EnumNew {
                ty: OPTION,
                variant: TAG_NONE,
                field_count: 0,
            },
            Instr::EnumTag,
            Instr::Return,
        ];
        assert_eq!(run(&none), Ok(Value::Int(1)));
    }

    #[test]
    fn enum_get_payload() {
        let code = [
            Instr::ConstInt(42),
            Instr::EnumNew {
                ty: RESULT,
                variant: TAG_OK,
                field_count: 1,
            },
            Instr::EnumGet(0),
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(42)));
    }

    #[test]
    fn enum_value_is_constructed() {
        let code = [
            Instr::ConstInt(7),
            Instr::EnumNew {
                ty: OPTION,
                variant: TAG_SOME,
                field_count: 1,
            },
            Instr::Return,
        ];
        assert_eq!(
            run(&code),
            Ok(Value::new_enum(OPTION, TAG_SOME, vec![Value::Int(7)]))
        );
    }

    #[test]
    fn structural_equality() {
        assert_eq!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
        );
        // different variant
        assert_ne!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(RESULT, TAG_ERR, vec![Value::Int(1)]),
        );
        // different payload
        assert_ne!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(2)]),
        );
        // different type id (same variant/payload)
        assert_ne!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(OPTION, TAG_SOME, vec![Value::Int(1)]),
        );
    }

    #[test]
    fn question_mark_propagation() {
        // f(r) = { let x = r?; return Ok(x + 10); }  (built via FnBuilder)
        let mut b = FnBuilder::new("f", 1);
        let ok = b.label();
        b.load(0);
        b.dup();
        b.enum_tag();
        b.const_int(TAG_ERR as i64);
        b.eq_i64();
        b.jump_if_false(ok);
        b.ret(); // Err: propagate the Result unchanged
        b.bind(ok);
        b.enum_get(0); // unwrap Ok payload
        b.store(1); // x  (bumps local_count to 2)
        b.load(1);
        b.const_int(10);
        b.add_i64();
        b.enum_new(RESULT, TAG_OK, 1);
        b.ret();
        let module = Module::new(vec![b.finish()]);

        // Ok(5) → Ok(15)
        assert_eq!(
            super::run(
                &module,
                0,
                &[Value::new_enum(RESULT, TAG_OK, vec![Value::Int(5)])]
            ),
            Ok(Value::new_enum(RESULT, TAG_OK, vec![Value::Int(15)]))
        );
        // Err(99) → Err(99), propagated unchanged
        assert_eq!(
            super::run(
                &module,
                0,
                &[Value::new_enum(RESULT, TAG_ERR, vec![Value::Int(99)])]
            ),
            Ok(Value::new_enum(RESULT, TAG_ERR, vec![Value::Int(99)]))
        );
    }

    #[test]
    fn match_on_option() {
        // match opt { Some(n) => n, None => -1 }
        let f = Function::new(
            "f",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::EnumTag,
                Instr::ConstInt(TAG_SOME as i64),
                Instr::EqI64,
                Instr::JumpIfFalse(8), // None arm
                Instr::Load(0),
                Instr::EnumGet(0), // n
                Instr::Return,
                Instr::ConstInt(-1), // index 8: None arm
                Instr::Return,
            ],
        );
        let module = Module::new(vec![f]);
        assert_eq!(
            super::run(
                &module,
                0,
                &[Value::new_enum(OPTION, TAG_SOME, vec![Value::Int(7)])]
            ),
            Ok(Value::Int(7))
        );
        assert_eq!(
            super::run(&module, 0, &[Value::new_enum(OPTION, TAG_NONE, vec![])]),
            Ok(Value::Int(-1))
        );
    }

    #[test]
    fn enum_tag_on_non_enum_is_a_bug() {
        let code = [Instr::ConstInt(1), Instr::EnumTag, Instr::Return];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    // --- increment 5: intrinsics & observable output ---

    /// Run a bare snippet, returning its result and any captured output.
    fn run_capturing(code: &[Instr]) -> (Result<Value, Trap>, String) {
        let module = Module::default();
        let mut buf: Vec<u8> = Vec::new();
        let result = Vm::new(&mut buf).exec(&module, code, &mut []);
        (result, String::from_utf8(buf).unwrap())
    }

    #[test]
    fn stringify_primitive() {
        let code = [
            Instr::ConstInt(42),
            Instr::CallNative {
                native: NATIVE_STRINGIFY,
                argc: 1,
            },
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::new_str("42")));
    }

    #[test]
    fn str_concat_joins_strings() {
        let code = [
            Instr::ConstStr("foo".into()),
            Instr::ConstStr("bar".into()),
            Instr::CallNative {
                native: NATIVE_STR_CONCAT,
                argc: 2,
            },
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::new_str("foobar")));
    }

    #[test]
    fn println_writes_to_output() {
        let code = [
            Instr::ConstStr("hello".into()),
            Instr::CallNative {
                native: NATIVE_PRINTLN,
                argc: 1,
            },
            Instr::Return,
        ];
        let (result, output) = run_capturing(&code);
        assert_eq!(result, Ok(Value::Unit));
        assert_eq!(output, "hello\n");
    }

    #[test]
    fn interpolation_pipeline() {
        // 'x = ${x}' with x = 7  →  "x = 7\n"
        let code = [
            Instr::ConstStr("x = ".into()),
            Instr::ConstInt(7),
            Instr::CallNative {
                native: NATIVE_STRINGIFY,
                argc: 1,
            },
            Instr::CallNative {
                native: NATIVE_STR_CONCAT,
                argc: 2,
            },
            Instr::CallNative {
                native: NATIVE_PRINTLN,
                argc: 1,
            },
            Instr::Return,
        ];
        let (result, output) = run_capturing(&code);
        assert_eq!(result, Ok(Value::Unit));
        assert_eq!(output, "x = 7\n");
    }

    #[test]
    fn unknown_native_is_a_bug() {
        let code = [Instr::CallNative {
            native: 999,
            argc: 0,
        }];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    #[test]
    fn str_concat_on_non_string_is_a_bug() {
        let code = [
            Instr::ConstInt(1),
            Instr::ConstInt(2),
            Instr::CallNative {
                native: NATIVE_STR_CONCAT,
                argc: 2,
            },
            Instr::Return,
        ];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    // --- increment 6: collections ---

    /// Build and run a parameterless function via the builder.
    fn run_fn(build: impl FnOnce(&mut FnBuilder)) -> Result<Value, Trap> {
        let mut b = FnBuilder::new("test", 0);
        build(&mut b);
        let module = Module::new(vec![b.finish()]);
        super::run(&module, 0, &[])
    }

    /// Emit `[a, b, c, ...]` as a list literal.
    fn push_int_list(b: &mut FnBuilder, items: &[i64]) {
        for &n in items {
            b.const_int(n);
        }
        b.list_new(items.len() as u32);
    }

    #[test]
    fn list_literal_and_len() {
        let r = run_fn(|b| {
            push_int_list(b, &[10, 20, 30]);
            b.call_native(NATIVE_LIST_LEN, 1);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(3)));
    }

    #[test]
    fn list_index_reads_element() {
        let r = run_fn(|b| {
            push_int_list(b, &[10, 20, 30]);
            b.const_int(1);
            b.call_native(NATIVE_LIST_INDEX, 2);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(20)));
    }

    #[test]
    fn list_index_out_of_bounds_traps() {
        let r = run_fn(|b| {
            push_int_list(b, &[10]);
            b.const_int(5);
            b.call_native(NATIVE_LIST_INDEX, 2);
            b.ret();
        });
        assert_eq!(r, Err(Trap::IndexOutOfBounds { index: 5, len: 1 }));
    }

    #[test]
    fn list_get_returns_option() {
        // get(1) → Some(20)
        let some = run_fn(|b| {
            push_int_list(b, &[10, 20]);
            b.const_int(1);
            b.call_native(NATIVE_LIST_GET, 2);
            b.ret();
        });
        assert_eq!(some, Ok(Value::some(Value::Int(20))));
        // get(9) → None
        let none = run_fn(|b| {
            push_int_list(b, &[10, 20]);
            b.const_int(9);
            b.call_native(NATIVE_LIST_GET, 2);
            b.ret();
        });
        assert_eq!(none, Ok(Value::none()));
    }

    #[test]
    fn list_set_mutates_in_place() {
        // l = [10, 20]; l[0] = 99; return l[0]
        let r = run_fn(|b| {
            push_int_list(b, &[10, 20]);
            b.store(0);
            b.load(0);
            b.const_int(0);
            b.const_int(99);
            b.call_native(NATIVE_LIST_SET, 3);
            b.pop(); // discard the Unit return
            b.load(0);
            b.const_int(0);
            b.call_native(NATIVE_LIST_INDEX, 2);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(99)));
    }

    #[test]
    fn reference_semantics_aliasing() {
        // l = [1]; a = l; l[0] = 42; return a[0]  → 42 (shared heap object)
        let r = run_fn(|b| {
            push_int_list(b, &[1]);
            b.store(0); // l
            b.load(0);
            b.store(1); // a = l  (copies the reference)
            b.load(0);
            b.const_int(0);
            b.const_int(42);
            b.call_native(NATIVE_LIST_SET, 3);
            b.pop();
            b.load(1); // read via a
            b.const_int(0);
            b.call_native(NATIVE_LIST_INDEX, 2);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(42)));
    }

    /// Emit the literal `{'a': 1, 'b': 2}`.
    fn push_ab_map(b: &mut FnBuilder) {
        b.const_str("a");
        b.const_int(1);
        b.const_str("b");
        b.const_int(2);
        b.call_native(NATIVE_MAP_NEW, 4);
    }

    #[test]
    fn map_literal_index_and_len() {
        let len = run_fn(|b| {
            push_ab_map(b);
            b.call_native(NATIVE_MAP_LEN, 1);
            b.ret();
        });
        assert_eq!(len, Ok(Value::Int(2)));

        let idx = run_fn(|b| {
            push_ab_map(b);
            b.const_str("b");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.ret();
        });
        assert_eq!(idx, Ok(Value::Int(2)));
    }

    #[test]
    fn map_index_missing_key_traps() {
        let r = run_fn(|b| {
            push_ab_map(b);
            b.const_str("zzz");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.ret();
        });
        assert_eq!(r, Err(Trap::MissingKey));
    }

    #[test]
    fn map_get_and_has() {
        let got = run_fn(|b| {
            push_ab_map(b);
            b.const_str("a");
            b.call_native(NATIVE_MAP_GET, 2);
            b.ret();
        });
        assert_eq!(got, Ok(Value::some(Value::Int(1))));

        let missing = run_fn(|b| {
            push_ab_map(b);
            b.const_str("x");
            b.call_native(NATIVE_MAP_GET, 2);
            b.ret();
        });
        assert_eq!(missing, Ok(Value::none()));

        let has = run_fn(|b| {
            push_ab_map(b);
            b.const_str("a");
            b.call_native(NATIVE_MAP_HAS, 2);
            b.ret();
        });
        assert_eq!(has, Ok(Value::Bool(true)));
    }

    #[test]
    fn map_set_updates_and_inserts() {
        // m = {'a':1}; m['a'] = 9 (update); m['c'] = 3 (insert);
        // return m['a'] + m['c'] + m.len()   → 9 + 3 + 2 = 14
        let r = run_fn(|b| {
            b.const_str("a");
            b.const_int(1);
            b.call_native(NATIVE_MAP_NEW, 2);
            b.store(0); // m
            // m['a'] = 9
            b.load(0);
            b.const_str("a");
            b.const_int(9);
            b.call_native(NATIVE_MAP_SET, 3);
            b.pop();
            // m['c'] = 3
            b.load(0);
            b.const_str("c");
            b.const_int(3);
            b.call_native(NATIVE_MAP_SET, 3);
            b.pop();
            // m['a'] + m['c']
            b.load(0);
            b.const_str("a");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.load(0);
            b.const_str("c");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.add_i64();
            // + m.len()
            b.load(0);
            b.call_native(NATIVE_MAP_LEN, 1);
            b.add_i64();
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(14)));
    }

    #[test]
    fn list_index_on_non_list_is_a_bug() {
        let r = run_fn(|b| {
            b.const_int(1); // not a list
            b.const_int(0);
            b.call_native(NATIVE_LIST_INDEX, 2);
            b.ret();
        });
        assert!(matches!(r, Err(Trap::Bug(_))));
    }
}
