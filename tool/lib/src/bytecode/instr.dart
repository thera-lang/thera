/// The in-memory bytecode instruction model — the Dart mirror of the runtime's
/// `Instr` enum (`runtime/src/instr.rs`). The front-end emits a list of these
/// per function; [encodeModule] serializes them to the `.hawkbc` wire format.
///
/// Jump targets are absolute instruction indices (as in the runtime's in-memory
/// form), serialized as uvarints.
library;

/// One-byte opcode tags. These must match `runtime/src/codec.rs` `mod op`
/// exactly — the byte values are the wire contract between the two toolchains.
enum Op {
  constInt(1),
  constDouble(2),
  constBool(3),
  constUnit(4),
  constStr(5),
  load(6),
  store(7),
  addI64(8),
  subI64(9),
  mulI64(10),
  divI64(11),
  modI64(12),
  negI64(13),
  addF64(14),
  subF64(15),
  mulF64(16),
  divF64(17),
  negF64(18),
  eqI64(19),
  neI64(20),
  ltI64(21),
  leI64(22),
  gtI64(23),
  geI64(24),
  eqF64(25),
  neF64(26),
  ltF64(27),
  leF64(28),
  gtF64(29),
  geF64(30),
  not(31),
  i64ToF64(32),
  f64ToI64(33),
  pop(34),
  dup(35),
  call(36),
  callNative(37),
  enumNew(38),
  enumTag(39),
  enumGet(40),
  listNew(41),
  jump(42),
  jumpIfTrue(43),
  jumpIfFalse(44),
  return_(45),
  structNew(46),
  fieldGet(47),
  fieldSet(48);

  final int byte;
  const Op(this.byte);
}

sealed class Instr {
  const Instr();
}

/// An opcode with no operands (arithmetic, comparison, stack, `return`, …).
class Simple extends Instr {
  final Op op;
  const Simple(this.op);
}

class ConstInt extends Instr {
  final int value;
  const ConstInt(this.value);
}

class ConstDouble extends Instr {
  final double value;
  const ConstDouble(this.value);
}

class ConstBool extends Instr {
  final bool value;
  const ConstBool(this.value);
}

class ConstStr extends Instr {
  final String value;
  const ConstStr(this.value);
}

class Load extends Instr {
  final int slot;
  const Load(this.slot);
}

class Store extends Instr {
  final int slot;
  const Store(this.slot);
}

class Call extends Instr {
  final int func; // index into the module's function table
  final int argc;
  const Call(this.func, this.argc);
}

/// A call to a runtime native. On the wire the native is referenced **by name**
/// (the runtime resolves the name to an index at load), so the front-end only
/// needs the name — never the runtime's internal native index.
class CallNative extends Instr {
  final String name;
  final int argc;
  const CallNative(this.name, this.argc);
}

class EnumNew extends Instr {
  final int type;
  final int variant;
  final int fieldCount;
  const EnumNew(this.type, this.variant, this.fieldCount);
}

class EnumGet extends Instr {
  final int index;
  const EnumGet(this.index);
}

class StructNew extends Instr {
  final int type;
  const StructNew(this.type);
}

class FieldGet extends Instr {
  final int index;
  const FieldGet(this.index);
}

class FieldSet extends Instr {
  final int index;
  const FieldSet(this.index);
}

class ListNew extends Instr {
  final int count;
  const ListNew(this.count);
}

class Jump extends Instr {
  final int target; // absolute instruction index
  const Jump(this.target);
}

class JumpIfTrue extends Instr {
  final int target;
  const JumpIfTrue(this.target);
}

class JumpIfFalse extends Instr {
  final int target;
  const JumpIfFalse(this.target);
}
