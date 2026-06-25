//! The runtime CLI. In its bare form (`hawkrt`) it loads and runs a `.hawkbc`.
//! The SDK build embeds the compiled front-end (`frontend.hawkbc`) into this same
//! binary and ships it as `hawk`: then a subcommand (`run`/`check`/…) boots the
//! embedded front-end, while a `.hawkbc` path (or `--entry`) still runs directly.

use std::process::ExitCode;

use hawk::builder::FnBuilder;
use hawk::codec::{decode_module, read_module_from_file, write_module_to_file};
use hawk::heap;
use hawk::interp::{
    NATIVE_INT_TO_STRING, NATIVE_PRINTLN, NATIVE_STR_CONCAT, run, set_program_args,
};
use hawk::module::Module;
use hawk::value::{Obj, TAG_OK, TY_RESULT, Value};

/// The compiled front-end, embedded by `build.rs`. Empty in a bare `cargo build`
/// (this is `hawkrt`); the SDK build supplies the real bytes (this is `hawk`).
const FRONTEND_BC: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/frontend.hawkbc"));

const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "+", env!("HAWK_BUILD_SHA"));

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--version") | Some("-V") => {
            println!("hawk {VERSION}");
            ExitCode::SUCCESS
        }
        // The dev helper to write a sample module.
        Some("emit-demo") => cmd_emit_demo(args.get(2)),
        // An explicit entry or a `.hawkbc` path runs directly on the bare runtime
        // — this is also how the embedded front-end re-invokes us to execute a
        // program it just compiled.
        Some("--entry") => cmd_run(&args[1..]),
        Some(p) if is_bytecode_path(p) => cmd_run(&args[1..]),
        // Any other first argument is a front-end subcommand (`run`, `check`,
        // `test`, `emit`, `lsp`, `--help`). Boot the embedded front-end if we
        // have one; otherwise this is the bare runtime and there's nothing to do.
        Some(_) | None if !FRONTEND_BC.is_empty() => cmd_frontend(&args[1..]),
        None => {
            eprintln!("usage: hawkrt [--entry NAME] <file.hawkbc> [args]");
            eprintln!("       hawkrt emit-demo <file.hawkbc>");
            ExitCode::from(2)
        }
        Some(other) => {
            eprintln!("hawkrt: '{other}' is not a bytecode file (.hawkbc)");
            eprintln!("this is the bare runtime; build the SDK for the `hawk` front-end");
            eprintln!("usage: hawkrt [--entry NAME] <file.hawkbc> [args]");
            ExitCode::from(2)
        }
    }
}

/// Whether an argument names a bytecode file (the bare-runtime fast path). A
/// suffix test, so a non-existent path still routes here and reports a load error
/// rather than being mistaken for a front-end subcommand.
fn is_bytecode_path(arg: &str) -> bool {
    arg.ends_with(".hawkbc")
}

/// Boot the embedded front-end: decode `frontend.hawkbc` and call its `main` with
/// the CLI arguments (`run foo.hawk`, `check .`, …) as a `List<String>`.
fn cmd_frontend(args: &[String]) -> ExitCode {
    let module = match decode_module(FRONTEND_BC) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("hawk: the embedded front-end is corrupt: {e:?}");
            return ExitCode::FAILURE;
        }
    };
    let Some(entry) = module.function_index("main") else {
        eprintln!("hawk: the embedded front-end has no 'main' function");
        return ExitCode::FAILURE;
    };

    set_program_args(args.to_vec());
    let argv = Value::new_list(args.iter().cloned().map(Value::new_str).collect());
    let call_args = match module.functions[entry].param_count {
        0 => vec![],
        1 => vec![argv],
        n => {
            eprintln!("hawk: the front-end's main takes {n} parameters; expected 0 or 1");
            return ExitCode::FAILURE;
        }
    };

    match run(&module, entry, &call_args) {
        Ok(v) => exit_code(&v),
        Err(trap) => {
            eprintln!("hawk: trap: {trap}");
            ExitCode::FAILURE
        }
    }
}

/// Load a `.hawkbc` file and run its entry function. `args` is an optional
/// `--entry NAME` (default `main`) selecting the entry — used by `hawk test`,
/// whose synthesized driver avoids colliding with a tested module's own `main` —
/// then the `.hawkbc` path, then the program arguments.
fn cmd_run(args: &[String]) -> ExitCode {
    let (entry_name, rest) = match args.split_first() {
        Some((flag, tail)) if flag == "--entry" => match tail.split_first() {
            Some((name, tail)) => (name.as_str(), tail),
            None => {
                eprintln!("usage: hawkrt [--entry NAME] <file.hawkbc> [args]");
                return ExitCode::from(2);
            }
        },
        _ => ("main", args),
    };

    let Some(path) = rest.first() else {
        eprintln!("usage: hawkrt [--entry NAME] <file.hawkbc> [args]");
        return ExitCode::from(2);
    };

    let module = match read_module_from_file(path) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("hawk: cannot load {path}: {e}");
            return ExitCode::FAILURE;
        }
    };

    let Some(entry) = module.function_index(entry_name) else {
        eprintln!("hawk: {path} has no '{entry_name}' function");
        return ExitCode::FAILURE;
    };

    // Entry convention: the entry takes 0 or 1 parameter. The 1-parameter form
    // receives the program arguments (everything after the `.hawkbc` path) as a
    // `List<String>`. A richer `Args` type is a stdlib concern that wraps this.
    // The same arguments back `env.args()`.
    hawk::interp::set_program_args(rest[1..].to_vec());
    let argv: Vec<Value> = rest[1..].iter().cloned().map(Value::new_str).collect();
    let call_args = match module.functions[entry].param_count {
        0 => vec![],
        1 => vec![Value::new_list(argv)],
        n => {
            eprintln!("hawk: main takes {n} parameters; only 0 or 1 (args) is supported");
            return ExitCode::FAILURE;
        }
    };

    match run(&module, entry, &call_args) {
        Ok(v) => exit_code(&v),
        Err(trap) => {
            eprintln!("hawk: trap: {trap}");
            ExitCode::FAILURE
        }
    }
}

/// Map `main`'s return value to a process exit code. A bare `Int` is the code; a
/// `Result` is unwrapped per Hawk's convention — `Ok(Int)` is the code, `Ok(_)`
/// succeeds, and `Err(e)` prints `e` to stderr and fails. Anything else exits 0.
fn exit_code(v: &Value) -> ExitCode {
    match v {
        Value::Int(n) => ExitCode::from(*n as u8),
        Value::Ref(h) => match heap::clone_obj(*h) {
            Obj::Enum(e) if e.ty == TY_RESULT && e.variant == TAG_OK => match e.fields.first() {
                Some(Value::Int(n)) => ExitCode::from(*n as u8),
                _ => ExitCode::SUCCESS,
            },
            Obj::Enum(e) if e.ty == TY_RESULT => {
                eprintln!(
                    "error: {}",
                    e.fields.first().map(render).unwrap_or_default()
                );
                ExitCode::FAILURE
            }
            _ => ExitCode::SUCCESS,
        },
        _ => ExitCode::SUCCESS,
    }
}

/// Render a value for an error message. Primitives and strings render directly;
/// richer types fall back to a debug form until `Display` dispatch exists.
fn render(v: &Value) -> String {
    match v {
        Value::Int(n) => n.to_string(),
        Value::Double(x) => hawk::value::format_double(*x),
        Value::Bool(b) => b.to_string(),
        Value::Unit => "()".to_string(),
        Value::Ref(h) => match heap::clone_obj(*h) {
            Obj::Str(s) => s,
            Obj::Struct { fields, .. } if fields.len() == 1 => render(&fields[0]),
            other => format!("{other:?}"),
        },
    }
}

/// Write a small sample module to `path`, for exercising `run` end to end.
fn cmd_emit_demo(path: Option<&String>) -> ExitCode {
    let Some(path) = path else {
        eprintln!("usage: hawkrt emit-demo <file.hawkbc>");
        return ExitCode::from(2);
    };

    if let Err(e) = write_module_to_file(path, &demo_module()) {
        eprintln!("hawk: cannot write {path}: {e}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

/// `double(x) = x * 2;  main() { println('double(21) = ' + int_to_string(double(21))); return 0; }`
fn demo_module() -> Module {
    let mut main = FnBuilder::new("main", 0);
    main.const_str("double(21) = ");
    main.const_int(21);
    main.call(1, 1); // double(21)
    main.call_native(NATIVE_INT_TO_STRING, 1);
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
