//! The native (Rust-implemented) function table and its built-in functions.
//!
//! `call.native <index>` resolves against [`default_natives`]; the `NATIVE_*`
//! constants name the indices. Each function takes the VM's output sink and the
//! call arguments. These are the stand-ins for the eventual stdlib `native fn`
//! bindings — enough to write observable programs without a real stdlib.

use std::io::Write;

use super::{Trap, bug, struct_field};
use crate::heap;
use crate::value::{Obj, TAG_SOME, TY_OPTION, Value};

/// A native function: receives the VM's output sink and the call arguments.
pub type NativeFn = fn(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap>;

// Named dispatch indices for the natives that Rust-side bytecode construction
// (the builders, codec, and demo) references by index. They *derive* from
// [`NATIVES`] via [`native_idx`], so the table is the single source of truth:
// reorder or insert anywhere and these follow automatically (a wrong name fails
// the build). The index is the runtime's *in-memory* dispatch slot; persisted
// bytecode references natives by name and resolves to it on load.
pub const NATIVE_PRINTLN: u32 = native_idx("println");
pub const NATIVE_PRINT: u32 = native_idx("print");
pub const NATIVE_STRINGIFY: u32 = native_idx("stringify");
pub const NATIVE_STR_CONCAT: u32 = native_idx("str_concat");
pub const NATIVE_LIST_INDEX: u32 = native_idx("list_index");
pub const NATIVE_LIST_GET: u32 = native_idx("list_get");
pub const NATIVE_LIST_LEN: u32 = native_idx("list_len");
pub const NATIVE_LIST_SET: u32 = native_idx("list_set");
pub const NATIVE_MAP_NEW: u32 = native_idx("map_new");
pub const NATIVE_MAP_INDEX: u32 = native_idx("map_index");
pub const NATIVE_MAP_GET: u32 = native_idx("map_get");
pub const NATIVE_MAP_LEN: u32 = native_idx("map_len");
pub const NATIVE_MAP_HAS: u32 = native_idx("map_has");
pub const NATIVE_MAP_SET: u32 = native_idx("map_set");
pub const NATIVE_SET_NEW: u32 = native_idx("set_new");
pub const NATIVE_SET_LEN: u32 = native_idx("set_len");
pub const NATIVE_SET_HAS: u32 = native_idx("set_has");
pub const NATIVE_SET_ADD: u32 = native_idx("set_add");
pub const NATIVE_SET_REMOVE: u32 = native_idx("set_remove");
pub const NATIVE_EQ: u32 = native_idx("eq");

/// The index of the native named `name` in [`NATIVES`], evaluated at compile
/// time so the `NATIVE_*` constants stay in sync with the table for free.
/// Panics (a build error) if `name` is not a registered native.
const fn native_idx(name: &str) -> u32 {
    let mut i = 0;
    while i < NATIVES.len() {
        if const_str_eq(NATIVES[i].0, name) {
            return i as u32;
        }
        i += 1;
    }
    panic!("native_idx: unknown native name");
}

/// `&str` equality usable in a `const fn`.
const fn const_str_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}

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
    ("str_try_from_chars", native_str_try_from_chars),
    ("int_to_double", native_int_to_double),
    ("double_to_int", native_double_to_int),
    ("double_to_bits", native_double_to_bits),
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
    ("fs_read_text", native_fs_read_text),
    ("fs_write_text", native_fs_write_text),
    ("fs_read_bytes", native_fs_read_bytes),
    ("fs_write_bytes", native_fs_write_bytes),
    ("fs_exists", native_fs_exists),
    ("fs_list_dir", native_fs_list_dir),
    ("fs_metadata", native_fs_metadata),
    ("fs_create_dir", native_fs_create_dir),
    ("fs_create_dir_all", native_fs_create_dir_all),
    ("fs_remove", native_fs_remove),
    ("fs_remove_dir_all", native_fs_remove_dir_all),
    ("fs_rename", native_fs_rename),
    ("fs_copy", native_fs_copy),
    ("fs_temp_dir", native_fs_temp_dir),
    ("time_now_millis", native_time_now_millis),
    ("time_monotonic_nanos", native_time_monotonic_nanos),
    ("time_sleep_millis", native_time_sleep_millis),
    ("random_seed_entropy", native_random_seed_entropy),
    ("env_get", native_env_get),
    ("env_set", native_env_set),
    ("env_vars", native_env_vars),
    ("env_args", native_env_args),
    ("env_current_dir", native_env_current_dir),
    ("env_current_exe", native_env_current_exe),
    ("env_set_current_dir", native_env_set_current_dir),
    ("env_os", native_env_os),
    ("env_exit", native_env_exit),
    ("map_keys", native_map_keys),
    ("map_values", native_map_values),
    ("map_remove", native_map_remove),
    ("list_join", native_list_join),
    ("list_push", native_list_push),
    ("process_run", native_process_run),
    ("process_exec", native_process_exec),
    ("process_start", native_process_start),
    ("process_wait", native_process_wait),
    ("process_kill", native_process_kill),
    ("process_stdin_write", native_process_stdin_write),
    ("process_stdin_close", native_process_stdin_close),
    ("process_stdout_read", native_process_stdout_read),
    ("process_stderr_read", native_process_stderr_read),
    ("bytes_len", native_bytes_len),
    ("bytes_get", native_bytes_get),
    ("bytes_slice", native_bytes_slice),
    ("bytes_concat", native_bytes_concat),
    ("bytes_to_string", native_bytes_to_string),
    ("bytes_to_list", native_bytes_to_list),
    ("bytes_empty", native_bytes_empty),
    ("bytes_from_list", native_bytes_from_list),
    ("bytesbuilder_new", native_bytesbuilder_new),
    ("bytesbuilder_write_u8", native_bytesbuilder_write_u8),
    ("bytesbuilder_write_bytes", native_bytesbuilder_write_bytes),
    ("bytesbuilder_write_str", native_bytesbuilder_write_str),
    ("bytesbuilder_len", native_bytesbuilder_len),
    ("bytesbuilder_finish", native_bytesbuilder_finish),
    ("io_stdin_read", native_io_stdin_read),
    ("io_stdout_write", native_io_stdout_write),
    ("io_stderr_write", native_io_stderr_write),
    // Appended after the index-stable block above (these are bound by name, so
    // no `NATIVE_*` index constant is needed).
    ("eprintln", native_eprintln),
    ("eprint", native_eprint),
    ("fiber_spawn", native_fiber_spawn),
    ("fiber_join", native_fiber_join),
    ("fiber_yield", native_fiber_yield),
    ("channel_new", native_channel_new),
    ("channel_send", native_channel_send),
    ("channel_receive", native_channel_receive),
    ("channel_close", native_channel_close),
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
        Value::Double(x) => crate::value::format_double(*x),
        Value::Bool(b) => b.to_string(),
        Value::Unit => "()".to_string(),
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Str(s) => Ok(s.clone()),
            Obj::Bytes(_)
            | Obj::BytesBuilder(_)
            | Obj::Enum(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Set(_)
            | Obj::Struct { .. }
            | Obj::Closure { .. } => Err(bug("display: type has no built-in Display")),
        })?,
    })
}

/// Extract the contents of a heap string, or fault.
fn str_contents(v: &Value) -> Result<String, Trap> {
    match v {
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Str(s) => Ok(s.clone()),
            Obj::Bytes(_)
            | Obj::BytesBuilder(_)
            | Obj::Enum(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Set(_)
            | Obj::Struct { .. }
            | Obj::Closure { .. } => Err(bug("expected string")),
        }),
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

/// `eprintln(value)` — like `println` but to stderr (diagnostics, errors). Flush
/// stdout first so the two streams stay correctly ordered.
fn native_eprintln(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = display_string(expect_one(args, "eprintln")?)?;
    let _ = out.flush();
    writeln!(std::io::stderr(), "{s}").map_err(|e| bug(format!("eprintln: {e}")))?;
    Ok(Value::Unit)
}

/// `eprint(value)` — like `eprintln` without the trailing newline.
fn native_eprint(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = display_string(expect_one(args, "eprint")?)?;
    let _ = out.flush();
    write!(std::io::stderr(), "{s}").map_err(|e| bug(format!("eprint: {e}")))?;
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

/// `s.bytes()` — the string's UTF-8 encoding as a `Bytes` buffer.
fn native_str_bytes(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_bytes")?)?;
    Ok(Value::new_bytes(s.into_bytes()))
}

/// `String.from_chars(cps)` — build a string from a list of Unicode code points.
/// Total: a non-scalar code point (a surrogate, out of range, or negative)
/// becomes U+FFFD rather than trapping. Use `try_from_chars` to detect them.
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
                    .unwrap_or('\u{FFFD}');
                s.push(c);
            }
            Ok(Value::new_str(s))
        },
    )
}

/// `String.try_from_chars(cps)` — like `from_chars`, but returns `None` if any
/// element is not a valid Unicode scalar value, so a caller can reject bad input
/// instead of getting U+FFFD substitutions.
fn native_str_try_from_chars(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_list(
        expect_one(args, "str_try_from_chars")?,
        "str_try_from_chars",
        |items| {
            let mut s = String::new();
            for item in items {
                let cp = as_int(item, "str_try_from_chars")?;
                match u32::try_from(cp).ok().and_then(char::from_u32) {
                    Some(c) => s.push(c),
                    None => return Ok(Value::none()),
                }
            }
            Ok(Value::some(Value::new_str(s)))
        },
    )
}

// --- bytes natives ---

/// Read a `Bytes` value's slice through `f` (no allocation inside; faults on a
/// non-`Bytes`).
fn with_bytes<R>(v: &Value, who: &str, f: impl FnOnce(&[u8]) -> R) -> Result<R, Trap> {
    match v {
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Bytes(b) => Ok(f(b)),
            _ => Err(bug(format!("{who}: expected Bytes"))),
        }),
        v => Err(bug(format!("{who}: expected Bytes, found {v:?}"))),
    }
}

/// A clone of a `Bytes` value's buffer, with the heap borrow released — so the
/// caller can allocate a result freely.
fn bytes_contents(v: &Value, who: &str) -> Result<Vec<u8>, Trap> {
    with_bytes(v, who, <[u8]>::to_vec)
}

/// `bytes.len()` — the number of bytes.
fn native_bytes_len(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_bytes(expect_one(args, "bytes_len")?, "bytes_len", |b| {
        Value::Int(b.len() as i64)
    })
}

/// `bytes.get(i)` — the byte (0..=255) at `i`, or None if out of range.
fn native_bytes_get(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (bv, iv) = args2(args, "bytes_get")?;
    let i = as_int(iv, "bytes_get")?;
    let byte = with_bytes(bv, "bytes_get", |b| {
        usize::try_from(i).ok().and_then(|i| b.get(i)).copied()
    })?;
    Ok(match byte {
        Some(x) => Value::some(Value::Int(i64::from(x))),
        None => Value::none(),
    })
}

/// `bytes.slice(start, end)` — the sub-buffer `[start, end)`, clamped to range.
fn native_bytes_slice(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (bv, sv, ev) = args3(args, "bytes_slice")?;
    let start = as_int(sv, "bytes_slice")?;
    let end = as_int(ev, "bytes_slice")?;
    let b = bytes_contents(bv, "bytes_slice")?;
    let len = b.len() as i64;
    let s = start.clamp(0, len) as usize;
    let e = (end.clamp(0, len) as usize).max(s);
    Ok(Value::new_bytes(b[s..e].to_vec()))
}

/// `a.concat(b)` — the two buffers joined.
fn native_bytes_concat(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (av, bv) = args2(args, "bytes_concat")?;
    let mut a = bytes_contents(av, "bytes_concat")?;
    let b = bytes_contents(bv, "bytes_concat")?;
    a.extend_from_slice(&b);
    Ok(Value::new_bytes(a))
}

/// `bytes.to_string()` — decode as UTF-8: `Ok(String)` or `Err(message)`.
fn native_bytes_to_string(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let b = bytes_contents(expect_one(args, "bytes_to_string")?, "bytes_to_string")?;
    Ok(match String::from_utf8(b) {
        Ok(s) => Value::ok(Value::new_str(s)),
        Err(_) => Value::err(Value::new_str("bytes are not valid UTF-8")),
    })
}

/// `bytes.to_list()` — the byte values (each 0..=255) as a `List<Int>`.
fn native_bytes_to_list(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let b = bytes_contents(expect_one(args, "bytes_to_list")?, "bytes_to_list")?;
    Ok(int_list(b.into_iter().map(i64::from)))
}

/// `Bytes.empty()` — an empty buffer.
fn native_bytes_empty(_out: &mut dyn Write, _args: &[Value]) -> Result<Value, Trap> {
    Ok(Value::new_bytes(Vec::new()))
}

/// `Bytes.from_list(values)` — build from byte values: `Ok(Bytes)`, or
/// `Err(message)` if a value is outside 0..=255.
fn native_bytes_from_list(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let built: Result<Vec<u8>, String> = with_list(
        expect_one(args, "bytes_from_list")?,
        "bytes_from_list",
        |items| {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let n = as_int(item, "bytes_from_list")?;
                if !(0..=255).contains(&n) {
                    return Ok(Err(format!("byte value out of range (0..=255): {n}")));
                }
                out.push(n as u8);
            }
            Ok(Ok(out))
        },
    )?;
    Ok(match built {
        Ok(bytes) => Value::ok(Value::new_bytes(bytes)),
        Err(msg) => Value::err(Value::new_str(msg)),
    })
}

// --- bytes-builder natives ---

/// Mutate a `BytesBuilder`'s buffer through `f` (faults on a non-builder).
fn with_builder_mut<R>(v: &Value, who: &str, f: impl FnOnce(&mut Vec<u8>) -> R) -> Result<R, Trap> {
    match v {
        Value::Ref(h) => heap::with_obj_mut(*h, |obj| match obj {
            Obj::BytesBuilder(buf) => Ok(f(buf)),
            _ => Err(bug(format!("{who}: expected BytesBuilder"))),
        }),
        v => Err(bug(format!("{who}: expected BytesBuilder, found {v:?}"))),
    }
}

/// `BytesBuilder.new()` — a fresh, empty accumulator.
fn native_bytesbuilder_new(_out: &mut dyn Write, _args: &[Value]) -> Result<Value, Trap> {
    Ok(Value::new_bytes_builder())
}

/// `builder.write_u8(byte)` — append the low 8 bits of `byte`.
fn native_bytesbuilder_write_u8(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (bv, nv) = args2(args, "bytesbuilder_write_u8")?;
    let n = as_int(nv, "bytesbuilder_write_u8")?;
    with_builder_mut(bv, "bytesbuilder_write_u8", |buf| {
        buf.push(n.rem_euclid(256) as u8);
    })?;
    Ok(Value::Unit)
}

/// `builder.write_bytes(data)` — append a `Bytes`.
fn native_bytesbuilder_write_bytes(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (bv, dv) = args2(args, "bytesbuilder_write_bytes")?;
    let data = bytes_contents(dv, "bytesbuilder_write_bytes")?;
    with_builder_mut(bv, "bytesbuilder_write_bytes", |buf| {
        buf.extend_from_slice(&data)
    })?;
    Ok(Value::Unit)
}

/// `builder.write_str(s)` — append a string's UTF-8.
fn native_bytesbuilder_write_str(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (bv, sv) = args2(args, "bytesbuilder_write_str")?;
    let s = str_contents(sv)?;
    with_builder_mut(bv, "bytesbuilder_write_str", |buf| {
        buf.extend_from_slice(s.as_bytes())
    })?;
    Ok(Value::Unit)
}

/// `builder.len()` — the number of bytes accumulated so far.
fn native_bytesbuilder_len(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_builder_mut(
        expect_one(args, "bytesbuilder_len")?,
        "bytesbuilder_len",
        |buf| Value::Int(buf.len() as i64),
    )
}

/// `builder.finish()` — freeze the accumulated bytes into a `Bytes` (a copy;
/// the builder is left intact).
fn native_bytesbuilder_finish(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let bytes = with_builder_mut(
        expect_one(args, "bytesbuilder_finish")?,
        "bytesbuilder_finish",
        |buf| buf.clone(),
    )?;
    Ok(Value::new_bytes(bytes))
}

// --- io natives (standard streams) ---

/// `io.stdin().read(max)` — read up to `max` bytes from stdin. An empty result
/// means end-of-stream. `Err(message)` on an I/O error.
fn native_io_stdin_read(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    use std::io::Read;
    let max = as_int(expect_one(args, "io_stdin_read")?, "io_stdin_read")?;
    let mut buf = vec![0u8; max.max(0) as usize];
    Ok(match std::io::stdin().read(&mut buf) {
        Ok(n) => {
            buf.truncate(n);
            Value::ok(Value::new_bytes(buf))
        }
        Err(e) => Value::err(Value::new_str(format!("stdin: {e}"))),
    })
}

/// `io.stdout().write(data)` — write all of `data` to the program's output.
/// Returns the number of bytes written, or `Err(message)`. Flushes after the
/// write: the runtime's stdout is line-buffered, so an explicit binary write
/// (e.g. an LSP `Content-Length`-framed message, whose JSON body has no trailing
/// newline) would otherwise sit in the buffer and never reach the consumer.
fn native_io_stdout_write(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let data = bytes_contents(expect_one(args, "io_stdout_write")?, "io_stdout_write")?;
    Ok(match out.write_all(&data).and_then(|()| out.flush()) {
        Ok(()) => Value::ok(Value::Int(data.len() as i64)),
        Err(e) => Value::err(Value::new_str(format!("stdout: {e}"))),
    })
}

/// `io.stderr().write(data)` — write all of `data` to stderr.
fn native_io_stderr_write(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let data = bytes_contents(expect_one(args, "io_stderr_write")?, "io_stderr_write")?;
    Ok(match std::io::stderr().write_all(&data) {
        Ok(()) => Value::ok(Value::Int(data.len() as i64)),
        Err(e) => Value::err(Value::new_str(format!("stderr: {e}"))),
    })
}

// --- more collection natives ---

/// `map.keys()` — the keys, in insertion order.
fn native_map_keys(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_map(expect_one(args, "map.keys")?, "map.keys", |entries| {
        Ok(Value::new_list(entries.iter().map(|(k, _)| *k).collect()))
    })
}

/// `map.values()` — the values, in insertion order.
fn native_map_values(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_map(expect_one(args, "map.values")?, "map.values", |entries| {
        Ok(Value::new_list(entries.iter().map(|(_, v)| *v).collect()))
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
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Enum(e) if e.ty == TY_OPTION => Ok((e.variant, e.fields.clone())),
            _ => Err(bug(format!("{who}: expected Option"))),
        }),
        _ => Err(bug(format!("{who}: expected Option"))),
    }
}

// --- std.fs natives ---
//
// Errors are returned as a `String` payload for now; once `std.core`'s `Error`
// type is linked in, these will build a proper `Error`.

/// `fs.read_text(path)` — read a UTF-8 file, `Ok(contents)` or `Err(message)`.
/// Build an `Err` value for a filesystem error. The String payload is
/// `"<kind>\u{1}<path>: <message>"`; the Hawk side splits on U+0001 and maps the
/// kind to the matching `FsError` variant (so callers can `match` on the cause).
fn fs_err(path: &str, e: &std::io::Error) -> Value {
    use std::io::ErrorKind;
    let kind = match e.kind() {
        ErrorKind::NotFound => "not_found",
        ErrorKind::PermissionDenied => "permission_denied",
        ErrorKind::AlreadyExists => "already_exists",
        ErrorKind::NotADirectory => "not_a_directory",
        ErrorKind::IsADirectory => "is_a_directory",
        _ => "other",
    };
    Value::err(Value::new_str(format!("{kind}\u{1}{path}: {e}")))
}

fn native_fs_read_text(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_read_text")?)?;
    Ok(match std::fs::read_to_string(&path) {
        Ok(s) => Value::ok(Value::new_str(s)),
        Err(e) => fs_err(&path, &e),
    })
}

/// `fs.write_text(path, contents)` — write a file, `Ok(())` or a classified Err.
fn native_fs_write_text(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (path, contents) = args2(args, "fs_write_text")?;
    let (path, contents) = (str_contents(path)?, str_contents(contents)?);
    Ok(match std::fs::write(&path, contents) {
        Ok(()) => Value::ok(Value::Unit),
        Err(e) => fs_err(&path, &e),
    })
}

/// `fs.read_bytes(path)` — the whole file as `Bytes`.
fn native_fs_read_bytes(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_read_bytes")?)?;
    Ok(match std::fs::read(&path) {
        Ok(b) => Value::ok(Value::new_bytes(b)),
        Err(e) => fs_err(&path, &e),
    })
}

/// `fs.write_bytes(path, data)` — write raw bytes.
fn native_fs_write_bytes(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (path, data) = args2(args, "fs_write_bytes")?;
    let path = str_contents(path)?;
    let data = bytes_contents(data, "fs_write_bytes")?;
    Ok(match std::fs::write(&path, &data) {
        Ok(()) => Value::ok(Value::Unit),
        Err(e) => fs_err(&path, &e),
    })
}

/// `fs.exists(path)` — whether the path exists (infallible; false on any error).
fn native_fs_exists(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_exists")?)?;
    Ok(Value::Bool(std::path::Path::new(&path).exists()))
}

/// `fs.list_dir(path)` — entry basenames (not full paths), in OS order.
fn native_fs_list_dir(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_list_dir")?)?;
    match std::fs::read_dir(&path) {
        Ok(entries) => {
            let mut names = Vec::new();
            for entry in entries {
                match entry {
                    Ok(e) => {
                        names.push(Value::new_str(e.file_name().to_string_lossy().into_owned()))
                    }
                    Err(e) => return Ok(fs_err(&path, &e)),
                }
            }
            Ok(Value::ok(Value::new_list(names)))
        }
        Err(e) => Ok(fs_err(&path, &e)),
    }
}

/// `fs.metadata(path)` — follows symlinks; returns `[kind, size, modified_millis]`
/// where kind is 0=file, 1=dir, 2=symlink, 3=other. The Hawk side builds a
/// `Metadata`. `modified_millis` is 0 when the platform can't report it.
fn native_fs_metadata(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_metadata")?)?;
    Ok(match std::fs::metadata(&path) {
        Ok(m) => {
            let kind = if m.is_dir() {
                1
            } else if m.is_file() {
                0
            } else {
                3
            };
            let size = m.len() as i64;
            let modified = m
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            Value::ok(Value::new_list(vec![
                Value::Int(kind),
                Value::Int(size),
                Value::Int(modified),
            ]))
        }
        Err(e) => fs_err(&path, &e),
    })
}

/// `fs.create_dir(path)` — create a single directory (parent must exist).
fn native_fs_create_dir(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_create_dir")?)?;
    Ok(match std::fs::create_dir(&path) {
        Ok(()) => Value::ok(Value::Unit),
        Err(e) => fs_err(&path, &e),
    })
}

/// `fs.create_dir_all(path)` — create a directory and any missing parents.
fn native_fs_create_dir_all(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_create_dir_all")?)?;
    Ok(match std::fs::create_dir_all(&path) {
        Ok(()) => Value::ok(Value::Unit),
        Err(e) => fs_err(&path, &e),
    })
}

/// `fs.remove(path)` — remove a file or an empty directory.
fn native_fs_remove(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_remove")?)?;
    let p = std::path::Path::new(&path);
    let res = if p.is_dir() {
        std::fs::remove_dir(&path)
    } else {
        std::fs::remove_file(&path)
    };
    Ok(match res {
        Ok(()) => Value::ok(Value::Unit),
        Err(e) => fs_err(&path, &e),
    })
}

/// `fs.remove_dir_all(path)` — remove a directory and all its contents.
fn native_fs_remove_dir_all(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_remove_dir_all")?)?;
    Ok(match std::fs::remove_dir_all(&path) {
        Ok(()) => Value::ok(Value::Unit),
        Err(e) => fs_err(&path, &e),
    })
}

/// `fs.rename(src, dst)` — rename/move a file or directory.
fn native_fs_rename(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (src, dst) = args2(args, "fs_rename")?;
    let (src, dst) = (str_contents(src)?, str_contents(dst)?);
    Ok(match std::fs::rename(&src, &dst) {
        Ok(()) => Value::ok(Value::Unit),
        Err(e) => fs_err(&src, &e),
    })
}

/// `fs.copy(src, dst)` — copy a file's contents and permissions.
fn native_fs_copy(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (src, dst) = args2(args, "fs_copy")?;
    let (src, dst) = (str_contents(src)?, str_contents(dst)?);
    Ok(match std::fs::copy(&src, &dst) {
        Ok(_) => Value::ok(Value::Unit),
        Err(e) => fs_err(&src, &e),
    })
}

/// `fs.temp_dir()` — the system temporary directory path.
fn native_fs_temp_dir(_out: &mut dyn Write, _args: &[Value]) -> Result<Value, Trap> {
    Ok(Value::new_str(
        std::env::temp_dir().to_string_lossy().into_owned(),
    ))
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

/// `time.monotonic()` — nanoseconds from a fixed process-start baseline. The
/// value is meaningless in absolute terms; only differences matter (it never
/// goes backwards, unlike the wall clock).
fn native_time_monotonic_nanos(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    if !args.is_empty() {
        return Err(bug(format!(
            "time_monotonic_nanos expects 0 arguments, got {}",
            args.len()
        )));
    }
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    let start = START.get_or_init(std::time::Instant::now);
    Ok(Value::Int(start.elapsed().as_nanos() as i64))
}

/// `time.sleep(d)` — block the current thread for `millis` milliseconds. (Parks
/// the fiber once cooperative fibers land; today it blocks the thread.)
fn native_time_sleep_millis(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let millis = as_int(expect_one(args, "time_sleep_millis")?, "time_sleep_millis")?;
    if millis > 0 {
        std::thread::sleep(std::time::Duration::from_millis(millis as u64));
    }
    Ok(Value::Unit)
}

// --- random natives ---
//
// std.random is a SplitMix64 generator whose entire state is a visible `Int`
// field in Hawk (no hidden runtime state). The state advance, the mixing
// finalizer, and the unit-Double mapping are all pure Hawk now (bitwise ops +
// wrapping multiply); the one remaining native is the entropy seed, which reads
// the system clock. `splitmix64_mix` stays only because that seed mixes its raw
// clock reading.

/// SplitMix64 finalizing mix: scramble a state value into a uniformly
/// distributed 64-bit output. (Mirrored in pure Hawk by `std.random`'s `mix`;
/// kept here for `random_seed_entropy`.)
fn splitmix64_mix(mut z: u64) -> u64 {
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
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

// --- fibers (std.fiber) ---

/// `fiber.spawn(work)` — schedule `work` (a `() -> T` closure) as a new fiber and
/// return its id (the Hawk surface wraps it in a `Fiber<T>`).
fn native_fiber_spawn(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let closure = *expect_one(args, "fiber_spawn")?;
    Ok(Value::Int(super::sched_spawn(closure) as i64))
}

/// `fiber.join(id)` — the result of fiber `id`, blocking until it finishes. While
/// the fiber is still running this parks the caller (re-running the call on
/// resume); once woken and retried, the result is present.
fn native_fiber_join(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let id = as_int(expect_one(args, "fiber_join")?, "fiber_join")? as usize;
    match super::sched_result(id) {
        Some(value) => Ok(value),
        None => {
            super::park_block_retry();
            Ok(Value::Unit) // placeholder; discarded — the call re-runs after the park
        }
    }
}

/// `fiber.yield()` — cede the thread to the scheduler; the fiber stays runnable
/// and resumes right after this call.
fn native_fiber_yield(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    expect_no_args(args, "fiber_yield")?;
    super::park_yield_ready();
    Ok(Value::Unit)
}

/// `channel(capacity)` — create a channel buffering up to `capacity`, returning
/// its id (the Hawk surface wraps it in a `Channel<T>`).
fn native_channel_new(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let cap = as_int(expect_one(args, "channel_new")?, "channel_new")?;
    let cap = if cap < 0 { 0 } else { cap as usize };
    Ok(Value::Int(super::sched_channel_new(cap) as i64))
}

/// `channel.send(id, value)` — buffer `value`, blocking while the channel is
/// full (re-running on resume). Traps if the channel is closed.
fn native_channel_send(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (id, value) = args2(args, "channel_send")?;
    let id = as_int(id, "channel_send")? as usize;
    match super::sched_chan_send(id, *value) {
        super::SendOutcome::Sent => Ok(Value::Unit),
        super::SendOutcome::Full => {
            super::park_block_retry();
            Ok(Value::Unit) // placeholder; discarded — the call re-runs after the park
        }
        super::SendOutcome::Closed => Err(Trap::ClosedChannel),
    }
}

/// `channel.receive(id)` — the next buffered value as `Some`, blocking while the
/// channel is empty (re-running on resume); `None` once closed and drained.
fn native_channel_receive(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let id = as_int(expect_one(args, "channel_receive")?, "channel_receive")? as usize;
    match super::sched_chan_receive(id) {
        super::RecvOutcome::Got(value) => Ok(Value::some(value)),
        super::RecvOutcome::Drained => Ok(Value::none()),
        super::RecvOutcome::Empty => {
            super::park_block_retry();
            Ok(Value::Unit) // placeholder; discarded — the call re-runs after the park
        }
    }
}

/// `channel.close(id)` — no more sends; receivers drain then get `None`.
fn native_channel_close(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let id = as_int(expect_one(args, "channel_close")?, "channel_close")? as usize;
    super::sched_chan_close(id);
    Ok(Value::Unit)
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

/// `env.current_exe()` — the path to the running executable, or None if it can't
/// be determined. The SDK uses this to locate its `std/` relative to `bin/hawk`.
fn native_env_current_exe(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    expect_no_args(args, "env_current_exe")?;
    Ok(match std::env::current_exe() {
        Ok(p) => Value::some(Value::new_str(p.to_string_lossy().into_owned())),
        Err(_) => Value::none(),
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

/// `d.to_bits()` — reinterpret the IEEE-754 bit pattern of `d` as an `Int`
/// (i64). The inverse of the bit-mixing in `std.random`; lets the bytecode
/// writer emit a Double's raw bytes from pure Hawk (via `write_u64_le`).
fn native_double_to_bits(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let x = as_double(expect_one(args, "double_to_bits")?, "double_to_bits")?;
    Ok(Value::Int(x.to_bits() as i64))
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

// Reads clone the collection out (cheap — `Value` is `Copy`) so `f` may compare
// elements (`==` re-enters the heap) or allocate (wrap a result in `Some`)
// without holding a heap borrow.
fn with_list<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&[Value]) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(h) => match heap::clone_obj(*h) {
            Obj::List(items) => f(&items),
            _ => Err(bug(format!("{who}: expected list"))),
        },
        _ => Err(bug(format!("{who}: expected list"))),
    }
}

// Like [`with_list`] but *borrows* the list — no clone. Only sound when `f`
// neither allocates nor mutates the heap while it runs (it holds a heap borrow),
// so it's restricted to trivial reads like `len` and indexing. This matters a
// lot: cloning the whole backing `Vec` just to read `list.len()` made `len` —
// the single most-called native in a compile — O(n) and allocating.
fn with_list_ref<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&[Value]) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::List(items) => f(items),
            _ => Err(bug(format!("{who}: expected list"))),
        }),
        _ => Err(bug(format!("{who}: expected list"))),
    }
}

// List mutators only store (already-allocated) handles, never compare, so they
// can mutate in place without re-entering the heap.
fn with_list_mut<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&mut Vec<Value>) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(h) => heap::with_obj_mut(*h, |obj| match obj {
            Obj::List(items) => f(items),
            _ => Err(bug(format!("{who}: expected list"))),
        }),
        _ => Err(bug(format!("{who}: expected list"))),
    }
}

fn with_map<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&[(Value, Value)]) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(h) => match heap::clone_obj(*h) {
            Obj::Map(entries) => f(&entries),
            _ => Err(bug(format!("{who}: expected map"))),
        },
        _ => Err(bug(format!("{who}: expected map"))),
    }
}

// Like [`with_map`] but *borrows* the map — no clone (the read-path clone was
// O(n) per lookup). `f` may compare keys (`==` re-enters the heap, but only for
// *reads*, so the nested shared borrow is fine); it must not allocate or mutate
// the VM heap while it runs (extract a `Value` and build any `Some` wrapper after
// it returns — see `map.get`).
fn with_map_ref<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&[(Value, Value)]) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Map(entries) => f(entries),
            _ => Err(bug(format!("{who}: expected map"))),
        }),
        _ => Err(bug(format!("{who}: expected map"))),
    }
}

// Map mutators compare keys (`==` re-enters the heap), so they operate on a
// clone and write it back — no heap borrow is held while `f` runs.
fn with_map_mut<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&mut Vec<(Value, Value)>) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(h) => {
            let mut entries = match heap::clone_obj(*h) {
                Obj::Map(entries) => entries,
                _ => return Err(bug(format!("{who}: expected map"))),
            };
            let r = f(&mut entries)?;
            heap::with_obj_mut(*h, |obj| {
                if let Obj::Map(e) = obj {
                    *e = entries;
                }
            });
            Ok(r)
        }
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
    with_list_ref(list, "list index", |items| {
        Ok(items[checked_index(i, items.len())?])
    })
}

/// `list.get(i)` — `Some(element)` if `i` is in range, else `None`.
fn native_list_get(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (list, idx) = args2(args, "list.get")?;
    let i = as_int(idx, "list.get")?;
    with_list(list, "list.get", |items| {
        Ok(match checked_index(i, items.len()) {
            Ok(n) => Value::some(items[n]),
            Err(_) => Value::none(),
        })
    })
}

/// `list.len()`.
fn native_list_len(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_list_ref(expect_one(args, "list.len")?, "list.len", |items| {
        Ok(Value::Int(items.len() as i64))
    })
}

/// `list[i] = v` — in-place update, faulting if out of range. Returns `Unit`.
fn native_list_set(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (list, idx, val) = args3(args, "list set")?;
    let i = as_int(idx, "list set")?;
    with_list_mut(list, "list set", |items| {
        let n = checked_index(i, items.len())?;
        items[n] = *val;
        Ok(Value::Unit)
    })
}

/// `list.push(value)` — append a value to the list, in place. Returns Unit.
fn native_list_push(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (list, val) = args2(args, "list push")?;
    with_list_mut(list, "list push", |items| {
        items.push(*val);
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
        map_insert(&mut entries, pair[0], pair[1]);
    }
    Ok(Value::new_map(entries))
}

/// `map[key]` — value for `key`, faulting if absent.
fn native_map_index(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map index")?;
    with_map_ref(map, "map index", |entries| {
        map_find(entries, key).copied().ok_or(Trap::MissingKey)
    })
}

/// `map.get(key)` — `Some(value)` if present, else `None`.
fn native_map_get(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map.get")?;
    // Find under a borrow (no clone), copy the value out, then build the `Some`
    // wrapper after the borrow is released (`Value::some` allocates).
    let found = with_map_ref(
        map,
        "map.get",
        |entries| Ok(map_find(entries, key).copied()),
    )?;
    Ok(match found {
        Some(v) => Value::some(v),
        None => Value::none(),
    })
}

/// `map.len()`.
fn native_map_len(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_map_ref(expect_one(args, "map.len")?, "map.len", |entries| {
        Ok(Value::Int(entries.len() as i64))
    })
}

/// `map.has(key)`.
fn native_map_has(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map.has")?;
    with_map_ref(map, "map.has", |entries| {
        Ok(Value::Bool(map_find(entries, key).is_some()))
    })
}

/// `map[key] = v` — insert or update in place. Returns `Unit`.
fn native_map_set(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key, val) = args3(args, "map set")?;
    with_map_mut(map, "map set", |entries| {
        map_insert(entries, *key, *val);
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
        Value::Ref(h) => match heap::clone_obj(*h) {
            Obj::Set(elements) => f(&elements),
            _ => Err(bug(format!("{who}: expected set"))),
        },
        _ => Err(bug(format!("{who}: expected set"))),
    }
}

// Set mutators compare elements (`==` re-enters the heap), so — like the map
// mutators — they operate on a clone and write it back.
fn with_set_mut<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&mut Vec<Value>) -> Result<R, Trap>,
) -> Result<R, Trap> {
    match v {
        Value::Ref(h) => {
            let mut elements = match heap::clone_obj(*h) {
                Obj::Set(elements) => elements,
                _ => return Err(bug(format!("{who}: expected set"))),
            };
            let r = f(&mut elements)?;
            heap::with_obj_mut(*h, |obj| {
                if let Obj::Set(e) = obj {
                    *e = elements;
                }
            });
            Ok(r)
        }
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
        set_insert(&mut elements, *v);
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
        set_insert(elements, *v);
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

// Process errors come back kind-tagged ("<kind>\u{1}<message>"); the Hawk side
// maps the kind to a `ProcessError` variant. `io` covers everything that isn't a
// missing executable.
fn proc_err_io(msg: impl Into<String>) -> Value {
    Value::err(Value::new_str(format!("io\u{1}{}", msg.into())))
}

fn proc_err(e: &std::io::Error, msg: String) -> Value {
    let kind = if e.kind() == std::io::ErrorKind::NotFound {
        "not_found"
    } else {
        "io"
    };
    Value::err(Value::new_str(format!("{kind}\u{1}{msg}")))
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
        Err(e) => Ok(proc_err(&e, format!("failed to run '{cmd_name}': {e}"))),
    }
}

/// `process_exec(command, args, working_dir, env)` — run a child that *inherits*
/// the parent's stdin/stdout/stderr (so its output streams live to the terminal
/// and it can read interactive input), returning just the exit code. The
/// inherit-stdio counterpart to `process_run`, which pipes and captures output.
fn native_process_exec(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    if args.is_empty() || args.len() > 4 {
        return Err(bug(format!(
            "process_exec expects between 1 and 4 arguments, got {}",
            args.len()
        )));
    }
    let cmd_name = str_contents(&args[0])?;
    let cmd_args = if args.len() >= 2 {
        expect_string_list(&args[1], "process_exec: args")?
    } else {
        Vec::new()
    };
    let working_dir = if args.len() >= 3 {
        expect_option_string(&args[2], "process_exec: working_dir")?
    } else {
        None
    };
    let env = if args.len() >= 4 {
        expect_option_map(&args[3], "process_exec: env")?
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
    // stdin/stdout/stderr are inherited by default (`Command::status`), so the
    // child shares our terminal. Flush our own buffered output first so the
    // parent's and child's writes stay correctly ordered.
    let _ = out.flush();
    command.stdin(Stdio::inherit());
    command.stdout(Stdio::inherit());
    command.stderr(Stdio::inherit());

    match command.status() {
        Ok(status) => Ok(Value::ok(Value::Int(status.code().unwrap_or(-1) as i64))),
        Err(e) => Ok(proc_err(&e, format!("failed to run '{cmd_name}': {e}"))),
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
        Err(e) => Ok(proc_err(&e, format!("failed to start '{cmd_name}': {e}"))),
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
            return Ok(proc_err_io(format!(
                "process {id} not found (it may have already been waited on)"
            )));
        }
    };
    drop(registry);

    match running.child.wait() {
        Ok(status) => {
            let exit_code = status.code().unwrap_or(-1) as i64;
            Ok(Value::ok(Value::Int(exit_code)))
        }
        Err(e) => Ok(proc_err(
            &e,
            format!("failed to wait for process {id}: {e}"),
        )),
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
            return Ok(proc_err_io(format!("process {id} not found")));
        }
    };
    drop(registry);

    match running.child.kill() {
        Ok(()) => {
            let _ = running.child.wait();
            Ok(Value::ok(Value::Unit))
        }
        Err(e) => Ok(proc_err(&e, format!("failed to kill process {id}: {e}"))),
    }
}

/// `process_stdin_write(id, data)` — write all of `data` (Bytes) to the child's
/// stdin, returning the byte count. Backs `Process.stdin(): Writer`.
fn native_process_stdin_write(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (id_val, data_val) = args2(args, "process_stdin_write")?;
    let id = as_int(id_val, "process_stdin_write")?;
    let data = bytes_contents(data_val, "process_stdin_write")?;

    let mut registry = process_registry().lock().unwrap();
    let running = match registry.get_mut(&id) {
        Some(r) => r,
        None => return Ok(proc_err_io(format!("process {id} not found"))),
    };
    let stdin = match &mut running.stdin {
        Some(s) => s,
        None => return Ok(proc_err_io(format!("process {id} stdin is not available"))),
    };
    match stdin.write_all(&data).and_then(|()| stdin.flush()) {
        Ok(()) => Ok(Value::ok(Value::Int(data.len() as i64))),
        Err(e) => Ok(proc_err(
            &e,
            format!("failed to write to process {id} stdin: {e}"),
        )),
    }
}

/// `process_stdin_close(id)` — drop the child's stdin so it sees EOF (the
/// write-then-read pattern needs this, or the child blocks waiting for input).
fn native_process_stdin_close(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let id = as_int(
        expect_one(args, "process_stdin_close")?,
        "process_stdin_close",
    )?;
    let mut registry = process_registry().lock().unwrap();
    match registry.get_mut(&id) {
        Some(running) => {
            running.stdin = None; // dropping the ChildStdin closes the pipe
            Ok(Value::ok(Value::Unit))
        }
        None => Ok(proc_err_io(format!("process {id} not found"))),
    }
}

/// Read up to `max` bytes from a child pipe; an empty result is EOF (and the
/// pipe is then dropped). Shared by stdout/stderr (both `impl Read`).
fn read_pipe<R: Read>(stream: &mut Option<R>, max: usize, id: i64) -> Value {
    let s = match stream {
        Some(s) => s,
        None => return Value::ok(Value::new_bytes(Vec::new())), // already at EOF
    };
    let mut buf = vec![0u8; max.clamp(1, 1 << 20)];
    match s.read(&mut buf) {
        Ok(0) => {
            *stream = None;
            Value::ok(Value::new_bytes(Vec::new()))
        }
        Ok(n) => {
            buf.truncate(n);
            Value::ok(Value::new_bytes(buf))
        }
        Err(e) => proc_err(&e, format!("failed to read from process {id}: {e}")),
    }
}

/// `process_stdout_read(id, max)` — backs `Process.stdout(): Reader`.
fn native_process_stdout_read(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (id_val, max_val) = args2(args, "process_stdout_read")?;
    let id = as_int(id_val, "process_stdout_read")?;
    let max = as_int(max_val, "process_stdout_read")?.max(0) as usize;
    let mut registry = process_registry().lock().unwrap();
    match registry.get_mut(&id) {
        Some(running) => Ok(read_pipe(&mut running.stdout, max, id)),
        None => Ok(proc_err_io(format!("process {id} not found"))),
    }
}

/// `process_stderr_read(id, max)` — backs `Process.stderr(): Reader`.
fn native_process_stderr_read(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (id_val, max_val) = args2(args, "process_stderr_read")?;
    let id = as_int(id_val, "process_stderr_read")?;
    let max = as_int(max_val, "process_stderr_read")?.max(0) as usize;
    let mut registry = process_registry().lock().unwrap();
    match registry.get_mut(&id) {
        Some(running) => Ok(read_pipe(&mut running.stderr, max, id)),
        None => Ok(proc_err_io(format!("process {id} not found"))),
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
