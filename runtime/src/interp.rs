//! The Tier-0 evaluator.
//!
//! Increment 1: execute a single linear instruction stream against a locals
//! array, maintaining an operand stack, until a [`Instr::Return`].

use crate::instr::Instr;
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

/// Evaluate `code`, using `locals` for `load`/`store`. Returns the value left
/// by [`Instr::Return`].
pub fn eval(code: &[Instr], locals: &mut [Value]) -> Result<Value, Trap> {
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

            // --- control ---
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

    /// Evaluate with no locals.
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
}
