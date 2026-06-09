/// The in-memory bytecode module model — the Dart mirror of the runtime's
/// `Module` (`runtime/src/module.rs`). A module is the unit the front-end emits
/// and the runtime loads from a `.hawkbc` file.
library;

import 'instr.dart';

/// A struct/enum layout entry. For now the runtime only needs the name and the
/// field count (the type table); richer layout info arrives with the GC.
class TypeDef {
  final String name;
  final int fieldCount;
  const TypeDef(this.name, this.fieldCount);
}

/// A single function: its name, arity, local-slot count (params included), and
/// instruction stream.
class FuncDef {
  final String name;
  final int paramCount;
  final int localCount; // includes params; locals are slots [0, localCount)
  final List<Instr> code;
  const FuncDef(this.name, this.paramCount, this.localCount, this.code);
}

/// One row of the dynamic-dispatch table: the implementation of interface
/// method [selector] for the concrete type id [type] is `functions[func]`.
/// `call.virtual <selector>` looks the target up by the receiver's type id.
/// Mirrors the runtime's `DispatchEntry` (`runtime/src/module.rs`).
class DispatchEntry {
  final int type; // runtime type id (a `types` index for structs/enums)
  final String selector;
  final int func;
  const DispatchEntry(this.type, this.selector, this.func);
}

/// A compiled module: its functions, type table, and virtual-dispatch table.
class Module {
  final List<FuncDef> functions;
  final List<TypeDef> types;
  final List<DispatchEntry> dispatch;
  const Module(this.functions,
      {this.types = const [], this.dispatch = const []});
}
