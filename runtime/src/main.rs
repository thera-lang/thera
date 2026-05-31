//! Placeholder entry point. For now it runs a hand-written bytecode program as
//! a smoke check; this grows into the real `hawk` CLI later.

use hawk::instr::Instr;
use hawk::interp::{NATIVE_PRINTLN, NATIVE_STR_CONCAT, NATIVE_STRINGIFY, run};
use hawk::module::{Function, Module};

fn main() {
    // double(x) = x * 2;
    // main() = println('double(21) = ' + stringify(double(21)))
    let main = Function::new(
        "main",
        0,
        0,
        vec![
            Instr::ConstStr("double(21) = ".into()),
            Instr::ConstInt(21),
            Instr::Call { func: 1, argc: 1 }, // double(21)
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

    if let Err(t) = run(&module, 0, &[]) {
        eprintln!("trap: {t:?}");
    }
}
