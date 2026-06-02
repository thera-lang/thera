//! The native (Rust-implemented) function table and its built-in functions.
//!
//! `call.native <index>` resolves against [`default_natives`]; the `NATIVE_*`
//! constants name the indices. Each function takes the VM's output sink and the
//! call arguments. These are the stand-ins for the eventual stdlib `native fn`
//! bindings — enough to write observable programs without a real stdlib.

use std::io::Write;

use super::{Trap, bug};
use crate::value::{Obj, Value};

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
fn display_string(v: &Value) -> Result<String, Trap> {
    Ok(match v {
        Value::Int(n) => n.to_string(),
        Value::Double(x) => x.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Unit => "()".to_string(),
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Str(s) => s.clone(),
            Obj::Enum(_) | Obj::List(_) | Obj::Map(_) | Obj::Set(_) | Obj::Struct { .. } => {
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
            Obj::Enum(_) | Obj::List(_) | Obj::Map(_) | Obj::Set(_) | Obj::Struct { .. } => {
                Err(bug("expected string"))
            }
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
