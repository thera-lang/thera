//! The runtime CLI. In its bare form (`thera-rt`) it loads and runs a `.thera-bc`.
//! As the SDK's `thera`, a subcommand (`run`/`check`/…) boots the compiled
//! front-end; a `.thera-bc` path (or `--entry`) still runs directly. The front-end
//! bytes are either baked in (a single-binary release) or, when the baked blob is
//! empty, loaded from a sibling `inc/frontend.thera-bc` at runtime — the shape the
//! assembled SDK ships, so building it needs no second compile.

use std::path::PathBuf;
use std::process::ExitCode;

use thera::builder::FnBuilder;
use thera::codec::{decode_module, read_module_from_file, write_module_to_file};
use thera::heap;
use thera::interp::{
    NATIVE_INT_TO_STRING, NATIVE_PRINTLN, NATIVE_STR_CONCAT, init_module, run, set_program_args,
};
use thera::module::Module;
use thera::value::{Obj, TAG_OK, TY_RESULT, Value};

/// The front-end baked in by `build.rs`. Empty in a bare `cargo build` (this is
/// `thera-rt`, and [`sibling_frontend`] supplies the bytes at runtime); non-empty
/// when `THERA_FRONTEND_BC` embedded it (a self-contained single-binary release).
const FRONTEND_BC: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/frontend.thera-bc"));

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--version") | Some("-V") => {
            println!("thera {}", version_string());
            ExitCode::SUCCESS
        }
        // The dev helper to write a sample module.
        Some("emit-demo") => cmd_emit_demo(args.get(2)),
        // An explicit entry or a `.thera-bc` path runs directly on the bare runtime
        // — this is also how the front-end re-invokes us to execute a program it
        // just compiled.
        Some("--entry") => cmd_run(&args[1..]),
        Some(p) if is_bytecode_path(p) => cmd_run(&args[1..]),
        // Any other first argument is a front-end subcommand (`run`, `check`,
        // `test`, `emit`, `lsp`, `--help`). Boot the front-end — baked in, or from
        // the sibling `inc/frontend.thera-bc`. Without either, this is the bare
        // runtime and there's nothing to do.
        Some(_) | None => match load_frontend() {
            Some(bytes) => cmd_frontend(&bytes, &args[1..]),
            None => match args.get(1) {
                None => {
                    eprintln!("usage: thera-rt [--entry NAME] <file.thera-bc> [args]");
                    eprintln!("       thera-rt emit-demo <file.thera-bc>");
                    ExitCode::from(2)
                }
                Some(other) => {
                    eprintln!("thera-rt: '{other}' is not a bytecode file (.thera-bc)");
                    eprintln!("this is the bare runtime; build the SDK for the `thera` front-end");
                    eprintln!("usage: thera-rt [--entry NAME] <file.thera-bc> [args]");
                    ExitCode::from(2)
                }
            },
        },
    }
}

/// The directory of the running binary, with symlinks resolved — so resources
/// found relative to it land next to the *real* executable, not a `PATH` symlink.
fn exe_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe = std::fs::canonicalize(&exe).unwrap_or(exe);
    exe.parent().map(PathBuf::from)
}

/// The front-end bytes: the baked-in blob when present, else a sibling
/// `inc/frontend.thera-bc` next to the binary (the shape the SDK ships). `None`
/// means neither is available — a plain bare runtime.
fn load_frontend() -> Option<Vec<u8>> {
    if !FRONTEND_BC.is_empty() {
        return Some(FRONTEND_BC.to_vec());
    }
    let path = exe_dir()?.join("inc").join("frontend.thera-bc");
    std::fs::read(path).ok()
}

/// The version string for `--version`. The build revision isn't baked into the
/// binary (that would force a relink per commit and defeat caching); the SDK's
/// `version` file — written by `bin/build_sdk.sh` from git, one level up from the
/// binary — is authoritative when present, falling back to the crate version.
fn version_string() -> String {
    if let Some(dir) = exe_dir()
        && let Ok(v) = std::fs::read_to_string(dir.join("..").join("version"))
    {
        let v = v.trim();
        if !v.is_empty() {
            return v.to_string();
        }
    }
    env!("CARGO_PKG_VERSION").to_string()
}

/// Whether an argument names a bytecode file (the bare-runtime fast path). A
/// suffix test, so a non-existent path still routes here and reports a load error
/// rather than being mistaken for a front-end subcommand.
fn is_bytecode_path(arg: &str) -> bool {
    arg.ends_with(".thera-bc")
}

/// Boot the front-end: decode `frontend.thera-bc` and call its `main` with the CLI
/// arguments (`run foo.thera`, `check .`, …) as a `List<String>`.
fn cmd_frontend(blob: &[u8], args: &[String]) -> ExitCode {
    let module = match decode_module(blob) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("thera: the front-end is corrupt: {e:?}");
            return ExitCode::FAILURE;
        }
    };
    let Some(entry) = module.entry_index() else {
        eprintln!("thera: the embedded front-end has no 'main' function");
        return ExitCode::FAILURE;
    };

    set_program_args(args.to_vec());
    let argv = Value::new_list(args.iter().cloned().map(Value::new_str).collect());
    let call_args = match module.functions[entry].param_count {
        0 => vec![],
        1 => vec![argv],
        n => {
            eprintln!("thera: the front-end's main takes {n} parameters; expected 0 or 1");
            return ExitCode::FAILURE;
        }
    };

    if let Err(trap) = init_module(&module) {
        eprintln!("thera: trap: {trap}");
        return ExitCode::FAILURE;
    }

    match run(&module, entry, &call_args) {
        Ok(v) => exit_code(&v),
        Err(trap) => {
            eprintln!("thera: trap: {trap}");
            ExitCode::FAILURE
        }
    }
}

/// Load a `.thera-bc` file and run its entry function. `args` is an optional
/// `--entry NAME` (default `main`) selecting the entry — used by `thera test`,
/// whose synthesized driver avoids colliding with a tested module's own `main` —
/// then the `.thera-bc` path, then the program arguments.
fn cmd_run(args: &[String]) -> ExitCode {
    let (explicit_entry, rest) = match args.split_first() {
        Some((flag, tail)) if flag == "--entry" => match tail.split_first() {
            Some((name, tail)) => (Some(name.as_str()), tail),
            None => {
                eprintln!("usage: thera-rt [--entry NAME] <file.thera-bc> [args]");
                return ExitCode::from(2);
            }
        },
        _ => (None, args),
    };

    let Some(path) = rest.first() else {
        eprintln!("usage: thera-rt [--entry NAME] <file.thera-bc> [args]");
        return ExitCode::from(2);
    };

    let module = match read_module_from_file(path) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("thera: cannot load {path}: {e}");
            return ExitCode::FAILURE;
        }
    };

    // An explicit `--entry NAME` is resolved by name (needs the Symbols table);
    // the default entry comes from the Entry section.
    let entry = match explicit_entry {
        Some(name) => module.function_index(name),
        None => module.entry_index(),
    };
    let Some(entry) = entry else {
        eprintln!(
            "thera: {path} has no '{}' function",
            explicit_entry.unwrap_or("main")
        );
        return ExitCode::FAILURE;
    };

    // Entry convention: the entry takes 0 or 1 parameter. The 1-parameter form
    // receives the program arguments (everything after the `.thera-bc` path) as a
    // `List<String>`. A richer `Args` type is a stdlib concern that wraps this.
    // The same arguments back `env.args()`.
    thera::interp::set_program_args(rest[1..].to_vec());
    let argv: Vec<Value> = rest[1..].iter().cloned().map(Value::new_str).collect();
    let call_args = match module.functions[entry].param_count {
        0 => vec![],
        1 => vec![Value::new_list(argv)],
        n => {
            eprintln!("thera: main takes {n} parameters; only 0 or 1 (args) is supported");
            return ExitCode::FAILURE;
        }
    };

    // Initialize module globals (top-level `let`) before the entry runs:
    // allocate the globals vector and run the program-init thunk, if any.
    if let Err(trap) = init_module(&module) {
        eprintln!("thera: trap: {trap}");
        return ExitCode::FAILURE;
    }

    match run(&module, entry, &call_args) {
        Ok(v) => exit_code(&v),
        Err(trap) => {
            eprintln!("thera: trap: {trap}");
            ExitCode::FAILURE
        }
    }
}

/// Map `main`'s return value to a process exit code. A bare `Int` is the code; a
/// `Result` is unwrapped per Thera's convention — `Ok(Int)` is the code, `Ok(_)`
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
        Value::Double(x) => thera::value::format_double(*x),
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
        eprintln!("usage: thera-rt emit-demo <file.thera-bc>");
        return ExitCode::from(2);
    };

    if let Err(e) = write_module_to_file(path, &demo_module()) {
        eprintln!("thera: cannot write {path}: {e}");
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
