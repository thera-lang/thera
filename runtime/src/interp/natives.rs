//! The native (Rust-implemented) function table and its built-in functions.
//!
//! `call.native <index>` resolves against [`default_natives`]; the `NATIVE_*`
//! constants name the indices. Each function takes the VM's output sink and the
//! call arguments. These are the stand-ins for the eventual stdlib `native fn`
//! bindings — enough to write observable programs without a real stdlib.

use std::io::Write;

use super::{Trap, bug, struct_field};
use crate::value::{Obj, TAG_NONE, TAG_SOME, TY_OPTION, Value};

/// A native function: receives the VM's output sink and the call arguments.
pub type NativeFn = fn(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap>;

// Indices into the native table. These must match the order of [`NATIVES`]
// (guarded by a test). They name the runtime's *in-memory* dispatch index;
// persisted bytecode references natives by name and resolves to these on load.
pub const NATIVE_PRINTLN: u32 = 0;
pub const NATIVE_PRINT: u32 = 1;
pub const NATIVE_STRINGIFY: u32 = 2;
pub const NATIVE_STR_CONCAT: u32 = 3;
pub const NATIVE_LIST_INDEX: u32 = 4;
pub const NATIVE_LIST_GET: u32 = 5;
pub const NATIVE_LIST_LEN: u32 = 6;
pub const NATIVE_LIST_SET: u32 = 7;
pub const NATIVE_MAP_NEW: u32 = 8;
pub const NATIVE_MAP_INDEX: u32 = 9;
pub const NATIVE_MAP_GET: u32 = 10;
pub const NATIVE_MAP_LEN: u32 = 11;
pub const NATIVE_MAP_HAS: u32 = 12;
pub const NATIVE_MAP_SET: u32 = 13;
pub const NATIVE_SET_NEW: u32 = 14;
pub const NATIVE_SET_LEN: u32 = 15;
pub const NATIVE_SET_HAS: u32 = 16;
pub const NATIVE_SET_ADD: u32 = 17;
pub const NATIVE_SET_REMOVE: u32 = 18;
pub const NATIVE_EQ: u32 = 19;

/// The canonical native table: the name each native is bound by, paired with
/// its implementation, in index order. Names are the stable identity used by
/// the wire format; the index is a runtime-internal dispatch slot.
const NATIVES: &[(&str, NativeFn)] = &[
    ("println", native_println),
    ("print", native_print),
    ("stringify", native_stringify),
    ("str_concat", native_str_concat),
    ("list_index", native_list_index),
    ("list_get", native_list_get),
    ("list_len", native_list_len),
    ("list_set", native_list_set),
    ("map_new", native_map_new),
    ("map_index", native_map_index),
    ("map_get", native_map_get),
    ("map_len", native_map_len),
    ("map_has", native_map_has),
    ("map_set", native_map_set),
    ("set_new", native_set_new),
    ("set_len", native_set_len),
    ("set_has", native_set_has),
    ("set_add", native_set_add),
    ("set_remove", native_set_remove),
    ("eq", native_eq),
    ("str_len", native_str_len),
    ("str_byte_len", native_str_byte_len),
    ("str_is_empty", native_str_is_empty),
    ("str_trim", native_str_trim),
    ("str_contains", native_str_contains),
    ("str_starts_with", native_str_starts_with),
    ("str_ends_with", native_str_ends_with),
    ("str_to_uppercase", native_str_to_uppercase),
    ("str_to_lowercase", native_str_to_lowercase),
    ("str_lines", native_str_lines),
    ("str_split_whitespace", native_str_split_whitespace),
    ("str_split", native_str_split),
    ("str_chars", native_str_chars),
    ("str_bytes", native_str_bytes),
    ("str_from_chars", native_str_from_chars),
    ("int_to_double", native_int_to_double),
    ("double_to_int", native_double_to_int),
    ("math_sqrt", native_math_sqrt),
    ("math_pow", native_math_pow),
    ("math_floor", native_math_floor),
    ("math_ceil", native_math_ceil),
    ("math_round", native_math_round),
    ("math_trunc", native_math_trunc),
    ("math_exp", native_math_exp),
    ("math_ln", native_math_ln),
    ("math_log10", native_math_log10),
    ("math_sin", native_math_sin),
    ("math_cos", native_math_cos),
    ("math_tan", native_math_tan),
    ("math_asin", native_math_asin),
    ("math_acos", native_math_acos),
    ("math_atan", native_math_atan),
    ("math_atan2", native_math_atan2),
    ("math_hypot", native_math_hypot),
    ("str_to_int", native_str_to_int),
    ("str_to_double", native_str_to_double),
    ("option_ok_or", native_option_ok_or),
    ("option_unwrap_or", native_option_unwrap_or),
    ("option_is_some", native_option_is_some),
    ("option_is_none", native_option_is_none),
    ("fs_read_text", native_fs_read_text),
    ("fs_write_text", native_fs_write_text),
    ("time_now_millis", native_time_now_millis),
    ("random_mix", native_random_mix),
    ("random_to_unit", native_random_to_unit),
    ("random_seed_entropy", native_random_seed_entropy),
    ("env_get", native_env_get),
    ("env_set", native_env_set),
    ("env_vars", native_env_vars),
    ("env_args", native_env_args),
    ("env_current_dir", native_env_current_dir),
    ("env_set_current_dir", native_env_set_current_dir),
    ("env_os", native_env_os),
    ("env_exit", native_env_exit),
    ("map_keys", native_map_keys),
    ("map_values", native_map_values),
    ("map_remove", native_map_remove),
    ("map_is_empty", native_map_is_empty),
    ("list_join", native_list_join),
    ("list_push", native_list_push),
    ("process_run", native_process_run),
    ("process_start", native_process_start),
    ("process_wait", native_process_wait),
    ("process_kill", native_process_kill),
    ("process_stdin_write", native_process_stdin_write),
    ("process_stdout_read", native_process_stdout_read),
    ("process_stderr_read", native_process_stderr_read),
];

/// The native functions the runtime ships with, in index order.
pub fn default_natives() -> Vec<NativeFn> {
    NATIVES.iter().map(|&(_, f)| f).collect()
}

/// Resolve a native's name to its dispatch index (used when loading bytecode).
pub fn native_index(name: &str) -> Option<u32> {
    NATIVES
        .iter()
        .position(|&(n, _)| n == name)
        .map(|i| i as u32)
}

/// The name a native is bound by, for its dispatch index (used when emitting).
pub fn native_name(index: u32) -> Option<&'static str> {
    NATIVES.get(index as usize).map(|&(n, _)| n)
}

// --- text natives ---

/// Render a value to its `Display` string. Handles primitives and strings;
/// types whose `Display` needs an interface method are out of the draft scope.
/// (Also the `call.virtual 'display'` fallback for receivers with no impl row —
/// the built-in `Display` of primitives/String.)
pub(super) fn display_string(v: &Value) -> Result<String, Trap> {
    Ok(match v {
        Value::Int(n) => n.to_string(),
        Value::Double(x) => x.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Unit => "()".to_string(),
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Str(s) => s.clone(),
            Obj::Enum(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Set(_)
            | Obj::Struct { .. }
            | Obj::Closure { .. } => {
                return Err(bug("display: type has no built-in Display"));
            }
        },
    })
}

/// Extract the contents of a heap string, or fault.
fn str_contents(v: &Value) -> Result<String, Trap> {
    match v {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Str(s) => Ok(s.clone()),
            Obj::Enum(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Set(_)
            | Obj::Struct { .. }
            | Obj::Closure { .. } => Err(bug("expected string")),
        },
        v => Err(bug(format!("expected string, found {v:?}"))),
    }
}

fn expect_one<'b>(args: &'b [Value], who: &str) -> Result<&'b Value, Trap> {
    match args {
        [v] => Ok(v),
        _ => Err(bug(format!("{who} expects 1 argument, got {}", args.len()))),
    }
}

/// `println(value)` — write the value's Display form followed by a newline.
fn native_println(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = display_string(expect_one(args, "println")?)?;
    writeln!(out, "{s}").map_err(|e| bug(format!("println: {e}")))?;
    Ok(Value::Unit)
}

/// `print(value)` — like `println` without the trailing newline.
fn native_print(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = display_string(expect_one(args, "print")?)?;
    write!(out, "{s}").map_err(|e| bug(format!("print: {e}")))?;
    Ok(Value::Unit)
}

/// `stringify(value)` — the value's Display form, as a `String`.
fn native_stringify(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    Ok(Value::new_str(display_string(expect_one(
        args,
        "stringify",
    )?)?))
}

/// `str_concat(s0, s1, …)` — concatenate string arguments into one `String`.
fn native_str_concat(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let mut s = String::new();
    for a in args {
        s.push_str(&str_contents(a)?);
    }
    Ok(Value::new_str(s))
}

/// `a == b` — structural equality, the default `Eq`. Works for every value kind
/// (`Value`'s `PartialEq` compares heap objects by content, not identity), so it
/// backs `==`/`!=` on strings, structs, enums, and collections.
fn native_eq(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (a, b) = args2(args, "eq")?;
    Ok(Value::Bool(a == b))
}

// --- string natives ---
//
// These back `String` methods; the frontend dispatches `s.method(...)` to the
// matching native with the receiver as the first argument. Behaviour mirrors
// the Dart interpreter's `String` methods so the two toolchains agree.

/// Build a `List<String>` from an iterator of owned strings.
fn string_list(parts: impl IntoIterator<Item = String>) -> Value {
    Value::new_list(parts.into_iter().map(Value::new_str).collect())
}

/// Build a `List<Int>` from an iterator of `i64`s.
fn int_list(items: impl IntoIterator<Item = i64>) -> Value {
    Value::new_list(items.into_iter().map(Value::Int).collect())
}

/// `s.len()` — number of Unicode scalar values (not bytes).
fn native_str_len(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_len")?)?;
    Ok(Value::Int(s.chars().count() as i64))
}

/// `s.byte_len()` — length in UTF-8 bytes.
fn native_str_byte_len(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_byte_len")?)?;
    Ok(Value::Int(s.len() as i64))
}

/// `s.is_empty()`.
fn native_str_is_empty(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_is_empty")?)?;
    Ok(Value::Bool(s.is_empty()))
}

/// `s.trim()` — strip leading/trailing whitespace.
fn native_str_trim(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_trim")?)?;
    Ok(Value::new_str(s.trim()))
}

/// `s.contains(sub)`.
fn native_str_contains(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (s, sub) = args2(args, "str_contains")?;
    Ok(Value::Bool(
        str_contents(s)?.contains(str_contents(sub)?.as_str()),
    ))
}

/// `s.starts_with(prefix)`.
fn native_str_starts_with(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (s, p) = args2(args, "str_starts_with")?;
    Ok(Value::Bool(
        str_contents(s)?.starts_with(str_contents(p)?.as_str()),
    ))
}

/// `s.ends_with(suffix)`.
fn native_str_ends_with(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (s, p) = args2(args, "str_ends_with")?;
    Ok(Value::Bool(
        str_contents(s)?.ends_with(str_contents(p)?.as_str()),
    ))
}

/// `s.to_uppercase()`.
fn native_str_to_uppercase(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_to_uppercase")?)?;
    Ok(Value::new_str(s.to_uppercase()))
}

/// `s.to_lowercase()`.
fn native_str_to_lowercase(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_to_lowercase")?)?;
    Ok(Value::new_str(s.to_lowercase()))
}

/// `s.lines()` — split on `\n`; a single trailing newline yields no extra empty
/// line.
fn native_str_lines(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_lines")?)?;
    if s.is_empty() {
        return Ok(Value::new_list(vec![]));
    }
    let trimmed = s.strip_suffix('\n').unwrap_or(&s);
    Ok(string_list(trimmed.split('\n').map(str::to_string)))
}

/// `s.split_whitespace()` — runs of Unicode whitespace, no empty entries.
fn native_str_split_whitespace(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_split_whitespace")?)?;
    Ok(string_list(s.split_whitespace().map(str::to_string)))
}

/// `s.split(sep)` — split on each occurrence of `sep` (empties kept).
fn native_str_split(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (s, sep) = args2(args, "str_split")?;
    let (s, sep) = (str_contents(s)?, str_contents(sep)?);
    Ok(string_list(s.split(sep.as_str()).map(str::to_string)))
}

/// `s.chars()` — the Unicode scalar values (code points) as a `List<Int>`. The
/// inverse of `String.from_chars`.
fn native_str_chars(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_chars")?)?;
    Ok(int_list(s.chars().map(|c| c as i64)))
}

/// `s.bytes()` — the raw UTF-8 bytes (each 0..=255) as a `List<Int>`.
fn native_str_bytes(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_bytes")?)?;
    Ok(int_list(s.bytes().map(i64::from)))
}

/// `String.from_chars(cps)` — build a string from a list of Unicode code points.
fn native_str_from_chars(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_list(
        expect_one(args, "str_from_chars")?,
        "str_from_chars",
        |items| {
            let mut s = String::new();
            for item in items {
                let cp = as_int(item, "str_from_chars")?;
                let c = u32::try_from(cp)
                    .ok()
                    .and_then(char::from_u32)
                    .ok_or_else(|| bug(format!("str_from_chars: invalid code point {cp}")))?;
                s.push(c);
            }
            Ok(Value::new_str(s))
        },
    )
}

// --- more collection natives ---

/// `map.keys()` — the keys, in insertion order.
fn native_map_keys(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_map(expect_one(args, "map.keys")?, "map.keys", |entries| {
        Ok(Value::new_list(
            entries.iter().map(|(k, _)| k.clone()).collect(),
        ))
    })
}

/// `map.values()` — the values, in insertion order.
fn native_map_values(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_map(expect_one(args, "map.values")?, "map.values", |entries| {
        Ok(Value::new_list(
            entries.iter().map(|(_, v)| v.clone()).collect(),
        ))
    })
}

/// `map.remove(key)` — remove and return the value (`Some`), or `None`.
fn native_map_remove(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map.remove")?;
    with_map_mut(map, "map.remove", |entries| {
        match entries.iter().position(|(k, _)| k == key) {
            Some(pos) => Ok(Value::some(entries.remove(pos).1)),
            None => Ok(Value::none()),
        }
    })
}

/// `map.is_empty()`.
fn native_map_is_empty(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_map(
        expect_one(args, "map.is_empty")?,
        "map.is_empty",
        |entries| Ok(Value::Bool(entries.is_empty())),
    )
}

/// `list.join(sep)` — each element's Display form, joined by `sep`.
fn native_list_join(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (list, sep) = args2(args, "list.join")?;
    let sep = str_contents(sep)?;
    with_list(list, "list.join", |items| {
        let parts: Result<Vec<String>, Trap> = items.iter().map(display_string).collect();
        Ok(Value::new_str(parts?.join(&sep)))
    })
}

// --- Option natives ---

/// Read an `Option`'s variant tag and payload, faulting if `v` isn't an Option.
fn as_option(v: &Value, who: &str) -> Result<(u16, Vec<Value>), Trap> {
    match v {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Enum(e) if e.ty == TY_OPTION => Ok((e.variant, e.fields.clone())),
            _ => Err(bug(format!("{who}: expected Option"))),
        },
        _ => Err(bug(format!("{who}: expected Option"))),
    }
}

/// `opt.ok_or(err)` — `Some(v)` → `Ok(v)`, `None` → `Err(err)`.
fn native_option_ok_or(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (opt, err) = args2(args, "option_ok_or")?;
    let (variant, fields) = as_option(opt, "ok_or")?;
    Ok(if variant == TAG_SOME {
        Value::ok(fields.into_iter().next().unwrap_or(Value::Unit))
    } else {
        Value::err(err.clone())
    })
}

/// `opt.unwrap_or(default)` — the payload of `Some`, else `default`.
fn native_option_unwrap_or(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (opt, default) = args2(args, "option_unwrap_or")?;
    let (variant, fields) = as_option(opt, "unwrap_or")?;
    Ok(if variant == TAG_SOME {
        fields.into_iter().next().unwrap_or(Value::Unit)
    } else {
        default.clone()
    })
}

/// `opt.is_some()`.
fn native_option_is_some(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (variant, _) = as_option(expect_one(args, "option_is_some")?, "is_some")?;
    Ok(Value::Bool(variant == TAG_SOME))
}

/// `opt.is_none()`.
fn native_option_is_none(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (variant, _) = as_option(expect_one(args, "option_is_none")?, "is_none")?;
    Ok(Value::Bool(variant == TAG_NONE))
}

// --- std.fs natives ---
//
// Errors are returned as a `String` payload for now; once `std.core`'s `Error`
// type is linked in, these will build a proper `Error`.

/// `fs.read_text(path)` — read a UTF-8 file, `Ok(contents)` or `Err(message)`.
fn native_fs_read_text(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_read_text")?)?;
    Ok(match std::fs::read_to_string(&path) {
        Ok(s) => Value::ok(Value::new_str(s)),
        Err(e) => Value::err(Value::new_str(format!("{path}: {e}"))),
    })
}

/// `fs.write_text(path, contents)` — write a file, `Ok(())` or `Err(message)`.
fn native_fs_write_text(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (path, contents) = args2(args, "fs_write_text")?;
    let (path, contents) = (str_contents(path)?, str_contents(contents)?);
    Ok(match std::fs::write(&path, contents) {
        Ok(()) => Value::ok(Value::Unit),
        Err(e) => Value::err(Value::new_str(format!("{path}: {e}"))),
    })
}

// --- time natives ---

/// `time.now_millis()` — Unix time in milliseconds (the system wall clock).
/// The single ambient time effect; the `Clock` capability builds on it.
fn native_time_now_millis(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    if !args.is_empty() {
        return Err(bug(format!(
            "time_now_millis expects 0 arguments, got {}",
            args.len()
        )));
    }
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    Ok(Value::Int(millis))
}

// --- random natives ---
//
// std.random is a SplitMix64 generator whose entire state is a visible `Int`
// field in Hawk (no hidden runtime state). The state advances in Hawk by a
// wrapping add of the golden-ratio constant; these natives do only the parts
// that need bit operations, which Hawk does not have yet: mixing a state value
// into a uniform output, mapping bits to a unit Double, and seeding from
// entropy. Hand-rolled (SplitMix64 is a few lines) to keep the runtime
// dependency-free; a crate could replace it behind the same three natives.

/// SplitMix64 finalizing mix: scramble a state value into a uniformly
/// distributed 64-bit output.
fn splitmix64_mix(mut z: u64) -> u64 {
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
}

/// `random_mix(state)` — the SplitMix64 output for a state value. The bit
/// pattern is reinterpreted between Hawk's `Int` (i64) and the u64 the mixer
/// uses.
fn native_random_mix(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let state = as_int(expect_one(args, "random_mix")?, "random_mix")? as u64;
    Ok(Value::Int(splitmix64_mix(state) as i64))
}

/// `random_to_unit(bits)` — map a uniform 64-bit pattern to a Double in [0, 1)
/// using its top 53 bits (the f64 mantissa width).
fn native_random_to_unit(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let bits = as_int(expect_one(args, "random_to_unit")?, "random_to_unit")? as u64;
    let unit = (bits >> 11) as f64 / (1u64 << 53) as f64;
    Ok(Value::Double(unit))
}

/// `random_seed_entropy()` — a non-deterministic seed from the system clock,
/// mixed with a per-call counter so near-simultaneous calls diverge. For
/// `random.from_entropy`; not cryptographically secure.
fn native_random_seed_entropy(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    if !args.is_empty() {
        return Err(bug(format!(
            "random_seed_entropy expects 0 arguments, got {}",
            args.len()
        )));
    }
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let seed = splitmix64_mix(nanos.wrapping_add(n.wrapping_mul(0x9E3779B97F4A7C15)));
    Ok(Value::Int(seed as i64))
}

// --- env natives ---
//
// The ambient environment: variables, program arguments, working directory, and
// platform. These are the real process effects behind `std.env`'s free
// functions; the `Env` capability dispatches to them (or, in tests, to a fake).

/// The program arguments (everything after the `.hawkbc` path), stashed by the
/// `run` entry point so `env.args()` can return them without re-deriving the
/// runtime's own argv prefix.
static PROGRAM_ARGS: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();

/// Record the program arguments for `env.args()`. Called once, before the entry
/// function runs.
pub fn set_program_args(args: Vec<String>) {
    let _ = PROGRAM_ARGS.set(args);
}

fn expect_no_args(args: &[Value], who: &str) -> Result<(), Trap> {
    if args.is_empty() {
        Ok(())
    } else {
        Err(bug(format!(
            "{who} expects 0 arguments, got {}",
            args.len()
        )))
    }
}

/// `env.get(name)` — the value of an environment variable, or None if unset.
fn native_env_get(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let name = str_contents(expect_one(args, "env_get")?)?;
    Ok(match std::env::var(&name) {
        Ok(v) => Value::some(Value::new_str(v)),
        Err(_) => Value::none(),
    })
}

/// `env.set(name, value)` — set an environment variable for this process.
fn native_env_set(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (name, value) = args2(args, "env_set")?;
    let (name, value) = (str_contents(name)?, str_contents(value)?);
    // Safety: the runtime is single-threaded; no other thread reads the
    // environment concurrently (the basis for `set_var` being unsafe in 2024).
    unsafe { std::env::set_var(name, value) };
    Ok(Value::Unit)
}

/// `env.vars()` — all environment variables as a `Map<String, String>`.
fn native_env_vars(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    expect_no_args(args, "env_vars")?;
    let entries = std::env::vars()
        .map(|(k, v)| (Value::new_str(k), Value::new_str(v)))
        .collect();
    Ok(Value::new_map(entries))
}

/// `env.args()` — the program arguments as a `List<String>`.
fn native_env_args(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    expect_no_args(args, "env_args")?;
    let argv = PROGRAM_ARGS.get().cloned().unwrap_or_default();
    Ok(Value::new_list(
        argv.into_iter().map(Value::new_str).collect(),
    ))
}

/// `env.current_dir()` — the process working directory, or an error.
fn native_env_current_dir(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    expect_no_args(args, "env_current_dir")?;
    Ok(match std::env::current_dir() {
        Ok(p) => Value::ok(Value::new_str(p.to_string_lossy().into_owned())),
        Err(e) => Value::err(Value::new_str(e.to_string())),
    })
}

/// `env.set_current_dir(path)` — change the process working directory.
fn native_env_set_current_dir(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "env_set_current_dir")?)?;
    Ok(match std::env::set_current_dir(&path) {
        Ok(()) => Value::ok(Value::Unit),
        Err(e) => Value::err(Value::new_str(format!("{path}: {e}"))),
    })
}

/// `env.os()` — the platform: 'macos' | 'linux' | 'windows' | ...
fn native_env_os(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    expect_no_args(args, "env_os")?;
    Ok(Value::new_str(std::env::consts::OS))
}

/// `env.exit(code)` — terminate the process with an exit code (does not return).
fn native_env_exit(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let code = as_int(expect_one(args, "env_exit")?, "env_exit")?;
    std::process::exit(code as i32)
}

// --- collection natives ---

fn args2<'b>(args: &'b [Value], who: &str) -> Result<(&'b Value, &'b Value), Trap> {
    match args {
        [a, b] => Ok((a, b)),
        _ => Err(bug(format!(
            "{who} expects 2 arguments, got {}",
            args.len()
        ))),
    }
}

fn args3<'b>(args: &'b [Value], who: &str) -> Result<(&'b Value, &'b Value, &'b Value), Trap> {
    match args {
        [a, b, c] => Ok((a, b, c)),
        _ => Err(bug(format!(
            "{who} expects 3 arguments, got {}",
            args.len()
        ))),
    }
}

fn as_int(v: &Value, who: &str) -> Result<i64, Trap> {
    match v {
        Value::Int(n) => Ok(*n),
        _ => Err(bug(format!("{who}: expected Int, found {v:?}"))),
    }
}

fn as_double(v: &Value, who: &str) -> Result<f64, Trap> {
    match v {
        Value::Double(x) => Ok(*x),
        _ => Err(bug(format!("{who}: expected Double, found {v:?}"))),
    }
}

// --- numeric natives ---

/// `n.to_double()` — widen an Int to a Double.
fn native_int_to_double(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let n = as_int(expect_one(args, "int_to_double")?, "int_to_double")?;
    Ok(Value::Double(n as f64))
}

/// `x.to_int()` — truncate a Double toward zero to an Int.
fn native_double_to_int(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let x = as_double(expect_one(args, "double_to_int")?, "double_to_int")?;
    Ok(Value::Int(x as i64))
}

/// Apply a unary `f64 -> f64` function to a single Double argument.
fn math_unary(args: &[Value], who: &str, f: impl Fn(f64) -> f64) -> Result<Value, Trap> {
    let x = as_double(expect_one(args, who)?, who)?;
    Ok(Value::Double(f(x)))
}

fn native_math_sqrt(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_sqrt", f64::sqrt)
}
fn native_math_floor(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_floor", f64::floor)
}
fn native_math_ceil(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_ceil", f64::ceil)
}
fn native_math_round(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_round", f64::round)
}
fn native_math_trunc(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_trunc", f64::trunc)
}
fn native_math_exp(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_exp", f64::exp)
}
fn native_math_ln(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_ln", f64::ln)
}
fn native_math_log10(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_log10", f64::log10)
}
fn native_math_sin(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_sin", f64::sin)
}
fn native_math_cos(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_cos", f64::cos)
}
fn native_math_tan(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_tan", f64::tan)
}

fn native_math_asin(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_asin", f64::asin)
}
fn native_math_acos(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_acos", f64::acos)
}
fn native_math_atan(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    math_unary(a, "math_atan", f64::atan)
}

/// `math.pow(base, exp)` — `base` raised to `exp` (both Double).
fn native_math_pow(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    let (base, exp) = args2(a, "math_pow")?;
    Ok(Value::Double(
        as_double(base, "math_pow")?.powf(as_double(exp, "math_pow")?),
    ))
}

/// `math.atan2(y, x)` — the angle of the point (x, y) from the positive x-axis.
fn native_math_atan2(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    let (y, x) = args2(a, "math_atan2")?;
    Ok(Value::Double(
        as_double(y, "math_atan2")?.atan2(as_double(x, "math_atan2")?),
    ))
}

/// `math.hypot(x, y)` — `sqrt(x*x + y*y)` without overflow/underflow.
fn native_math_hypot(_o: &mut dyn Write, a: &[Value]) -> Result<Value, Trap> {
    let (x, y) = args2(a, "math_hypot")?;
    Ok(Value::Double(
        as_double(x, "math_hypot")?.hypot(as_double(y, "math_hypot")?),
    ))
}

/// `s.to_int()` — parse the whole string as a base-10 Int, or None.
fn native_str_to_int(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_to_int")?)?;
    Ok(match s.parse::<i64>() {
        Ok(n) => Value::some(Value::Int(n)),
        Err(_) => Value::none(),
    })
}

/// `s.to_double()` — parse the whole string as a Double, or None.
fn native_str_to_double(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_to_double")?)?;
    Ok(match s.parse::<f64>() {
        Ok(x) => Value::some(Value::Double(x)),
        Err(_) => Value::none(),
    })
}

/// Resolve a (possibly out-of-range) index against `len`, faulting if outside
/// `0..len`. This is the trap behind `list[i]`.
fn checked_index(i: i64, len: usize) -> Result<usize, Trap> {
    if i < 0 || i as u64 >= len as u64 {
        Err(Trap::IndexOutOfBounds { index: i, len })
    } else {
        Ok(i as usize)
    }
}

fn with_list<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&[Value]) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::List(items) => f(items),
            _ => Err(bug(format!("{who}: expected list"))),
        },
        _ => Err(bug(format!("{who}: expected list"))),
    }
}

fn with_list_mut<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&mut Vec<Value>) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(rc) => match &mut *rc.borrow_mut() {
            Obj::List(items) => f(items),
            _ => Err(bug(format!("{who}: expected list"))),
        },
        _ => Err(bug(format!("{who}: expected list"))),
    }
}

fn with_map<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&[(Value, Value)]) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Map(entries) => f(entries),
            _ => Err(bug(format!("{who}: expected map"))),
        },
        _ => Err(bug(format!("{who}: expected map"))),
    }
}

fn with_map_mut<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&mut Vec<(Value, Value)>) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(rc) => match &mut *rc.borrow_mut() {
            Obj::Map(entries) => f(entries),
            _ => Err(bug(format!("{who}: expected map"))),
        },
        _ => Err(bug(format!("{who}: expected map"))),
    }
}

fn map_find<'b>(entries: &'b [(Value, Value)], key: &Value) -> Option<&'b Value> {
    entries.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

fn map_insert(entries: &mut Vec<(Value, Value)>, key: Value, val: Value) {
    if let Some(slot) = entries.iter_mut().find(|(k, _)| *k == key) {
        slot.1 = val;
    } else {
        entries.push((key, val));
    }
}

/// `list[i]` — element at `i`, faulting if out of range.
fn native_list_index(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (list, idx) = args2(args, "list index")?;
    let i = as_int(idx, "list index")?;
    with_list(list, "list index", |items| {
        Ok(items[checked_index(i, items.len())?].clone())
    })
}

/// `list.get(i)` — `Some(element)` if `i` is in range, else `None`.
fn native_list_get(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (list, idx) = args2(args, "list.get")?;
    let i = as_int(idx, "list.get")?;
    with_list(list, "list.get", |items| {
        Ok(match checked_index(i, items.len()) {
            Ok(n) => Value::some(items[n].clone()),
            Err(_) => Value::none(),
        })
    })
}

/// `list.len()`.
fn native_list_len(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_list(expect_one(args, "list.len")?, "list.len", |items| {
        Ok(Value::Int(items.len() as i64))
    })
}

/// `list[i] = v` — in-place update, faulting if out of range. Returns `Unit`.
fn native_list_set(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (list, idx, val) = args3(args, "list set")?;
    let i = as_int(idx, "list set")?;
    with_list_mut(list, "list set", |items| {
        let n = checked_index(i, items.len())?;
        items[n] = val.clone();
        Ok(Value::Unit)
    })
}

/// `list.push(value)` — append a value to the list, in place. Returns Unit.
fn native_list_push(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (list, val) = args2(args, "list push")?;
    with_list_mut(list, "list push", |items| {
        items.push(val.clone());
        Ok(Value::Unit)
    })
}

/// `{k0: v0, …}` — build a map from alternating key/value arguments.
fn native_map_new(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    if !args.len().is_multiple_of(2) {
        return Err(bug("map literal: expected an even number of arguments"));
    }
    let mut entries: Vec<(Value, Value)> = Vec::new();
    for pair in args.chunks_exact(2) {
        map_insert(&mut entries, pair[0].clone(), pair[1].clone());
    }
    Ok(Value::new_map(entries))
}

/// `map[key]` — value for `key`, faulting if absent.
fn native_map_index(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map index")?;
    with_map(map, "map index", |entries| {
        map_find(entries, key).cloned().ok_or(Trap::MissingKey)
    })
}

/// `map.get(key)` — `Some(value)` if present, else `None`.
fn native_map_get(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map.get")?;
    with_map(map, "map.get", |entries| {
        Ok(match map_find(entries, key) {
            Some(v) => Value::some(v.clone()),
            None => Value::none(),
        })
    })
}

/// `map.len()`.
fn native_map_len(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_map(expect_one(args, "map.len")?, "map.len", |entries| {
        Ok(Value::Int(entries.len() as i64))
    })
}

/// `map.has(key)`.
fn native_map_has(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map.has")?;
    with_map(map, "map.has", |entries| {
        Ok(Value::Bool(map_find(entries, key).is_some()))
    })
}

/// `map[key] = v` — insert or update in place. Returns `Unit`.
fn native_map_set(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key, val) = args3(args, "map set")?;
    with_map_mut(map, "map set", |entries| {
        map_insert(entries, key.clone(), val.clone());
        Ok(Value::Unit)
    })
}

// --- set natives ---

fn with_set<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&[Value]) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Set(elements) => f(elements),
            _ => Err(bug(format!("{who}: expected set"))),
        },
        _ => Err(bug(format!("{who}: expected set"))),
    }
}

fn with_set_mut<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&mut Vec<Value>) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(rc) => match &mut *rc.borrow_mut() {
            Obj::Set(elements) => f(elements),
            _ => Err(bug(format!("{who}: expected set"))),
        },
        _ => Err(bug(format!("{who}: expected set"))),
    }
}

fn set_contains(elements: &[Value], v: &Value) -> bool {
    elements.iter().any(|e| e == v)
}

fn set_insert(elements: &mut Vec<Value>, v: Value) {
    if !set_contains(elements, &v) {
        elements.push(v);
    }
}

/// `Set.from([...])` — build a set from values, dropping duplicates.
fn native_set_new(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let mut elements: Vec<Value> = Vec::new();
    for v in args {
        set_insert(&mut elements, v.clone());
    }
    Ok(Value::new_set(elements))
}

/// `set.len()`.
fn native_set_len(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_set(expect_one(args, "set.len")?, "set.len", |elements| {
        Ok(Value::Int(elements.len() as i64))
    })
}

/// `set.has(value)`.
fn native_set_has(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (set, v) = args2(args, "set.has")?;
    with_set(set, "set.has", |elements| {
        Ok(Value::Bool(set_contains(elements, v)))
    })
}

/// `set.add(value)` — insert in place (no-op if present). Returns `Unit`.
fn native_set_add(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (set, v) = args2(args, "set.add")?;
    with_set_mut(set, "set.add", |elements| {
        set_insert(elements, v.clone());
        Ok(Value::Unit)
    })
}

/// `set.remove(value)` — remove in place; returns whether it was present.
fn native_set_remove(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (set, v) = args2(args, "set.remove")?;
    with_set_mut(set, "set.remove", |elements| {
        match elements.iter().position(|e| e == v) {
            Some(pos) => {
                elements.remove(pos);
                Ok(Value::Bool(true))
            }
            None => Ok(Value::Bool(false)),
        }
    })
}

// --- process natives ---

use std::collections::HashMap;
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Mutex, OnceLock};

static NEXT_PROCESS_ID: AtomicI64 = AtomicI64::new(1);

struct RunningProcess {
    child: Child,
    stdin: Option<std::process::ChildStdin>,
    stdout: Option<std::process::ChildStdout>,
    stderr: Option<std::process::ChildStderr>,
}

fn process_registry() -> &'static Mutex<HashMap<i64, RunningProcess>> {
    static REGISTRY: OnceLock<Mutex<HashMap<i64, RunningProcess>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn make_error(msg: impl Into<String>) -> Value {
    Value::err(Value::new_struct(0, vec![Value::new_str(msg)]))
}

fn get_process_id(process_val: &Value) -> Result<i64, Trap> {
    let id_val = struct_field(process_val, 0)?;
    match id_val {
        Value::Int(id) => Ok(id),
        _ => Err(bug("expected process id to be an Int")),
    }
}

fn expect_string_list(v: &Value, who: &str) -> Result<Vec<String>, Trap> {
    with_list(v, who, |items| {
        let mut list = Vec::new();
        for item in items {
            list.push(str_contents(item)?);
        }
        Ok(list)
    })
}

fn expect_option_string(v: &Value, who: &str) -> Result<Option<String>, Trap> {
    let (variant, fields) = as_option(v, who)?;
    if variant == TAG_SOME {
        let first = fields
            .first()
            .ok_or_else(|| bug(format!("{who}: missing Some field")))?;
        Ok(Some(str_contents(first)?))
    } else {
        Ok(None)
    }
}

fn expect_option_map(v: &Value, who: &str) -> Result<Option<HashMap<String, String>>, Trap> {
    let (variant, fields) = as_option(v, who)?;
    if variant == TAG_SOME {
        let first = fields
            .first()
            .ok_or_else(|| bug(format!("{who}: missing Some field")))?;
        with_map(first, who, |entries| {
            let mut map = HashMap::new();
            for (k, val) in entries {
                map.insert(str_contents(k)?, str_contents(val)?);
            }
            Ok(Some(map))
        })
    } else {
        Ok(None)
    }
}

/// `process_run(command, args, working_dir, env)`
fn native_process_run(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    if args.is_empty() || args.len() > 4 {
        return Err(bug(format!(
            "process_run expects between 1 and 4 arguments, got {}",
            args.len()
        )));
    }
    let cmd_name = str_contents(&args[0])?;
    let cmd_args = if args.len() >= 2 {
        expect_string_list(&args[1], "process_run: args")?
    } else {
        Vec::new()
    };
    let working_dir = if args.len() >= 3 {
        expect_option_string(&args[2], "process_run: working_dir")?
    } else {
        None
    };
    let env = if args.len() >= 4 {
        expect_option_map(&args[3], "process_run: env")?
    } else {
        None
    };

    let mut command = Command::new(&cmd_name);
    command.args(&cmd_args);
    if let Some(dir) = working_dir {
        command.current_dir(dir);
    }
    if let Some(env_map) = env {
        command.envs(env_map);
    }
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());

    match command.output() {
        Ok(output) => {
            let exit_code = output.status.code().unwrap_or(-1) as i64;
            let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
            let stderr = String::from_utf8_lossy(&output.stderr).into_owned();

            let res = Value::new_struct(
                0,
                vec![
                    Value::Int(exit_code),
                    Value::new_str(stdout),
                    Value::new_str(stderr),
                ],
            );
            Ok(Value::ok(res))
        }
        Err(e) => Ok(make_error(format!(
            "Failed to run command '{}': {}",
            cmd_name, e
        ))),
    }
}

/// `process_start(command, args, working_dir, env)`
fn native_process_start(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    if args.is_empty() || args.len() > 4 {
        return Err(bug(format!(
            "process_start expects between 1 and 4 arguments, got {}",
            args.len()
        )));
    }
    let cmd_name = str_contents(&args[0])?;
    let cmd_args = if args.len() >= 2 {
        expect_string_list(&args[1], "process_start: args")?
    } else {
        Vec::new()
    };
    let working_dir = if args.len() >= 3 {
        expect_option_string(&args[2], "process_start: working_dir")?
    } else {
        None
    };
    let env = if args.len() >= 4 {
        expect_option_map(&args[3], "process_start: env")?
    } else {
        None
    };

    let mut command = Command::new(&cmd_name);
    command.args(&cmd_args);
    if let Some(dir) = working_dir {
        command.current_dir(dir);
    }
    if let Some(env_map) = env {
        command.envs(env_map);
    }
    command.stdin(Stdio::piped());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());

    match command.spawn() {
        Ok(mut child) => {
            let id = NEXT_PROCESS_ID.fetch_add(1, Ordering::SeqCst);

            let stdin = child.stdin.take();
            let stdout = child.stdout.take();
            let stderr = child.stderr.take();

            let running = RunningProcess {
                child,
                stdin,
                stdout,
                stderr,
            };

            process_registry().lock().unwrap().insert(id, running);

            let proc = Value::new_struct(0, vec![Value::Int(id)]);
            Ok(Value::ok(proc))
        }
        Err(e) => Ok(make_error(format!(
            "Failed to start command '{}': {}",
            cmd_name, e
        ))),
    }
}

/// `process_wait(self)`
fn native_process_wait(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let process_val = expect_one(args, "process_wait")?;
    let id = get_process_id(process_val)?;

    let mut registry = process_registry().lock().unwrap();
    let mut running = match registry.remove(&id) {
        Some(r) => r,
        None => {
            return Ok(make_error(format!(
                "Process with ID {id} not found (it may have already been waited on)"
            )));
        }
    };
    drop(registry);

    match running.child.wait() {
        Ok(status) => {
            let exit_code = status.code().unwrap_or(-1) as i64;
            Ok(Value::ok(Value::Int(exit_code)))
        }
        Err(e) => Ok(make_error(format!(
            "Failed to wait for process {id}: {}",
            e
        ))),
    }
}

/// `process_kill(self)`
fn native_process_kill(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let process_val = expect_one(args, "process_kill")?;
    let id = get_process_id(process_val)?;

    let mut registry = process_registry().lock().unwrap();
    let mut running = match registry.remove(&id) {
        Some(r) => r,
        None => {
            return Ok(make_error(format!("Process with ID {id} not found")));
        }
    };
    drop(registry);

    match running.child.kill() {
        Ok(()) => {
            let _ = running.child.wait();
            Ok(Value::ok(Value::Unit))
        }
        Err(e) => Ok(make_error(format!("Failed to kill process {id}: {}", e))),
    }
}

/// `process_stdin_write(self, data)`
fn native_process_stdin_write(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (process_val, data_val) = args2(args, "process_stdin_write")?;
    let id = get_process_id(process_val)?;
    let data = str_contents(data_val)?;

    let mut registry = process_registry().lock().unwrap();
    let running = match registry.get_mut(&id) {
        Some(r) => r,
        None => {
            return Ok(make_error(format!("Process with ID {id} not found")));
        }
    };

    let stdin = match &mut running.stdin {
        Some(s) => s,
        None => {
            return Ok(make_error(format!(
                "Process with ID {id} standard input is not available"
            )));
        }
    };

    match stdin.write_all(data.as_bytes()) {
        Ok(()) => {
            let _ = stdin.flush();
            Ok(Value::ok(Value::Unit))
        }
        Err(e) => Ok(make_error(format!(
            "Failed to write to stdin of process {id}: {}",
            e
        ))),
    }
}

/// `process_stdout_read(self)`
fn native_process_stdout_read(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let process_val = expect_one(args, "process_stdout_read")?;
    let id = get_process_id(process_val)?;

    let mut registry = process_registry().lock().unwrap();
    let running = match registry.get_mut(&id) {
        Some(r) => r,
        None => {
            return Ok(make_error(format!("Process with ID {id} not found")));
        }
    };

    let stdout = match &mut running.stdout {
        Some(s) => s,
        None => {
            return Ok(Value::ok(Value::new_str("")));
        }
    };

    let mut buf = [0u8; 4096];
    match stdout.read(&mut buf) {
        Ok(0) => {
            running.stdout = None;
            Ok(Value::ok(Value::new_str("")))
        }
        Ok(n) => {
            let s = String::from_utf8_lossy(&buf[..n]).into_owned();
            Ok(Value::ok(Value::new_str(s)))
        }
        Err(e) => Ok(make_error(format!(
            "Failed to read stdout of process {id}: {}",
            e
        ))),
    }
}

/// `process_stderr_read(self)`
fn native_process_stderr_read(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let process_val = expect_one(args, "process_stderr_read")?;
    let id = get_process_id(process_val)?;

    let mut registry = process_registry().lock().unwrap();
    let running = match registry.get_mut(&id) {
        Some(r) => r,
        None => {
            return Ok(make_error(format!("Process with ID {id} not found")));
        }
    };

    let stderr = match &mut running.stderr {
        Some(s) => s,
        None => {
            return Ok(Value::ok(Value::new_str("")));
        }
    };

    let mut buf = [0u8; 4096];
    match stderr.read(&mut buf) {
        Ok(0) => {
            running.stderr = None;
            Ok(Value::ok(Value::new_str("")))
        }
        Ok(n) => {
            let s = String::from_utf8_lossy(&buf[..n]).into_owned();
            Ok(Value::ok(Value::new_str(s)))
        }
        Err(e) => Ok(make_error(format!(
            "Failed to read stderr of process {id}: {}",
            e
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_indices_agree() {
        assert_eq!(native_index("println"), Some(NATIVE_PRINTLN));
        assert_eq!(native_index("str_concat"), Some(NATIVE_STR_CONCAT));
        assert_eq!(native_index("map_set"), Some(NATIVE_MAP_SET));
        assert_eq!(native_name(NATIVE_STRINGIFY), Some("stringify"));
        assert_eq!(native_index("set_add"), Some(NATIVE_SET_ADD));
        assert_eq!(native_index("eq"), Some(NATIVE_EQ));
        assert_eq!(native_index("nope"), None);
        assert_eq!(default_natives().len(), NATIVES.len());
    }

    #[test]
    fn splitmix64_is_deterministic_and_distributed() {
        // The reference SplitMix64 output for seed 0 advanced by the gamma
        // constant once: state 0x9E3779B97F4A7C15 mixes to this value. Locks
        // the algorithm constants so a behaviour change is caught here.
        let state = 0x9E3779B97F4A7C15u64;
        assert_eq!(splitmix64_mix(state), 0xE220A8397B1DCDAF);
        // Distinct states give distinct outputs; the mixer is not the identity.
        assert_ne!(splitmix64_mix(1), splitmix64_mix(2));
        assert_ne!(splitmix64_mix(1), 1);
    }

    #[test]
    fn random_to_unit_is_in_range() {
        let sink = &mut std::io::sink();
        // All-zero bits -> 0.0; all-one bits -> just under 1.0.
        assert_eq!(
            native_random_to_unit(sink, &[Value::Int(0)]),
            Ok(Value::Double(0.0)),
        );
        let max = native_random_to_unit(sink, &[Value::Int(-1)]); // 0xFFFF...FFFF
        match max {
            Ok(Value::Double(x)) => assert!((0.0..1.0).contains(&x), "{x} not in [0,1)"),
            other => panic!("expected a Double in [0,1), got {other:?}"),
        }
    }

    #[test]
    fn option_ok_or_converts() {
        let sink = &mut std::io::sink();
        assert_eq!(
            native_option_ok_or(sink, &[Value::some(Value::Int(5)), Value::Int(0)]),
            Ok(Value::ok(Value::Int(5))),
        );
        assert_eq!(
            native_option_ok_or(sink, &[Value::none(), Value::new_str("e")]),
            Ok(Value::err(Value::new_str("e"))),
        );
    }

    #[test]
    fn eq_is_structural() {
        let yes = |a, b| native_eq(&mut std::io::sink(), &[a, b]) == Ok(Value::Bool(true));
        // Strings and lists compare by content, not identity.
        assert!(yes(Value::new_str("hi"), Value::new_str("hi")));
        assert!(!yes(Value::new_str("hi"), Value::new_str("ho")));
        assert!(yes(
            Value::new_list(vec![Value::Int(1), Value::Int(2)]),
            Value::new_list(vec![Value::Int(1), Value::Int(2)]),
        ));
        assert!(yes(Value::Int(7), Value::Int(7)));
        assert!(!yes(Value::Int(7), Value::new_str("7")));
    }
}
