//! A minimal CLI for the runtime: enough to persist a module to a `.hawkbc`
//! file and run one back. This is a placeholder that grows into the real `hawk`
//! tool (front-end, JIT, …) later.

use std::process::ExitCode;

use hawk::builder::FnBuilder;
use hawk::codec::{read_module_from_file, write_module_to_file};
use hawk::interp::{NATIVE_PRINTLN, NATIVE_STR_CONCAT, NATIVE_STRINGIFY, run};
use hawk::module::Module;
use hawk::value::Value;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("run") => cmd_run(args.get(2)),
        Some("emit-demo") => cmd_emit_demo(args.get(2)),
        _ => {
            eprintln!("usage: hawk <run|emit-demo> <file.hawkbc>");
            ExitCode::from(2)
        }
    }
}

/// Load a `.hawkbc` file and run its `main` function.
fn cmd_run(path: Option<&String>) -> ExitCode {
    let Some(path) = path else {
        eprintln!("usage: hawk run <file.hawkbc>");
        return ExitCode::from(2);
    };

    let module = match read_module_from_file(path) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("hawk: cannot load {path}: {e}");
            return ExitCode::FAILURE;
        }
    };

    let Some(entry) = module.function_index("main") else {
        eprintln!("hawk: {path} has no 'main' function");
        return ExitCode::FAILURE;
    };

    match run(&module, entry, &[]) {
        // main returns an Int exit code (Hawk's convention); other values exit 0.
        Ok(Value::Int(n)) => ExitCode::from(n as u8),
        Ok(_) => ExitCode::SUCCESS,
        Err(trap) => {
            eprintln!("hawk: trap: {trap:?}");
            ExitCode::FAILURE
        }
    }
}

/// Write a small sample module to `path`, for exercising `run` end to end.
fn cmd_emit_demo(path: Option<&String>) -> ExitCode {
    let Some(path) = path else {
        eprintln!("usage: hawk emit-demo <file.hawkbc>");
        return ExitCode::from(2);
    };

    if let Err(e) = write_module_to_file(path, &demo_module()) {
        eprintln!("hawk: cannot write {path}: {e}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

/// `double(x) = x * 2;  main() { println('double(21) = ' + stringify(double(21))); return 0; }`
fn demo_module() -> Module {
    let mut main = FnBuilder::new("main", 0);
    main.const_str("double(21) = ");
    main.const_int(21);
    main.call(1, 1); // double(21)
    main.call_native(NATIVE_STRINGIFY, 1);
    main.call_native(NATIVE_STR_CONCAT, 2);
    main.call_native(NATIVE_PRINTLN, 1);
    main.pop(); // discard println's Unit
    main.const_int(0); // exit code
    main.ret();

    let mut double = FnBuilder::new("double", 1);
    double.load(0);
    double.const_int(2);
    double.mul_i64();
    double.ret();

    Module::new(vec![main.finish(), double.finish()])
}
