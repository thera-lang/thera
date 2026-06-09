/// Encodes a [Module] to the `.hawkbc` wire format.
///
/// A direct port of the encode side of the runtime's `codec.rs`: a `"HAWK"`
/// magic + version header, then length-prefixed sections (Constants, Types,
/// Functions). Strings are deduplicated into a constant pool and referenced by
/// index; `call.native` references its native by name (pooled). The runtime's
/// loader decodes this back into its `Module` — and must produce byte-identical
/// output for the same module, which is the round-trip contract the two
/// toolchains share.
library;

import 'dart:typed_data';

import 'instr.dart';
import 'module.dart';
import 'writer.dart';

const List<int> _magic = [0x48, 0x41, 0x57, 0x4b]; // "HAWK"
const int _version = 1;

/// Section ids. Unknown ids are skipped on decode via their byte length.
class _Section {
  static const int functions = 1;
  static const int constants = 2;
  static const int types = 3;
  static const int dispatch = 4;
}

/// Collects and deduplicates strings during encoding, preserving first-seen
/// order so the encoded pool matches the runtime's.
class _StringPool {
  final List<String> strings = [];
  final Map<String, int> _index = {};

  int intern(String s) => _index.putIfAbsent(s, () {
        final i = strings.length;
        strings.add(s);
        return i;
      });

  int indexOf(String s) => _index[s]!;
}

/// Encode a module to the wire format.
Uint8List encodeModule(Module m) {
  // First pass: intern every string the module references — type names, string
  // literals, and the names of called natives — in the same order the runtime
  // does, so the pools (and therefore the bytes) match exactly.
  final pool = _StringPool();
  for (final t in m.types) {
    pool.intern(t.name);
  }
  for (final f in m.functions) {
    for (final instr in f.code) {
      if (instr is ConstStr) {
        pool.intern(instr.value);
      } else if (instr is CallVirtual) {
        pool.intern(instr.selector);
      } else if (instr is CallNative) {
        pool.intern(instr.name);
      }
    }
  }
  for (final e in m.dispatch) {
    pool.intern(e.selector);
  }

  // Constants section: the deduplicated strings.
  final consts = Writer();
  consts.writeUvarint(pool.strings.length);
  for (final s in pool.strings) {
    consts.writeStr(s);
  }

  // Types section: name (pool index) + field count per type.
  final types = Writer();
  types.writeUvarint(m.types.length);
  for (final t in m.types) {
    types.writeUvarint(pool.indexOf(t.name));
    types.writeUvarint(t.fieldCount);
  }

  // Functions section: bodies reference the pool by index.
  final funcs = Writer();
  funcs.writeUvarint(m.functions.length);
  for (final f in m.functions) {
    _encodeFunction(funcs, f, pool);
  }

  // Dispatch section: (type id, selector pool index, function index) per row.
  final dispatch = Writer();
  dispatch.writeUvarint(m.dispatch.length);
  for (final e in m.dispatch) {
    dispatch.writeUvarint(e.type);
    dispatch.writeUvarint(pool.indexOf(e.selector));
    dispatch.writeUvarint(e.func);
  }

  final w = Writer();
  w.writeRaw(_magic);
  w.writeU32Le(_version);
  _writeSection(w, _Section.constants, consts.toBytes());
  _writeSection(w, _Section.types, types.toBytes());
  _writeSection(w, _Section.functions, funcs.toBytes());
  if (m.dispatch.isNotEmpty) {
    _writeSection(w, _Section.dispatch, dispatch.toBytes());
  }
  return w.toBytes();
}

void _writeSection(Writer w, int id, List<int> payload) {
  w.writeU8(id);
  w.writeUvarint(payload.length);
  w.writeRaw(payload);
}

void _encodeFunction(Writer w, FuncDef f, _StringPool pool) {
  w.writeStr(f.name);
  w.writeUvarint(f.paramCount);
  w.writeUvarint(f.localCount);
  w.writeUvarint(f.code.length);
  for (final instr in f.code) {
    _encodeInstr(w, instr, pool);
  }
}

void _encodeInstr(Writer w, Instr instr, _StringPool pool) {
  switch (instr) {
    case Simple(:final op):
      w.writeU8(op.byte);
    case ConstInt(:final value):
      w.writeU8(Op.constInt.byte);
      w.writeIvarint(value);
    case ConstDouble(:final value):
      w.writeU8(Op.constDouble.byte);
      w.writeF64(value);
    case ConstBool(:final value):
      w.writeU8(Op.constBool.byte);
      w.writeU8(value ? 1 : 0);
    case ConstStr(:final value):
      w.writeU8(Op.constStr.byte);
      w.writeUvarint(pool.indexOf(value));
    case Load(:final slot):
      w.writeU8(Op.load.byte);
      w.writeUvarint(slot);
    case Store(:final slot):
      w.writeU8(Op.store.byte);
      w.writeUvarint(slot);
    case Call(:final func, :final argc):
      w.writeU8(Op.call.byte);
      w.writeUvarint(func);
      w.writeUvarint(argc);
    case CallNative(:final name, :final argc):
      w.writeU8(Op.callNative.byte);
      w.writeUvarint(pool.indexOf(name));
      w.writeUvarint(argc);
    case EnumNew(:final type, :final variant, :final fieldCount):
      w.writeU8(Op.enumNew.byte);
      w.writeUvarint(type);
      w.writeUvarint(variant);
      w.writeUvarint(fieldCount);
    case EnumGet(:final index):
      w.writeU8(Op.enumGet.byte);
      w.writeUvarint(index);
    case StructNew(:final type):
      w.writeU8(Op.structNew.byte);
      w.writeUvarint(type);
    case FieldGet(:final index):
      w.writeU8(Op.fieldGet.byte);
      w.writeUvarint(index);
    case FieldSet(:final index):
      w.writeU8(Op.fieldSet.byte);
      w.writeUvarint(index);
    case ListNew(:final count):
      w.writeU8(Op.listNew.byte);
      w.writeUvarint(count);
    case ClosureNew(:final func, :final captures):
      w.writeU8(Op.closureNew.byte);
      w.writeUvarint(func);
      w.writeUvarint(captures);
    case CallIndirect(:final argc):
      w.writeU8(Op.callIndirect.byte);
      w.writeUvarint(argc);
    case CallVirtual(:final selector, :final argc):
      w.writeU8(Op.callVirtual.byte);
      w.writeUvarint(pool.indexOf(selector));
      w.writeUvarint(argc);
    case Jump(:final target):
      w.writeU8(Op.jump.byte);
      w.writeUvarint(target);
    case JumpIfTrue(:final target):
      w.writeU8(Op.jumpIfTrue.byte);
      w.writeUvarint(target);
    case JumpIfFalse(:final target):
      w.writeU8(Op.jumpIfFalse.byte);
      w.writeUvarint(target);
  }
}
