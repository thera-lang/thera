//! Placeholder entry point. For now it runs a hand-written bytecode program as
//! a smoke check; this grows into the real `hawk` CLI later.

use hawk::instr::Instr;
use hawk::interp::eval;

fn main() {
    // (2 + 3) * 4
    let code = vec![
        Instr::ConstInt(2),
        Instr::ConstInt(3),
        Instr::AddI64,
        Instr::ConstInt(4),
        Instr::MulI64,
        Instr::Return,
    ];

    match eval(&code, &mut []) {
        Ok(v) => println!("{v:?}"),
        Err(t) => eprintln!("trap: {t:?}"),
    }
}
