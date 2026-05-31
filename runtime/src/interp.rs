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

use crate::instr::Instr;
use crate::module::Module;
use crate::value::Value;

/// A runtime fault that aborts execution (see docs/language.md, "Runtime
/// faults"). Variants that describe malformed bytecode ([`Trap::Bug`]) indicate
/// a producer error rather than a program-level fault; valid bytecode never
/// raises them.
#[derive(Clone, Debug, PartialEq)]
pub enum Trap {
    /// Integer or float division/modulo by zero.
    DivByZero,
    /// The bytecode was malformed (stack underflow, type mismatch, bad slot).
    /// Valid bytecode from a correct producer never triggers this.
    Bug(String),
}

fn bug(msg: impl Into<String>) -> Trap {
    Trap::Bug(msg.into())
}

/// Run `module`'s function at index `func` with `args`, returning its result.
pub fn run(module: &Module, func: usize, args: &[Value]) -> Result<Value, Trap> {
    call(module, func, args.to_vec())
}

/// Evaluate a bare instruction stream with no enclosing module (so `call` is
/// unavailable). A convenience for testing self-contained snippets.
pub fn eval(code: &[Instr], locals: &mut [Value]) -> Result<Value, Trap> {
    let module = Module::default();
    exec(&module, code, locals)
}

/// Build a frame for `module.functions[func]`, placing `args` in its leading
/// local slots, and execute it.
fn call(module: &Module, func: usize, args: Vec<Value>) -> Result<Value, Trap> {
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
    exec(module, &f.code, &mut locals)
}

/// Execute `code` against `locals`, resolving any `call` in `module`.
fn exec(module: &Module, code: &[Instr], locals: &mut [Value]) -> Result<Value, Trap> {
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
                let v = stack
                    .last()
                    .ok_or_else(|| bug("dup: empty stack"))?
                    .clone();
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
                let ret = call(module, *func as usize, args)?;
                stack.push(ret);
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
    use crate::module::{Function, Module};

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
            Instr::ConstInt(200),  // else (index 6)
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
            vec![Instr::Load(0), Instr::ConstInt(2), Instr::MulI64, Instr::Return],
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
        // fact(n) = if n <= 1 { 1 } else { n * fact(n - 1) }
        let fact = Function::new(
            "fact",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::ConstInt(1),
                Instr::LeI64,
                Instr::JumpIfFalse(6),
                Instr::ConstInt(1), // base case
                Instr::Return,
                Instr::Load(0),               // index 6
                Instr::Load(0),
                Instr::ConstInt(1),
                Instr::SubI64,
                Instr::Call { func: 0, argc: 1 }, // fact(n - 1)
                Instr::MulI64,
                Instr::Return,
            ],
        );
        let module = Module::new(vec![fact]);
        assert_eq!(super::run(&module, 0, &[Value::Int(5)]), Ok(Value::Int(120)));
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
                Instr::Load(0),               // index 6
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
        assert_eq!(super::run(&module, 0, &[Value::Int(10)]), Ok(Value::Int(55)));
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
}
