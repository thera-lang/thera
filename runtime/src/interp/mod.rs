//! The Tier-0 evaluator.
//!
//! [`Vm::run_loop`] drives an **explicit call-frame stack**: each [`Frame`] owns
//! its operand stack, locals, and program counter, and one loop dispatches the
//! instruction stream until the frame stack empties. A `pc` (program counter)
//! indexes the running frame's instruction vec; the `jump` family redirects it.
//!
//! `Instr::Call` pushes a new frame and `Instr::Return` pops one — calls do
//! **not** recurse through the Rust stack, so deep Hawk recursion is bounded by
//! the heap (the frame `Vec`), not the host stack. Keeping every active frame in
//! one `Vec` is also what lets a precise GC enumerate the roots, and it is the
//! structure fibers will pause/resume.

use std::io::Write;

use crate::instr::Instr;
use crate::module::{ENUM_DISPATCH_BASE, Function, Module};
use crate::value::{Obj, TAG_OK, TAG_SOME, TY_OPTION, TY_RESULT, Value};

/// A runtime fault that aborts execution (see docs/language.md, "Runtime
/// faults"). Variants that describe malformed bytecode ([`Trap::Bug`]) indicate
/// a producer error rather than a program-level fault; valid bytecode never
/// raises them.
#[derive(Clone, Debug, PartialEq)]
pub enum Trap {
    /// Integer or float division/modulo by zero.
    DivByZero,
    /// List index outside `0..len` (the faulting case of `list[i]`).
    IndexOutOfBounds { index: i64, len: usize },
    /// Map indexed with `map[key]` where `key` is absent.
    MissingKey,
    /// The bytecode was malformed (stack underflow, type mismatch, bad slot).
    /// Valid bytecode from a correct producer never triggers this.
    Bug(String),
}

pub(crate) fn bug(msg: impl Into<String>) -> Trap {
    Trap::Bug(msg.into())
}

mod natives;
pub use natives::{
    NATIVE_EQ, NATIVE_LIST_GET, NATIVE_LIST_INDEX, NATIVE_LIST_LEN, NATIVE_LIST_SET,
    NATIVE_MAP_GET, NATIVE_MAP_HAS, NATIVE_MAP_INDEX, NATIVE_MAP_LEN, NATIVE_MAP_NEW,
    NATIVE_MAP_SET, NATIVE_PRINT, NATIVE_PRINTLN, NATIVE_SET_ADD, NATIVE_SET_HAS, NATIVE_SET_LEN,
    NATIVE_SET_NEW, NATIVE_SET_REMOVE, NATIVE_STR_CONCAT, NATIVE_STRINGIFY, NativeFn,
    default_natives, native_index, native_name, set_program_args,
};

/// The interpreter's execution context: where output goes and what native
/// functions are available. Later increments grow this with the heap/GC and the
/// fiber scheduler.
pub struct Vm<'a> {
    out: &'a mut dyn Write,
    natives: Vec<NativeFn>,
}

/// One activation record on the interpreter's explicit call-frame stack: the
/// running function, its program counter, its locals, and its operand stack.
/// Holding frames in an explicit `Vec` (rather than the Rust call stack) is what
/// lets a precise GC enumerate every active frame's values as roots.
struct Frame {
    func: usize,
    pc: usize,
    locals: Vec<Value>,
    stack: Vec<Value>,
}

/// What to do to the frame stack after dispatching one instruction. The
/// control-flow arms compute their effect while the running frame is borrowed,
/// then [`Vm::run_loop`] applies it once that borrow is released — so an arm
/// never restructures `frames` while it is holding a borrow into it.
enum Action {
    /// Stay in the current frame.
    Next,
    /// A call: push a new top frame.
    PushFrame(Frame),
    /// A return: pop the current frame, delivering `value` to its caller.
    Return(Value),
}

/// Run `module`'s function at index `func` with `args`, writing output to
/// stdout. Convenience over [`Vm`].
pub fn run(module: &Module, func: usize, args: &[Value]) -> Result<Value, Trap> {
    let mut out = std::io::stdout();
    Vm::new(&mut out).run(module, func, args)
}

/// Evaluate a bare instruction stream in a synthetic single-function module
/// (so `call` is unavailable) and discard output. `locals` seeds the frame's
/// leading slots. A convenience for testing snippets.
pub fn eval(code: &[Instr], locals: &[Value]) -> Result<Value, Trap> {
    let n = locals.len() as u16;
    let module = Module::new(vec![Function::new("<eval>", n, n, code.to_vec())]);
    let mut sink = std::io::sink();
    Vm::new(&mut sink).call(&module, 0, locals.to_vec())
}

impl<'a> Vm<'a> {
    /// Create a VM that writes output to `out`, with the default native table.
    pub fn new(out: &'a mut dyn Write) -> Self {
        Self {
            out,
            natives: default_natives(),
        }
    }

    /// Run `module`'s function at index `func` with `args`.
    pub fn run(&mut self, module: &Module, func: usize, args: &[Value]) -> Result<Value, Trap> {
        self.call(module, func, args.to_vec())
    }

    /// Build the call frame for `module.functions[func]`, placing `locals`
    /// (the arguments) in the leading slots and padding the rest with `Unit`.
    fn make_frame(
        &self,
        module: &Module,
        func: usize,
        mut locals: Vec<Value>,
    ) -> Result<Frame, Trap> {
        let f = module
            .functions
            .get(func)
            .ok_or_else(|| bug(format!("call: no function at index {func}")))?;
        if locals.len() != f.param_count as usize {
            return Err(bug(format!(
                "call: function '{}' expects {} args, got {}",
                f.name,
                f.param_count,
                locals.len()
            )));
        }
        locals.resize(f.local_count as usize, Value::Unit);
        Ok(Frame {
            func,
            pc: 0,
            locals,
            stack: Vec::new(),
        })
    }

    /// Build a frame for `func` and run it to completion.
    fn call(&mut self, module: &Module, func: usize, args: Vec<Value>) -> Result<Value, Trap> {
        let frame = self.make_frame(module, func, args)?;
        self.run_loop(module, frame)
    }

    /// The interpreter loop over an **explicit call-frame stack**. Each [`Frame`]
    /// owns its operand stack and locals, so every active frame's values stay
    /// reachable from `frames` (the precise-GC root set) and calls no longer
    /// recurse through the Rust stack — `Instr::Call`/`Return` push and pop
    /// frames here.
    fn run_loop(&mut self, module: &Module, initial: Frame) -> Result<Value, Trap> {
        let mut frames: Vec<Frame> = vec![initial];

        loop {
            let top = frames.len() - 1;
            let func = frames[top].func;
            let pc = frames[top].pc;
            let code = &module.functions[func].code;
            let instr = code
                .get(pc)
                .ok_or_else(|| bug("pc ran off the end of the instruction stream"))?;
            // Borrow the running frame's parts for dispatch. `module` (holding
            // `instr`) and `frames` are distinct objects, so these borrows
            // coexist; structural changes are deferred to `action`.
            let Frame {
                stack,
                locals,
                pc: frame_pc,
                ..
            } = &mut frames[top];
            *frame_pc = pc + 1; // advance; jumps overwrite below

            let mut action = Action::Next;
            match instr {
                // --- constants ---
                Instr::ConstInt(n) => stack.push(Value::Int(*n)),
                Instr::ConstDouble(x) => stack.push(Value::Double(*x)),
                Instr::ConstBool(b) => stack.push(Value::Bool(*b)),
                Instr::ConstUnit => stack.push(Value::Unit),
                Instr::ConstStr(s) => stack.push(Value::new_str(s.clone())),

                // --- locals ---
                Instr::Load(slot) => {
                    let v = locals
                        .get(*slot as usize)
                        .ok_or_else(|| bug(format!("load: slot {slot} out of range")))?
                        .clone();
                    stack.push(v);
                }
                Instr::Store(slot) => {
                    let v = pop(stack)?;
                    *locals
                        .get_mut(*slot as usize)
                        .ok_or_else(|| bug(format!("store: slot {slot} out of range")))? = v;
                }

                // --- integer arithmetic (wrapping) ---
                Instr::AddI64 => {
                    let (a, b) = pop_two_int(stack)?;
                    stack.push(Value::Int(a.wrapping_add(b)));
                }
                Instr::SubI64 => {
                    let (a, b) = pop_two_int(stack)?;
                    stack.push(Value::Int(a.wrapping_sub(b)));
                }
                Instr::MulI64 => {
                    let (a, b) = pop_two_int(stack)?;
                    stack.push(Value::Int(a.wrapping_mul(b)));
                }
                Instr::DivI64 => {
                    let (a, b) = pop_two_int(stack)?;
                    if b == 0 {
                        return Err(Trap::DivByZero);
                    }
                    stack.push(Value::Int(a.wrapping_div(b)));
                }
                Instr::ModI64 => {
                    let (a, b) = pop_two_int(stack)?;
                    if b == 0 {
                        return Err(Trap::DivByZero);
                    }
                    stack.push(Value::Int(a.wrapping_rem(b)));
                }
                Instr::NegI64 => {
                    let a = pop_int(stack)?;
                    stack.push(Value::Int(a.wrapping_neg()));
                }

                // --- float arithmetic ---
                Instr::AddF64 => {
                    let (a, b) = pop_two_double(stack)?;
                    stack.push(Value::Double(a + b));
                }
                Instr::SubF64 => {
                    let (a, b) = pop_two_double(stack)?;
                    stack.push(Value::Double(a - b));
                }
                Instr::MulF64 => {
                    let (a, b) = pop_two_double(stack)?;
                    stack.push(Value::Double(a * b));
                }
                Instr::DivF64 => {
                    let (a, b) = pop_two_double(stack)?;
                    stack.push(Value::Double(a / b));
                }
                Instr::NegF64 => {
                    let a = pop_double(stack)?;
                    stack.push(Value::Double(-a));
                }

                // --- integer comparison ---
                Instr::EqI64 => cmp_int(stack, |a, b| a == b)?,
                Instr::NeI64 => cmp_int(stack, |a, b| a != b)?,
                Instr::LtI64 => cmp_int(stack, |a, b| a < b)?,
                Instr::LeI64 => cmp_int(stack, |a, b| a <= b)?,
                Instr::GtI64 => cmp_int(stack, |a, b| a > b)?,
                Instr::GeI64 => cmp_int(stack, |a, b| a >= b)?,

                // --- float comparison ---
                Instr::EqF64 => cmp_double(stack, |a, b| a == b)?,
                Instr::NeF64 => cmp_double(stack, |a, b| a != b)?,
                Instr::LtF64 => cmp_double(stack, |a, b| a < b)?,
                Instr::LeF64 => cmp_double(stack, |a, b| a <= b)?,
                Instr::GtF64 => cmp_double(stack, |a, b| a > b)?,
                Instr::GeF64 => cmp_double(stack, |a, b| a >= b)?,

                // --- boolean ---
                Instr::Not => {
                    let b = pop_bool(stack)?;
                    stack.push(Value::Bool(!b));
                }

                // --- conversions ---
                Instr::I64ToF64 => {
                    let a = pop_int(stack)?;
                    stack.push(Value::Double(a as f64));
                }
                Instr::F64ToI64 => {
                    let a = pop_double(stack)?;
                    stack.push(Value::Int(a as i64));
                }

                // --- stack manipulation ---
                Instr::Pop => {
                    pop(stack)?;
                }
                Instr::Dup => {
                    let v = stack.last().ok_or_else(|| bug("dup: empty stack"))?.clone();
                    stack.push(v);
                }

                // --- calls ---
                Instr::Call { func, argc } => {
                    let argc = *argc as usize;
                    let base = stack
                        .len()
                        .checked_sub(argc)
                        .ok_or_else(|| bug("call: operand stack underflow"))?;
                    let args = stack.split_off(base);
                    action = Action::PushFrame(self.make_frame(module, *func as usize, args)?);
                }
                Instr::CallNative { native, argc } => {
                    let argc = *argc as usize;
                    let base = stack
                        .len()
                        .checked_sub(argc)
                        .ok_or_else(|| bug("call.native: operand stack underflow"))?;
                    let args = stack.split_off(base);
                    let f = *self
                        .natives
                        .get(*native as usize)
                        .ok_or_else(|| bug(format!("call.native: no native at index {native}")))?;
                    let ret = f(&mut *self.out, &args)?;
                    stack.push(ret);
                }
                Instr::CallIndirect { argc } => {
                    let argc = *argc as usize;
                    // Beneath the `argc` arguments sits the closure value.
                    let base = stack
                        .len()
                        .checked_sub(argc + 1)
                        .ok_or_else(|| bug("call.indirect: operand stack underflow"))?;
                    let mut slot = stack.split_off(base);
                    let args = slot.split_off(1);
                    let callee = slot.pop().expect("closure slot present");
                    let (func, mut callee_locals) = closure_parts(&callee)?;
                    // The callee frame is captures followed by the arguments.
                    callee_locals.extend(args);
                    action =
                        Action::PushFrame(self.make_frame(module, func as usize, callee_locals)?);
                }
                Instr::CallVirtual { selector, argc } => {
                    let argc = *argc as usize;
                    let base = stack
                        .len()
                        .checked_sub(argc)
                        .ok_or_else(|| bug("call.virtual: operand stack underflow"))?;
                    let args = stack.split_off(base);
                    // The receiver is the first argument; its concrete type id
                    // selects the implementation. A miss (no row, or a receiver
                    // with no dispatch id — primitives, strings, collections)
                    // falls back to the built-in interfaces' structural forms.
                    let recv = args
                        .first()
                        .ok_or_else(|| bug("call.virtual: missing receiver"))?;
                    let target =
                        dispatch_type_id(recv).and_then(|ty| module.dispatch_target(ty, selector));
                    match target {
                        Some(func) => {
                            action =
                                Action::PushFrame(self.make_frame(module, func as usize, args)?);
                        }
                        None => {
                            let ret = self.virtual_fallback(module, selector, &args)?;
                            stack.push(ret);
                        }
                    }
                }

                // --- enums ---
                Instr::EnumNew {
                    ty,
                    variant,
                    field_count,
                } => {
                    let fc = *field_count as usize;
                    let base = stack
                        .len()
                        .checked_sub(fc)
                        .ok_or_else(|| bug("enum.new: operand stack underflow"))?;
                    let fields = stack.split_off(base);
                    stack.push(Value::new_enum(*ty, *variant, fields));
                }
                Instr::EnumTag => {
                    let variant = pop_enum_variant(stack)?;
                    stack.push(Value::Int(variant as i64));
                }
                Instr::EnumGet(idx) => {
                    let v = pop(stack)?;
                    stack.push(enum_field(&v, *idx as usize)?);
                }

                // --- structs ---
                Instr::StructNew { ty } => {
                    let field_count = module
                        .types
                        .get(*ty as usize)
                        .ok_or_else(|| bug(format!("struct.new: no type at index {ty}")))?
                        .field_count as usize;
                    let base = stack
                        .len()
                        .checked_sub(field_count)
                        .ok_or_else(|| bug("struct.new: operand stack underflow"))?;
                    let fields = stack.split_off(base);
                    stack.push(Value::new_struct(*ty, fields));
                }
                Instr::FieldGet(idx) => {
                    let v = pop(stack)?;
                    stack.push(struct_field(&v, *idx as usize)?);
                }
                Instr::FieldSet(idx) => {
                    let value = pop(stack)?;
                    let obj = pop(stack)?;
                    set_struct_field(&obj, *idx as usize, value)?;
                }

                // --- collections ---
                Instr::ListNew { count } => {
                    let n = *count as usize;
                    let base = stack
                        .len()
                        .checked_sub(n)
                        .ok_or_else(|| bug("list.new: operand stack underflow"))?;
                    let items = stack.split_off(base);
                    stack.push(Value::new_list(items));
                }
                Instr::ListGet => {
                    let idx = pop_int(stack)?;
                    let list = pop(stack)?;
                    let elem = match &list {
                        Value::Ref(rc) => match &*rc.borrow() {
                            Obj::List(items) => {
                                items[checked_list_index(idx, items.len())?].clone()
                            }
                            _ => return Err(bug("list.get: expected a list")),
                        },
                        _ => return Err(bug("list.get: expected a list")),
                    };
                    stack.push(elem);
                }
                Instr::ListSet => {
                    let value = pop(stack)?;
                    let idx = pop_int(stack)?;
                    let list = pop(stack)?;
                    match &list {
                        Value::Ref(rc) => match &mut *rc.borrow_mut() {
                            Obj::List(items) => {
                                let i = checked_list_index(idx, items.len())?;
                                items[i] = value;
                            }
                            _ => return Err(bug("list.set: expected a list")),
                        },
                        _ => return Err(bug("list.set: expected a list")),
                    }
                }

                // --- closures ---
                Instr::ClosureNew { func, captures } => {
                    let n = *captures as usize;
                    let base = stack
                        .len()
                        .checked_sub(n)
                        .ok_or_else(|| bug("closure.new: operand stack underflow"))?;
                    let captured = stack.split_off(base);
                    stack.push(Value::new_closure(*func, captured));
                }

                // --- control ---
                Instr::Jump(target) => *frame_pc = *target,
                Instr::JumpIfTrue(target) => {
                    if pop_bool(stack)? {
                        *frame_pc = *target;
                    }
                }
                Instr::JumpIfFalse(target) => {
                    if !pop_bool(stack)? {
                        *frame_pc = *target;
                    }
                }
                Instr::Return => action = Action::Return(stack.pop().unwrap_or(Value::Unit)),
            }

            // The running frame's borrow ends here; apply the structural effect.
            match action {
                Action::Next => {}
                Action::PushFrame(frame) => frames.push(frame),
                Action::Return(value) => {
                    frames.pop();
                    match frames.last_mut() {
                        Some(caller) => caller.stack.push(value),
                        None => return Ok(value),
                    }
                }
            }
        }
    }

    /// A `call.virtual` with no dispatch row: the built-in interfaces'
    /// structural implementations. This is what makes the auto-derives real —
    /// primitives (and strings/collections) carry built-in `Display`/`Eq`/
    /// `Debug`, and structs/enums without an explicit impl get structural
    /// `eq`/`debug` (an explicit impl, when present, won via the table).
    fn virtual_fallback(
        &mut self,
        module: &Module,
        selector: &str,
        args: &[Value],
    ) -> Result<Value, Trap> {
        let recv = args.first().expect("call.virtual receiver present");
        match selector {
            "display" => Ok(Value::new_str(natives::display_string(recv)?)),
            "debug" => {
                let s = self.debug_value(module, recv)?;
                Ok(Value::new_str(s))
            }
            "eq" => match args {
                [a, b] => Ok(Value::Bool(a == b)),
                _ => Err(bug("call.virtual eq: expected 2 args")),
            },
            _ => Err(bug(format!(
                "call.virtual: no impl of '{selector}' for the receiver's type"
            ))),
        }
    }

    /// The structural `Debug` rendering of [v] — the auto-derived `debug`.
    /// Strings are quoted; collections recurse; a struct renders as
    /// `Name { field, ... }` (positionally — field names aren't in the type
    /// table); an enum as `Variant(field, ...)` with the reserved Result/Option
    /// variants named (other enums' variant names aren't in the runtime yet).
    /// A nested value with an explicit `impl Debug` renders through it.
    fn debug_value(&mut self, module: &Module, v: &Value) -> Result<String, Trap> {
        // An explicit `impl Debug` overrides the structural rendering.
        if let Some(ty) = dispatch_type_id(v)
            && let Some(func) = module.dispatch_target(ty, "debug")
        {
            let ret = self.call(module, func as usize, vec![v.clone()])?;
            return match &ret {
                Value::Ref(rc) => match &*rc.borrow() {
                    Obj::Str(s) => Ok(s.clone()),
                    _ => Err(bug("debug impl did not return a String")),
                },
                _ => Err(bug("debug impl did not return a String")),
            };
        }
        Ok(match v {
            Value::Int(n) => n.to_string(),
            Value::Double(x) => x.to_string(),
            Value::Bool(b) => b.to_string(),
            Value::Unit => "()".to_string(),
            Value::Ref(rc) => match &*rc.borrow() {
                Obj::Str(s) => format!("'{}'", s.replace('\\', r"\\").replace('\'', r"\'")),
                Obj::List(items) => format!("[{}]", self.debug_list(module, items)?),
                Obj::Set(items) => format!("{{{}}}", self.debug_list(module, items)?),
                Obj::Map(entries) => {
                    let mut parts = Vec::with_capacity(entries.len());
                    for (k, val) in entries {
                        parts.push(format!(
                            "{}: {}",
                            self.debug_value(module, k)?,
                            self.debug_value(module, val)?
                        ));
                    }
                    format!("{{{}}}", parts.join(", "))
                }
                Obj::Struct { ty, fields } => {
                    let name = module
                        .types
                        .get(*ty as usize)
                        .map_or("<struct>", |t| t.name.as_str());
                    if fields.is_empty() {
                        format!("{name} {{}}")
                    } else {
                        format!("{name} {{ {} }}", self.debug_list(module, fields)?)
                    }
                }
                Obj::Enum(e) => {
                    let variant = match (e.ty, e.variant) {
                        (TY_RESULT, TAG_OK) => "Ok".to_string(),
                        (TY_RESULT, _) => "Err".to_string(),
                        (TY_OPTION, TAG_SOME) => "Some".to_string(),
                        (TY_OPTION, _) => "None".to_string(),
                        (_, tag) => format!("variant{tag}"),
                    };
                    if e.fields.is_empty() {
                        variant
                    } else {
                        format!("{variant}({})", self.debug_list(module, &e.fields)?)
                    }
                }
                Obj::Closure { .. } => "<fn>".to_string(),
            },
        })
    }

    /// Comma-joined [debug_value]s of [items].
    fn debug_list(&mut self, module: &Module, items: &[Value]) -> Result<String, Trap> {
        let mut parts = Vec::with_capacity(items.len());
        for item in items {
            parts.push(self.debug_value(module, item)?);
        }
        Ok(parts.join(", "))
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

/// Resolve a (possibly out-of-range) list index, trapping if outside `0..len`.
/// The bounds check behind the `list.get` / `list.set` opcodes.
fn checked_list_index(i: i64, len: usize) -> Result<usize, Trap> {
    if i < 0 || i as u64 >= len as u64 {
        Err(Trap::IndexOutOfBounds { index: i, len })
    } else {
        Ok(i as usize)
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

/// Pop an enum value and return its variant tag.
fn pop_enum_variant(stack: &mut Vec<Value>) -> Result<u16, Trap> {
    match pop(stack)? {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Enum(e) => Ok(e.variant),
            Obj::Str(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Set(_)
            | Obj::Struct { .. }
            | Obj::Closure { .. } => Err(bug("enum.tag: expected enum")),
        },
        v => Err(bug(format!("expected enum, found {v:?}"))),
    }
}

/// Unpack a closure value into its function index and a fresh copy of its
/// captured environment (which becomes the callee's leading local slots).
fn closure_parts(v: &Value) -> Result<(u32, Vec<Value>), Trap> {
    match v {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Closure { func, captures } => Ok((*func, captures.clone())),
            _ => Err(bug("call.indirect: expected a closure")),
        },
        v => Err(bug(format!(
            "call.indirect: expected a closure, found {v:?}"
        ))),
    }
}

/// The dispatch-table type id of a `call.virtual` receiver — a struct's `ty`
/// (an index into `Module::types`), or an enum's `ty` offset by
/// [`ENUM_DISPATCH_BASE`] (the two id spaces overlap numerically). None for
/// receivers that can't carry an impl row (primitives, strings, collections,
/// closures) — those dispatch through the built-in fallback.
fn dispatch_type_id(v: &Value) -> Option<u32> {
    match v {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Struct { ty, .. } => Some(*ty),
            Obj::Enum(e) => Some(ENUM_DISPATCH_BASE | e.ty),
            Obj::Str(_) | Obj::List(_) | Obj::Map(_) | Obj::Set(_) | Obj::Closure { .. } => None,
        },
        _ => None,
    }
}

/// Read payload field `idx` of an enum value.
fn enum_field(v: &Value, idx: usize) -> Result<Value, Trap> {
    match v {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Enum(e) => e
                .fields
                .get(idx)
                .cloned()
                .ok_or_else(|| bug(format!("enum.get: field {idx} out of range"))),
            Obj::Str(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Set(_)
            | Obj::Struct { .. }
            | Obj::Closure { .. } => Err(bug("enum.get: expected enum")),
        },
        v => Err(bug(format!("enum.get: expected enum, found {v:?}"))),
    }
}

/// Read field `idx` of a struct value.
pub(super) fn struct_field(v: &Value, idx: usize) -> Result<Value, Trap> {
    match v {
        Value::Ref(rc) => match &*rc.borrow() {
            Obj::Struct { fields, .. } => fields
                .get(idx)
                .cloned()
                .ok_or_else(|| bug(format!("field.get: field {idx} out of range"))),
            Obj::Str(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Set(_)
            | Obj::Enum(_)
            | Obj::Closure { .. } => Err(bug("field.get: expected struct")),
        },
        v => Err(bug(format!("field.get: expected struct, found {v:?}"))),
    }
}

/// Store `value` into field `idx` of a struct value (in place).
fn set_struct_field(v: &Value, idx: usize, value: Value) -> Result<(), Trap> {
    match v {
        Value::Ref(rc) => match &mut *rc.borrow_mut() {
            Obj::Struct { fields, .. } => {
                let slot = fields
                    .get_mut(idx)
                    .ok_or_else(|| bug(format!("field.set: field {idx} out of range")))?;
                *slot = value;
                Ok(())
            }
            Obj::Str(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Set(_)
            | Obj::Enum(_)
            | Obj::Closure { .. } => Err(bug("field.set: expected struct")),
        },
        v => Err(bug(format!("field.set: expected struct, found {v:?}"))),
    }
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
    use crate::builder::FnBuilder;
    use crate::module::{Function, Module, TypeDef};
    use crate::value::{TAG_ERR, TAG_NONE, TAG_OK, TAG_SOME};

    // Opaque type ids for the draft (no type table yet).
    const RESULT: u32 = 0;
    const OPTION: u32 = 1;

    /// Evaluate a bare snippet with no locals. (Shadows the module-level `run`
    /// for the earlier increments' tests; increment-3 tests use `super::run`.)
    fn run(code: &[Instr]) -> Result<Value, Trap> {
        eval(code, &[])
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
        let locals = vec![Value::Unit];
        let code = [
            Instr::ConstInt(42),
            Instr::Store(0),
            Instr::Load(0),
            Instr::Return,
        ];
        assert_eq!(eval(&code, &locals), Ok(Value::Int(42)));
    }

    #[test]
    fn unconditional_jump_skips_instructions() {
        // Jump over a ConstInt(999) that would otherwise overwrite the result.
        let code = [
            Instr::ConstInt(42),
            Instr::Jump(4),
            Instr::ConstInt(999), // skipped
            Instr::Return,        // skipped
            Instr::Return,        // target
        ];
        assert_eq!(run(&code), Ok(Value::Int(42)));
    }

    /// `if a < b { 100 } else { 200 }`.
    fn branch(a: i64, b: i64) -> Result<Value, Trap> {
        let code = [
            Instr::ConstInt(a),
            Instr::ConstInt(b),
            Instr::LtI64,
            Instr::JumpIfFalse(6), // false → else branch
            Instr::ConstInt(100),  // then
            Instr::Return,
            Instr::ConstInt(200), // else (index 6)
            Instr::Return,
        ];
        run(&code)
    }

    #[test]
    fn conditional_branch_taken_and_not_taken() {
        assert_eq!(branch(2, 3), Ok(Value::Int(100))); // 2 < 3 → then
        assert_eq!(branch(3, 2), Ok(Value::Int(200))); // 3 < 2 → else
    }

    #[test]
    fn jump_if_true() {
        // if true, jump to return 1; else fall through to return 0.
        let code = [
            Instr::ConstBool(true),
            Instr::JumpIfTrue(4),
            Instr::ConstInt(0),
            Instr::Return,
            Instr::ConstInt(1), // target
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(1)));
    }

    #[test]
    fn counted_loop_sums_range() {
        // sum = 0; i = 0; while i < 5 { sum += i; i += 1 }; return sum  // = 10
        let code = [
            Instr::ConstInt(0),
            Instr::Store(1), // sum = 0
            Instr::ConstInt(0),
            Instr::Store(0), // i = 0
            // loop head (index 4):
            Instr::Load(0),
            Instr::ConstInt(5),
            Instr::LtI64,
            Instr::JumpIfFalse(17), // exit
            Instr::Load(1),
            Instr::Load(0),
            Instr::AddI64,
            Instr::Store(1), // sum += i
            Instr::Load(0),
            Instr::ConstInt(1),
            Instr::AddI64,
            Instr::Store(0), // i += 1
            Instr::Jump(4),
            // after loop (index 17):
            Instr::Load(1),
            Instr::Return,
        ];
        let locals = vec![Value::Unit; 2];
        assert_eq!(eval(&code, &locals), Ok(Value::Int(10)));
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

    // --- increment 3: functions & calls ---

    #[test]
    fn simple_call() {
        // double(x) = x * 2;  main() = double(21)
        let main = Function::new(
            "main",
            0,
            0,
            vec![
                Instr::ConstInt(21),
                Instr::Call { func: 1, argc: 1 },
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
        assert_eq!(super::run(&module, 0, &[]), Ok(Value::Int(42)));
    }

    #[test]
    fn deep_recursion_does_not_overflow_the_host_stack() {
        // countdown(n) = if n == 0 { 0 } else { countdown(n - 1) }
        // Not tail-call optimized, so all N frames are live at peak depth. With
        // the explicit frame stack that depth is bounded by the heap, not the
        // Rust call stack — a depth that would blow the host stack runs fine.
        let countdown = Function::new(
            "countdown",
            1,
            1,
            vec![
                Instr::Load(0),                   // 0: n
                Instr::ConstInt(0),               // 1
                Instr::EqI64,                     // 2: n == 0
                Instr::JumpIfFalse(6),            // 3: nonzero → recurse at 6
                Instr::ConstInt(0),               // 4
                Instr::Return,                    // 5: base case → 0
                Instr::Load(0),                   // 6: n
                Instr::ConstInt(1),               // 7
                Instr::SubI64,                    // 8: n - 1
                Instr::Call { func: 0, argc: 1 }, // 9: countdown(n - 1)
                Instr::Return,                    // 10
            ],
        );
        let module = Module::new(vec![countdown]);
        // 250k frames deep — well past what the native stack could hold.
        assert_eq!(
            super::run(&module, 0, &[Value::Int(250_000)]),
            Ok(Value::Int(0)),
        );
    }

    #[test]
    fn argument_order_is_preserved() {
        // sub(a, b) = a - b;  sub(10, 3) = 7  (args land in locals[0], locals[1])
        let sub = Function::new(
            "sub",
            2,
            2,
            vec![Instr::Load(0), Instr::Load(1), Instr::SubI64, Instr::Return],
        );
        let module = Module::new(vec![sub]);
        assert_eq!(
            super::run(&module, 0, &[Value::Int(10), Value::Int(3)]),
            Ok(Value::Int(7))
        );
    }

    #[test]
    fn recursive_factorial() {
        // fact(n) = if n <= 1 { 1 } else { n * fact(n - 1) }  (built via FnBuilder)
        let mut b = FnBuilder::new("fact", 1);
        let recurse = b.label();
        b.load(0);
        b.const_int(1);
        b.le_i64();
        b.jump_if_false(recurse);
        b.const_int(1); // base case
        b.ret();
        b.bind(recurse);
        b.load(0);
        b.load(0);
        b.const_int(1);
        b.sub_i64();
        b.call(0, 1); // fact(n - 1)
        b.mul_i64();
        b.ret();
        let module = Module::new(vec![b.finish()]);
        assert_eq!(
            super::run(&module, 0, &[Value::Int(5)]),
            Ok(Value::Int(120))
        );
        assert_eq!(super::run(&module, 0, &[Value::Int(0)]), Ok(Value::Int(1)));
    }

    #[test]
    fn recursive_fibonacci() {
        // fib(n) = if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
        let fib = Function::new(
            "fib",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::ConstInt(2),
                Instr::LtI64,
                Instr::JumpIfFalse(6),
                Instr::Load(0), // base case: return n
                Instr::Return,
                Instr::Load(0), // index 6
                Instr::ConstInt(1),
                Instr::SubI64,
                Instr::Call { func: 0, argc: 1 }, // fib(n - 1)
                Instr::Load(0),
                Instr::ConstInt(2),
                Instr::SubI64,
                Instr::Call { func: 0, argc: 1 }, // fib(n - 2)
                Instr::AddI64,
                Instr::Return,
            ],
        );
        let module = Module::new(vec![fib]);
        assert_eq!(
            super::run(&module, 0, &[Value::Int(10)]),
            Ok(Value::Int(55))
        );
    }

    #[test]
    fn void_function_returns_unit() {
        // f() returns nothing; main() = f()
        let main = Function::new(
            "main",
            0,
            0,
            vec![Instr::Call { func: 1, argc: 0 }, Instr::Return],
        );
        let f = Function::new("f", 0, 0, vec![Instr::Return]);
        let module = Module::new(vec![main, f]);
        assert_eq!(super::run(&module, 0, &[]), Ok(Value::Unit));
    }

    #[test]
    fn unknown_function_is_a_bug() {
        let module = Module::default();
        assert!(matches!(super::run(&module, 0, &[]), Err(Trap::Bug(_))));
    }

    #[test]
    fn arity_mismatch_is_a_bug() {
        // Call passes 0 args to a function expecting 1.
        let main = Function::new(
            "main",
            0,
            0,
            vec![Instr::Call { func: 1, argc: 0 }, Instr::Return],
        );
        let g = Function::new("g", 1, 1, vec![Instr::Load(0), Instr::Return]);
        let module = Module::new(vec![main, g]);
        assert!(matches!(super::run(&module, 0, &[]), Err(Trap::Bug(_))));
    }

    // --- increment 4: enums & the heap ---

    #[test]
    fn enum_tag() {
        let ok = [
            Instr::ConstInt(42),
            Instr::EnumNew {
                ty: RESULT,
                variant: TAG_OK,
                field_count: 1,
            },
            Instr::EnumTag,
            Instr::Return,
        ];
        assert_eq!(run(&ok), Ok(Value::Int(0)));

        let none = [
            Instr::EnumNew {
                ty: OPTION,
                variant: TAG_NONE,
                field_count: 0,
            },
            Instr::EnumTag,
            Instr::Return,
        ];
        assert_eq!(run(&none), Ok(Value::Int(1)));
    }

    #[test]
    fn enum_get_payload() {
        let code = [
            Instr::ConstInt(42),
            Instr::EnumNew {
                ty: RESULT,
                variant: TAG_OK,
                field_count: 1,
            },
            Instr::EnumGet(0),
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(42)));
    }

    #[test]
    fn enum_value_is_constructed() {
        let code = [
            Instr::ConstInt(7),
            Instr::EnumNew {
                ty: OPTION,
                variant: TAG_SOME,
                field_count: 1,
            },
            Instr::Return,
        ];
        assert_eq!(
            run(&code),
            Ok(Value::new_enum(OPTION, TAG_SOME, vec![Value::Int(7)]))
        );
    }

    #[test]
    fn structural_equality() {
        assert_eq!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
        );
        // different variant
        assert_ne!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(RESULT, TAG_ERR, vec![Value::Int(1)]),
        );
        // different payload
        assert_ne!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(2)]),
        );
        // different type id (same variant/payload)
        assert_ne!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(OPTION, TAG_SOME, vec![Value::Int(1)]),
        );
    }

    #[test]
    fn question_mark_propagation() {
        // f(r) = { let x = r?; return Ok(x + 10); }  (built via FnBuilder)
        let mut b = FnBuilder::new("f", 1);
        let ok = b.label();
        b.load(0);
        b.dup();
        b.enum_tag();
        b.const_int(TAG_ERR as i64);
        b.eq_i64();
        b.jump_if_false(ok);
        b.ret(); // Err: propagate the Result unchanged
        b.bind(ok);
        b.enum_get(0); // unwrap Ok payload
        b.store(1); // x  (bumps local_count to 2)
        b.load(1);
        b.const_int(10);
        b.add_i64();
        b.enum_new(RESULT, TAG_OK, 1);
        b.ret();
        let module = Module::new(vec![b.finish()]);

        // Ok(5) → Ok(15)
        assert_eq!(
            super::run(
                &module,
                0,
                &[Value::new_enum(RESULT, TAG_OK, vec![Value::Int(5)])]
            ),
            Ok(Value::new_enum(RESULT, TAG_OK, vec![Value::Int(15)]))
        );
        // Err(99) → Err(99), propagated unchanged
        assert_eq!(
            super::run(
                &module,
                0,
                &[Value::new_enum(RESULT, TAG_ERR, vec![Value::Int(99)])]
            ),
            Ok(Value::new_enum(RESULT, TAG_ERR, vec![Value::Int(99)]))
        );
    }

    #[test]
    fn match_on_option() {
        // match opt { Some(n) => n, None => -1 }
        let f = Function::new(
            "f",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::EnumTag,
                Instr::ConstInt(TAG_SOME as i64),
                Instr::EqI64,
                Instr::JumpIfFalse(8), // None arm
                Instr::Load(0),
                Instr::EnumGet(0), // n
                Instr::Return,
                Instr::ConstInt(-1), // index 8: None arm
                Instr::Return,
            ],
        );
        let module = Module::new(vec![f]);
        assert_eq!(
            super::run(
                &module,
                0,
                &[Value::new_enum(OPTION, TAG_SOME, vec![Value::Int(7)])]
            ),
            Ok(Value::Int(7))
        );
        assert_eq!(
            super::run(&module, 0, &[Value::new_enum(OPTION, TAG_NONE, vec![])]),
            Ok(Value::Int(-1))
        );
    }

    #[test]
    fn enum_tag_on_non_enum_is_a_bug() {
        let code = [Instr::ConstInt(1), Instr::EnumTag, Instr::Return];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    // --- increment 5: intrinsics & observable output ---

    /// Run a bare snippet, returning its result and any captured output.
    fn run_capturing(code: &[Instr]) -> (Result<Value, Trap>, String) {
        let module = Module::new(vec![Function::new("<eval>", 0, 0, code.to_vec())]);
        let mut buf: Vec<u8> = Vec::new();
        let result = Vm::new(&mut buf).call(&module, 0, vec![]);
        (result, String::from_utf8(buf).unwrap())
    }

    #[test]
    fn stringify_primitive() {
        let code = [
            Instr::ConstInt(42),
            Instr::CallNative {
                native: NATIVE_STRINGIFY,
                argc: 1,
            },
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::new_str("42")));
    }

    #[test]
    fn str_concat_joins_strings() {
        let code = [
            Instr::ConstStr("foo".into()),
            Instr::ConstStr("bar".into()),
            Instr::CallNative {
                native: NATIVE_STR_CONCAT,
                argc: 2,
            },
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::new_str("foobar")));
    }

    #[test]
    fn println_writes_to_output() {
        let code = [
            Instr::ConstStr("hello".into()),
            Instr::CallNative {
                native: NATIVE_PRINTLN,
                argc: 1,
            },
            Instr::Return,
        ];
        let (result, output) = run_capturing(&code);
        assert_eq!(result, Ok(Value::Unit));
        assert_eq!(output, "hello\n");
    }

    #[test]
    fn interpolation_pipeline() {
        // 'x = ${x}' with x = 7  →  "x = 7\n"
        let code = [
            Instr::ConstStr("x = ".into()),
            Instr::ConstInt(7),
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
        ];
        let (result, output) = run_capturing(&code);
        assert_eq!(result, Ok(Value::Unit));
        assert_eq!(output, "x = 7\n");
    }

    #[test]
    fn unknown_native_is_a_bug() {
        let code = [Instr::CallNative {
            native: 999,
            argc: 0,
        }];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    #[test]
    fn str_concat_on_non_string_is_a_bug() {
        let code = [
            Instr::ConstInt(1),
            Instr::ConstInt(2),
            Instr::CallNative {
                native: NATIVE_STR_CONCAT,
                argc: 2,
            },
            Instr::Return,
        ];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    // --- increment 6: collections ---

    /// Build and run a parameterless function via the builder.
    fn run_fn(build: impl FnOnce(&mut FnBuilder)) -> Result<Value, Trap> {
        let mut b = FnBuilder::new("test", 0);
        build(&mut b);
        let module = Module::new(vec![b.finish()]);
        super::run(&module, 0, &[])
    }

    /// Emit `[a, b, c, ...]` as a list literal.
    fn push_int_list(b: &mut FnBuilder, items: &[i64]) {
        for &n in items {
            b.const_int(n);
        }
        b.list_new(items.len() as u32);
    }

    #[test]
    fn list_literal_and_len() {
        let r = run_fn(|b| {
            push_int_list(b, &[10, 20, 30]);
            b.call_native(NATIVE_LIST_LEN, 1);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(3)));
    }

    #[test]
    fn list_index_reads_element() {
        let r = run_fn(|b| {
            push_int_list(b, &[10, 20, 30]);
            b.const_int(1);
            b.list_get();
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(20)));
    }

    #[test]
    fn list_index_out_of_bounds_traps() {
        let r = run_fn(|b| {
            push_int_list(b, &[10]);
            b.const_int(5);
            b.list_get();
            b.ret();
        });
        assert_eq!(r, Err(Trap::IndexOutOfBounds { index: 5, len: 1 }));
    }

    #[test]
    fn list_push_appends_in_place() {
        // l = [1, 2]; l.push(3); return l.len()  → 3
        let push = native_index("list_push").unwrap();
        let r = run_fn(|b| {
            push_int_list(b, &[1, 2]);
            b.store(0);
            b.load(0);
            b.const_int(3);
            b.call_native(push, 2);
            b.pop(); // discard the Unit return
            b.load(0);
            b.call_native(NATIVE_LIST_LEN, 1);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(3)));
    }

    #[test]
    fn list_get_returns_option() {
        // get(1) → Some(20)
        let some = run_fn(|b| {
            push_int_list(b, &[10, 20]);
            b.const_int(1);
            b.call_native(NATIVE_LIST_GET, 2);
            b.ret();
        });
        assert_eq!(some, Ok(Value::some(Value::Int(20))));
        // get(9) → None
        let none = run_fn(|b| {
            push_int_list(b, &[10, 20]);
            b.const_int(9);
            b.call_native(NATIVE_LIST_GET, 2);
            b.ret();
        });
        assert_eq!(none, Ok(Value::none()));
    }

    #[test]
    fn list_set_mutates_in_place() {
        // l = [10, 20]; l[0] = 99; return l[0]
        let r = run_fn(|b| {
            push_int_list(b, &[10, 20]);
            b.store(0);
            b.load(0);
            b.const_int(0);
            b.const_int(99);
            b.list_set();
            b.load(0);
            b.const_int(0);
            b.list_get();
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(99)));
    }

    #[test]
    fn reference_semantics_aliasing() {
        // l = [1]; a = l; l[0] = 42; return a[0]  → 42 (shared heap object)
        let r = run_fn(|b| {
            push_int_list(b, &[1]);
            b.store(0); // l
            b.load(0);
            b.store(1); // a = l  (copies the reference)
            b.load(0);
            b.const_int(0);
            b.const_int(42);
            b.list_set();
            b.load(1); // read via a
            b.const_int(0);
            b.list_get();
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(42)));
    }

    /// Emit the literal `{'a': 1, 'b': 2}`.
    fn push_ab_map(b: &mut FnBuilder) {
        b.const_str("a");
        b.const_int(1);
        b.const_str("b");
        b.const_int(2);
        b.call_native(NATIVE_MAP_NEW, 4);
    }

    #[test]
    fn map_literal_index_and_len() {
        let len = run_fn(|b| {
            push_ab_map(b);
            b.call_native(NATIVE_MAP_LEN, 1);
            b.ret();
        });
        assert_eq!(len, Ok(Value::Int(2)));

        let idx = run_fn(|b| {
            push_ab_map(b);
            b.const_str("b");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.ret();
        });
        assert_eq!(idx, Ok(Value::Int(2)));
    }

    #[test]
    fn map_index_missing_key_traps() {
        let r = run_fn(|b| {
            push_ab_map(b);
            b.const_str("zzz");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.ret();
        });
        assert_eq!(r, Err(Trap::MissingKey));
    }

    #[test]
    fn map_get_and_has() {
        let got = run_fn(|b| {
            push_ab_map(b);
            b.const_str("a");
            b.call_native(NATIVE_MAP_GET, 2);
            b.ret();
        });
        assert_eq!(got, Ok(Value::some(Value::Int(1))));

        let missing = run_fn(|b| {
            push_ab_map(b);
            b.const_str("x");
            b.call_native(NATIVE_MAP_GET, 2);
            b.ret();
        });
        assert_eq!(missing, Ok(Value::none()));

        let has = run_fn(|b| {
            push_ab_map(b);
            b.const_str("a");
            b.call_native(NATIVE_MAP_HAS, 2);
            b.ret();
        });
        assert_eq!(has, Ok(Value::Bool(true)));
    }

    #[test]
    fn map_set_updates_and_inserts() {
        // m = {'a':1}; m['a'] = 9 (update); m['c'] = 3 (insert);
        // return m['a'] + m['c'] + m.len()   → 9 + 3 + 2 = 14
        let r = run_fn(|b| {
            b.const_str("a");
            b.const_int(1);
            b.call_native(NATIVE_MAP_NEW, 2);
            b.store(0); // m
            // m['a'] = 9
            b.load(0);
            b.const_str("a");
            b.const_int(9);
            b.call_native(NATIVE_MAP_SET, 3);
            b.pop();
            // m['c'] = 3
            b.load(0);
            b.const_str("c");
            b.const_int(3);
            b.call_native(NATIVE_MAP_SET, 3);
            b.pop();
            // m['a'] + m['c']
            b.load(0);
            b.const_str("a");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.load(0);
            b.const_str("c");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.add_i64();
            // + m.len()
            b.load(0);
            b.call_native(NATIVE_MAP_LEN, 1);
            b.add_i64();
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(14)));
    }

    #[test]
    fn list_index_on_non_list_is_a_bug() {
        let r = run_fn(|b| {
            b.const_int(1); // not a list
            b.const_int(0);
            b.list_get();
            b.ret();
        });
        assert!(matches!(r, Err(Trap::Bug(_))));
    }

    // --- structs & the type table ---

    /// Run a parameterless function against a module with the given types.
    fn run_with_types(
        types: Vec<TypeDef>,
        build: impl FnOnce(&mut FnBuilder),
    ) -> Result<Value, Trap> {
        let mut b = FnBuilder::new("test", 0);
        build(&mut b);
        let module = Module::with_types(vec![b.finish()], types);
        super::run(&module, 0, &[])
    }

    #[test]
    fn struct_construction_and_field_access() {
        // type Point = { x, y };  Point { 1, 2 }.y  → 2
        let r = run_with_types(vec![TypeDef::new("Point", 2)], |b| {
            b.const_int(1);
            b.const_int(2);
            b.struct_new(0);
            b.field_get(1); // y
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(2)));
    }

    #[test]
    fn struct_field_set_and_reference_semantics() {
        // p = Point{1, 2}; q = p; p.x = 9; return q.x  → 9 (shared heap object)
        let r = run_with_types(vec![TypeDef::new("Point", 2)], |b| {
            b.const_int(1);
            b.const_int(2);
            b.struct_new(0);
            b.store(0); // p
            b.load(0);
            b.store(1); // q = p
            b.load(0);
            b.const_int(9);
            b.field_set(0); // p.x = 9  (stack: struct value →)
            b.load(1);
            b.field_get(0); // q.x
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(9)));
    }

    #[test]
    fn struct_equality_is_structural() {
        assert_eq!(
            Value::new_struct(0, vec![Value::Int(1)]),
            Value::new_struct(0, vec![Value::Int(1)])
        );
        assert_ne!(
            Value::new_struct(0, vec![Value::Int(1)]),
            Value::new_struct(0, vec![Value::Int(2)])
        );
        // different type id, same fields
        assert_ne!(
            Value::new_struct(0, vec![Value::Int(1)]),
            Value::new_struct(1, vec![Value::Int(1)])
        );
    }

    #[test]
    fn struct_new_unknown_type_is_a_bug() {
        // No types registered, so type index 0 is invalid.
        let r = run_with_types(vec![], |b| {
            b.struct_new(0);
            b.ret();
        });
        assert!(matches!(r, Err(Trap::Bug(_))));
    }

    #[test]
    fn field_get_on_non_struct_is_a_bug() {
        let code = [Instr::ConstInt(1), Instr::FieldGet(0), Instr::Return];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    // --- sets ---

    /// Emit `Set.from([1, 2, 2, 3])` (with a duplicate).
    fn push_demo_set(b: &mut FnBuilder) {
        b.const_int(1);
        b.const_int(2);
        b.const_int(2);
        b.const_int(3);
        b.call_native(NATIVE_SET_NEW, 4);
    }

    #[test]
    fn set_dedups_and_reports_len() {
        let r = run_fn(|b| {
            push_demo_set(b);
            b.call_native(NATIVE_SET_LEN, 1);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(3))); // {1, 2, 3}
    }

    #[test]
    fn set_membership() {
        let present = run_fn(|b| {
            push_demo_set(b);
            b.const_int(2);
            b.call_native(NATIVE_SET_HAS, 2);
            b.ret();
        });
        assert_eq!(present, Ok(Value::Bool(true)));

        let absent = run_fn(|b| {
            push_demo_set(b);
            b.const_int(9);
            b.call_native(NATIVE_SET_HAS, 2);
            b.ret();
        });
        assert_eq!(absent, Ok(Value::Bool(false)));
    }

    #[test]
    fn set_add_and_remove_in_place() {
        // s = {1,2,3}; s.add(2) (no-op); s.add(4); s.remove(1); return s.len()  → 3
        let r = run_fn(|b| {
            push_demo_set(b);
            b.store(0);
            b.load(0);
            b.const_int(2);
            b.call_native(NATIVE_SET_ADD, 2);
            b.pop();
            b.load(0);
            b.const_int(4);
            b.call_native(NATIVE_SET_ADD, 2);
            b.pop();
            b.load(0);
            b.const_int(1);
            b.call_native(NATIVE_SET_REMOVE, 2);
            b.pop();
            b.load(0);
            b.call_native(NATIVE_SET_LEN, 1);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(3))); // {2, 3, 4}
    }

    #[test]
    fn set_remove_reports_presence() {
        let r = run_fn(|b| {
            push_demo_set(b);
            b.const_int(9); // not present
            b.call_native(NATIVE_SET_REMOVE, 2);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Bool(false)));
    }

    #[test]
    fn set_op_on_non_set_is_a_bug() {
        let r = run_fn(|b| {
            b.const_int(1); // not a set
            b.call_native(NATIVE_SET_LEN, 1);
            b.ret();
        });
        assert!(matches!(r, Err(Trap::Bug(_))));
    }

    // --- closures ---

    /// `adder(captured, x) = captured + x`: a lifted lambda whose first slot is
    /// a captured value and whose second is the call argument.
    fn adder() -> Function {
        Function::new(
            "adder",
            2,
            2,
            vec![Instr::Load(0), Instr::Load(1), Instr::AddI64, Instr::Return],
        )
    }

    #[test]
    fn closure_captures_and_calls_indirect() {
        // main() = { let g = closure(adder, [10]); g(5) }  → 15
        let main = Function::new(
            "main",
            0,
            0,
            vec![
                Instr::ConstInt(10),
                Instr::ClosureNew {
                    func: 1,
                    captures: 1,
                },
                Instr::ConstInt(5),
                Instr::CallIndirect { argc: 1 },
                Instr::Return,
            ],
        );
        let module = Module::new(vec![main, adder()]);
        assert_eq!(super::run(&module, 0, &[]), Ok(Value::Int(15)));
    }

    #[test]
    fn closure_with_no_captures() {
        // inc(x) = x + 1, captured as a zero-capture closure and called with 41.
        let inc = Function::new(
            "inc",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::ConstInt(1),
                Instr::AddI64,
                Instr::Return,
            ],
        );
        let main = Function::new(
            "main",
            0,
            0,
            vec![
                Instr::ClosureNew {
                    func: 1,
                    captures: 0,
                },
                Instr::ConstInt(41),
                Instr::CallIndirect { argc: 1 },
                Instr::Return,
            ],
        );
        let module = Module::new(vec![main, inc]);
        assert_eq!(super::run(&module, 0, &[]), Ok(Value::Int(42)));
    }

    #[test]
    fn closure_new_builds_the_expected_value() {
        let r = run_fn(|b| {
            b.const_int(7);
            b.const_int(8);
            b.closure_new(3, 2);
            b.ret();
        });
        assert_eq!(
            r,
            Ok(Value::new_closure(3, vec![Value::Int(7), Value::Int(8)]))
        );
    }

    #[test]
    fn call_indirect_arity_mismatch_is_a_bug() {
        // The closure captures one value and is called with one argument, but
        // `adder` only declares two locals — wait, that is correct; instead call
        // a zero-capture closure of `adder` with one arg (frame of 1 ≠ 2 params).
        let main = Function::new(
            "main",
            0,
            0,
            vec![
                Instr::ClosureNew {
                    func: 1,
                    captures: 0,
                },
                Instr::ConstInt(5),
                Instr::CallIndirect { argc: 1 },
                Instr::Return,
            ],
        );
        let module = Module::new(vec![main, adder()]);
        assert!(matches!(super::run(&module, 0, &[]), Err(Trap::Bug(_))));
    }

    #[test]
    fn call_indirect_on_non_closure_is_a_bug() {
        let r = run_fn(|b| {
            b.const_int(1); // not a closure
            b.call_indirect(0);
            b.ret();
        });
        assert!(matches!(r, Err(Trap::Bug(_))));
    }

    // --- dynamic dispatch (call.virtual) ---

    /// A module with two struct types, a `display` impl for each, and a
    /// `describe(x)` that dispatches `x.display()` virtually.
    fn dispatch_module() -> Module {
        use crate::module::DispatchEntry;
        // Dog (ty 0) and Cat (ty 1); their displays return distinct strings.
        let dog_display = Function::new(
            "Dog.display",
            1,
            1,
            vec![Instr::ConstStr("woof".into()), Instr::Return],
        );
        let cat_display = Function::new(
            "Cat.display",
            1,
            1,
            vec![Instr::ConstStr("meow".into()), Instr::Return],
        );
        // describe(x) = x.display()   (the concrete type isn't known here)
        let describe = Function::new(
            "describe",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::CallVirtual {
                    selector: "display".into(),
                    argc: 1,
                },
                Instr::Return,
            ],
        );
        let mut m = Module::with_types(
            vec![dog_display, cat_display, describe],
            vec![TypeDef::new("Dog", 0), TypeDef::new("Cat", 0)],
        );
        m.dispatch = vec![
            DispatchEntry::new(0, "display", 0),
            DispatchEntry::new(1, "display", 1),
        ];
        m
    }

    #[test]
    fn call_virtual_dispatches_on_receiver_type() {
        let m = dispatch_module();
        // describe is function index 2.
        let dog = Value::new_struct(0, vec![]);
        let cat = Value::new_struct(1, vec![]);
        assert_eq!(super::run(&m, 2, &[dog]), Ok(Value::new_str("woof")));
        assert_eq!(super::run(&m, 2, &[cat]), Ok(Value::new_str("meow")));
    }

    #[test]
    fn call_virtual_display_without_an_impl_is_a_bug_for_structs() {
        // The display fallback covers primitives/String only; a struct that
        // reaches it without an impl row is malformed bytecode (the front-end
        // requires an explicit `impl Display`).
        let mut m = dispatch_module();
        m.dispatch.clear(); // no rows → nothing to dispatch to
        let dog = Value::new_struct(0, vec![]);
        assert!(matches!(super::run(&m, 2, &[dog]), Err(Trap::Bug(_))));
    }

    #[test]
    fn call_virtual_display_on_a_primitive_uses_the_builtin_fallback() {
        // Primitives carry built-in Display: no impl row, rendered natively.
        let m = dispatch_module();
        assert_eq!(super::run(&m, 2, &[Value::Int(5)]), Ok(Value::new_str("5")));
    }

    #[test]
    fn struct_and_enum_dispatch_ids_do_not_collide() {
        // A struct with type-table index 0 and an enum with ty 0 (Result's
        // reserved id) both impl 'display'; each receiver must reach its own.
        use crate::module::{DispatchEntry, ENUM_DISPATCH_BASE};
        let struct_display = Function::new(
            "S.display",
            1,
            1,
            vec![Instr::ConstStr("struct".into()), Instr::Return],
        );
        let enum_display = Function::new(
            "E.display",
            1,
            1,
            vec![Instr::ConstStr("enum".into()), Instr::Return],
        );
        let describe = Function::new(
            "describe",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::CallVirtual {
                    selector: "display".into(),
                    argc: 1,
                },
                Instr::Return,
            ],
        );
        let mut m = Module::with_types(
            vec![struct_display, enum_display, describe],
            vec![TypeDef::new("S", 0)],
        );
        m.dispatch = vec![
            DispatchEntry::new(0, "display", 0),
            DispatchEntry::new(ENUM_DISPATCH_BASE, "display", 1),
        ];
        let s = Value::new_struct(0, vec![]);
        let e = Value::new_enum(0, 0, vec![]);
        assert_eq!(super::run(&m, 2, &[s]), Ok(Value::new_str("struct")));
        assert_eq!(super::run(&m, 2, &[e]), Ok(Value::new_str("enum")));
    }

    // --- the structural debug / eq fallbacks ---

    /// `dbg(x) = x.debug()` over a module with one struct type `Dog` (2 fields)
    /// — no explicit `impl Debug`, so the structural fallback renders.
    fn debug_module() -> Module {
        let dbg = Function::new(
            "dbg",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::CallVirtual {
                    selector: "debug".into(),
                    argc: 1,
                },
                Instr::Return,
            ],
        );
        Module::with_types(vec![dbg], vec![TypeDef::new("Dog", 2)])
    }

    #[test]
    fn structural_debug_renders_primitives_and_strings() {
        let m = debug_module();
        assert_eq!(super::run(&m, 0, &[Value::Int(5)]), Ok(Value::new_str("5")));
        assert_eq!(
            super::run(&m, 0, &[Value::Bool(true)]),
            Ok(Value::new_str("true"))
        );
        // Strings are quoted (debug, not display).
        assert_eq!(
            super::run(&m, 0, &[Value::new_str("hi")]),
            Ok(Value::new_str("'hi'"))
        );
    }

    #[test]
    fn structural_debug_recurses_into_collections_and_structs() {
        let m = debug_module();
        let list = Value::new_list(vec![Value::Int(1), Value::new_str("a")]);
        assert_eq!(super::run(&m, 0, &[list]), Ok(Value::new_str("[1, 'a']")));
        // A struct renders by name with positional fields.
        let dog = Value::new_struct(0, vec![Value::new_str("Rex"), Value::Int(3)]);
        assert_eq!(
            super::run(&m, 0, &[dog]),
            Ok(Value::new_str("Dog { 'Rex', 3 }"))
        );
        // The reserved Result/Option enums render their variant names.
        assert_eq!(
            super::run(&m, 0, &[Value::some(Value::Int(7))]),
            Ok(Value::new_str("Some(7)"))
        );
        assert_eq!(
            super::run(&m, 0, &[Value::none()]),
            Ok(Value::new_str("None"))
        );
    }

    #[test]
    fn an_explicit_debug_impl_overrides_the_structural_rendering() {
        use crate::module::DispatchEntry;
        let mut m = debug_module();
        m.functions.push(Function::new(
            "Dog.debug",
            1,
            1,
            vec![Instr::ConstStr("custom".into()), Instr::Return],
        ));
        m.dispatch = vec![DispatchEntry::new(0, "debug", 1)];
        let dog = Value::new_struct(0, vec![Value::new_str("Rex"), Value::Int(3)]);
        // Direct receiver and nested (inside a list) both use the impl.
        assert_eq!(
            super::run(&m, 0, &[dog.clone()]),
            Ok(Value::new_str("custom"))
        );
        assert_eq!(
            super::run(&m, 0, &[Value::new_list(vec![dog])]),
            Ok(Value::new_str("[custom]"))
        );
    }

    #[test]
    fn call_virtual_eq_falls_back_to_structural_equality() {
        let eq = Function::new(
            "eq2",
            2,
            2,
            vec![
                Instr::Load(0),
                Instr::Load(1),
                Instr::CallVirtual {
                    selector: "eq".into(),
                    argc: 2,
                },
                Instr::Return,
            ],
        );
        let m = Module::with_types(vec![eq], vec![TypeDef::new("P", 1)]);
        let a = Value::new_struct(0, vec![Value::Int(1)]);
        let b = Value::new_struct(0, vec![Value::Int(1)]);
        let c = Value::new_struct(0, vec![Value::Int(2)]);
        assert_eq!(super::run(&m, 0, &[a.clone(), b]), Ok(Value::Bool(true)));
        assert_eq!(super::run(&m, 0, &[a, c]), Ok(Value::Bool(false)));
    }
}
