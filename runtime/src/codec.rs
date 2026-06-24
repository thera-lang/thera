//! Encoding and decoding of a [`Module`] to/from the bytecode wire format.
//!
//! See docs/bytecode.md, "Serialized format": a `"HAWK"` magic + version header,
//! then length-prefixed sections (so unknown sections are skippable). v0 emits a
//! single Functions section and inlines constants in the instruction stream; a
//! type table, entry section, and a dedup'd constant pool arrive as the in-memory
//! `Module` grows those and as a later compaction step.
//!
//! Input is trusted (our own front-end produces it), so decoding does only
//! lightweight integrity checks — magic, version, opcode — rather than a full
//! verifier.

use std::collections::HashMap;
use std::path::Path;

use crate::instr::Instr;
use crate::interp::{native_index, native_name};
use crate::module::{DispatchEntry, Function, Module, TypeDef};
use crate::serialize::{DecodeError, Reader, Writer};

/// An error loading a module from disk: either the file could not be read or
/// its contents did not decode.
#[derive(Debug)]
pub enum LoadError {
    Io(std::io::Error),
    Decode(DecodeError),
}

impl From<std::io::Error> for LoadError {
    fn from(e: std::io::Error) -> Self {
        LoadError::Io(e)
    }
}

impl From<DecodeError> for LoadError {
    fn from(e: DecodeError) -> Self {
        LoadError::Decode(e)
    }
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::Io(e) => write!(f, "I/O error: {e}"),
            LoadError::Decode(e) => write!(f, "decode error: {e:?}"),
        }
    }
}

impl std::error::Error for LoadError {}

/// Write a module to a `.hawkbc` file.
pub fn write_module_to_file(path: impl AsRef<Path>, m: &Module) -> std::io::Result<()> {
    std::fs::write(path, encode_module(m))
}

/// Read and decode a module from a `.hawkbc` file.
pub fn read_module_from_file(path: impl AsRef<Path>) -> Result<Module, LoadError> {
    let bytes = std::fs::read(path)?;
    Ok(decode_module(&bytes)?)
}

const MAGIC: &[u8] = b"HAWK";
const VERSION: u32 = 1;

/// Section ids. Unknown ids are skipped on decode via their byte length.
mod section {
    pub const FUNCTIONS: u8 = 1;
    pub const CONSTANTS: u8 = 2;
    pub const TYPES: u8 = 3;
    pub const DISPATCH: u8 = 4;
}

/// Collects and deduplicates string literals during encoding. Strings are
/// stored once in the Constants section; `const.str` instructions reference
/// them by index. (Strings only for now — f64 and large ints can join later.)
#[derive(Default)]
struct StringPool {
    strings: Vec<String>,
    index: HashMap<String, u32>,
}

impl StringPool {
    /// Intern `s`, returning its pool index (reusing an existing entry).
    fn intern(&mut self, s: &str) -> u32 {
        if let Some(&i) = self.index.get(s) {
            return i;
        }
        let i = self.strings.len() as u32;
        self.strings.push(s.to_string());
        self.index.insert(s.to_string(), i);
        i
    }
}

/// One-byte opcode tags. Shared by [`encode_instr`] and [`decode_instr`] so the
/// two can never drift.
mod op {
    pub const CONST_INT: u8 = 1;
    pub const CONST_DOUBLE: u8 = 2;
    pub const CONST_BOOL: u8 = 3;
    pub const CONST_UNIT: u8 = 4;
    pub const CONST_STR: u8 = 5;
    pub const LOAD: u8 = 6;
    pub const STORE: u8 = 7;
    pub const ADD_I64: u8 = 8;
    pub const SUB_I64: u8 = 9;
    pub const MUL_I64: u8 = 10;
    pub const DIV_I64: u8 = 11;
    pub const MOD_I64: u8 = 12;
    pub const NEG_I64: u8 = 13;
    pub const ADD_F64: u8 = 14;
    pub const SUB_F64: u8 = 15;
    pub const MUL_F64: u8 = 16;
    pub const DIV_F64: u8 = 17;
    pub const NEG_F64: u8 = 18;
    pub const EQ_I64: u8 = 19;
    pub const NE_I64: u8 = 20;
    pub const LT_I64: u8 = 21;
    pub const LE_I64: u8 = 22;
    pub const GT_I64: u8 = 23;
    pub const GE_I64: u8 = 24;
    pub const EQ_F64: u8 = 25;
    pub const NE_F64: u8 = 26;
    pub const LT_F64: u8 = 27;
    pub const LE_F64: u8 = 28;
    pub const GT_F64: u8 = 29;
    pub const GE_F64: u8 = 30;
    pub const NOT: u8 = 31;
    pub const I64_TO_F64: u8 = 32;
    pub const F64_TO_I64: u8 = 33;
    pub const POP: u8 = 34;
    pub const DUP: u8 = 35;
    pub const CALL: u8 = 36;
    pub const CALL_NATIVE: u8 = 37;
    pub const ENUM_NEW: u8 = 38;
    pub const ENUM_TAG: u8 = 39;
    pub const ENUM_GET: u8 = 40;
    pub const LIST_NEW: u8 = 41;
    pub const JUMP: u8 = 42;
    pub const JUMP_IF_TRUE: u8 = 43;
    pub const JUMP_IF_FALSE: u8 = 44;
    pub const RETURN: u8 = 45;
    pub const STRUCT_NEW: u8 = 46;
    pub const FIELD_GET: u8 = 47;
    pub const FIELD_SET: u8 = 48;
    pub const CLOSURE_NEW: u8 = 49;
    pub const CALL_INDIRECT: u8 = 50;
    pub const CALL_VIRTUAL: u8 = 51;
    pub const LIST_GET: u8 = 52;
    pub const LIST_SET: u8 = 53;
    pub const AND_I64: u8 = 54;
    pub const OR_I64: u8 = 55;
    pub const XOR_I64: u8 = 56;
    pub const BNOT_I64: u8 = 57;
    pub const SHL_I64: u8 = 58;
    pub const SHR_I64: u8 = 59;
    pub const USHR_I64: u8 = 60;
    pub const LIST_LEN: u8 = 61;
}

/// Encode a module to the wire format.
pub fn encode_module(m: &Module) -> Vec<u8> {
    // First pass: intern every string the module references — literals, the
    // names of called natives (natives are bound by name on the wire), and the
    // names of types.
    let mut pool = StringPool::default();
    for t in &m.types {
        pool.intern(&t.name);
    }
    for f in &m.functions {
        for instr in &f.code {
            match instr {
                Instr::ConstStr(s) => {
                    pool.intern(s);
                }
                Instr::CallVirtual { selector, .. } => {
                    pool.intern(selector);
                }
                Instr::CallNative { native, .. } => {
                    if let Some(name) = native_name(*native) {
                        pool.intern(name);
                    }
                }
                _ => {}
            }
        }
    }
    for e in &m.dispatch {
        pool.intern(&e.selector);
    }

    // Constants section: the deduplicated strings.
    let mut consts = Writer::new();
    consts.write_uvarint(pool.strings.len() as u64);
    for s in &pool.strings {
        consts.write_str(s);
    }

    // Types section: name (pool index) + field count per type.
    let mut types = Writer::new();
    types.write_uvarint(m.types.len() as u64);
    for t in &m.types {
        types.write_uvarint(u64::from(pool.index[t.name.as_str()]));
        types.write_uvarint(u64::from(t.field_count));
    }

    // Functions section: bodies reference the pool by index.
    let mut funcs = Writer::new();
    funcs.write_uvarint(m.functions.len() as u64);
    for f in &m.functions {
        encode_function(&mut funcs, f, &pool);
    }

    // Dispatch section: (type id, selector pool index, function index) per row.
    let mut dispatch = Writer::new();
    dispatch.write_uvarint(m.dispatch.len() as u64);
    for e in &m.dispatch {
        dispatch.write_uvarint(u64::from(e.ty));
        dispatch.write_uvarint(u64::from(pool.index[e.selector.as_str()]));
        dispatch.write_uvarint(u64::from(e.func));
    }

    let mut w = Writer::new();
    w.write_raw(MAGIC);
    w.write_u32_le(VERSION);
    write_section(&mut w, section::CONSTANTS, &consts.into_bytes());
    write_section(&mut w, section::TYPES, &types.into_bytes());
    write_section(&mut w, section::FUNCTIONS, &funcs.into_bytes());
    if !m.dispatch.is_empty() {
        write_section(&mut w, section::DISPATCH, &dispatch.into_bytes());
    }
    w.into_bytes()
}

/// Decode a module from the wire format.
pub fn decode_module(bytes: &[u8]) -> Result<Module, DecodeError> {
    let mut r = Reader::new(bytes);
    if r.read_raw(MAGIC.len())? != MAGIC {
        return Err(DecodeError::BadMagic);
    }
    let version = r.read_u32_le()?;
    if version != VERSION {
        return Err(DecodeError::UnsupportedVersion(version));
    }

    // Collect section payloads first (order-independent; unknown ids ignored).
    let mut consts_payload: Option<&[u8]> = None;
    let mut types_payload: Option<&[u8]> = None;
    let mut funcs_payload: Option<&[u8]> = None;
    let mut dispatch_payload: Option<&[u8]> = None;
    while !r.is_empty() {
        let id = r.read_u8()?;
        let len = r.read_uvarint()? as usize;
        let payload = r.read_raw(len)?;
        match id {
            section::CONSTANTS => consts_payload = Some(payload),
            section::TYPES => types_payload = Some(payload),
            section::FUNCTIONS => funcs_payload = Some(payload),
            section::DISPATCH => dispatch_payload = Some(payload),
            _ => {} // unknown section: skip (payload already consumed)
        }
    }

    // The constant pool must be available before decoding types and bodies.
    let pool = match consts_payload {
        Some(p) => decode_pool(p)?,
        None => Vec::new(),
    };

    let types = match types_payload {
        Some(p) => decode_types(p, &pool)?,
        None => Vec::new(),
    };

    let mut functions = Vec::new();
    if let Some(p) = funcs_payload {
        let mut pr = Reader::new(p);
        let count = pr.read_uvarint()?;
        for _ in 0..count {
            functions.push(decode_function(&mut pr, &pool)?);
        }
    }

    let mut module = Module::with_types(functions, types);
    if let Some(p) = dispatch_payload {
        module.dispatch = decode_dispatch(p, &pool)?;
    }
    Ok(module)
}

fn decode_dispatch(payload: &[u8], pool: &[String]) -> Result<Vec<DispatchEntry>, DecodeError> {
    let mut r = Reader::new(payload);
    let count = r.read_uvarint()? as usize;
    let mut dispatch = Vec::with_capacity(count);
    for _ in 0..count {
        let ty = r.read_uvarint()? as u32;
        let sel_idx = r.read_uvarint()? as usize;
        let selector = pool
            .get(sel_idx)
            .ok_or(DecodeError::ConstIndexOutOfRange)?
            .clone();
        let func = r.read_uvarint()? as u32;
        dispatch.push(DispatchEntry::new(ty, selector, func));
    }
    Ok(dispatch)
}

fn decode_types(payload: &[u8], pool: &[String]) -> Result<Vec<TypeDef>, DecodeError> {
    let mut r = Reader::new(payload);
    let count = r.read_uvarint()? as usize;
    let mut types = Vec::with_capacity(count);
    for _ in 0..count {
        let name_idx = r.read_uvarint()? as usize;
        let name = pool
            .get(name_idx)
            .ok_or(DecodeError::ConstIndexOutOfRange)?
            .clone();
        let field_count = r.read_uvarint()? as u16;
        types.push(TypeDef::new(name, field_count));
    }
    Ok(types)
}

fn decode_pool(payload: &[u8]) -> Result<Vec<String>, DecodeError> {
    let mut r = Reader::new(payload);
    let count = r.read_uvarint()? as usize;
    let mut strings = Vec::with_capacity(count);
    for _ in 0..count {
        strings.push(r.read_str()?);
    }
    Ok(strings)
}

fn write_section(w: &mut Writer, id: u8, payload: &[u8]) {
    w.write_u8(id);
    w.write_uvarint(payload.len() as u64);
    w.write_raw(payload);
}

fn encode_function(w: &mut Writer, f: &Function, pool: &StringPool) {
    w.write_str(&f.name);
    w.write_uvarint(f.param_count as u64);
    w.write_uvarint(f.local_count as u64);
    w.write_uvarint(f.code.len() as u64);
    for instr in &f.code {
        encode_instr(w, instr, pool);
    }
}

fn decode_function(r: &mut Reader, pool: &[String]) -> Result<Function, DecodeError> {
    let name = r.read_str()?;
    let param_count = r.read_uvarint()? as u16;
    let local_count = r.read_uvarint()? as u16;
    let code_len = r.read_uvarint()? as usize;
    let mut code = Vec::with_capacity(code_len);
    for _ in 0..code_len {
        code.push(decode_instr(r, pool)?);
    }
    Ok(Function::new(name, param_count, local_count, code))
}

fn encode_instr(w: &mut Writer, instr: &Instr, pool: &StringPool) {
    match instr {
        Instr::ConstInt(n) => {
            w.write_u8(op::CONST_INT);
            w.write_ivarint(*n);
        }
        Instr::ConstDouble(x) => {
            w.write_u8(op::CONST_DOUBLE);
            w.write_f64(*x);
        }
        Instr::ConstBool(b) => {
            w.write_u8(op::CONST_BOOL);
            w.write_u8(u8::from(*b));
        }
        Instr::ConstUnit => w.write_u8(op::CONST_UNIT),
        Instr::ConstStr(s) => {
            w.write_u8(op::CONST_STR);
            w.write_uvarint(u64::from(pool.index[s]));
        }
        Instr::Load(slot) => {
            w.write_u8(op::LOAD);
            w.write_uvarint(*slot as u64);
        }
        Instr::Store(slot) => {
            w.write_u8(op::STORE);
            w.write_uvarint(*slot as u64);
        }
        Instr::AddI64 => w.write_u8(op::ADD_I64),
        Instr::SubI64 => w.write_u8(op::SUB_I64),
        Instr::MulI64 => w.write_u8(op::MUL_I64),
        Instr::DivI64 => w.write_u8(op::DIV_I64),
        Instr::ModI64 => w.write_u8(op::MOD_I64),
        Instr::NegI64 => w.write_u8(op::NEG_I64),
        Instr::AndI64 => w.write_u8(op::AND_I64),
        Instr::OrI64 => w.write_u8(op::OR_I64),
        Instr::XorI64 => w.write_u8(op::XOR_I64),
        Instr::BNotI64 => w.write_u8(op::BNOT_I64),
        Instr::ShlI64 => w.write_u8(op::SHL_I64),
        Instr::ShrI64 => w.write_u8(op::SHR_I64),
        Instr::UShrI64 => w.write_u8(op::USHR_I64),
        Instr::AddF64 => w.write_u8(op::ADD_F64),
        Instr::SubF64 => w.write_u8(op::SUB_F64),
        Instr::MulF64 => w.write_u8(op::MUL_F64),
        Instr::DivF64 => w.write_u8(op::DIV_F64),
        Instr::NegF64 => w.write_u8(op::NEG_F64),
        Instr::EqI64 => w.write_u8(op::EQ_I64),
        Instr::NeI64 => w.write_u8(op::NE_I64),
        Instr::LtI64 => w.write_u8(op::LT_I64),
        Instr::LeI64 => w.write_u8(op::LE_I64),
        Instr::GtI64 => w.write_u8(op::GT_I64),
        Instr::GeI64 => w.write_u8(op::GE_I64),
        Instr::EqF64 => w.write_u8(op::EQ_F64),
        Instr::NeF64 => w.write_u8(op::NE_F64),
        Instr::LtF64 => w.write_u8(op::LT_F64),
        Instr::LeF64 => w.write_u8(op::LE_F64),
        Instr::GtF64 => w.write_u8(op::GT_F64),
        Instr::GeF64 => w.write_u8(op::GE_F64),
        Instr::Not => w.write_u8(op::NOT),
        Instr::I64ToF64 => w.write_u8(op::I64_TO_F64),
        Instr::F64ToI64 => w.write_u8(op::F64_TO_I64),
        Instr::Pop => w.write_u8(op::POP),
        Instr::Dup => w.write_u8(op::DUP),
        Instr::Call { func, argc } => {
            w.write_u8(op::CALL);
            w.write_uvarint(*func as u64);
            w.write_uvarint(*argc as u64);
        }
        Instr::CallNative { native, argc } => {
            w.write_u8(op::CALL_NATIVE);
            let name = native_name(*native).expect("CallNative references an unknown native index");
            w.write_uvarint(u64::from(pool.index[name]));
            w.write_uvarint(u64::from(*argc));
        }
        Instr::EnumNew {
            ty,
            variant,
            field_count,
        } => {
            w.write_u8(op::ENUM_NEW);
            w.write_uvarint(*ty as u64);
            w.write_uvarint(*variant as u64);
            w.write_uvarint(*field_count as u64);
        }
        Instr::EnumTag => w.write_u8(op::ENUM_TAG),
        Instr::EnumGet(idx) => {
            w.write_u8(op::ENUM_GET);
            w.write_uvarint(*idx as u64);
        }
        Instr::StructNew { ty } => {
            w.write_u8(op::STRUCT_NEW);
            w.write_uvarint(u64::from(*ty));
        }
        Instr::FieldGet(idx) => {
            w.write_u8(op::FIELD_GET);
            w.write_uvarint(u64::from(*idx));
        }
        Instr::FieldSet(idx) => {
            w.write_u8(op::FIELD_SET);
            w.write_uvarint(u64::from(*idx));
        }
        Instr::ListNew { count } => {
            w.write_u8(op::LIST_NEW);
            w.write_uvarint(*count as u64);
        }
        Instr::ListGet => w.write_u8(op::LIST_GET),
        Instr::ListSet => w.write_u8(op::LIST_SET),
        Instr::ListLen => w.write_u8(op::LIST_LEN),
        Instr::ClosureNew { func, captures } => {
            w.write_u8(op::CLOSURE_NEW);
            w.write_uvarint(*func as u64);
            w.write_uvarint(*captures as u64);
        }
        Instr::CallIndirect { argc } => {
            w.write_u8(op::CALL_INDIRECT);
            w.write_uvarint(*argc as u64);
        }
        Instr::CallVirtual { selector, argc } => {
            w.write_u8(op::CALL_VIRTUAL);
            w.write_uvarint(u64::from(pool.index[selector.as_str()]));
            w.write_uvarint(*argc as u64);
        }
        Instr::Jump(t) => {
            w.write_u8(op::JUMP);
            w.write_uvarint(*t as u64);
        }
        Instr::JumpIfTrue(t) => {
            w.write_u8(op::JUMP_IF_TRUE);
            w.write_uvarint(*t as u64);
        }
        Instr::JumpIfFalse(t) => {
            w.write_u8(op::JUMP_IF_FALSE);
            w.write_uvarint(*t as u64);
        }
        Instr::Return => w.write_u8(op::RETURN),
    }
}

fn decode_instr(r: &mut Reader, pool: &[String]) -> Result<Instr, DecodeError> {
    let opcode = r.read_u8()?;
    Ok(match opcode {
        op::CONST_INT => Instr::ConstInt(r.read_ivarint()?),
        op::CONST_DOUBLE => Instr::ConstDouble(r.read_f64()?),
        op::CONST_BOOL => Instr::ConstBool(r.read_u8()? != 0),
        op::CONST_UNIT => Instr::ConstUnit,
        op::CONST_STR => {
            let idx = r.read_uvarint()? as usize;
            let s = pool
                .get(idx)
                .ok_or(DecodeError::ConstIndexOutOfRange)?
                .clone();
            Instr::ConstStr(s)
        }
        op::LOAD => Instr::Load(r.read_uvarint()? as u16),
        op::STORE => Instr::Store(r.read_uvarint()? as u16),
        op::ADD_I64 => Instr::AddI64,
        op::SUB_I64 => Instr::SubI64,
        op::MUL_I64 => Instr::MulI64,
        op::DIV_I64 => Instr::DivI64,
        op::MOD_I64 => Instr::ModI64,
        op::NEG_I64 => Instr::NegI64,
        op::AND_I64 => Instr::AndI64,
        op::OR_I64 => Instr::OrI64,
        op::XOR_I64 => Instr::XorI64,
        op::BNOT_I64 => Instr::BNotI64,
        op::SHL_I64 => Instr::ShlI64,
        op::SHR_I64 => Instr::ShrI64,
        op::USHR_I64 => Instr::UShrI64,
        op::ADD_F64 => Instr::AddF64,
        op::SUB_F64 => Instr::SubF64,
        op::MUL_F64 => Instr::MulF64,
        op::DIV_F64 => Instr::DivF64,
        op::NEG_F64 => Instr::NegF64,
        op::EQ_I64 => Instr::EqI64,
        op::NE_I64 => Instr::NeI64,
        op::LT_I64 => Instr::LtI64,
        op::LE_I64 => Instr::LeI64,
        op::GT_I64 => Instr::GtI64,
        op::GE_I64 => Instr::GeI64,
        op::EQ_F64 => Instr::EqF64,
        op::NE_F64 => Instr::NeF64,
        op::LT_F64 => Instr::LtF64,
        op::LE_F64 => Instr::LeF64,
        op::GT_F64 => Instr::GtF64,
        op::GE_F64 => Instr::GeF64,
        op::NOT => Instr::Not,
        op::I64_TO_F64 => Instr::I64ToF64,
        op::F64_TO_I64 => Instr::F64ToI64,
        op::POP => Instr::Pop,
        op::DUP => Instr::Dup,
        op::CALL => Instr::Call {
            func: r.read_uvarint()? as u32,
            argc: r.read_uvarint()? as u8,
        },
        op::CALL_NATIVE => {
            let name_idx = r.read_uvarint()? as usize;
            let name = pool
                .get(name_idx)
                .ok_or(DecodeError::ConstIndexOutOfRange)?;
            let native =
                native_index(name).ok_or_else(|| DecodeError::UnknownNative(name.clone()))?;
            let argc = r.read_uvarint()? as u8;
            Instr::CallNative { native, argc }
        }
        op::ENUM_NEW => Instr::EnumNew {
            ty: r.read_uvarint()? as u32,
            variant: r.read_uvarint()? as u16,
            field_count: r.read_uvarint()? as u8,
        },
        op::ENUM_TAG => Instr::EnumTag,
        op::ENUM_GET => Instr::EnumGet(r.read_uvarint()? as u16),
        op::STRUCT_NEW => Instr::StructNew {
            ty: r.read_uvarint()? as u32,
        },
        op::FIELD_GET => Instr::FieldGet(r.read_uvarint()? as u16),
        op::FIELD_SET => Instr::FieldSet(r.read_uvarint()? as u16),
        op::LIST_NEW => Instr::ListNew {
            count: r.read_uvarint()? as u32,
        },
        op::LIST_GET => Instr::ListGet,
        op::LIST_SET => Instr::ListSet,
        op::LIST_LEN => Instr::ListLen,
        op::CLOSURE_NEW => Instr::ClosureNew {
            func: r.read_uvarint()? as u32,
            captures: r.read_uvarint()? as u8,
        },
        op::CALL_INDIRECT => Instr::CallIndirect {
            argc: r.read_uvarint()? as u8,
        },
        op::CALL_VIRTUAL => {
            let idx = r.read_uvarint()? as usize;
            let selector = pool
                .get(idx)
                .ok_or(DecodeError::ConstIndexOutOfRange)?
                .clone();
            let argc = r.read_uvarint()? as u8;
            Instr::CallVirtual { selector, argc }
        }
        op::JUMP => Instr::Jump(r.read_uvarint()? as usize),
        op::JUMP_IF_TRUE => Instr::JumpIfTrue(r.read_uvarint()? as usize),
        op::JUMP_IF_FALSE => Instr::JumpIfFalse(r.read_uvarint()? as usize),
        op::RETURN => Instr::Return,
        other => return Err(DecodeError::UnknownOpcode(other)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::builder::FnBuilder;
    use crate::disasm::disassemble;
    use crate::interp::NATIVE_PRINTLN;

    fn factorial_module() -> Module {
        let mut b = FnBuilder::new("fact", 1);
        let recurse = b.label();
        b.load(0);
        b.const_int(1);
        b.le_i64();
        b.jump_if_false(recurse);
        b.const_int(1);
        b.ret();
        b.bind(recurse);
        b.load(0);
        b.load(0);
        b.const_int(1);
        b.sub_i64();
        b.call(0, 1);
        b.mul_i64();
        b.ret();
        Module::new(vec![b.finish()])
    }

    #[test]
    fn empty_module_round_trips() {
        let m = Module::default();
        assert_eq!(decode_module(&encode_module(&m)), Ok(m));
    }

    #[test]
    fn factorial_round_trips() {
        let m = factorial_module();
        assert_eq!(decode_module(&encode_module(&m)), Ok(m));
    }

    #[test]
    fn disassembly_survives_round_trip() {
        let m = factorial_module();
        let decoded = decode_module(&encode_module(&m)).unwrap();
        assert_eq!(disassemble(&decoded), disassemble(&m));
    }

    /// One of every instruction variant, to pin every opcode mapping.
    #[test]
    fn all_instructions_round_trip() {
        let code = vec![
            Instr::ConstInt(-12345),
            Instr::ConstDouble(3.5),
            Instr::ConstBool(true),
            Instr::ConstUnit,
            Instr::ConstStr("hi".into()),
            Instr::Load(3),
            Instr::Store(4),
            Instr::AddI64,
            Instr::SubI64,
            Instr::MulI64,
            Instr::DivI64,
            Instr::ModI64,
            Instr::NegI64,
            Instr::AndI64,
            Instr::OrI64,
            Instr::XorI64,
            Instr::BNotI64,
            Instr::ShlI64,
            Instr::ShrI64,
            Instr::UShrI64,
            Instr::AddF64,
            Instr::SubF64,
            Instr::MulF64,
            Instr::DivF64,
            Instr::NegF64,
            Instr::EqI64,
            Instr::NeI64,
            Instr::LtI64,
            Instr::LeI64,
            Instr::GtI64,
            Instr::GeI64,
            Instr::EqF64,
            Instr::NeF64,
            Instr::LtF64,
            Instr::LeF64,
            Instr::GtF64,
            Instr::GeF64,
            Instr::Not,
            Instr::I64ToF64,
            Instr::F64ToI64,
            Instr::Pop,
            Instr::Dup,
            Instr::Call { func: 7, argc: 2 },
            Instr::CallNative { native: 9, argc: 1 },
            Instr::EnumNew {
                ty: 1,
                variant: 0,
                field_count: 2,
            },
            Instr::EnumTag,
            Instr::EnumGet(1),
            Instr::StructNew { ty: 0 },
            Instr::FieldGet(1),
            Instr::FieldSet(2),
            Instr::ListNew { count: 3 },
            Instr::ClosureNew {
                func: 4,
                captures: 2,
            },
            Instr::CallIndirect { argc: 1 },
            Instr::CallVirtual {
                selector: "display".into(),
                argc: 1,
            },
            Instr::Jump(10),
            Instr::JumpIfTrue(11),
            Instr::JumpIfFalse(12),
            Instr::Return,
        ];
        let m = Module::new(vec![Function::new("all", 0, 5, code)]);
        assert_eq!(decode_module(&encode_module(&m)), Ok(m));
    }

    #[test]
    fn repeated_string_is_pooled_once() {
        // The same literal used three times is stored once in the pool.
        let code = vec![
            Instr::ConstStr("hello".into()),
            Instr::ConstStr("hello".into()),
            Instr::ConstStr("hello".into()),
            Instr::Return,
        ];
        let m = Module::new(vec![Function::new("f", 0, 0, code)]);
        let bytes = encode_module(&m);

        let occurrences = bytes
            .windows(b"hello".len())
            .filter(|w| *w == b"hello")
            .count();
        assert_eq!(occurrences, 1, "string literal should be stored once");
        assert_eq!(decode_module(&bytes), Ok(m));
    }

    #[test]
    fn rejects_out_of_range_const_index() {
        // A hand-built module whose `const.str` references an empty pool.
        let mut consts = Writer::new();
        consts.write_uvarint(0); // empty pool

        let mut funcs = Writer::new();
        funcs.write_uvarint(1); // one function
        funcs.write_str("f");
        funcs.write_uvarint(0); // params
        funcs.write_uvarint(0); // locals
        funcs.write_uvarint(2); // code len
        funcs.write_u8(super::op::CONST_STR);
        funcs.write_uvarint(5); // index 5 into an empty pool
        funcs.write_u8(super::op::RETURN);

        let mut w = Writer::new();
        w.write_raw(MAGIC);
        w.write_u32_le(VERSION);
        write_section(&mut w, super::section::CONSTANTS, &consts.into_bytes());
        write_section(&mut w, super::section::FUNCTIONS, &funcs.into_bytes());

        assert_eq!(
            decode_module(&w.into_bytes()),
            Err(DecodeError::ConstIndexOutOfRange)
        );
    }

    #[test]
    fn native_call_is_encoded_by_name() {
        let code = vec![
            Instr::ConstStr("hi".into()),
            Instr::CallNative {
                native: NATIVE_PRINTLN,
                argc: 1,
            },
            Instr::Return,
        ];
        let m = Module::new(vec![Function::new("f", 0, 0, code)]);
        let bytes = encode_module(&m);
        // the native name is in the wire form (pooled), not a raw index
        assert!(bytes.windows(7).any(|w| w == b"println"));
        assert_eq!(decode_module(&bytes), Ok(m));
    }

    #[test]
    fn rejects_unknown_native() {
        // A hand-built module whose call.native names a native we don't provide.
        let mut consts = Writer::new();
        consts.write_uvarint(1);
        consts.write_str("bogus_native");

        let mut funcs = Writer::new();
        funcs.write_uvarint(1);
        funcs.write_str("f");
        funcs.write_uvarint(0); // params
        funcs.write_uvarint(0); // locals
        funcs.write_uvarint(2); // code len
        funcs.write_u8(super::op::CALL_NATIVE);
        funcs.write_uvarint(0); // pool index 0 = "bogus_native"
        funcs.write_uvarint(0); // argc
        funcs.write_u8(super::op::RETURN);

        let mut w = Writer::new();
        w.write_raw(MAGIC);
        w.write_u32_le(VERSION);
        write_section(&mut w, super::section::CONSTANTS, &consts.into_bytes());
        write_section(&mut w, super::section::FUNCTIONS, &funcs.into_bytes());

        assert_eq!(
            decode_module(&w.into_bytes()),
            Err(DecodeError::UnknownNative("bogus_native".to_string()))
        );
    }

    #[test]
    fn module_with_types_round_trips() {
        let mut b = FnBuilder::new("make", 0);
        b.const_int(1);
        b.const_int(2);
        b.struct_new(0);
        b.field_get(1);
        b.ret();
        let m = Module::with_types(vec![b.finish()], vec![TypeDef::new("Point", 2)]);
        assert_eq!(decode_module(&encode_module(&m)), Ok(m));
    }

    #[test]
    fn module_with_dispatch_table_round_trips() {
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
        let mut m = Module::with_types(vec![describe], vec![TypeDef::new("Dog", 0)]);
        m.dispatch = vec![DispatchEntry::new(0, "display", 0)];
        assert_eq!(decode_module(&encode_module(&m)), Ok(m));
    }

    #[test]
    fn file_round_trips() {
        let m = factorial_module();
        let path = std::env::temp_dir().join(format!("hawk_codec_{}.hawkbc", std::process::id()));
        write_module_to_file(&path, &m).unwrap();
        let loaded = read_module_from_file(&path).unwrap();
        let _ = std::fs::remove_file(&path);
        assert_eq!(loaded, m);
    }

    #[test]
    fn rejects_bad_magic() {
        let bytes = [b'X', b'X', b'X', b'X', 1, 0, 0, 0];
        assert_eq!(decode_module(&bytes), Err(DecodeError::BadMagic));
    }

    #[test]
    fn rejects_unsupported_version() {
        let mut w = Writer::new();
        w.write_raw(MAGIC);
        w.write_u32_le(999);
        assert_eq!(
            decode_module(&w.into_bytes()),
            Err(DecodeError::UnsupportedVersion(999))
        );
    }

    #[test]
    fn rejects_unknown_opcode() {
        // The last byte of this module is the Return opcode; corrupt it.
        let m = Module::new(vec![Function::new("f", 0, 0, vec![Instr::Return])]);
        let mut bytes = encode_module(&m);
        *bytes.last_mut().unwrap() = 0xFF;
        assert_eq!(decode_module(&bytes), Err(DecodeError::UnknownOpcode(0xFF)));
    }
}
