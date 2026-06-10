/// Lowers a type-checked Hawk [Program] to a bytecode [Module].
///
/// This is the front-end's bytecode-emitter backend (roadmap arc 2). It walks
/// the AST and emits the runtime's stack-based instructions; the lowering rules
/// here are the reference the eventual Hawk-written front-end re-implements.
///
/// Scope is grown incrementally. This first cut handles top-level functions,
/// `return`, expression statements, literals, and calls to runtime natives
/// (e.g. `println`). Unsupported constructs raise [CodegenException] rather
/// than emitting wrong bytecode.
library;

import '../ast.dart';
import '../bytecode/instr.dart';
import '../bytecode/module.dart';
import '../element/inference.dart';
import '../element/namespace.dart';
import '../element/resolver.dart';
import '../element/types.dart';
import '../token.dart';

/// A construct the code generator does not yet handle.
class CodegenException implements Exception {
  final String message;
  final SourceSpan? span;
  CodegenException(this.message, [this.span]);

  @override
  String toString() =>
      'CodegenException: $message${span != null ? ' at $span' : ''}';
}

/// The three conditional/unconditional jump kinds, used by the backpatcher.
enum _Jk { jump, ifTrue, ifFalse }

/// A placeholder jump awaiting its target: the instruction position to patch,
/// the label it targets, and which jump opcode to emit.
class _Fixup {
  final int pos;
  final int label;
  final _Jk kind;
  const _Fixup(this.pos, this.label, this.kind);
}

// Well-known enum type ids and variant tags, fixed by convention and shared
// with the runtime (runtime/src/value.rs). Result and Option are not in the
// type table — `enum.new` carries its field count inline.
const int _tyResult = 0;
const int _tyOption = 1;
const int _tagOk = 0;
const int _tagErr = 1;

/// Compile [program] — plus any [imports] it links against — into one module.
///
/// All modules' functions, types, and methods are registered into a single
/// scope (so cross-module calls resolve), then compiled. The caller (the CLI)
/// resolves and parses the import closure; this keeps codegen free of file I/O
/// and unit-testable with in-memory modules.
Module compileProgram(Program program,
    {List<Program> imports = const [],
    Map<String, LibraryNamespace> namespaces = const {}}) {
  // Register everything first (declarations across every module) so forward and
  // cross-module references — calls, methods, struct types — all resolve before
  // any body is compiled. Functions and impl methods become a flat list of
  // "units"; a unit's position is the function-table index used by `call`.
  // Resolve the element model and annotate every expression with its semantic
  // type (Expr.resolvedType), which codegen consumes for opcode selection. This
  // sees through generics where the bottom-up `_typeOf` fallback cannot.
  final inferrer =
      Inferrer(buildLibrary(program, imports: imports, namespaces: namespaces));
  for (final module in [...imports, program]) {
    inferrer.inferProgram(module);
  }

  final scope = _ModuleScope(namespaces: namespaces.keys.toSet());
  for (final module in [...imports, program]) {
    _registerModule(scope, module);
  }

  final functions = [
    for (var i = 0; i < scope.units.length; i++) _FnCompiler(scope).compile(i),
  ];
  return Module(functions, types: scope.types, dispatch: scope.buildDispatch());
}

/// Register one module's declarations into the shared [scope].
void _registerModule(_ModuleScope scope, Program program) {
  for (final decl in program.decls) {
    switch (decl) {
      case FnDecl() when decl.isNative:
        scope.addNative(decl);
      case FnDecl():
        scope.addFunction(decl);
      case TypeDecl():
        scope.addStruct(decl);
      case EnumDecl():
        scope.addEnum(decl);
      case ConstDecl():
        scope.addConst(decl);
      case InterfaceDecl():
        scope.addInterface(decl);
      case ImplDecl():
        if (decl.interfaceName != null) {
          scope.addInterfaceImpl(decl.typeName, decl.interfaceName!);
        }
        for (final method in decl.methods) {
          final isStatic = !method.params.any((p) => p.isSelf);
          if (method.isNative && isStatic) {
            scope.addNativeStaticMethod(decl.typeName, method);
          } else if (method.isNative) {
            scope.addNativeInstanceMethod(decl.typeName, method);
          } else if (method.body != null) {
            scope.addMethod(decl.typeName, method);
          }
          // Each non-native interface-method impl gets a dispatch-table row so
          // `call.virtual` can reach it from an interface-typed receiver.
          if (decl.interfaceName != null && !isStatic && !method.isNative) {
            scope.addDispatch(decl.typeName, method.name);
          }
        }
      default:
        break;
    }
  }
}

/// The name of a type reference (`Int`, `Double`, …), or null.
String? _typeRefName(TypeRef? type) => type is NamedType ? type.name : null;

/// The plain-text value of a non-interpolated string-literal expression, or
/// null (used to read decorator arguments like `@extern('fs_read_text')`).
String? _stringLiteral(Expr e) {
  if (e is StringExpr && e.parts.length == 1 && e.parts.first is TextPart) {
    return (e.parts.first as TextPart).text;
  }
  return null;
}

/// The runtime native symbol a `native fn` binds to: its `@extern('<symbol>')`
/// decorator argument, or its own name when unannotated.
String _externSymbol(FnDecl decl) {
  final extern = decl.decorators.where((d) => d.name == 'extern').firstOrNull;
  if (extern != null && extern.args.isNotEmpty) {
    return _stringLiteral(extern.args.first) ?? decl.name;
  }
  return decl.name;
}

/// Layout of a struct type: its index in the module type table and its field
/// names in declaration order (which fixes the field indices).
class _StructInfo {
  final int index;
  final List<String> fieldNames;
  _StructInfo(this.index, this.fieldNames);

  int fieldIndexOf(String name) => fieldNames.indexOf(name);
}

/// Layout of a user-defined enum: its runtime type id and its variants in
/// declaration order (which fixes the variant tags). Built-in `Result`/`Option`
/// use the fixed ids 0/1 and aren't registered here.
class _EnumInfo {
  final int ty;
  final List<EnumVariant> variants;
  _EnumInfo(this.ty, this.variants);

  /// The tag (variant index) of [name], or -1 if it isn't a variant.
  int tagOf(String name) => variants.indexWhere((v) => v.name == name);
  int fieldCountOf(String name) =>
      variants.firstWhere((v) => v.name == name).fields.length;
}

/// Module-wide tables shared by every function compiler: the flat list of
/// compiled units (functions + impl methods), how to resolve a call to a unit
/// index, and the struct/enum/type layout.
class _ModuleScope {
  final List<FnDecl> units = []; // index -> declaration
  final List<String> unitNames = []; // index -> mangled name (e.g. Point.area)
  final List<String?> unitSelfTypes = []; // index -> receiver type, if a method
  final Map<String, int> functionIndex = {}; // bare name -> unit index
  final Map<String, Map<String, int>> methodTable = {}; // type -> method -> idx
  final Map<String, _StructInfo> structs = {};
  final Map<String, _EnumInfo> enums = {};
  final List<TypeDef> types = [];

  /// Top-level `const` initializers, by bare name (across every module — the
  /// type table is flat, so a qualified `ns.NAME` resolves to the same `NAME`).
  /// Codegen has no global storage, so a const reference inlines its
  /// initializer expression at the use site (see `_FnCompiler._emitConst`).
  final Map<String, Expr> consts = {};

  /// `native fn` name -> the runtime native symbol it binds to (from its
  /// `@extern('...')` decorator, or its own name as a fallback).
  final Map<String, String> nativeFns = {};

  /// Static `native fn`s declared in `impl` blocks: type -> method -> runtime
  /// native symbol (e.g. `String` -> `from_chars` -> `str_from_chars`). Lowered
  /// as a `call.native` with no receiver.
  final Map<String, Map<String, String>> nativeStaticMethods = {};

  /// Instance `native fn`s declared in `impl` blocks: type -> method -> runtime
  /// native symbol (e.g. `List` -> `len` -> `list_len`). Lowered as a
  /// `call.native` with the receiver pushed as the first argument.
  final Map<String, Map<String, String>> nativeInstanceMethods = {};

  /// Interfaces explicitly implemented by a type, from `impl Interface for Type`
  /// blocks (e.g. `Tag` -> {`Display`}). Lets `==`/`${}` dispatch to a type's
  /// own `Eq`/`Display` method instead of the structural default.
  final Map<String, Set<String>> interfaceImpls = {};

  /// Declared interfaces (`interface Display { … }`) -> their method names. A
  /// method call on a value of one of these types dispatches dynamically via
  /// `call.virtual`; a call to a name not in the set is rejected.
  final Map<String, Set<String>> interfaceMethods = {};

  /// Pending dynamic-dispatch rows as `(typeName, selector)`, recorded from
  /// `impl Interface for Type` blocks. Resolved to `(typeId, selector, func)`
  /// once every type and method is registered — see [buildDispatch].
  final List<(String, String)> _pendingDispatch = [];

  void addInterface(InterfaceDecl decl) =>
      interfaceMethods[decl.name] = {for (final m in decl.methods) m.name};

  void addDispatch(String type, String selector) =>
      _pendingDispatch.add((type, selector));

  /// Resolve the pending dispatch rows into the module's dispatch table: map
  /// each `(type, selector)` to the type's runtime dispatch id (an enum's id is
  /// offset by [enumDispatchBase] — the struct and enum id spaces overlap
  /// numerically) and the implementing unit. Skips any whose method or type id
  /// can't be resolved.
  List<DispatchEntry> buildDispatch() {
    final entries = <DispatchEntry>[];
    for (final (type, selector) in _pendingDispatch) {
      final func = methodTable[type]?[selector];
      final enumTy = enums[type]?.ty;
      final typeId = structs[type]?.index ??
          (enumTy == null ? null : enumDispatchBase | enumTy);
      if (func != null && typeId != null) {
        entries.add(DispatchEntry(typeId, selector, func));
      }
    }
    return entries;
  }

  /// Import namespaces in scope for the program being compiled (alias / trailing
  /// path segment). A qualified `ns.Name` resolves to the flat `Name`.
  final Set<String> namespaces;

  _ModuleScope({this.namespaces = const {}});

  // Runtime type ids for user enums start after the reserved Result (0) and
  // Option (1), and must be distinct so structural equality never conflates two
  // enum types.
  int _nextEnumTy = 2;

  // The two language-blessed enums occupy reserved type ids shared with the
  // runtime (see runtime/src/value.rs). When std.core defines them as ordinary
  // enums they must still land on those ids, not be assigned fresh ones.
  static const _reservedEnumTys = {'Result': _tyResult, 'Option': _tyOption};

  void addConst(ConstDecl decl) => consts[decl.name] = decl.value;

  void addStruct(TypeDecl decl) {
    final fieldNames = [for (final f in decl.fields) f.$1];
    structs[decl.name] = _StructInfo(types.length, fieldNames);
    types.add(TypeDef(decl.name, fieldNames.length));
  }

  void addEnum(EnumDecl decl) {
    final ty = _reservedEnumTys[decl.name] ?? _nextEnumTy++;
    enums[decl.name] = _EnumInfo(ty, decl.variants);
  }

  void addFunction(FnDecl decl) {
    functionIndex[decl.name] = units.length;
    _addUnit(decl, decl.name, null);
  }

  /// Register a top-level `native fn`: its name binds to the runtime native
  /// named by its `@extern('<symbol>')` decorator (or its own name).
  void addNative(FnDecl decl) {
    nativeFns[decl.name] = _externSymbol(decl);
  }

  /// Register a static `native fn` from an `impl` block (no `self`), e.g.
  /// `impl String { @extern('str_from_chars') native fn from_chars(...) }`.
  void addNativeStaticMethod(String type, FnDecl method) {
    nativeStaticMethods.putIfAbsent(type, () => {})[method.name] =
        _externSymbol(method);
  }

  /// Register an instance `native fn` from an `impl` block (takes `self`), e.g.
  /// `impl List<T> { @extern('list_len') native fn len(self) -> Int }`.
  void addNativeInstanceMethod(String type, FnDecl method) {
    nativeInstanceMethods.putIfAbsent(type, () => {})[method.name] =
        _externSymbol(method);
  }

  /// Record an `impl Interface for Type` conformance.
  void addInterfaceImpl(String type, String interfaceName) {
    interfaceImpls.putIfAbsent(type, () => {}).add(interfaceName);
  }

  void addMethod(String type, FnDecl method) {
    final selfType = method.params.any((p) => p.isSelf) ? type : null;
    methodTable.putIfAbsent(type, () => {})[method.name] = units.length;
    _addUnit(method, '$type.${method.name}', selfType);
  }

  void _addUnit(FnDecl decl, String name, String? selfType) {
    units.add(decl);
    unitNames.add(name);
    unitSelfTypes.add(selfType);
  }

  /// Register a lifted lambda as a synthetic top-level unit and return its
  /// function-table index. Compiled by the same per-unit loop as any function
  /// (the loop re-reads `units.length`, so units added mid-compilation are
  /// still compiled). [boxedParams] names the leading (capture) parameters that
  /// hold a boxed cell rather than a plain value, so the lifted function reads
  /// and writes them through the cell.
  int addLambda(FnDecl decl, Set<String> boxedParams) {
    final index = units.length;
    _addUnit(decl, '__lambda_$index', null);
    if (boxedParams.isNotEmpty) this.boxedParams[index] = boxedParams;
    return index;
  }

  /// Unit index -> the names of its parameters that hold a boxed cell (a
  /// captured `mut` local). See [addLambda] and the boxing lowering in
  /// `_FnCompiler`.
  final Map<int, Set<String>> boxedParams = {};

  /// The type-table index of the one-field cell struct used to box captured
  /// `mut` locals, created on first use.
  int? _cellType;
  int cellTypeIndex() {
    if (_cellType case final i?) return i;
    final i = types.length;
    types.add(TypeDef('<cell>', 1));
    return _cellType = i;
  }
}

/// Compiles one function: tracks local slots and emits its instruction stream.
class _FnCompiler {
  final _ModuleScope _scope;
  Map<String, int> get functionIndex => _scope.functionIndex;
  Map<String, Map<String, int>> get _methods => _scope.methodTable;

  /// Whether [type] explicitly implements [interfaceName] (an `impl Interface
  /// for Type` block), and the unit index of [type]'s `[interfaceName]` method.
  int? _interfaceMethod(String? type, String interfaceName, String method) {
    if (type == null) return null;
    if (!(_scope.interfaceImpls[type]?.contains(interfaceName) ?? false)) {
      return null;
    }
    return _methods[type]?[method];
  }

  Map<String, _StructInfo> get structs => _scope.structs;
  Map<String, _EnumInfo> get _enums => _scope.enums;
  List<FnDecl> get _units => _scope.units;

  /// Whether [name] is an import namespace here (not shadowed by a local).
  bool _isNamespace(String name) =>
      !_slots.containsKey(name) && _scope.namespaces.contains(name);

  /// Built-in type names that can host static methods (`String.from_chars(...)`,
  /// `List.of(...)`). The type table is flat, so a static call resolves through
  /// the method table by this name.
  static const _builtinTypeNames = {
    'String',
    'Int',
    'Bool',
    'Double',
    'Float',
    'Void',
    'List',
    'Map',
    'Set',
    'Result',
    'Option',
  };

  bool _isTypeName(String name) =>
      structs.containsKey(name) ||
      _enums.containsKey(name) ||
      _builtinTypeNames.contains(name);

  /// The bare type name a (possibly namespace-qualified) type expression refers
  /// to — `Type` or `ns.Type` — when it names a struct, enum, or built-in type.
  /// The type table is flat, so `ns.Type` resolves to the same `Type`.
  String? _staticTypeName(Expr e) {
    if (e is IdentExpr && !_slots.containsKey(e.name) && _isTypeName(e.name)) {
      return e.name;
    }
    if (e is FieldExpr &&
        e.object is IdentExpr &&
        _isNamespace((e.object as IdentExpr).name) &&
        _isTypeName(e.field)) {
      return e.field;
    }
    return null;
  }

  /// If [object] names a user enum — `Enum` or `ns.Enum`, not a local — and
  /// [name] is one of its variants, return that enum and the variant's tag.
  (_EnumInfo, int)? _enumVariant(Expr object, String name) {
    final typeName = _staticTypeName(object);
    if (typeName == null) return null;
    final info = _enums[typeName];
    if (info == null) return null;
    final tag = info.tagOf(name);
    return tag < 0 ? null : (info, tag);
  }

  final List<Instr> _code = [];
  final Map<String, int> _slots = {};
  // This unit's generic parameters -> their bounds (e.g. `T` -> [`Display`]). A
  // method call on a value typed `T` dispatches through the interface bound.
  final Map<String, List<String>> _typeParamBounds = {};
  // Const names currently being inlined, to catch a cyclic definition
  // (`const A = B; const B = A;`) instead of recursing forever.
  final Set<String> _constsInProgress = {};
  // Locals (and capture parameters) whose slot holds a one-field heap cell
  // rather than a plain value: captured `mut` locals, boxed so the closure and
  // the enclosing scope share later writes. Reads/writes go through the cell.
  final Set<String> _boxedLocals = {};
  int _localCount = 0;
  int _paramCount = 0;
  // Whether this function returns `Result<...>`, which enables implicit `Ok`
  // wrapping on a bare `return v`.
  bool _returnsResult = false;

  // Jump targets are absolute instruction indices, but a forward jump is
  // emitted before its target is known. We emit a placeholder, record a fixup,
  // and backpatch once all labels are bound — the same scheme as the runtime's
  // FnBuilder.
  final List<int?> _labels = []; // label id -> bound instruction index
  final List<_Fixup> _fixups = [];

  _FnCompiler(this._scope);

  /// Compile the unit at [index] in the module scope.
  FuncDef compile(int index) {
    final fn = _units[index];
    _returnsResult = _typeRefName(fn.returnType) == 'Result';
    // This unit's generic parameters and their bounds, so a method call on a
    // value of type `T` (erased) can dispatch through `T`'s interface bound.
    for (final tp in fn.typeParams) {
      _typeParamBounds[tp.name] = tp.bounds;
    }
    // Capture parameters that arrive as boxed cells (a captured `mut` local of
    // the enclosing function), plus this function's own `mut` locals that some
    // lambda captures — both are read/written through a cell.
    _boxedLocals.addAll(_scope.boxedParams[index] ?? const {});
    if (fn.body != null) _boxedLocals.addAll(_boxedMutLocals(fn.body!));
    for (final p in fn.params) {
      _declareLocal(p.name);
      _paramCount++;
    }
    if (fn.body != null) {
      _block(fn.body!);
    }
    // Guarantee the stream ends with a return, so execution never runs off the
    // end (a Void fall-through returns Unit).
    if (_code.isEmpty || !_endsInReturn()) {
      _emit(const Simple(Op.constUnit));
      _emit(const Simple(Op.return_));
    }
    _resolveJumps();
    return FuncDef(_scope.unitNames[index], _paramCount, _localCount, _code);
  }

  /// Backpatch each placeholder jump with the absolute index of its label.
  void _resolveJumps() {
    for (final f in _fixups) {
      final target = _labels[f.label]!;
      _code[f.pos] = switch (f.kind) {
        _Jk.jump => Jump(target),
        _Jk.ifTrue => JumpIfTrue(target),
        _Jk.ifFalse => JumpIfFalse(target),
      };
    }
  }

  int _newLabel() {
    _labels.add(null);
    return _labels.length - 1;
  }

  void _bind(int label) => _labels[label] = _code.length;

  /// Emit a jump to [label]; the concrete target is patched in by
  /// [_resolveJumps].
  void _emitJump(_Jk kind, int label) {
    _fixups.add(_Fixup(_code.length, label, kind));
    _code.add(const Jump(0)); // placeholder, replaced during resolution
  }

  /// Allocate an unnamed local slot (loop counters, limits, …).
  int _freshSlot() => _localCount++;

  bool _endsInReturn() {
    final last = _code.last;
    return last is Simple && last.op == Op.return_;
  }

  int _declareLocal(String name) {
    final slot = _localCount++;
    _slots[name] = slot;
    return slot;
  }

  void _emit(Instr instr) => _code.add(instr);

  /// Push the value of local [name]. A boxed local (a captured `mut`) holds a
  /// one-field cell, so its value is the cell's field rather than the slot.
  void _loadLocalValue(String name, SourceSpan span) {
    final slot = _slots[name];
    if (slot == null) {
      // Not a local — a reference to a top-level `const`? Inline its
      // initializer (codegen has no global storage).
      if (_scope.consts.containsKey(name)) {
        _emitConst(name, span);
        return;
      }
      throw CodegenException('not a local variable: $name', span);
    }
    _emit(Load(slot));
    if (_boxedLocals.contains(name)) _emit(const FieldGet(0));
  }

  /// Inline a top-level constant by compiling its initializer expression at the
  /// use site. Guards against a cyclic definition.
  void _emitConst(String name, SourceSpan span) {
    if (!_constsInProgress.add(name)) {
      throw CodegenException('cyclic constant: $name', span);
    }
    _expr(_scope.consts[name]!);
    _constsInProgress.remove(name);
  }

  // --- Statements ---

  void _block(Block block) {
    for (final stmt in block.stmts) {
      _stmt(stmt);
    }
  }

  void _stmt(Stmt stmt) {
    switch (stmt) {
      case LetStmt(:final name, :final value):
        // Evaluate the initializer before declaring the binding, so the
        // initializer can't see the (not-yet-bound) name. A captured `mut`
        // local is boxed: wrap the initial value in a one-field cell.
        _expr(value);
        if (_boxedLocals.contains(name)) {
          _emit(StructNew(_scope.cellTypeIndex()));
        }
        final slot = _declareLocal(name);
        _emit(Store(slot));
      case AssignStmt(:final target, :final value):
        switch (target) {
          case IdentExpr(:final name):
            final slot = _slots[name];
            if (slot == null) {
              throw CodegenException(
                  'assignment to unknown local: $name', stmt.span);
            }
            if (_boxedLocals.contains(name)) {
              // Write into the cell, not the slot, so the closure sees it.
              _emit(Load(slot));
              _expr(value);
              _emit(const FieldSet(0));
            } else {
              _expr(value);
              _emit(Store(slot));
            }
          case FieldExpr(:final object, :final field):
            // field.set pops the value then the receiver: push receiver first.
            final info = _structOf(object, stmt.span);
            _expr(object);
            _expr(value);
            _emit(FieldSet(_fieldIndex(info, field, stmt.span)));
          case IndexExpr(:final object, :final index):
            // coll[i] = v  →  store (collection, index, value). `List` uses the
            // dedicated `list.set` opcode (stack-neutral, like field.set); `Map`
            // is a keyed insert via native, whose Unit result is discarded.
            _expr(object);
            _expr(index);
            _expr(value);
            switch (_typeOf(object)) {
              case 'List':
                _emit(const Simple(Op.listSet));
              case 'Map':
                _emit(const CallNative('map_set', 3));
                _emit(const Simple(Op.pop));
              default:
                throw CodegenException(
                    'indexed assignment on ${_typeOf(object) ?? 'unknown type'} '
                    'is not supported',
                    stmt.span);
            }
          default:
            throw CodegenException(
                'unsupported assignment target: ${target.runtimeType}',
                stmt.span);
        }
      case IfStmt(:final condition, :final then, :final else_):
        _expr(condition);
        if (else_ == null) {
          final end = _newLabel();
          _emitJump(_Jk.ifFalse, end);
          _block(then);
          _bind(end);
        } else {
          final elseLabel = _newLabel();
          final end = _newLabel();
          _emitJump(_Jk.ifFalse, elseLabel);
          _block(then);
          _emitJump(_Jk.jump, end);
          _bind(elseLabel);
          _block(else_);
          _bind(end);
        }
      case WhileStmt(:final condition, :final body):
        final start = _newLabel();
        final end = _newLabel();
        _bind(start);
        _expr(condition);
        _emitJump(_Jk.ifFalse, end);
        _block(body);
        _emitJump(_Jk.jump, start);
        _bind(end);
      case ForStmt(:final pattern, :final iterable, :final body):
        _forStmt(pattern, iterable, body);
      case ReturnStmt(:final value):
        _emitReturn(value);
      case ThrowStmt(:final value):
        _emitThrow(value);
      case ExprStmt(:final expr):
        // The result of an expression statement is discarded; every expression
        // leaves exactly one slot on the stack, so pop it.
        _expr(expr);
        _emit(const Simple(Op.pop));
    }
  }

  /// Emit a `return`, applying implicit `Ok` wrapping when the function returns
  /// `Result` and the value isn't already a `Result` (e.g. a bare `return n`).
  void _emitReturn(Expr? value) {
    if (value == null) {
      _emit(const Simple(Op.constUnit));
    } else {
      _expr(value);
      if (_returnsResult && _typeOf(value) != 'Result') {
        _emit(const EnumNew(_tyResult, _tagOk, 1));
      }
    }
    _emit(const Simple(Op.return_));
  }

  /// `throw e` is sugar for `return Err(e)` in a `Result`-returning function.
  void _emitThrow(Expr value) {
    _expr(value);
    _emit(const EnumNew(_tyResult, _tagErr, 1));
    _emit(const Simple(Op.return_));
  }

  /// `for x in <iterable>` — a counter loop over a range, or an index loop over
  /// a list. Other iterables await a general iterator protocol.
  void _forStmt(Pattern pattern, Expr iterable, Block body) {
    final varName = switch (pattern) {
      IdentPattern(:final name) => name,
      WildcardPattern() => null,
      _ => throw CodegenException(
          'unsupported for-loop pattern: ${pattern.runtimeType}',
          iterable.span),
    };
    if (iterable is RangeExpr) {
      _rangeFor(varName, iterable, body);
    } else if (_typeOf(iterable) == 'List') {
      _listFor(varName, iterable, body);
    } else {
      throw CodegenException(
          'cannot iterate ${_typeOf(iterable) ?? 'this value'} '
          '(only ranges and lists are supported)',
          iterable.span);
    }
  }

  /// `for x in start..end` — counter from start (inclusive) to end (exclusive,
  /// evaluated once).
  void _rangeFor(String? varName, RangeExpr range, Block body) {
    _expr(range.start);
    final counter = varName != null ? _declareLocal(varName) : _freshSlot();
    _emit(Store(counter));
    _expr(range.end);
    final limit = _freshSlot();
    _emit(Store(limit));

    final start = _newLabel();
    final end = _newLabel();
    _bind(start);
    _emit(Load(counter));
    _emit(Load(limit));
    _emit(const Simple(Op.ltI64));
    _emitJump(_Jk.ifFalse, end);
    _block(body);
    _emit(Load(counter));
    _emit(const ConstInt(1));
    _emit(const Simple(Op.addI64));
    _emit(Store(counter));
    _emitJump(_Jk.jump, start);
    _bind(end);
  }

  /// `for x in list` — index from 0 to `list.len()`, binding `x = list[i]`.
  void _listFor(String? varName, Expr listExpr, Block body) {
    _expr(listExpr);
    final list = _freshSlot();
    _emit(Store(list));
    final i = _freshSlot();
    _emit(const ConstInt(0));
    _emit(Store(i));

    final start = _newLabel();
    final end = _newLabel();
    _bind(start);
    _emit(Load(i));
    _emit(Load(list));
    _emit(const CallNative('list_len', 1));
    _emit(const Simple(Op.ltI64));
    _emitJump(_Jk.ifFalse, end);
    // x = list[i]
    final elem = varName != null ? _declareLocal(varName) : _freshSlot();
    _emit(Load(list));
    _emit(Load(i));
    _emit(const Simple(Op.listGet));
    _emit(Store(elem));
    _block(body);
    _emit(Load(i));
    _emit(const ConstInt(1));
    _emit(const Simple(Op.addI64));
    _emit(Store(i));
    _emitJump(_Jk.jump, start);
    _bind(end);
  }

  // --- Expressions ---

  void _expr(Expr expr) {
    switch (expr) {
      case IntLiteral(:final value):
        _emit(ConstInt(value));
      case FloatLiteral(:final value):
        _emit(ConstDouble(value));
      case BoolLiteral(:final value):
        _emit(ConstBool(value));
      case UnitLiteral():
        _emit(const Simple(Op.constUnit));
      case StringExpr():
        _stringExpr(expr);
      case IdentExpr(:final name):
        _loadLocalValue(name, expr.span);
      case UnaryExpr():
        _unaryExpr(expr);
      case BinaryExpr():
        _binaryExpr(expr);
      case StructExpr():
        _structExpr(expr);
      case ListExpr(:final items):
        for (final item in items) {
          _expr(item);
        }
        _emit(ListNew(items.length));
      case MapExpr(:final entries):
        for (final (key, value) in entries) {
          _expr(key);
          _expr(value);
        }
        _emit(CallNative('map_new', entries.length * 2));
      case IndexExpr(:final object, :final index):
        _expr(object);
        _expr(index);
        _emitIndexGet(object, expr.span);
      case FieldExpr(:final object, :final field):
        // A namespace-qualified constant: `ns.NAME` → inline its initializer.
        if (object is IdentExpr &&
            _isNamespace(object.name) &&
            _scope.consts.containsKey(field)) {
          _emitConst(field, expr.span);
          return;
        }
        // A bare `Enum.Variant` is a zero-field enum constructor.
        final variant = _enumVariant(object, field);
        if (variant != null) {
          final (info, tag) = variant;
          if (info.fieldCountOf(field) != 0) {
            throw CodegenException(
                'enum variant `$field` takes arguments', expr.span);
          }
          _emit(EnumNew(info.ty, tag, 0));
        } else {
          final info = _structOf(object, expr.span);
          _expr(object);
          _emit(FieldGet(_fieldIndex(info, field, expr.span)));
        }
      case CallExpr():
        _callExpr(expr);
      case PropagateExpr():
        _propagateExpr(expr);
      case MatchExpr():
        _matchExpr(expr);
      case ReturnExpr(:final value):
        _emitReturn(value);
      case ThrowExpr(:final value):
        _emitThrow(value);
      case LambdaExpr():
        _lambdaExpr(expr);
      default:
        throw CodegenException(
            'unsupported expression: ${expr.runtimeType}', expr.span);
    }
  }

  /// A lambda: lift its body to a synthetic top-level function whose leading
  /// parameters are its captured variables, push the captured values, and build
  /// a closure value `{ func, captures }`. A captured `mut` local is already a
  /// boxed cell in this scope; the cell reference is captured (so the closure
  /// and the enclosing scope share writes) and the lifted parameter is marked
  /// boxed so the lambda body reads/writes through the cell too.
  void _lambdaExpr(LambdaExpr expr) {
    // Free variables that name an enclosing local are the captures; references
    // to functions, types, namespaces, etc. resolve the same way in the lifted
    // unit and need no capture.
    final captures = [
      for (final name in _freeVariables(expr))
        if (_slots.containsKey(name)) name,
    ];
    final boxedCaptures = {
      for (final name in captures)
        if (_boxedLocals.contains(name)) name,
    };
    final lifted = _liftLambda(expr, captures);
    final index = _scope.addLambda(lifted, boxedCaptures);
    // Push the captured values (in capture order), then bundle the closure. A
    // boxed capture pushes the cell itself (Load, no field.get) so it's shared.
    for (final name in captures) {
      _emit(Load(_slots[name]!));
    }
    _emit(ClosureNew(index, captures.length));
  }

  /// Build the synthetic [FnDecl] a lambda lowers to. Its parameters are the
  /// captured variables (leading, in capture order) followed by the lambda's
  /// own parameters; its body returns the lambda's body expression. Capture
  /// reads in the body resolve to the leading parameter slots by name.
  FnDecl _liftLambda(LambdaExpr expr, List<String> captures) {
    final body = Block(expr.span, expr.span, [
      ReturnStmt(expr.span, value: expr.body),
    ]);
    return FnDecl(
      expr.span,
      decorators: const [],
      isNative: false,
      name: '<lambda>',
      nameSpan: expr.span,
      params: [
        for (final c in captures) Param(name: c, label: c, nameSpan: expr.span),
        for (final p in expr.params)
          Param(name: p.name, label: p.name, nameSpan: expr.span),
      ],
      body: body,
    );
  }

  /// The free variables of [lambda]: identifiers referenced in its body that it
  /// does not itself bind. Its own parameters, and any names introduced inside
  /// the body by nested lambdas, `match` patterns, block `let`s, and `for`
  /// loops, are bound (not free). Listed in first-reference order so the
  /// capture layout is deterministic.
  List<String> _freeVariables(LambdaExpr lambda) {
    final free = <String>[];
    final seen = <String>{};

    void ref(String name, Set<String> bound) {
      if (!bound.contains(name) && seen.add(name)) free.add(name);
    }

    void patternBindings(Pattern p, Set<String> into) {
      switch (p) {
        case IdentPattern(:final name):
          into.add(name);
        case ConstructorPattern(:final args):
          for (final a in args) {
            patternBindings(a, into);
          }
        case WildcardPattern():
        case LiteralPattern():
          break;
      }
    }

    // `visit`, `stmt`, and `visitBlock` are mutually recursive; Dart local
    // functions must be declared before use, so they're `late` variables.
    late final void Function(Expr, Set<String>) visit;
    late final void Function(Stmt, Set<String>) stmt;

    void visitBlock(Block b, Set<String> bound) {
      final local = {...bound};
      for (final s in b.stmts) {
        stmt(s, local);
      }
    }

    visit = (Expr e, Set<String> bound) {
      switch (e) {
        case IdentExpr(:final name):
          ref(name, bound);
        case IntLiteral():
        case FloatLiteral():
        case BoolLiteral():
        case UnitLiteral():
          break;
        case StringExpr(:final parts):
          for (final p in parts) {
            if (p is InterpPart) visit(p.expr, bound);
          }
        case ListExpr(:final items):
          for (final i in items) {
            visit(i, bound);
          }
        case MapExpr(:final entries):
          for (final (k, v) in entries) {
            visit(k, bound);
            visit(v, bound);
          }
        case StructExpr(:final fields):
          for (final (_, v) in fields) {
            visit(v, bound);
          }
        case CallExpr(:final callee, :final args):
          visit(callee, bound);
          for (final a in args) {
            visit(a.value, bound);
          }
        case FieldExpr(:final object):
          visit(object, bound);
        case IndexExpr(:final object, :final index):
          visit(object, bound);
          visit(index, bound);
        case BinaryExpr(:final left, :final right):
          visit(left, bound);
          visit(right, bound);
        case UnaryExpr(:final operand):
          visit(operand, bound);
        case PropagateExpr(:final inner):
          visit(inner, bound);
        case RangeExpr(:final start, :final end):
          visit(start, bound);
          visit(end, bound);
        case MatchExpr(:final subject, :final arms):
          visit(subject, bound);
          for (final arm in arms) {
            final armBound = {...bound};
            patternBindings(arm.pattern, armBound);
            visit(arm.body, armBound);
          }
        case LambdaExpr(:final params, :final body):
          visit(body, {...bound, for (final p in params) p.name});
        case BlockExpr(:final block):
          visitBlock(block, bound);
        case ReturnExpr(:final value):
          if (value != null) visit(value, bound);
        case ThrowExpr(:final value):
          visit(value, bound);
      }
    };

    stmt = (Stmt s, Set<String> bound) {
      switch (s) {
        case LetStmt(:final name, :final value):
          visit(value, bound);
          bound.add(name); // visible to later statements in the block
        case AssignStmt(:final target, :final value):
          visit(target, bound);
          visit(value, bound);
        case ExprStmt(:final expr):
          visit(expr, bound);
        case ReturnStmt(:final value):
          if (value != null) visit(value, bound);
        case ThrowStmt(:final value):
          visit(value, bound);
        case IfStmt(:final condition, :final then, :final else_):
          visit(condition, bound);
          visitBlock(then, bound);
          if (else_ != null) visitBlock(else_, bound);
        case WhileStmt(:final condition, :final body):
          visit(condition, bound);
          visitBlock(body, bound);
        case ForStmt(:final pattern, :final iterable, :final body):
          visit(iterable, bound);
          final loopBound = {...bound};
          patternBindings(pattern, loopBound);
          visitBlock(body, loopBound);
      }
    };

    visit(lambda.body, {for (final p in lambda.params) p.name});
    return free;
  }

  /// The `mut` locals of the function with body [body] that are captured by a
  /// lambda, and therefore need boxing. A single walk gathers this function's
  /// own `mut` declarations (not descending into lambda bodies — those belong
  /// to the lifted function) and its top-level lambdas; a captured-and-mutable
  /// local is the intersection. (A lambda's free variables already include
  /// names referenced by lambdas nested inside it, so the top-level lambdas
  /// suffice.)
  Set<String> _boxedMutLocals(Block body) {
    final muts = <String>{};
    final lambdas = <LambdaExpr>[];

    late final void Function(Expr) ex;
    late final void Function(Stmt) st;
    void blk(Block b) {
      for (final s in b.stmts) {
        st(s);
      }
    }

    ex = (Expr e) {
      switch (e) {
        case LambdaExpr():
          lambdas.add(e); // a lambda of this function; don't descend into it
        case IdentExpr():
        case IntLiteral():
        case FloatLiteral():
        case BoolLiteral():
        case UnitLiteral():
          break;
        case StringExpr(:final parts):
          for (final p in parts) {
            if (p is InterpPart) ex(p.expr);
          }
        case ListExpr(:final items):
          for (final i in items) {
            ex(i);
          }
        case MapExpr(:final entries):
          for (final (k, v) in entries) {
            ex(k);
            ex(v);
          }
        case StructExpr(:final fields):
          for (final (_, v) in fields) {
            ex(v);
          }
        case CallExpr(:final callee, :final args):
          ex(callee);
          for (final a in args) {
            ex(a.value);
          }
        case FieldExpr(:final object):
          ex(object);
        case IndexExpr(:final object, :final index):
          ex(object);
          ex(index);
        case BinaryExpr(:final left, :final right):
          ex(left);
          ex(right);
        case UnaryExpr(:final operand):
          ex(operand);
        case PropagateExpr(:final inner):
          ex(inner);
        case RangeExpr(:final start, :final end):
          ex(start);
          ex(end);
        case MatchExpr(:final subject, :final arms):
          ex(subject);
          for (final arm in arms) {
            ex(arm.body);
          }
        case BlockExpr(:final block):
          blk(block);
        case ReturnExpr(:final value):
          if (value != null) ex(value);
        case ThrowExpr(:final value):
          ex(value);
      }
    };

    st = (Stmt s) {
      switch (s) {
        case LetStmt(:final name, :final value, :final isMut):
          ex(value);
          if (isMut) muts.add(name);
        case AssignStmt(:final target, :final value):
          ex(target);
          ex(value);
        case ExprStmt(:final expr):
          ex(expr);
        case ReturnStmt(:final value):
          if (value != null) ex(value);
        case ThrowStmt(:final value):
          ex(value);
        case IfStmt(:final condition, :final then, :final else_):
          ex(condition);
          blk(then);
          if (else_ != null) blk(else_);
        case WhileStmt(:final condition, :final body):
          ex(condition);
          blk(body);
        case ForStmt(:final iterable, :final body):
          ex(iterable);
          blk(body);
      }
    };

    blk(body);
    if (muts.isEmpty || lambdas.isEmpty) return const {};
    final captured = <String>{};
    for (final l in lambdas) {
      captured.addAll(_freeVariables(l));
    }
    return {
      for (final name in muts)
        if (captured.contains(name)) name,
    };
  }

  /// `expr?` — propagate `Err`/`None`. The same lowering serves both `Result`
  /// and `Option` because the failing variant tag is 1 for each (`Err`/`None`)
  /// and the payload to unwrap is field 0 (`Ok`/`Some`).
  void _propagateExpr(PropagateExpr e) {
    _expr(e.inner); // a Result/Option on the stack
    _emit(const Simple(Op.dup));
    _emit(const Simple(Op.enumTag));
    _emit(const ConstInt(_tagErr)); // the failing tag is 1 for Err and None
    _emit(const Simple(Op.eqI64));
    final ok = _newLabel();
    _emitJump(_Jk.ifFalse, ok);
    _emit(const Simple(Op.return_)); // failing: return the value as-is
    _bind(ok);
    _emit(const EnumGet(0)); // success: unwrap the payload
  }

  /// `match` on an enum (`Result`/`Option` or a user enum): store the subject,
  /// then a tag-check chain. The final arm is the fall-through (matches always,
  /// given exhaustiveness), so a value is produced on every path that doesn't
  /// return/throw.
  void _matchExpr(MatchExpr e) {
    final subjectType = _typeOf(e.subject);
    _expr(e.subject);
    final subject = _freshSlot();
    _emit(Store(subject));
    final end = _newLabel();

    for (var i = 0; i < e.arms.length; i++) {
      final arm = e.arms[i];
      final pattern = arm.pattern;
      final isLast = i == e.arms.length - 1;
      final catchAll = pattern is WildcardPattern || pattern is IdentPattern;

      if (isLast || catchAll) {
        _bindArm(pattern, subject, e.span);
        _armBody(arm.body, end, jumpToEnd: false);
        break; // any later arms are unreachable
      }
      if (pattern is! ConstructorPattern) {
        throw CodegenException(
            'unsupported match pattern: ${pattern.runtimeType}', e.span);
      }
      final next = _newLabel();
      _emit(Load(subject));
      _emit(const Simple(Op.enumTag));
      _emit(ConstInt(_variantTag(subjectType, pattern.name, e.span)));
      _emit(const Simple(Op.eqI64));
      _emitJump(_Jk.ifFalse, next);
      _bindArm(pattern, subject, e.span);
      _armBody(arm.body, end, jumpToEnd: true);
      _bind(next);
    }
    _bind(end);
  }

  /// A match arm body either yields a value (and jumps to the merge point) or
  /// transfers control out of the function (`return`/`throw`).
  void _armBody(Expr body, int end, {required bool jumpToEnd}) {
    switch (body) {
      case ReturnExpr(:final value):
        _emitReturn(value);
      case ThrowExpr(:final value):
        _emitThrow(value);
      default:
        _expr(body);
        if (jumpToEnd) _emitJump(_Jk.jump, end);
    }
  }

  /// Bind the variables a pattern introduces, reading payload fields from the
  /// subject in [subjectSlot]. Payload bindings' types come from the inference
  /// pass (`Expr.resolvedType` on their uses), so no type bookkeeping is needed
  /// here.
  void _bindArm(Pattern pattern, int subjectSlot, SourceSpan span) {
    switch (pattern) {
      case ConstructorPattern(:final args):
        for (var k = 0; k < args.length; k++) {
          final arg = args[k];
          switch (arg) {
            case IdentPattern(name: final boundName):
              _emit(Load(subjectSlot));
              _emit(EnumGet(k));
              _emit(Store(_declareLocal(boundName)));
            case WildcardPattern():
              break; // payload field ignored
            default:
              throw CodegenException(
                  'unsupported nested pattern: ${arg.runtimeType}', span);
          }
        }
      case IdentPattern(:final name):
        _slots[name] = subjectSlot; // bind the whole subject
      case WildcardPattern():
        break;
      case LiteralPattern():
        throw CodegenException(
            'literal patterns in match not yet supported', span);
    }
  }

  /// The variant tag for a constructor [name] within an enum of type [enumType],
  /// from the enum registry. Result/Option are ordinary enums and resolve here
  /// too (pinned to ids 0/1 by [_ModuleScope.addEnum]).
  int _variantTag(String? enumType, String name, SourceSpan span) {
    final tag = enumType == null ? -1 : (_enums[enumType]?.tagOf(name) ?? -1);
    if (tag >= 0) return tag;
    throw CodegenException(
        'unknown variant `$name`${enumType == null ? '' : ' on $enumType'}',
        span);
  }

  /// `e.name()` — the variant name, looked up from the enum tag. Synthesized as
  /// a tag-check chain (the last variant is the fall-through).
  void _enumName(Expr receiver, _EnumInfo info) {
    _expr(receiver);
    _emit(const Simple(Op.enumTag));
    final tag = _freshSlot();
    _emit(Store(tag));
    final end = _newLabel();
    for (var i = 0; i < info.variants.length; i++) {
      final name = info.variants[i].name;
      if (i == info.variants.length - 1) {
        _emit(ConstStr(name)); // last variant: fall through
      } else {
        final next = _newLabel();
        _emit(Load(tag));
        _emit(ConstInt(i));
        _emit(const Simple(Op.eqI64));
        _emitJump(_Jk.ifFalse, next);
        _emit(ConstStr(name));
        _emitJump(_Jk.jump, end);
        _bind(next);
      }
    }
    _bind(end);
  }

  void _unaryExpr(UnaryExpr e) {
    _expr(e.operand);
    switch (e.op) {
      case '-':
        _emit(Simple(_isDouble(e.operand) ? Op.negF64 : Op.negI64));
      case '!':
        _emit(const Simple(Op.not));
      default:
        throw CodegenException('unsupported unary operator: ${e.op}', e.span);
    }
  }

  static const _arithmetic = {'+', '-', '*', '/', '%'};
  static const _comparison = {'==', '!=', '<', '<=', '>', '>='};

  void _binaryExpr(BinaryExpr e) {
    if (e.op == '&&' || e.op == '||') {
      _logicalExpr(e);
      return;
    }

    // Operand type is taken from the left; the checker guarantees both sides
    // agree. Lambda parameters are always typed by now (annotation or context,
    // else a checker error), so there's no need to guess from the other side.
    final operandType = _typeOf(e.left);
    final isPrimitive = operandType == 'Int' ||
        operandType == 'Double' ||
        operandType == 'Bool';

    // `==`/`!=`: dispatch to an explicit `impl Eq` when the operand type has
    // one; otherwise the structural `eq` native (the derived default for
    // non-primitives) or a typed opcode (primitives).
    if (e.op == '==' || e.op == '!=') {
      // An Eq-typed value or an `Eq`-bounded type parameter: the concrete type
      // isn't known here, so dispatch dynamically — an explicit `impl Eq` wins
      // at runtime; the structural fallback covers the rest.
      if (_dispatchesVia(operandType, 'eq')) {
        _expr(e.left); // self
        _expr(e.right); // other
        _emit(const CallVirtual('eq', 2));
        if (e.op == '!=') _emit(const Simple(Op.not));
        return;
      }
      final eqIdx = _interfaceMethod(operandType, 'Eq', 'eq');
      if (eqIdx != null) {
        _expr(e.left); // self
        _expr(e.right); // other
        _emit(Call(eqIdx, 2));
        if (e.op == '!=') _emit(const Simple(Op.not));
        return;
      }
      if (!isPrimitive) {
        _expr(e.left);
        _expr(e.right);
        _emit(const CallNative('eq', 2));
        if (e.op == '!=') _emit(const Simple(Op.not));
        return;
      }
    }

    if (!isPrimitive) {
      throw CodegenException(
          'operator `${e.op}` on ${operandType ?? 'unknown type'} '
          'not yet supported',
          e.span);
    }
    final isDouble = operandType == 'Double';

    _expr(e.left);
    _expr(e.right);
    if (_arithmetic.contains(e.op)) {
      _emit(Simple(_arithOp(e.op, isDouble, e.span)));
    } else if (_comparison.contains(e.op)) {
      _emit(Simple(_cmpOp(e.op, isDouble)));
    } else {
      throw CodegenException('unsupported operator: ${e.op}', e.span);
    }
  }

  /// `&&` / `||` short-circuit, so they lower to branches (there is no and/or
  /// opcode). Each leaves exactly one bool on the stack.
  void _logicalExpr(BinaryExpr e) {
    final isAnd = e.op == '&&';
    final shortCircuit = _newLabel();
    final end = _newLabel();

    _expr(e.left);
    // `&&`: if left is false, skip the right and yield false.
    // `||`: if left is true, skip the right and yield true.
    _emitJump(isAnd ? _Jk.ifFalse : _Jk.ifTrue, shortCircuit);
    _expr(e.right);
    _emitJump(_Jk.jump, end);
    _bind(shortCircuit);
    _emit(ConstBool(!isAnd)); // && → false, || → true
    _bind(end);
  }

  Op _arithOp(String op, bool isDouble, SourceSpan span) => switch (op) {
        '+' => isDouble ? Op.addF64 : Op.addI64,
        '-' => isDouble ? Op.subF64 : Op.subI64,
        '*' => isDouble ? Op.mulF64 : Op.mulI64,
        '/' => isDouble ? Op.divF64 : Op.divI64,
        '%' when !isDouble => Op.modI64,
        '%' => throw CodegenException('`%` is not defined for Double', span),
        _ => throw CodegenException('unsupported operator: $op', span),
      };

  Op _cmpOp(String op, bool isDouble) => switch (op) {
        '==' => isDouble ? Op.eqF64 : Op.eqI64,
        '!=' => isDouble ? Op.neF64 : Op.neI64,
        '<' => isDouble ? Op.ltF64 : Op.ltI64,
        '<=' => isDouble ? Op.leF64 : Op.leI64,
        '>' => isDouble ? Op.gtF64 : Op.gtI64,
        '>=' => isDouble ? Op.geF64 : Op.geI64,
        _ => throw CodegenException('unsupported comparison: $op'),
      };

  bool _isDouble(Expr e) => _typeOf(e) == 'Double';

  /// The static type *name* of an expression, for opcode and dispatch selection
  /// (`Int`/`Double`/`Bool`/`String`, a collection/enum/struct name, …). Read
  /// straight from the inference pass's [Expr.resolvedType]; null when that is
  /// absent or unknown.
  String? _typeOf(Expr e) {
    final t = e.resolvedType;
    if (t == null || t is UnknownType) return null;
    return _nameOfType(t);
  }

  /// Map a resolved semantic [Type] to the type-name string codegen keys on.
  /// Null for `Unit` and anything without a usable concrete name.
  static String? _nameOfType(Type t) => switch (t) {
        PrimitiveType(:final primitive) => switch (primitive) {
            Primitive.int_ => 'Int',
            Primitive.double_ => 'Double',
            Primitive.bool_ => 'Bool',
            Primitive.string => 'String',
            Primitive.unit => null,
          },
        InterfaceType(:final element) => element.name,
        TypeParameterType(:final name) => name,
        _ => null,
      };

  /// The interface(s) a method call on a receiver of type-name [name] dispatches
  /// through: [name] itself when it's an interface, or the interface bounds of a
  /// generic parameter named [name]. Null for a concrete receiver (static call).
  List<String>? _dispatchInterfaces(String? name) {
    if (name == null) return null;
    if (_scope.interfaceMethods.containsKey(name)) return [name];
    final bounds = _typeParamBounds[name];
    if (bounds != null) {
      final ifaces = bounds.where(_scope.interfaceMethods.containsKey).toList();
      if (ifaces.isNotEmpty) return ifaces;
    }
    return null;
  }

  /// Whether a value whose static type-name is [type] dispatches [method]
  /// dynamically — i.e. the type is an interface (or a type parameter bounded
  /// by one) that declares [method]. Such a call lowers to `call.virtual`.
  bool _dispatchesVia(String? type, String method) {
    final ifaces = _dispatchInterfaces(type);
    if (ifaces == null) return false;
    return ifaces.any((i) => _scope.interfaceMethods[i]!.contains(method));
  }

  /// The unit index of method [name] on the receiver expression [receiver], or
  /// null if it can't be resolved. A type name — `Type` or `ns.Type`, not a
  /// local — selects a static method; otherwise the receiver's static type does.
  int? _resolveMethod(Expr receiver, String name) {
    final type = _staticTypeName(receiver) ?? _typeOf(receiver);
    return type == null ? null : _methods[type]?[name];
  }

  /// String interpolation: each part becomes a string, then the pieces are
  /// folded together with the binary `str_concat` native. A `${expr}` of a
  /// primitive is converted via `stringify`; Display dispatch for user types
  /// arrives with methods/interfaces.
  void _stringExpr(StringExpr expr) {
    final parts = expr.parts;
    if (parts.isEmpty) {
      _emit(const ConstStr(''));
      return;
    }
    _stringPiece(parts.first, expr.span);
    for (final part in parts.skip(1)) {
      _stringPiece(part, expr.span);
      _emit(const CallNative('str_concat', 2));
    }
  }

  /// Push the argument of `println`/`print`, rendered to a String via its
  /// `Display` impl when it has one (the native can't call a Hawk `display`):
  /// a direct call for a known concrete type, `call.virtual` for an
  /// interface-typed value or a `Display`-bounded type parameter. Without a
  /// Display impl the value is passed as-is — the native renders
  /// primitives/String, matching the prior behavior.
  void _renderForPrint(Expr value) {
    _expr(value);
    final type = _typeOf(value);
    final displayIdx = _interfaceMethod(type, 'Display', 'display');
    if (displayIdx != null) {
      _emit(Call(displayIdx, 1));
    } else if (_dispatchesVia(type, 'display')) {
      _emit(const CallVirtual('display', 1));
    }
  }

  void _stringPiece(StringPart part, SourceSpan span) {
    switch (part) {
      case TextPart(:final text):
        _emit(ConstStr(text));
      case InterpPart(:final expr):
        final type = _typeOf(expr);
        _expr(expr);
        if (type == 'String') {
          // already a string; nothing to convert
        } else if (type == 'Int' || type == 'Double' || type == 'Bool') {
          _emit(const CallNative('stringify', 1));
        } else if (_dispatchesVia(type, 'display')) {
          // An interface-typed value or a `Display`-bounded type parameter:
          // the concrete type isn't known here, so dispatch dynamically.
          _emit(const CallVirtual('display', 1));
        } else {
          // A user type renders via its `Display` impl. The concrete type is
          // known here, so dispatch directly.
          final displayIdx = _interfaceMethod(type, 'Display', 'display');
          if (displayIdx == null) {
            throw CodegenException(
                'cannot interpolate ${type ?? 'value'} — '
                'it does not implement Display',
                span);
          }
          _emit(Call(displayIdx, 1));
        }
    }
  }

  /// `T { f: e, ... }` — push field values in declaration order (which fixes
  /// the field indices the runtime addresses), then allocate the struct.
  void _structExpr(StructExpr expr) {
    final info = structs[expr.typeName];
    if (info == null) {
      throw CodegenException(
          'unknown struct type: ${expr.typeName}', expr.span);
    }
    for (final fieldName in info.fieldNames) {
      final entry = expr.fields.where((f) => f.$1 == fieldName).firstOrNull;
      if (entry == null) {
        throw CodegenException(
            'missing field `$fieldName` in ${expr.typeName} literal',
            expr.span);
      }
      _expr(entry.$2);
    }
    _emit(StructNew(info.index));
  }

  /// Resolve the struct layout of [object] from its static type.
  _StructInfo _structOf(Expr object, SourceSpan span) {
    final typeName = _typeOf(object);
    final info = typeName == null ? null : structs[typeName];
    if (info == null) {
      throw CodegenException(
          'field access on non-struct value (${typeName ?? 'unknown type'})',
          span);
    }
    return info;
  }

  int _fieldIndex(_StructInfo info, String field, SourceSpan span) {
    final idx = info.fieldIndexOf(field);
    if (idx < 0) throw CodegenException('no such field: $field', span);
    return idx;
  }

  /// Emit the faulting `coll[i]` read for a collection already on the stack
  /// (collection then index), chosen from the collection's static type. `List`
  /// uses the dedicated `list.get` opcode (a primitive the JIT can lower
  /// inline); `Map` is a keyed lookup, so it stays a native call.
  void _emitIndexGet(Expr object, SourceSpan span) {
    switch (_typeOf(object)) {
      case 'List':
        _emit(const Simple(Op.listGet));
      case 'Map':
        _emit(const CallNative('map_index', 2));
      default:
        throw CodegenException(
            'indexing on ${_typeOf(object) ?? 'unknown type'} is not supported',
            span);
    }
  }

  void _callExpr(CallExpr expr) {
    final callee = expr.callee;
    if (callee is FieldExpr) {
      _methodCall(expr, callee);
      return;
    }
    if (callee is! IdentExpr) {
      throw CodegenException(
          'unsupported call target: ${callee.runtimeType}', expr.span);
    }
    final name = callee.name;

    // A call through a function value held in a local — a let-bound lambda or a
    // function-typed parameter. A local shadows a same-named function, so this
    // is checked first. Push the closure, then the (positional) arguments, and
    // dispatch indirectly.
    if (_slots.containsKey(name)) {
      _loadLocalValue(name, expr.span); // the closure value (unboxed if boxed)
      for (final arg in expr.args) {
        _expr(arg.value);
      }
      _emit(CallIndirect(expr.args.length));
      return;
    }

    final fnIndex = functionIndex[name];
    if (fnIndex != null) {
      final ordered =
          _resolveArgs(_units[fnIndex].params, expr.args, expr.span);
      for (final value in ordered) {
        _expr(value);
      }
      _emit(Call(fnIndex, ordered.length));
      return;
    }
    final nativeFn = _scope.nativeFns[name];
    if (nativeFn != null) {
      // `println`/`print` render their argument via `Display`. A native can't
      // call back into a Hawk `display` method, so for a user type the
      // front-end renders it here (the concrete type is known) and hands the
      // resulting String to the native. Primitives/String render in the native.
      if ((nativeFn == 'println' || nativeFn == 'print') &&
          expr.args.length == 1) {
        _renderForPrint(expr.args.single.value);
        _emit(CallNative(nativeFn, 1));
        return;
      }
      for (final arg in expr.args) {
        _expr(arg.value);
      }
      _emit(CallNative(nativeFn, expr.args.length));
      return;
    }
    throw CodegenException('unknown function: $name', expr.span);
  }

  /// `recv.method(args)` / `Type.method(args)`. For an instance method the
  /// receiver is pushed first as `self`; arguments follow in parameter order.
  void _methodCall(CallExpr expr, FieldExpr callee) {
    // Enum payload constructor: `Shape.Circle(5)`.
    final variant = _enumVariant(callee.object, callee.field);
    if (variant != null) {
      final (info, tag) = variant;
      for (final arg in expr.args) {
        _expr(arg.value);
      }
      _emit(EnumNew(info.ty, tag, expr.args.length));
      return;
    }

    // `e.name()` on an enum value → the variant name (synthesized from its tag).
    if (callee.field == 'name' && expr.args.isEmpty) {
      final info = _enums[_typeOf(callee.object)];
      if (info != null) {
        _enumName(callee.object, info);
        return;
      }
    }

    // Namespace-qualified native function (`fs.read_text(...)`) → a runtime
    // native, no receiver.
    if (callee.object is IdentExpr &&
        _isNamespace((callee.object as IdentExpr).name)) {
      final native = _scope.nativeFns[callee.field];
      if (native != null) {
        for (final arg in expr.args) {
          _expr(arg.value);
        }
        _emit(CallNative(native, expr.args.length));
        return;
      }
    }

    // Instance `native fn` declared in an `impl` block (`@extern`): the receiver
    // is pushed as the native's first argument. This is how the built-in methods
    // on String/List/Map/Option are backed — they are ordinary `native fn`s in
    // std.core, not a hardcoded table.
    final instanceNative =
        _scope.nativeInstanceMethods[_typeOf(callee.object)]?[callee.field];
    if (instanceNative != null) {
      _expr(callee.object);
      for (final arg in expr.args) {
        _expr(arg.value);
      }
      _emit(CallNative(instanceNative, expr.args.length + 1));
      return;
    }

    // Namespace-qualified free function: `ns.fn(...)` → a direct call (the
    // imported function is a unit in the flat table).
    if (callee.object is IdentExpr &&
        _isNamespace((callee.object as IdentExpr).name)) {
      final fnIdx = functionIndex[callee.field];
      if (fnIdx != null) {
        final ordered =
            _resolveArgs(_units[fnIdx].params, expr.args, expr.span);
        for (final value in ordered) {
          _expr(value);
        }
        _emit(Call(fnIdx, ordered.length));
        return;
      }
    }

    // Static native method on a type: `String.from_chars(...)` → a runtime
    // native, no receiver.
    final staticType = _staticTypeName(callee.object);
    if (staticType != null) {
      final native = _scope.nativeStaticMethods[staticType]?[callee.field];
      if (native != null) {
        for (final arg in expr.args) {
          _expr(arg.value);
        }
        _emit(CallNative(native, expr.args.length));
        return;
      }
    }

    // Dynamic dispatch: the receiver is interface-typed (`x: Display`) or a
    // generic parameter bound by an interface (`x: T` where `T: Display`). The
    // concrete type isn't known here, so dispatch on the runtime type id. The
    // receiver is pushed first (self), then the arguments. Only the interface's
    // own methods are callable through it.
    final recvTypeName = _typeOf(callee.object);
    final dispatchIfaces = _dispatchInterfaces(recvTypeName);
    if (dispatchIfaces != null) {
      final declares = dispatchIfaces
          .any((i) => _scope.interfaceMethods[i]!.contains(callee.field));
      if (!declares) {
        throw CodegenException(
            'no method "${callee.field}" on $recvTypeName', expr.span);
      }
      _expr(callee.object);
      for (final arg in expr.args) {
        _expr(arg.value);
      }
      _emit(CallVirtual(callee.field, expr.args.length + 1));
      return;
    }

    final idx = _resolveMethod(callee.object, callee.field);
    if (idx == null) {
      // A function-valued field invoked like a method: `c.now()` where `now` is
      // a struct field holding a closure (and no method of that name exists).
      // Push the field's value, then the arguments, and dispatch indirectly.
      final objType = _typeOf(callee.object);
      final structInfo = objType == null ? null : structs[objType];
      if (structInfo != null && structInfo.fieldIndexOf(callee.field) >= 0) {
        _expr(callee.object);
        _emit(FieldGet(structInfo.fieldIndexOf(callee.field)));
        for (final arg in expr.args) {
          _expr(arg.value);
        }
        _emit(CallIndirect(expr.args.length));
        return;
      }
      throw CodegenException(
          'no method "${callee.field}" on '
          '${_typeOf(callee.object) ?? 'unknown type'}',
          expr.span);
    }
    final decl = _units[idx];
    final isStatic = _scope.unitSelfTypes[idx] == null;
    if (!isStatic) {
      _expr(callee.object); // self → local slot 0 of the callee
    }
    final ordered = _resolveArgs(decl.params, expr.args, expr.span);
    for (final value in ordered) {
      _expr(value);
    }
    _emit(Call(idx, ordered.length + (isStatic ? 0 : 1)));
  }

  /// Match call arguments to a callee's (non-`self`) parameters, returning the
  /// value expressions in parameter order — applying named-argument resolution
  /// and default values, mirroring the interpreter's `_callFn`.
  List<Expr> _resolveArgs(
      List<Param> params, List<CallArg> callArgs, SourceSpan span) {
    final positional = [
      for (final a in callArgs)
        if (a.label == null) a.value,
    ];
    final named = {
      for (final a in callArgs)
        if (a.label != null) a.label!: a.value,
    };

    final ordered = <Expr>[];
    var pi = 0;
    for (final p in params.where((p) => !p.isSelf)) {
      final Expr? value;
      if (p.label == null) {
        // Suppressed external label (`_`): positional only.
        value = pi < positional.length ? positional[pi++] : p.defaultValue;
      } else {
        // Named param: by label, else positionally if label == name.
        value = named[p.label] ??
            ((pi < positional.length && p.label == p.name)
                ? positional[pi++]
                : p.defaultValue);
      }
      if (value == null) {
        throw CodegenException(
            'missing argument for parameter `${p.name}`', span);
      }
      ordered.add(value);
    }
    return ordered;
  }
}
