//! The native (Rust-implemented) function table and its built-in functions.
//!
//! `call.native <index>` resolves against [`default_natives`]; the `NATIVE_*`
//! constants name the indices. Each function takes the VM's output sink and the
//! call arguments. These are the stand-ins for the eventual stdlib `native fn`
//! bindings — enough to write observable programs without a real stdlib.

use std::any::Any;
use std::io::Write;

use super::{Trap, bug, struct_field};
use crate::heap;
use crate::map::{MapObj, hash_value};
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
pub const NATIVE_INT_TO_STRING: u32 = native_idx("int_to_string");
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
    ("eq", native_eq),
    ("str_len", native_str_len),
    ("str_byte_len", native_str_byte_len),
    ("str_trim", native_str_trim),
    ("str_compare", native_str_compare),
    ("str_trim_start", native_str_trim_start),
    ("str_trim_end", native_str_trim_end),
    ("str_contains", native_str_contains),
    ("str_starts_with", native_str_starts_with),
    ("str_ends_with", native_str_ends_with),
    ("str_to_uppercase", native_str_to_uppercase),
    ("str_to_lowercase", native_str_to_lowercase),
    ("str_lines", native_str_lines),
    ("str_split_whitespace", native_str_split_whitespace),
    ("str_split", native_str_split),
    ("str_slice", native_str_slice),
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
    ("fs_symlink_metadata", native_fs_symlink_metadata),
    ("fs_create_dir", native_fs_create_dir),
    ("fs_create_dir_all", native_fs_create_dir_all),
    ("fs_remove", native_fs_remove),
    ("fs_remove_dir_all", native_fs_remove_dir_all),
    ("fs_rename", native_fs_rename),
    ("fs_copy", native_fs_copy),
    ("fs_temp_dir", native_fs_temp_dir),
    ("fs_temp_file", native_fs_temp_file),
    ("fs_open", native_fs_open),
    ("fs_create", native_fs_create),
    ("file_read", native_file_read),
    ("file_write", native_file_write),
    ("file_seek", native_file_seek),
    ("file_close", native_file_close),
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
    ("term_is_tty", native_term_is_tty),
    ("term_size", native_term_size),
    ("map_keys", native_map_keys),
    ("map_values", native_map_values),
    ("map_remove", native_map_remove),
    ("map_clear", native_map_clear),
    ("list_join", native_list_join),
    ("list_push", native_list_push),
    ("list_pop", native_list_pop),
    ("list_clear", native_list_clear),
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
    ("int_to_string", native_int_to_string),
    ("double_to_string", native_double_to_string),
    ("bool_to_string", native_bool_to_string),
    ("str_identity", native_str_identity),
    ("test_capture_begin", native_test_capture_begin),
    ("test_capture_end", native_test_capture_end),
    ("fiber_spawn", native_fiber_spawn),
    ("fiber_join", native_fiber_join),
    ("fiber_yield", native_fiber_yield),
    ("channel_new", native_channel_new),
    ("channel_send", native_channel_send),
    ("channel_receive", native_channel_receive),
    ("channel_close", native_channel_close),
    ("hash_sha256", native_hash_sha256),
    ("hash_sha1", native_hash_sha1),
    ("hash_md5", native_hash_md5),
    ("hash_crc32", native_hash_crc32),
    ("str_byte_slice", native_str_byte_slice),
    ("regex_compile", native_regex_compile),
    ("regex_is_match", native_regex_is_match),
    ("regex_find", native_regex_find),
    ("regex_find_all", native_regex_find_all),
    ("regex_captures", native_regex_captures),
    ("regex_replace", native_regex_replace),
    ("regex_replace_all", native_regex_replace_all),
    ("socket_listen", native_socket_listen),
    ("socket_accept", native_socket_accept),
    ("socket_connect", native_socket_connect),
    ("socket_connect_finish", native_socket_connect_finish),
    ("socket_read", native_socket_read),
    ("socket_write", native_socket_write),
    ("socket_close", native_socket_close),
    ("socket_local_addr", native_socket_local_addr),
    ("socket_peer_addr", native_socket_peer_addr),
    ("socket_resolve", native_socket_resolve),
    ("socket_is_ready", native_socket_is_ready),
    ("fiber_is_done", native_fiber_is_done),
    ("chan_is_ready", native_chan_is_ready),
    ("select_park", native_select_park),
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
/// Whether `v` has a built-in `Display` rendering via [display_string] — the
/// primitives and `String`. Other heap types (lists, maps, structs, enums,
/// closures, bytes) have no built-in Display and fall back to `Debug` under
/// total rendering.
pub(super) fn has_builtin_display(v: &Value) -> bool {
    match v {
        Value::Int(_) | Value::Double(_) | Value::Bool(_) | Value::Unit => true,
        Value::Ref(h) => heap::with_obj(*h, |obj| matches!(obj, Obj::Str(_))),
    }
}

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
            | Obj::Struct { .. }
            | Obj::Closure { .. } => Err(bug("display: type has no built-in Display")),
        })?,
    })
}

/// Extract the contents of a heap string, or fault.
pub(crate) fn str_contents(v: &Value) -> Result<String, Trap> {
    match v {
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Str(s) => Ok(s.clone()),
            Obj::Bytes(_)
            | Obj::BytesBuilder(_)
            | Obj::Enum(_)
            | Obj::List(_)
            | Obj::Map(_)
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

thread_local! {
    /// A stack of in-memory capture buffers. While the stack is non-empty, the
    /// stdout-bound natives (`println`/`print`/`io.stdout().write`) append to the
    /// top buffer instead of the program's real stdout. `hawk test` uses this to
    /// buffer each test's output and reveal it only when the test fails. A stack
    /// (rather than a single buffer) keeps nested captures composing cleanly.
    static CAPTURE: std::cell::RefCell<Vec<Vec<u8>>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// Route program stdout: append `bytes` to the active capture buffer if one is
/// set, otherwise write them to `out` (the real stdout). The single funnel every
/// stdout-bound native goes through, so capture is uniform.
fn emit_stdout(out: &mut dyn Write, bytes: &[u8]) -> std::io::Result<()> {
    let captured = CAPTURE.with(|c| match c.borrow_mut().last_mut() {
        Some(buf) => {
            buf.extend_from_slice(bytes);
            true
        }
        None => false,
    });
    if captured {
        Ok(())
    } else {
        out.write_all(bytes)
    }
}

// The console-write natives. Codegen renders each `println`/`print`/`eprintln`/
// `eprint` argument to a `String` via `Display` *before* the call (see
// `emit_as_string`), so these are plain string writers — no rendering here.

/// `println(s)` — write the string `s` followed by a newline.
fn native_println(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "println")?)?;
    emit_stdout(out, format!("{s}\n").as_bytes()).map_err(|e| bug(format!("println: {e}")))?;
    Ok(Value::Unit)
}

/// `print(s)` — like `println` without the trailing newline.
fn native_print(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "print")?)?;
    emit_stdout(out, s.as_bytes()).map_err(|e| bug(format!("print: {e}")))?;
    Ok(Value::Unit)
}

/// `test_capture_begin()` — start buffering program stdout (push a fresh capture
/// buffer). Paired with [`native_test_capture_end`]; used only by the `hawk test`
/// driver to isolate one test's output.
fn native_test_capture_begin(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    if !args.is_empty() {
        return Err(bug("test_capture_begin expects 0 arguments"));
    }
    CAPTURE.with(|c| c.borrow_mut().push(Vec::new()));
    Ok(Value::Unit)
}

/// `test_capture_end()` — stop buffering and return everything captured since the
/// matching `test_capture_begin()` as a `String`.
fn native_test_capture_end(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    if !args.is_empty() {
        return Err(bug("test_capture_end expects 0 arguments"));
    }
    let buf = CAPTURE
        .with(|c| c.borrow_mut().pop())
        .ok_or_else(|| bug("test_capture_end: no active capture"))?;
    Ok(Value::new_str(String::from_utf8_lossy(&buf).into_owned()))
}

/// `eprintln(s)` — like `println` but to stderr (diagnostics, errors). Flush
/// stdout first so the two streams stay correctly ordered.
fn native_eprintln(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "eprintln")?)?;
    let _ = out.flush();
    writeln!(std::io::stderr(), "{s}").map_err(|e| bug(format!("eprintln: {e}")))?;
    Ok(Value::Unit)
}

/// `eprint(s)` — like `eprintln` without the trailing newline.
fn native_eprint(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "eprint")?)?;
    let _ = out.flush();
    write!(std::io::stderr(), "{s}").map_err(|e| bug(format!("eprint: {e}")))?;
    Ok(Value::Unit)
}

// The per-type `Display` natives behind `impl Display for Int/Double/Bool/String`.
// Each renders its own primitive (delegating to the shared `display_string`, the
// single built-in renderer), so interpolation/`println` lower to a self-documenting
// per-type call rather than the catch-all `stringify`.

/// `int_to_string(n)` — an `Int`'s `Display` form.
fn native_int_to_string(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    Ok(Value::new_str(display_string(expect_one(
        args,
        "int_to_string",
    )?)?))
}

/// `double_to_string(x)` — a `Double`'s `Display` form.
fn native_double_to_string(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    Ok(Value::new_str(display_string(expect_one(
        args,
        "double_to_string",
    )?)?))
}

/// `bool_to_string(b)` — a `Bool`'s `Display` form.
fn native_bool_to_string(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    Ok(Value::new_str(display_string(expect_one(
        args,
        "bool_to_string",
    )?)?))
}

/// `str_identity(s)` — a `String`'s `Display` form is itself. Interpolation and
/// `println` elide it (a `String` is already a `String`); an explicit
/// `s.display()` lands here.
fn native_str_identity(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let v = expect_one(args, "str_identity")?;
    str_contents(v)?; // validate it is a string
    Ok(*v)
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

/// `a.compare(b)` for String — the static `impl Ord for String` (lexicographic
/// by Unicode scalar / UTF-8 byte order). Returns the built-in `Ordering` enum.
fn native_str_compare(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (a, b) = args2(args, "str_compare")?;
    Ok(crate::value::ordering(
        str_contents(a)?.cmp(&str_contents(b)?),
    ))
}

/// `s.trim_start()` — strip leading whitespace.
fn native_str_trim_start(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_trim_start")?)?;
    Ok(Value::new_str(s.trim_start()))
}

/// `s.trim_end()` — strip trailing whitespace.
fn native_str_trim_end(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let s = str_contents(expect_one(args, "str_trim_end")?)?;
    Ok(Value::new_str(s.trim_end()))
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

// --- std.hash digests (backed by battle-tested RustCrypto / crc32fast) ---

/// `hash.sha256(data)` — the SHA-256 digest (32 bytes).
fn native_hash_sha256(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    use sha2::{Digest, Sha256};
    let digest = with_bytes(expect_one(args, "hash.sha256")?, "hash.sha256", |b| {
        Sha256::digest(b).to_vec()
    })?;
    Ok(Value::new_bytes(digest))
}

/// `hash.sha1(data)` — the SHA-1 digest (20 bytes).
fn native_hash_sha1(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    use sha1::{Digest, Sha1};
    let digest = with_bytes(expect_one(args, "hash.sha1")?, "hash.sha1", |b| {
        Sha1::digest(b).to_vec()
    })?;
    Ok(Value::new_bytes(digest))
}

/// `hash.md5(data)` — the MD5 digest (16 bytes).
fn native_hash_md5(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    use md5::{Digest, Md5};
    let digest = with_bytes(expect_one(args, "hash.md5")?, "hash.md5", |b| {
        Md5::digest(b).to_vec()
    })?;
    Ok(Value::new_bytes(digest))
}

/// `hash.crc32(data)` — the CRC-32 (IEEE 802.3) checksum, as a 0..=2^32-1 `Int`.
fn native_hash_crc32(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let checksum = with_bytes(expect_one(args, "hash.crc32")?, "hash.crc32", |b| {
        crc32fast::hash(b) as i64
    })?;
    Ok(Value::Int(checksum))
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
/// means end-of-stream. `Err(message)` on an I/O error. Parks on the worker pool,
/// so a fiber waiting on stdin doesn't stall the others.
fn native_io_stdin_read(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let max = as_int(expect_one(args, "io_stdin_read")?, "io_stdin_read")?;
    park_syscall(
        move || -> std::io::Result<Vec<u8>> {
            use std::io::Read;
            let mut buf = vec![0u8; max.max(0) as usize];
            let n = std::io::stdin().read(&mut buf)?;
            buf.truncate(n);
            Ok(buf)
        },
        move |res| match res {
            Ok(buf) => Value::ok(Value::new_bytes(buf)),
            Err(e) => Value::err(Value::new_str(format!("stdin: {e}"))),
        },
    );
    Ok(Value::Unit)
}

/// `io.stdout().write(data)` — write all of `data` to the program's output.
/// Returns the number of bytes written, or `Err(message)`. Flushes after the
/// write: the runtime's stdout is line-buffered, so an explicit binary write
/// (e.g. an LSP `Content-Length`-framed message, whose JSON body has no trailing
/// newline) would otherwise sit in the buffer and never reach the consumer.
fn native_io_stdout_write(out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let data = bytes_contents(expect_one(args, "io_stdout_write")?, "io_stdout_write")?;
    Ok(match emit_stdout(out, &data).and_then(|()| out.flush()) {
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
    // Collect the keys under a borrow (copying handles, no alloc), then build the
    // list after the borrow is released (`new_list` allocates).
    let keys = with_map_ref(expect_one(args, "map.keys")?, "map.keys", |m| {
        Ok(m.entries().iter().map(|(k, _)| *k).collect::<Vec<_>>())
    })?;
    Ok(Value::new_list(keys))
}

/// `map.values()` — the values, in insertion order.
fn native_map_values(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let vals = with_map_ref(expect_one(args, "map.values")?, "map.values", |m| {
        Ok(m.entries().iter().map(|(_, v)| *v).collect::<Vec<_>>())
    })?;
    Ok(Value::new_list(vals))
}

/// `map.remove(key)` — remove and return the value (`Some`), or `None`.
fn native_map_remove(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map.remove")?;
    let hash = hash_value(*key);
    // Remove under the taken map, then build the `Some` wrapper after it's put
    // back (`Value::some` allocates).
    let removed = with_map_taken(map, "map.remove", |m| Ok(m.remove(*key, hash)))?;
    Ok(match removed {
        Some(v) => Value::some(v),
        None => Value::none(),
    })
}

/// `map.clear()` — remove every entry, in place. Returns Unit.
fn native_map_clear(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_map_taken(expect_one(args, "map.clear")?, "map.clear", |m| {
        m.clear();
        Ok(Value::Unit)
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

/// Park the running fiber on a blocking syscall: run `job` off the Hawk thread on
/// the worker pool, then map its owned, `Send` result into a Hawk `Value` with
/// `build` back on the Hawk thread (where allocating a `Value` is safe). The native
/// itself returns a discarded placeholder — `build`'s value becomes the call's
/// result when the fiber resumes. See the `Await` park model in the scheduler.
///
/// The blocking `fs`/`stdin`/`process` natives call this so their syscall parks the
/// issuing fiber (letting other fibers run) instead of blocking the whole thread.
fn park_syscall<T: Send + 'static>(
    job: impl FnOnce() -> T + Send + 'static,
    build: impl FnOnce(T) -> Value + 'static,
) {
    super::park_await(
        Box::new(move || Box::new(job()) as Box<dyn Any + Send>),
        Box::new(move |payload| {
            let value = *payload
                .downcast::<T>()
                .expect("worker payload type does not match its finish");
            Ok(build(value))
        }),
    );
}

// --- std.fs natives ---
//
// Errors are returned as a `String` payload for now; once `std.core`'s `Error`
// type is linked in, these will build a proper `Error`. The read/write natives
// park the calling fiber on the worker pool (`park_syscall`) so the blocking
// syscall doesn't stall the scheduler.

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
    let err_path = path.clone();
    park_syscall(
        move || std::fs::read_to_string(&path),
        move |res| match res {
            Ok(s) => Value::ok(Value::new_str(s)),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit) // placeholder; the delivered value replaces it on resume
}

/// `fs.write_text(path, contents)` — write a file, `Ok(())` or a classified Err.
fn native_fs_write_text(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (path, contents) = args2(args, "fs_write_text")?;
    let (path, contents) = (str_contents(path)?, str_contents(contents)?);
    let err_path = path.clone();
    park_syscall(
        move || std::fs::write(&path, contents),
        move |res| match res {
            Ok(()) => Value::ok(Value::Unit),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.read_bytes(path)` — the whole file as `Bytes`.
fn native_fs_read_bytes(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_read_bytes")?)?;
    let err_path = path.clone();
    park_syscall(
        move || std::fs::read(&path),
        move |res| match res {
            Ok(b) => Value::ok(Value::new_bytes(b)),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit) // placeholder; the delivered value replaces it on resume
}

/// `fs.write_bytes(path, data)` — write raw bytes.
fn native_fs_write_bytes(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (path, data) = args2(args, "fs_write_bytes")?;
    let path = str_contents(path)?;
    let data = bytes_contents(data, "fs_write_bytes")?;
    let err_path = path.clone();
    park_syscall(
        move || std::fs::write(&path, &data),
        move |res| match res {
            Ok(()) => Value::ok(Value::Unit),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.exists(path)` — whether the path exists (infallible; false on any error).
fn native_fs_exists(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_exists")?)?;
    Ok(Value::Bool(std::path::Path::new(&path).exists()))
}

/// `fs.list_dir(path)` — entry basenames (not full paths), in OS order.
fn native_fs_list_dir(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_list_dir")?)?;
    let err_path = path.clone();
    // The worker reads the directory into owned `String` names (or an error); the
    // `Value` list is built back on the Hawk thread.
    park_syscall(
        move || -> std::io::Result<Vec<String>> {
            let mut names = Vec::new();
            for entry in std::fs::read_dir(&path)? {
                names.push(entry?.file_name().to_string_lossy().into_owned());
            }
            Ok(names)
        },
        move |res| match res {
            Ok(names) => Value::ok(Value::new_list(
                names.into_iter().map(Value::new_str).collect(),
            )),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// The `[kind, size, modified_millis]` list the Hawk `Metadata` reads, where kind
/// is 0=file, 1=dir, 2=symlink, 3=other. `modified_millis` is 0 when the platform
/// can't report it. (`is_symlink` is only ever true for `symlink_metadata`, which
/// doesn't follow the link; `metadata` follows it, so it reports the target.)
fn metadata_fields(m: &std::fs::Metadata) -> Value {
    let kind = if m.is_symlink() {
        2
    } else if m.is_dir() {
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
    Value::new_list(vec![
        Value::Int(kind),
        Value::Int(size),
        Value::Int(modified),
    ])
}

/// `fs.metadata(path)` — follows symlinks; returns `[kind, size, modified_millis]`.
/// The Hawk side builds a `Metadata`.
fn native_fs_metadata(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_metadata")?)?;
    let err_path = path.clone();
    park_syscall(
        move || std::fs::metadata(&path),
        move |res| match res {
            Ok(m) => Value::ok(metadata_fields(&m)),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.symlink_metadata(path)` — like `fs_metadata` but does **not** follow a
/// symlink, so a symlink reports kind 2 (its own metadata, not the target's).
fn native_fs_symlink_metadata(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_symlink_metadata")?)?;
    let err_path = path.clone();
    park_syscall(
        move || std::fs::symlink_metadata(&path),
        move |res| match res {
            Ok(m) => Value::ok(metadata_fields(&m)),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.create_dir(path)` — create a single directory (parent must exist).
fn native_fs_create_dir(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_create_dir")?)?;
    let err_path = path.clone();
    park_syscall(
        move || std::fs::create_dir(&path),
        move |res| match res {
            Ok(()) => Value::ok(Value::Unit),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.create_dir_all(path)` — create a directory and any missing parents.
fn native_fs_create_dir_all(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_create_dir_all")?)?;
    let err_path = path.clone();
    park_syscall(
        move || std::fs::create_dir_all(&path),
        move |res| match res {
            Ok(()) => Value::ok(Value::Unit),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.remove(path)` — remove a file or an empty directory.
fn native_fs_remove(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_remove")?)?;
    let err_path = path.clone();
    park_syscall(
        move || {
            if std::path::Path::new(&path).is_dir() {
                std::fs::remove_dir(&path)
            } else {
                std::fs::remove_file(&path)
            }
        },
        move |res| match res {
            Ok(()) => Value::ok(Value::Unit),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.remove_dir_all(path)` — remove a directory and all its contents.
fn native_fs_remove_dir_all(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_remove_dir_all")?)?;
    let err_path = path.clone();
    park_syscall(
        move || std::fs::remove_dir_all(&path),
        move |res| match res {
            Ok(()) => Value::ok(Value::Unit),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.rename(src, dst)` — rename/move a file or directory.
fn native_fs_rename(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (src, dst) = args2(args, "fs_rename")?;
    let (src, dst) = (str_contents(src)?, str_contents(dst)?);
    let err_path = src.clone();
    park_syscall(
        move || std::fs::rename(&src, &dst),
        move |res| match res {
            Ok(()) => Value::ok(Value::Unit),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.copy(src, dst)` — copy a file's contents and permissions.
fn native_fs_copy(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (src, dst) = args2(args, "fs_copy")?;
    let (src, dst) = (str_contents(src)?, str_contents(dst)?);
    let err_path = src.clone();
    park_syscall(
        move || std::fs::copy(&src, &dst),
        move |res| match res {
            Ok(_) => Value::ok(Value::Unit),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.temp_dir()` — the system temporary directory path.
fn native_fs_temp_dir(_out: &mut dyn Write, _args: &[Value]) -> Result<Value, Trap> {
    Ok(Value::new_str(
        std::env::temp_dir().to_string_lossy().into_owned(),
    ))
}

// --- streaming file handles (fs.open / fs.create -> File) ---
//
// An open file lives in a registry keyed by an `Int` handle (the regex/process
// pattern). Hawk's `File` carries the handle and dispatches its
// Reader/Writer/Seek/Closer methods to the natives below. Dropping a `File`
// without `close()` leaks the fd until the process exits — there are no
// finalizers in this GC — so the docs tell callers to close their files.
//
// The blocking ops (`read`/`write`/`seek`) park on the worker pool. Because a
// worker can't hold the registry lock across a blocking syscall, the op **takes
// the `File` out** of the registry for its duration and the value-builder **puts it
// back**. Consequence: a concurrent op on the *same* handle from another fiber sees
// it briefly absent and gets `file_closed_err` — an unsupported pattern (a `File`
// is owned by one fiber at a time; interleaving reads on one cursor is meaningless).

static NEXT_FILE_ID: AtomicI64 = AtomicI64::new(1);

fn file_registry() -> &'static Mutex<HashMap<i64, std::fs::File>> {
    static REGISTRY: OnceLock<Mutex<HashMap<i64, std::fs::File>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Register an open file and hand back its `Int` handle (wrapped in `Ok`).
fn register_file(file: std::fs::File) -> Value {
    let id = NEXT_FILE_ID.fetch_add(1, Ordering::SeqCst);
    file_registry().lock().unwrap().insert(id, file);
    Value::ok(Value::Int(id))
}

/// A use-after-close / unknown-handle error, classified like the fs natives so
/// the Hawk side maps it to `FsError.Other`.
fn file_closed_err() -> Value {
    Value::err(Value::new_str("other\u{1}file is closed".to_string()))
}

/// `fs.open(path)` — open an existing file for reading. Returns an `Int` handle.
fn native_fs_open(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_open")?)?;
    let err_path = path.clone();
    park_syscall(
        move || std::fs::File::open(&path),
        move |res| match res {
            Ok(f) => register_file(f),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

/// `fs.create(path)` — create or truncate a file for writing. Returns a handle.
fn native_fs_create(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let path = str_contents(expect_one(args, "fs_create")?)?;
    let err_path = path.clone();
    park_syscall(
        move || std::fs::File::create(&path),
        move |res| match res {
            Ok(f) => register_file(f),
            Err(e) => fs_err(&err_path, &e),
        },
    );
    Ok(Value::Unit)
}

static TEMP_FILE_COUNTER: AtomicI64 = AtomicI64::new(0);

/// The result of the `fs.temp_file` syscall, produced on a worker thread (owned,
/// `Send`) and turned into a `Value` on the Hawk thread.
enum TempFileOutcome {
    Created(String),                 // "<handle>\u{1}<path>"
    FsError(String, std::io::Error), // path, error → classified `fs_err`
    Exhausted(String),               // retries exhausted → `FsError.Other(message)`
}

/// `fs.temp_file(prefix)` — create a new, uniquely-named file in the system temp
/// directory, opened read+write. Returns `"<handle>\u{1}<path>"` on success (the
/// Hawk side splits it into a `File` with its path). Creation is atomic
/// (`create_new` / O_EXCL), so it never clobbers an existing file — a colliding
/// name is retried with a fresh suffix. The whole retry loop (and registering the
/// handle in the thread-safe file registry) runs on the worker pool.
fn native_fs_temp_file(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let prefix = str_contents(expect_one(args, "fs_temp_file")?)?;
    park_syscall(
        move || -> TempFileOutcome {
            let dir = std::env::temp_dir();
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            let mut last: Option<std::io::Error> = None;
            for _ in 0..64 {
                let n = TEMP_FILE_COUNTER.fetch_add(1, Ordering::SeqCst);
                let path = dir.join(format!("{prefix}{stamp}_{n}"));
                match std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create_new(true)
                    .open(&path)
                {
                    Ok(f) => {
                        let id = NEXT_FILE_ID.fetch_add(1, Ordering::SeqCst);
                        file_registry().lock().unwrap().insert(id, f);
                        let path_str = path.to_string_lossy().into_owned();
                        return TempFileOutcome::Created(format!("{id}\u{1}{path_str}"));
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                        last = Some(e);
                    }
                    Err(e) => {
                        return TempFileOutcome::FsError(path.to_string_lossy().into_owned(), e);
                    }
                }
            }
            let msg = last
                .map(|e| e.to_string())
                .unwrap_or_else(|| "could not create a unique temp file".to_string());
            TempFileOutcome::Exhausted(msg)
        },
        move |outcome| match outcome {
            TempFileOutcome::Created(s) => Value::ok(Value::new_str(s)),
            TempFileOutcome::FsError(p, e) => fs_err(&p, &e),
            TempFileOutcome::Exhausted(msg) => {
                Value::err(Value::new_str(format!("other\u{1}{msg}")))
            }
        },
    );
    Ok(Value::Unit)
}

/// Take a `File` out of the registry to run a blocking op on the worker pool
/// without holding the registry lock; a missing handle short-circuits to a
/// closed-file error (no park). See the take-out/return note above.
fn take_file(handle: i64) -> Option<std::fs::File> {
    file_registry().lock().unwrap().remove(&handle)
}

/// Return a `File` to the registry after its op completes (on the Hawk thread).
fn return_file(handle: i64, file: std::fs::File) {
    file_registry().lock().unwrap().insert(handle, file);
}

/// `file.read(handle, max)` — up to `max` bytes; an empty result is EOF.
fn native_file_read(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, maxv) = args2(args, "file_read")?;
    let handle = as_int(hv, "file_read")?;
    let max = as_int(maxv, "file_read")?.max(0) as usize;
    if max == 0 {
        return Ok(Value::ok(Value::new_bytes(Vec::new())));
    }
    let mut file = match take_file(handle) {
        Some(f) => f,
        None => return Ok(file_closed_err()),
    };
    park_syscall(
        move || {
            let mut buf = vec![0u8; max.min(1 << 20)];
            let res = file.read(&mut buf).map(|n| {
                buf.truncate(n);
                buf
            });
            (file, res)
        },
        move |(file, res)| {
            return_file(handle, file);
            match res {
                Ok(buf) => Value::ok(Value::new_bytes(buf)),
                Err(e) => fs_err("<file>", &e),
            }
        },
    );
    Ok(Value::Unit)
}

/// `file.write(handle, data)` — write all of `data`; returns the byte count.
fn native_file_write(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, dv) = args2(args, "file_write")?;
    let handle = as_int(hv, "file_write")?;
    let data = bytes_contents(dv, "file_write")?;
    let n = data.len() as i64;
    let mut file = match take_file(handle) {
        Some(f) => f,
        None => return Ok(file_closed_err()),
    };
    park_syscall(
        move || {
            let res = file.write_all(&data).and_then(|()| file.flush());
            (file, res)
        },
        move |(file, res)| {
            return_file(handle, file);
            match res {
                Ok(()) => Value::ok(Value::Int(n)),
                Err(e) => fs_err("<file>", &e),
            }
        },
    );
    Ok(Value::Unit)
}

/// `file.seek(handle, whence, offset)` — `whence` is 0=Start, 1=Current, 2=End;
/// returns the new absolute offset from the start.
fn native_file_seek(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    use std::io::Seek;
    let (hv, wv, ov) = args3(args, "file_seek")?;
    let handle = as_int(hv, "file_seek")?;
    let whence = as_int(wv, "file_seek")?;
    let offset = as_int(ov, "file_seek")?;
    let target = match whence {
        0 => std::io::SeekFrom::Start(offset.max(0) as u64),
        1 => std::io::SeekFrom::Current(offset),
        2 => std::io::SeekFrom::End(offset),
        _ => return Err(bug(format!("file_seek: invalid whence {whence}"))),
    };
    let mut file = match take_file(handle) {
        Some(f) => f,
        None => return Ok(file_closed_err()),
    };
    park_syscall(
        move || {
            let res = file.seek(target);
            (file, res)
        },
        move |(file, res)| {
            return_file(handle, file);
            match res {
                Ok(pos) => Value::ok(Value::Int(pos as i64)),
                Err(e) => fs_err("<file>", &e),
            }
        },
    );
    Ok(Value::Unit)
}

/// `file.close(handle)` — drop the file (closing the fd). A closed/unknown
/// handle is an error.
fn native_file_close(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let handle = as_int(expect_one(args, "file_close")?, "file_close")?;
    let mut registry = file_registry().lock().unwrap();
    Ok(match registry.remove(&handle) {
        Some(_) => Value::ok(Value::Unit), // dropping the File closes the fd
        None => file_closed_err(),
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

/// `time.sleep(d)` — park the calling fiber until `millis` milliseconds have
/// elapsed, letting other fibers run in the meantime. The scheduler's timer wakes
/// it; with no other runnable fiber the driver sleeps the thread until the
/// deadline, so a single-fiber program still blocks for the full span. A
/// non-positive span is a no-op (it does not even yield).
fn native_time_sleep_millis(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let millis = as_int(expect_one(args, "time_sleep_millis")?, "time_sleep_millis")?;
    if millis > 0 {
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(millis as u64);
        super::park_timer(deadline);
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

/// Has this fiber finished? A non-destructive probe for `select`; `join` is still
/// how the value comes out.
fn native_fiber_is_done(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let id = as_int(expect_one(args, "fiber_is_done")?, "fiber_is_done")? as usize;
    Ok(Value::Bool(super::sched_result(id).is_some()))
}

/// Would a `receive` on this channel return without blocking? True when a value is
/// buffered, and also when the channel is **closed and drained** — a receive then
/// yields `None` immediately, which is a result, not a block.
fn native_chan_is_ready(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let id = as_int(expect_one(args, "chan_is_ready")?, "chan_is_ready")? as usize;
    Ok(Value::Bool(super::sched_chan_ready(id)))
}

/// Park until any of `handles` is ready, or `deadline_millis` passes (< 0 for no
/// deadline), or another fiber makes progress. The primitive under `fiber.select`;
/// the Hawk side re-checks every source when this returns.
fn native_select_park(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, dv) = args2(args, "select_park")?;
    let handles = with_list(hv, "select_park", |items| {
        items
            .iter()
            .map(|v| as_int(v, "select_park"))
            .collect::<Result<Vec<i64>, Trap>>()
    })?;
    let deadline_millis = as_int(dv, "select_park")?;
    let deadline = if deadline_millis < 0 {
        None
    } else {
        // The Hawk side passes a wall-clock deadline; the scheduler's timers are
        // `Instant`s, so turn it back into a duration from now. Saturating: an
        // already-past deadline parks for zero, and the driver wakes it at once.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let remaining = (deadline_millis - now).max(0) as u64;
        Some(std::time::Instant::now() + std::time::Duration::from_millis(remaining))
    };
    super::park_multi(deadline, handles);
    // The call's actual result: a `Multi` park resumes *after* the call (the native
    // is not re-run — that would just re-park); the Hawk-side loop re-probes.
    Ok(Value::Unit)
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

/// `term.is_tty()` — whether this process's standard output is an interactive
/// terminal. False when stdout is piped or redirected (the signal `style` uses to
/// stay plain).
fn native_term_is_tty(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    use std::io::IsTerminal;
    expect_no_args(args, "term_is_tty")?;
    Ok(Value::Bool(std::io::stdout().is_terminal()))
}

/// `term.size()` — the terminal as `[cols, rows]`, or None when the size can't be
/// determined (stdout is not a terminal). The Hawk layer assembles the `TermSize`
/// so this native never hardcodes a struct type-id (the std.regex ABI).
fn native_term_size(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    expect_no_args(args, "term_size")?;
    Ok(match terminal_size::terminal_size() {
        Some((terminal_size::Width(cols), terminal_size::Height(rows))) => {
            Value::some(Value::new_list(vec![
                Value::Int(i64::from(cols)),
                Value::Int(i64::from(rows)),
            ]))
        }
        None => Value::none(),
    })
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

fn map_handle(v: &Value, who: &str) -> Result<u32, Trap> {
    match v {
        Value::Ref(h) => Ok(*h),
        _ => Err(bug(format!("{who}: expected map"))),
    }
}

// Read a map under a shared heap borrow — no clone. `f` may compare keys
// (`values_eq` re-enters the heap, but only for *reads*, a fine nested shared
// borrow); it must not allocate or mutate the heap. Hash any lookup key *before*
// calling (see `map.get`) so no hashing re-enters under the borrow, and build any
// wrapper after `f` returns.
fn with_map_ref<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&MapObj) -> Result<R, Trap>,
) -> Result<R, Trap> {
    heap::with_obj(map_handle(v, who)?, |obj| match obj {
        Obj::Map(m) => f(m),
        _ => Err(bug(format!("{who}: expected map"))),
    })
}

// Mutate a map by *taking* it out of the heap (not cloning): `f` operates on the
// owned map with the heap free to be re-entered for key hashing/comparison, then
// it is put back — O(1) vs the old clone-out/write-back O(n). Restores the object
// even when `f` errors. Build any allocating result after this returns (the slot
// is empty while `f` runs).
fn with_map_taken<R>(
    v: &Value,
    who: &str,
    f: impl FnOnce(&mut MapObj) -> Result<R, Trap>,
) -> Result<R, Trap> {
    let handle = map_handle(v, who)?;
    let mut obj = heap::take_obj(handle);
    let r = match &mut obj {
        Obj::Map(m) => f(m),
        _ => Err(bug(format!("{who}: expected map"))),
    };
    heap::restore_obj(handle, obj);
    r
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

/// `list.pop()` — remove and return the last element, or `None` if empty.
fn native_list_pop(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    // Remove inside the borrow, then build the `Some`/`None` wrapper after it is
    // released — `with_list_mut` holds a heap borrow, so allocating the Option
    // inside would re-enter the heap (cf. `with_map_ref`).
    let popped = with_list_mut(expect_one(args, "list.pop")?, "list.pop", |items| {
        Ok(items.pop())
    })?;
    Ok(match popped {
        Some(v) => Value::some(v),
        None => Value::none(),
    })
}

/// `list.clear()` — remove every element, in place. Returns Unit.
fn native_list_clear(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_list_mut(expect_one(args, "list.clear")?, "list.clear", |items| {
        items.clear();
        Ok(Value::Unit)
    })
}

/// `{k0: v0, …}` — build a map from alternating key/value arguments.
fn native_map_new(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    if !args.len().is_multiple_of(2) {
        return Err(bug("map literal: expected an even number of arguments"));
    }
    // `new_map` (via `MapObj::from_pairs`) dedups, later keys overwriting earlier.
    let entries: Vec<(Value, Value)> = args.chunks_exact(2).map(|p| (p[0], p[1])).collect();
    Ok(Value::new_map(entries))
}

/// `map[key]` — value for `key`, faulting (naming the key) if absent.
fn native_map_index(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map index")?;
    let hash = hash_value(*key);
    let found = with_map_ref(map, "map index", |m| Ok(m.get(*key, hash)))?;
    // Render the key for the message only on the miss path, after the map borrow
    // is released (rendering a string key re-borrows the heap).
    found.ok_or_else(|| Trap::MissingKey {
        key: key_label(key),
    })
}

/// A short, human-readable rendering of a map key for the `MissingKey` message:
/// strings quoted (`'bob'`), other primitives as their `Display` form. Map keys
/// are strings or ints in practice; anything else falls back to a placeholder.
fn key_label(v: &Value) -> String {
    match v {
        Value::Int(n) => n.to_string(),
        Value::Double(x) => crate::value::format_double(*x),
        Value::Bool(b) => b.to_string(),
        Value::Unit => "void".to_string(),
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Str(s) => format!("'{s}'"),
            _ => "<key>".to_string(),
        }),
    }
}

/// `map.get(key)` — `Some(value)` if present, else `None`.
fn native_map_get(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map.get")?;
    // Hash the key before borrowing; find under the borrow (no clone), copy the
    // value out, then build the `Some` wrapper after the borrow is released
    // (`Value::some` allocates).
    let hash = hash_value(*key);
    let found = with_map_ref(map, "map.get", |m| Ok(m.get(*key, hash)))?;
    Ok(match found {
        Some(v) => Value::some(v),
        None => Value::none(),
    })
}

/// `map.len()`.
fn native_map_len(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    with_map_ref(expect_one(args, "map.len")?, "map.len", |m| {
        Ok(Value::Int(m.len() as i64))
    })
}

/// `map.has(key)`.
fn native_map_has(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key) = args2(args, "map.has")?;
    let hash = hash_value(*key);
    with_map_ref(map, "map.has", |m| Ok(Value::Bool(m.contains(*key, hash))))
}

/// `map[key] = v` — insert or update in place. Returns `Unit`.
fn native_map_set(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (map, key, val) = args3(args, "map set")?;
    let hash = hash_value(*key);
    with_map_taken(map, "map set", |m| {
        m.insert(*key, hash, *val);
        Ok(Value::Unit)
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
    let id_val = struct_field(process_val, 0, None)?;
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
        with_map_ref(first, who, |m| {
            let mut map = HashMap::new();
            for (k, val) in m.entries() {
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

    // The child runs to completion on the worker pool (parking the fiber); the
    // captured `Output` is turned into the result struct on the Hawk thread.
    park_syscall(
        move || command.output(),
        move |res| match res {
            Ok(output) => {
                let exit_code = output.status.code().unwrap_or(-1) as i64;
                let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
                let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
                Value::ok(Value::new_struct(
                    0,
                    vec![
                        Value::Int(exit_code),
                        Value::new_str(stdout),
                        Value::new_str(stderr),
                    ],
                ))
            }
            Err(e) => proc_err(&e, format!("failed to run '{cmd_name}': {e}")),
        },
    );
    Ok(Value::Unit)
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

    // The child inherits the *process's* stdio fds, so running it on the worker pool
    // is fine — it still shares the terminal — and the fiber parks until it exits.
    park_syscall(
        move || command.status(),
        move |res| match res {
            Ok(status) => Value::ok(Value::Int(status.code().unwrap_or(-1) as i64)),
            Err(e) => proc_err(&e, format!("failed to run '{cmd_name}': {e}")),
        },
    );
    Ok(Value::Unit)
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

    // Take the child out of the registry (so its pipes drop after the wait, as
    // before), then park on `wait()` on the worker pool. `wait` mustn't hold the
    // registry lock — a fiber blocked in `wait` would otherwise wedge every other
    // process op — so removal happens up front, matching the old drop-lock-then-wait.
    let removed = process_registry().lock().unwrap().remove(&id);
    let mut running = match removed {
        Some(r) => r,
        None => {
            return Ok(proc_err_io(format!(
                "process {id} not found (it may have already been waited on)"
            )));
        }
    };
    park_syscall(
        move || running.child.wait(),
        move |res| match res {
            Ok(status) => Value::ok(Value::Int(status.code().unwrap_or(-1) as i64)),
            Err(e) => proc_err(&e, format!("failed to wait for process {id}: {e}")),
        },
    );
    Ok(Value::Unit)
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
/// stdin, returning the byte count. Backs `Process.stdin(): Writer`. Parks on the
/// worker pool: the `ChildStdin` is taken out for the write and returned after (see
/// the take-out/return note on the file registry), so a full-pipe write doesn't
/// stall other fibers — and a reader fiber can drain stdout meanwhile to unblock it.
fn native_process_stdin_write(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (id_val, data_val) = args2(args, "process_stdin_write")?;
    let id = as_int(id_val, "process_stdin_write")?;
    let data = bytes_contents(data_val, "process_stdin_write")?;
    let n = data.len() as i64;

    let mut registry = process_registry().lock().unwrap();
    let running = match registry.get_mut(&id) {
        Some(r) => r,
        None => return Ok(proc_err_io(format!("process {id} not found"))),
    };
    let stdin = match running.stdin.take() {
        Some(s) => s,
        None => return Ok(proc_err_io(format!("process {id} stdin is not available"))),
    };
    drop(registry);
    park_syscall(
        move || {
            let mut stdin = stdin;
            let res = stdin.write_all(&data).and_then(|()| stdin.flush());
            (stdin, res)
        },
        move |(stdin, res)| {
            // Return the pipe so later writes / close still find it (unless the
            // process was waited/removed meanwhile, in which case it just drops).
            if let Some(running) = process_registry().lock().unwrap().get_mut(&id) {
                running.stdin = Some(stdin);
            }
            match res {
                Ok(()) => Value::ok(Value::Int(n)),
                Err(e) => proc_err(&e, format!("failed to write to process {id} stdin: {e}")),
            }
        },
    );
    Ok(Value::Unit)
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

/// Read up to `max` bytes from an owned child pipe (run on the worker pool); an
/// empty result is EOF, in which case the stream is dropped (returned as `None`).
/// Shared by stdout/stderr (both `impl Read`).
fn read_pipe_owned<R: Read>(
    mut stream: Option<R>,
    max: usize,
) -> (Option<R>, std::io::Result<Vec<u8>>) {
    let s = match &mut stream {
        Some(s) => s,
        None => return (None, Ok(Vec::new())), // already at EOF
    };
    let mut buf = vec![0u8; max.clamp(1, 1 << 20)];
    match s.read(&mut buf) {
        Ok(0) => (None, Ok(Vec::new())), // EOF: drop the pipe
        Ok(n) => {
            buf.truncate(n);
            (stream, Ok(buf))
        }
        Err(e) => (stream, Err(e)), // keep the pipe on error
    }
}

/// Park a child-pipe read on the worker pool: `stream` is taken from the registry,
/// read off-thread, and the (possibly-drained) pipe is put back by `restore` on the
/// Hawk thread. `restore` writes the stream into the right `RunningProcess` field.
fn park_pipe_read<R, F>(id: i64, stream: Option<R>, max: usize, restore: F)
where
    R: Read + Send + 'static,
    F: FnOnce(&mut RunningProcess, Option<R>) + Send + 'static,
{
    park_syscall(
        move || read_pipe_owned(stream, max),
        move |(stream, res)| {
            if let Some(running) = process_registry().lock().unwrap().get_mut(&id) {
                restore(running, stream);
            }
            match res {
                Ok(buf) => Value::ok(Value::new_bytes(buf)),
                Err(e) => proc_err(&e, format!("failed to read from process {id}: {e}")),
            }
        },
    );
}

/// `process_stdout_read(id, max)` — backs `Process.stdout(): Reader`.
fn native_process_stdout_read(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (id_val, max_val) = args2(args, "process_stdout_read")?;
    let id = as_int(id_val, "process_stdout_read")?;
    let max = as_int(max_val, "process_stdout_read")?.max(0) as usize;
    let mut registry = process_registry().lock().unwrap();
    let stream = match registry.get_mut(&id) {
        Some(running) => running.stdout.take(),
        None => return Ok(proc_err_io(format!("process {id} not found"))),
    };
    drop(registry);
    park_pipe_read(id, stream, max, |running, s| running.stdout = s);
    Ok(Value::Unit)
}

/// `process_stderr_read(id, max)` — backs `Process.stderr(): Reader`.
fn native_process_stderr_read(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (id_val, max_val) = args2(args, "process_stderr_read")?;
    let id = as_int(id_val, "process_stderr_read")?;
    let max = as_int(max_val, "process_stderr_read")?.max(0) as usize;
    let mut registry = process_registry().lock().unwrap();
    let stream = match registry.get_mut(&id) {
        Some(running) => running.stderr.take(),
        None => return Ok(proc_err_io(format!("process {id} not found"))),
    };
    drop(registry);
    park_pipe_read(id, stream, max, |running, s| running.stderr = s);
    Ok(Value::Unit)
}

// --- string slices ---

/// The substring of the code points in the half-open range `[start, end)`, by
/// code-point index. The native behind `String.slice`: it walks to the byte
/// offsets of code points `start` and `end` in a single pass — O(end), not
/// O(string length) — rather than materializing the whole string as a code-point
/// list. Indices are clamped: a negative start is 0, an end past the string stops
/// at its end, and a reversed or empty range yields `''`.
fn native_str_slice(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (sv, startv, endv) = args3(args, "str_slice")?;
    let s = str_contents(sv)?;
    let start = as_int(startv, "str_slice")?.max(0);
    let end = as_int(endv, "str_slice")?.max(0);
    if end <= start {
        return Ok(Value::new_str(""));
    }
    let start = start as usize;
    let end = end as usize;
    // Default to the string's end so an out-of-range index clamps to a
    // shorter/empty slice (start past the end leaves both at `len` → `''`).
    let mut byte_start = s.len();
    let mut byte_end = s.len();
    for (cp_idx, (byte_idx, _)) in s.char_indices().enumerate() {
        if cp_idx == start {
            byte_start = byte_idx;
        }
        if cp_idx == end {
            byte_end = byte_idx;
            break;
        }
    }
    Ok(Value::new_str(&s[byte_start..byte_end]))
}

// --- string byte-offset slice (companion to `str_byte_len`) ---

/// The substring in the half-open **UTF-8 byte** range `[start, end)`. The
/// byte-offset counterpart to the code-point `String.slice`, for callers that
/// work in byte positions (regex matches, `byte_len`). Offsets are clamped to the
/// string; a range whose ends don't fall on char boundaries yields `''`.
fn native_str_byte_slice(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (sv, startv, endv) = args3(args, "str_byte_slice")?;
    let s = str_contents(sv)?;
    let start = as_int(startv, "str_byte_slice")?;
    let end = as_int(endv, "str_byte_slice")?;
    let len = s.len() as i64;
    let a = start.clamp(0, len) as usize;
    let b = (end.clamp(0, len) as usize).max(a);
    Ok(Value::new_str(s.get(a..b).unwrap_or("").to_string()))
}

// --- std.regex: compiled patterns held in a registry, referenced by Int handle ---
//
// A compiled `regex::Regex` lives in a process-global registry (the same shape as
// std.process's child table); Hawk holds an opaque `Int` handle and never sees the
// compiled object. Match offsets are UTF-8 **byte** positions (docs/stdlib.md
// principle 8); the Hawk layer slices substrings out with `String.byte_slice`.
// Replacement (`$1` / `${name}` expansion) is performed here by the crate.
//
// Compiled patterns are not freed (compile-once / match-many), like the process
// table — acceptable for the typical "compile a handful at startup" usage.

static NEXT_REGEX_ID: AtomicI64 = AtomicI64::new(1);

fn regex_registry() -> &'static Mutex<HashMap<i64, regex::Regex>> {
    static REGISTRY: OnceLock<Mutex<HashMap<i64, regex::Regex>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Run `f` with the compiled regex for `handle`. An unknown handle is a bug —
/// Hawk only ever passes a handle it received from `regex_compile`.
fn with_regex<R>(handle: i64, who: &str, f: impl FnOnce(&regex::Regex) -> R) -> Result<R, Trap> {
    let reg = regex_registry().lock().unwrap();
    match reg.get(&handle) {
        Some(re) => Ok(f(re)),
        None => Err(bug(format!("{who}: unknown regex handle {handle}"))),
    }
}

/// Compile a pattern -> `Result<Int handle, String error>`. A syntax error is a
/// value, not a trap (the Hawk layer wraps it in `RegexError.Syntax`).
fn native_regex_compile(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let pattern = str_contents(expect_one(args, "regex_compile")?)?;
    match regex::Regex::new(&pattern) {
        Ok(re) => {
            let id = NEXT_REGEX_ID.fetch_add(1, Ordering::SeqCst);
            regex_registry().lock().unwrap().insert(id, re);
            Ok(Value::ok(Value::Int(id)))
        }
        Err(e) => Ok(Value::err(Value::new_str(e.to_string()))),
    }
}

fn native_regex_is_match(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, tv) = args2(args, "regex_is_match")?;
    let handle = as_int(hv, "regex_is_match")?;
    let text = str_contents(tv)?;
    with_regex(handle, "regex_is_match", |re| {
        Value::Bool(re.is_match(&text))
    })
}

/// First match as `[start, end]` byte offsets, or `[]` for no match.
fn native_regex_find(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, tv) = args2(args, "regex_find")?;
    let handle = as_int(hv, "regex_find")?;
    let text = str_contents(tv)?;
    with_regex(handle, "regex_find", |re| match re.find(&text) {
        Some(m) => Value::new_list(vec![
            Value::Int(m.start() as i64),
            Value::Int(m.end() as i64),
        ]),
        None => Value::new_list(vec![]),
    })
}

/// All non-overlapping matches as a flat `[s0, e0, s1, e1, ...]` of byte offsets.
fn native_regex_find_all(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, tv) = args2(args, "regex_find_all")?;
    let handle = as_int(hv, "regex_find_all")?;
    let text = str_contents(tv)?;
    with_regex(handle, "regex_find_all", |re| {
        let mut out = Vec::new();
        for m in re.find_iter(&text) {
            out.push(Value::Int(m.start() as i64));
            out.push(Value::Int(m.end() as i64));
        }
        Value::new_list(out)
    })
}

/// First match's capture groups as a flat `[s0, e0, s1, e1, ...]` of byte offsets
/// (group 0 is the whole match); a group that did not participate is `-1, -1`.
/// `[]` means no match.
fn native_regex_captures(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, tv) = args2(args, "regex_captures")?;
    let handle = as_int(hv, "regex_captures")?;
    let text = str_contents(tv)?;
    with_regex(handle, "regex_captures", |re| match re.captures(&text) {
        Some(caps) => {
            let mut out = Vec::new();
            for i in 0..caps.len() {
                match caps.get(i) {
                    Some(m) => {
                        out.push(Value::Int(m.start() as i64));
                        out.push(Value::Int(m.end() as i64));
                    }
                    None => {
                        out.push(Value::Int(-1));
                        out.push(Value::Int(-1));
                    }
                }
            }
            Value::new_list(out)
        }
        None => Value::new_list(vec![]),
    })
}

/// Replace the first match; `replacement` may reference groups with `$1`/`${name}`.
fn native_regex_replace(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, tv, rv) = args3(args, "regex_replace")?;
    let handle = as_int(hv, "regex_replace")?;
    let text = str_contents(tv)?;
    let repl = str_contents(rv)?;
    with_regex(handle, "regex_replace", |re| {
        Value::new_str(re.replace(&text, repl.as_str()).into_owned())
    })
}

/// Replace all non-overlapping matches; `replacement` may reference groups.
fn native_regex_replace_all(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, tv, rv) = args3(args, "regex_replace_all")?;
    let handle = as_int(hv, "regex_replace_all")?;
    let text = str_contents(tv)?;
    let repl = str_contents(rv)?;
    with_regex(handle, "regex_replace_all", |re| {
        Value::new_str(re.replace_all(&text, repl.as_str()).into_owned())
    })
}

// --- socket natives ---
//
// The internal layer under `std.net` (and, above it, `std.http`). Unlike every
// other blocking family here, sockets do **not** use the worker pool: their fds are
// non-blocking, so each syscall runs inline on the Hawk thread and returns at once.
// A `WouldBlock` parks the fiber on the readiness poller instead (`park_ready`),
// and the `call.native` re-runs when the kernel reports readiness. A blocking
// `accept` on the four-thread pool would pin a worker indefinitely and stall every
// other fiber's I/O — see interp/mod.rs §the readiness poller.
//
// Two consequences of "the native re-runs on wake" shape this surface, and both
// are load-bearing:
//
//  1. **Every native must attempt its syscall before parking.** That is what makes
//     a dropped edge harmless (see `ParkRequest::Ready`), so it is a correctness
//     requirement, not a fast path.
//  2. **Every native must be idempotent across the retry.** `read`/`accept` are
//     naturally so. `write` is only safe because it returns a *count* and lets the
//     Hawk side loop (`io.write_all`) — a write-all native here would re-send the
//     bytes it already wrote on every retry. `connect` is split in two for the same
//     reason: `socket_connect` starts it and `socket_connect_finish` polls for the
//     result, because re-issuing `connect(2)` on a pending fd gets `EALREADY`, not
//     a fresh attempt.
//
// Because the ops never leave the Hawk thread, sockets need none of the
// take-out/return discipline the `File` registry uses, and concurrent read + write
// on one socket from two fibers works (unlike a `File`, where it does not).

use mio::Interest;
use mio::net::{TcpListener, TcpStream};
use std::cell::{Cell, RefCell};
use std::io::ErrorKind;
use std::net::{SocketAddr, ToSocketAddrs};

/// A registered socket. The `mio` types own the fd and set O_NONBLOCK themselves.
enum Socket {
    Listener(TcpListener),
    Stream(TcpStream),
}

thread_local! {
    /// Open sockets by handle. Thread-local, not a process-global `Mutex` like the
    /// `File`/process registries: socket ops never run on a worker thread, and the
    /// poller these are registered with is itself thread-local.
    static SOCKETS: RefCell<HashMap<i64, Socket>> = RefCell::new(HashMap::new());
    /// Handles start at 1: each doubles as its `mio::Token`, and token 0 is the
    /// poller's waker (`WAKE_TOKEN`).
    static NEXT_SOCKET_ID: Cell<i64> = const { Cell::new(1) };
}

/// Drop every open socket. Called when the scheduler resets around a run, so fds
/// don't leak into a later run on this thread (the poller is reset alongside, which
/// drops the registrations).
pub(super) fn reset_sockets() {
    SOCKETS.with(|s| s.borrow_mut().clear());
    NEXT_SOCKET_ID.with(|n| n.set(1));
}

/// Build an `Err` for a socket error, kind-tagged `"<kind>\u{1}<message>"` like
/// `fs_err`; the Hawk side maps the kind to a `NetError` variant.
fn socket_err(e: &std::io::Error) -> Value {
    let kind = match e.kind() {
        ErrorKind::ConnectionRefused => "refused",
        ErrorKind::ConnectionReset => "reset",
        ErrorKind::ConnectionAborted => "reset",
        ErrorKind::BrokenPipe => "reset",
        ErrorKind::AddrInUse => "addr_in_use",
        ErrorKind::AddrNotAvailable => "addr_unavailable",
        ErrorKind::TimedOut => "timed_out",
        ErrorKind::PermissionDenied => "permission_denied",
        _ => "other",
    };
    Value::err(Value::new_str(format!("{kind}\u{1}{e}")))
}

/// An `Err` for a handle that isn't an open socket — a use-after-close.
fn socket_closed_err() -> Value {
    Value::err(Value::new_str("closed\u{1}socket is closed"))
}

/// An `Err` for a malformed address, tagged so the Hawk side can report it as a
/// distinct `NetError::Addr` rather than a generic I/O failure.
fn socket_addr_err(addr: &str) -> Value {
    Value::err(Value::new_str(format!(
        "addr\u{1}not an <ip>:<port> address: {addr}"
    )))
}

/// Register `source` with the readiness poller for read+write and file it in the
/// registry under a fresh handle. Registered once, for both directions, so a park
/// never has to re-arm anything.
fn register_socket(mut sock: Socket) -> Result<Value, Trap> {
    let id = NEXT_SOCKET_ID.with(|n| {
        let id = n.get();
        n.set(id + 1);
        id
    });
    let token = mio::Token(id as usize);
    let interest = Interest::READABLE | Interest::WRITABLE;
    let registered = super::with_registry(|r| match &mut sock {
        Socket::Listener(l) => r.register(l, token, interest),
        Socket::Stream(s) => r.register(s, token, interest),
    });
    if let Err(e) = registered {
        return Ok(socket_err(&e));
    }
    SOCKETS.with(|s| s.borrow_mut().insert(id, sock));
    Ok(Value::ok(Value::Int(id)))
}

/// Run `f` against the socket `handle` names. `Err(socket_closed_err())` if the
/// handle is closed or of the wrong kind — the registry borrow is held across `f`,
/// which is safe because `f` only ever performs a non-blocking syscall.
fn with_socket<T>(handle: i64, f: impl FnOnce(&mut Socket) -> T) -> Option<T> {
    SOCKETS.with(|s| s.borrow_mut().get_mut(&handle).map(f))
}

/// `net.listen(addr)` — bind + listen on `<ip>:<port>`, returning a handle.
fn native_socket_listen(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let addr = str_contents(expect_one(args, "socket_listen")?)?;
    let Ok(parsed) = addr.parse::<SocketAddr>() else {
        return Ok(socket_addr_err(&addr));
    };
    match TcpListener::bind(parsed) {
        Ok(l) => register_socket(Socket::Listener(l)),
        Err(e) => Ok(socket_err(&e)),
    }
}

/// `listener.accept()` — the next inbound connection's handle. Parks on the poller
/// until one arrives; idempotent (each retry takes a fresh connection or blocks).
fn native_socket_accept(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let handle = as_int(expect_one(args, "socket_accept")?, "socket_accept")?;
    let accepted = with_socket(handle, |sock| match sock {
        Socket::Listener(l) => l.accept().map(|(stream, _peer)| stream),
        Socket::Stream(_) => Err(std::io::Error::other("not a listener")),
    });
    match accepted {
        None => Ok(socket_closed_err()),
        Some(Ok(stream)) => register_socket(Socket::Stream(stream)),
        Some(Err(e)) if e.kind() == ErrorKind::WouldBlock => {
            super::park_ready(handle);
            Ok(Value::Unit) // discarded: the native re-runs on wake
        }
        Some(Err(e)) => Ok(socket_err(&e)),
    }
}

/// `net.connect(addr)` — *start* a non-blocking connect to `<ip>:<port>`, returning
/// the handle immediately. The connect is still in flight: `socket_connect_finish`
/// waits for it. Split in two because `connect(2)` is not idempotent, and this
/// native's retry-on-wake would re-issue it (see the module note above).
fn native_socket_connect(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let addr = str_contents(expect_one(args, "socket_connect")?)?;
    let Ok(parsed) = addr.parse::<SocketAddr>() else {
        return Ok(socket_addr_err(&addr));
    };
    // Returns at once with the connect in progress; readiness (or failure) shows up
    // on the poller as writability.
    match TcpStream::connect(parsed) {
        Ok(s) => register_socket(Socket::Stream(s)),
        Err(e) => Ok(socket_err(&e)),
    }
}

/// Wait for a `socket_connect` to resolve: `Ok(void)` once connected, or the
/// connect's error. Idempotent — it only ever *inspects* the socket, so re-running
/// it on wake is free.
fn native_socket_connect_finish(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let handle = as_int(
        expect_one(args, "socket_connect_finish")?,
        "socket_connect_finish",
    )?;
    let state = with_socket(handle, |sock| match sock {
        Socket::Stream(s) => {
            // A failed connect surfaces here (SO_ERROR), not from `peer_addr`.
            match s.take_error() {
                Ok(Some(e)) | Err(e) => return Err(e),
                Ok(None) => {}
            }
            // `peer_addr` is the ground truth for "has it landed yet": still
            // in-flight until the handshake completes.
            s.peer_addr().map(|_| ())
        }
        Socket::Listener(_) => Err(std::io::Error::other("not a stream")),
    });
    match state {
        None => Ok(socket_closed_err()),
        Some(Ok(())) => Ok(Value::ok(Value::Unit)),
        Some(Err(e))
            if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::NotConnected =>
        {
            super::park_ready(handle);
            Ok(Value::Unit) // discarded: the native re-runs on wake
        }
        Some(Err(e)) => Ok(socket_err(&e)),
    }
}

/// `stream.read(max)` — up to `max` bytes; an empty `Bytes` means the peer closed
/// (EOF). Parks until readable; idempotent (a retry consumed nothing).
fn native_socket_read(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, maxv) = args2(args, "socket_read")?;
    let handle = as_int(hv, "socket_read")?;
    let max = as_int(maxv, "socket_read")?.max(0) as usize;
    if max == 0 {
        return Ok(Value::ok(Value::new_bytes(Vec::new())));
    }
    let read = with_socket(handle, |sock| match sock {
        Socket::Stream(s) => {
            let mut buf = vec![0u8; max.min(1 << 20)];
            s.read(&mut buf).map(|n| {
                buf.truncate(n);
                buf
            })
        }
        Socket::Listener(_) => Err(std::io::Error::other("not a stream")),
    });
    match read {
        None => Ok(socket_closed_err()),
        Some(Ok(buf)) => Ok(Value::ok(Value::new_bytes(buf))),
        Some(Err(e)) if e.kind() == ErrorKind::WouldBlock => {
            super::park_ready(handle);
            Ok(Value::Unit) // discarded: the native re-runs on wake
        }
        Some(Err(e)) => Ok(socket_err(&e)),
    }
}

/// `stream.write(data)` — returns the number of bytes *actually* written, which may
/// be short. Returning a count (rather than writing all of `data`) is what keeps
/// this idempotent under the retry: nothing is written on a `WouldBlock`, and the
/// Hawk side (`io.write_all`) loops over the remainder.
fn native_socket_write(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, dv) = args2(args, "socket_write")?;
    let handle = as_int(hv, "socket_write")?;
    let data = bytes_contents(dv, "socket_write")?;
    if data.is_empty() {
        return Ok(Value::ok(Value::Int(0)));
    }
    let written = with_socket(handle, |sock| match sock {
        Socket::Stream(s) => s.write(&data),
        Socket::Listener(_) => Err(std::io::Error::other("not a stream")),
    });
    match written {
        None => Ok(socket_closed_err()),
        Some(Ok(n)) => Ok(Value::ok(Value::Int(n as i64))),
        Some(Err(e)) if e.kind() == ErrorKind::WouldBlock => {
            super::park_ready(handle);
            Ok(Value::Unit) // discarded: the native re-runs on wake
        }
        Some(Err(e)) => Ok(socket_err(&e)),
    }
}

/// `socket.close()` — deregister and drop. Closing twice is an error, matching
/// `File`.
fn native_socket_close(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let handle = as_int(expect_one(args, "socket_close")?, "socket_close")?;
    let Some(mut sock) = SOCKETS.with(|s| s.borrow_mut().remove(&handle)) else {
        return Ok(socket_closed_err());
    };
    // Deregister before the fd closes; a dropped registration on a closed fd is a
    // resource leak in the poller on some platforms.
    let _ = super::with_registry(|r| match &mut sock {
        Socket::Listener(l) => r.deregister(l),
        Socket::Stream(s) => r.deregister(s),
    });
    drop(sock);
    // Wake anyone parked on this socket — this is load-bearing, not tidiness.
    // Readiness events are routed by handle, and a closed socket produces no more
    // of them, so a fiber parked on it would never be woken by anything: a
    // permanent hang, not an error. Woken, it retries, finds the handle gone, and
    // gets `socket_closed_err`.
    //
    // That also makes close-from-another-fiber the only way to cancel a blocked
    // read, until `select` gives us a real one (docs/roadmap.md § Networking
    // punchlist).
    super::wake_poll_waiters(handle);
    Ok(Value::ok(Value::Unit))
}

/// `socket.local_addr()` — the bound `<ip>:<port>`. Useful for a listener bound to
/// port 0, where the OS picks the port.
fn native_socket_local_addr(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let handle = as_int(expect_one(args, "socket_local_addr")?, "socket_local_addr")?;
    let addr = with_socket(handle, |sock| match sock {
        Socket::Listener(l) => l.local_addr(),
        Socket::Stream(s) => s.local_addr(),
    });
    match addr {
        None => Ok(socket_closed_err()),
        Some(Ok(a)) => Ok(Value::ok(Value::new_str(a.to_string()))),
        Some(Err(e)) => Ok(socket_err(&e)),
    }
}

/// `stream.peer_addr()` — the remote `<ip>:<port>`.
fn native_socket_peer_addr(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let handle = as_int(expect_one(args, "socket_peer_addr")?, "socket_peer_addr")?;
    let addr = with_socket(handle, |sock| match sock {
        Socket::Stream(s) => s.peer_addr(),
        Socket::Listener(_) => Err(std::io::Error::other("not a stream")),
    });
    match addr {
        None => Ok(socket_closed_err()),
        Some(Ok(a)) => Ok(Value::ok(Value::new_str(a.to_string()))),
        Some(Err(e)) => Ok(socket_err(&e)),
    }
}

/// Is this socket ready to read? A **non-destructive** probe, which is what makes
/// the two-step `select` (ask which is ready, then act) possible: `peek` looks at
/// the received data without consuming it, so the `read` that follows still sees
/// it. EOF and a pending error both count as ready — the `read` will surface them,
/// and reporting "not ready" would park a fiber on a socket that will never speak
/// again.
///
/// Streams only. A listener has no non-destructive probe (`accept` *is* the
/// consumption), so `TcpListener` is not selectable; see sdk/std/net.
fn native_socket_is_ready(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let handle = as_int(expect_one(args, "socket_is_ready")?, "socket_is_ready")?;
    let ready = with_socket(handle, |sock| match sock {
        Socket::Stream(s) => {
            let mut probe = [0u8; 1];
            match s.peek(&mut probe) {
                Ok(_) => true,                               // data, or EOF
                Err(e) => e.kind() != ErrorKind::WouldBlock, // a real error is "ready"
            }
        }
        Socket::Listener(_) => false,
    });
    // A closed handle is "ready": the op re-run by `select`'s caller returns the
    // closed error at once, rather than parking on a socket that no longer exists.
    Ok(Value::Bool(ready.unwrap_or(true)))
}

/// `net.resolve(host, port)` — DNS, as a U+0001-joined list of `<ip>:<port>`.
///
/// The one socket op that *does* use the worker pool: name resolution blocks with
/// no fd to poll on, but unlike `accept` it is bounded, so it can't pin a worker
/// indefinitely. It has to be its own native regardless — a native may park only
/// once per call, and resolve-then-connect needs the pool *and* then the poller.
fn native_socket_resolve(_out: &mut dyn Write, args: &[Value]) -> Result<Value, Trap> {
    let (hv, pv) = args2(args, "socket_resolve")?;
    let host = str_contents(hv)?;
    let port = as_int(pv, "socket_resolve")?;
    if !(0..=65535).contains(&port) {
        return Ok(socket_addr_err(&format!("{host}:{port}")));
    }
    let err_host = host.clone();
    park_syscall(
        move || {
            (host.as_str(), port as u16)
                .to_socket_addrs()
                .map(|it| it.map(|a| a.to_string()).collect::<Vec<_>>().join("\u{1}"))
        },
        move |res| match res {
            Ok(joined) if joined.is_empty() => Value::err(Value::new_str(format!(
                "dns\u{1}no addresses for {err_host}"
            ))),
            Ok(joined) => Value::ok(Value::new_str(joined)),
            // Resolution failures surface as a grab-bag of io kinds across
            // platforms; tag them all as `dns` so the Hawk side reports the cause
            // the user can act on.
            Err(e) => Value::err(Value::new_str(format!("dns\u{1}{err_host}: {e}"))),
        },
    );
    Ok(Value::Unit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_indices_agree() {
        assert_eq!(native_index("println"), Some(NATIVE_PRINTLN));
        assert_eq!(native_index("str_concat"), Some(NATIVE_STR_CONCAT));
        assert_eq!(native_index("map_set"), Some(NATIVE_MAP_SET));
        assert_eq!(native_name(NATIVE_INT_TO_STRING), Some("int_to_string"));
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

    #[test]
    fn capture_buffers_stdout_then_restores() {
        let mut out: Vec<u8> = Vec::new();
        // With no capture active, output flows straight to `out`.
        native_println(&mut out, &[Value::new_str("live")]).unwrap();
        assert_eq!(out, b"live\n");

        // Begin a capture: stdout is buffered, `out` is left untouched.
        native_test_capture_begin(&mut std::io::sink(), &[]).unwrap();
        native_print(&mut out, &[Value::new_str("a")]).unwrap();
        native_println(&mut out, &[Value::new_str("b")]).unwrap();
        assert_eq!(out, b"live\n");

        // End the capture: it returns exactly what was buffered.
        let captured = native_test_capture_end(&mut std::io::sink(), &[]).unwrap();
        assert_eq!(display_string(&captured).unwrap(), "ab\n");

        // Output is live again once the capture ends.
        native_println(&mut out, &[Value::new_str("after")]).unwrap();
        assert_eq!(out, b"live\nafter\n");
    }

    // --- regex + str_byte_slice ---

    fn int_list(v: &Value) -> Vec<i64> {
        match v {
            Value::Ref(h) => heap::with_obj(*h, |o| match o {
                Obj::List(items) => items
                    .iter()
                    .map(|x| match x {
                        Value::Int(n) => *n,
                        other => panic!("non-int in list: {other:?}"),
                    })
                    .collect(),
                other => panic!("not a list: {other:?}"),
            }),
            other => panic!("not a ref: {other:?}"),
        }
    }

    fn ok_int(v: &Value) -> i64 {
        match v {
            Value::Ref(h) => heap::with_obj(*h, |o| match o {
                Obj::Enum(e) => match e.fields[0] {
                    Value::Int(n) => n,
                    other => panic!("ok payload not int: {other:?}"),
                },
                other => panic!("not an enum: {other:?}"),
            }),
            other => panic!("not a ref: {other:?}"),
        }
    }

    #[test]
    fn str_byte_slice_clamps_and_respects_char_boundaries() {
        let s = Value::new_str("héllo"); // 'é' is 2 UTF-8 bytes → byte_len 6
        let mut sink = std::io::sink();
        let mut slice = |a: i64, b: i64| {
            display_string(
                &native_str_byte_slice(&mut sink, &[s, Value::Int(a), Value::Int(b)]).unwrap(),
            )
            .unwrap()
        };
        assert_eq!(slice(0, 1), "h");
        assert_eq!(slice(1, 3), "é"); // the two bytes of 'é'
        assert_eq!(slice(0, 100), "héllo"); // end clamped to the string
        assert_eq!(slice(3, 1), ""); // end < start
        assert_eq!(slice(1, 2), ""); // mid-codepoint cut → not a boundary → ''
    }

    #[test]
    fn regex_natives_compile_match_find_replace() {
        let mut sink = std::io::sink();
        let compiled = native_regex_compile(&mut sink, &[Value::new_str(r"(\w+)@(\w+)")]).unwrap();
        let h = ok_int(&compiled);
        let text = Value::new_str("a@b and c@d");

        assert_eq!(
            native_regex_is_match(&mut sink, &[Value::Int(h), text]).unwrap(),
            Value::Bool(true)
        );
        // First match offsets ("a@b"), then both matches flattened.
        assert_eq!(
            int_list(&native_regex_find(&mut sink, &[Value::Int(h), text]).unwrap()),
            vec![0, 3]
        );
        assert_eq!(
            int_list(&native_regex_find_all(&mut sink, &[Value::Int(h), text]).unwrap()),
            vec![0, 3, 8, 11]
        );
        // Captures: group 0 (whole), then the two subgroups, as offset pairs.
        assert_eq!(
            int_list(
                &native_regex_captures(&mut sink, &[Value::Int(h), Value::new_str("a@b")]).unwrap()
            ),
            vec![0, 3, 0, 1, 2, 3]
        );
        // Replacement expands `$1`/`$2`.
        assert_eq!(
            display_string(
                &native_regex_replace_all(
                    &mut sink,
                    &[
                        Value::Int(h),
                        Value::new_str("a@b"),
                        Value::new_str("$2.$1")
                    ],
                )
                .unwrap()
            )
            .unwrap(),
            "b.a"
        );
    }

    #[test]
    fn regex_no_match_returns_empty_and_bad_pattern_is_a_value() {
        let mut sink = std::io::sink();
        let h = ok_int(&native_regex_compile(&mut sink, &[Value::new_str(r"\d+")]).unwrap());
        assert!(
            int_list(
                &native_regex_find(&mut sink, &[Value::Int(h), Value::new_str("abc")]).unwrap()
            )
            .is_empty()
        );

        // An invalid pattern is an Err value (TAG_ERR), not a trap.
        let bad = native_regex_compile(&mut sink, &[Value::new_str("(")]).unwrap();
        let is_err = match bad {
            Value::Ref(hh) => heap::with_obj(
                hh,
                |o| matches!(o, Obj::Enum(e) if e.variant == crate::value::TAG_ERR),
            ),
            _ => false,
        };
        assert!(is_err, "an invalid pattern should compile to Err, not trap");
    }
}
