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

/// Runtime natives callable directly by name. The front-end emits a
/// `call.native` (resolved to an index by the runtime at load); the set grows
/// as the stdlib surface does.
const Set<String> _natives = {'println', 'print'};

// Well-known enum type ids and variant tags, fixed by convention and shared
// with the runtime (runtime/src/value.rs). Result and Option are not in the
// type table — `enum.new` carries its field count inline.
const int _tyResult = 0;
const int _tyOption = 1;
const int _tagOk = 0;
const int _tagErr = 1;
const int _tagSome = 0;
const int _tagNone = 1;

/// Compile a whole program to a module.
Module compileProgram(Program program) {
  // Index every (non-native) function up front, so direct calls can resolve a
  // callee to its table index regardless of declaration order. Return types are
  // recorded too, so a call expression's static type is known for opcode
  // selection on its result.
  final functionIndex = <String, int>{};
  final functionReturns = <String, String?>{};
  final fns = <FnDecl>[];

  // Struct declarations populate the module's type table; their index in that
  // table is the type id used by `struct.new`.
  final structs = <String, _StructInfo>{};
  final types = <TypeDef>[];

  for (final decl in program.decls) {
    if (decl is FnDecl && !decl.isNative) {
      functionIndex[decl.name] = fns.length;
      functionReturns[decl.name] = _typeRefName(decl.returnType);
      fns.add(decl);
    } else if (decl is TypeDecl) {
      final fieldNames = [for (final f in decl.fields) f.$1];
      final fieldTypes = {
        for (final f in decl.fields) f.$1: _typeRefName(f.$2),
      };
      structs[decl.name] = _StructInfo(types.length, fieldNames, fieldTypes);
      types.add(TypeDef(decl.name, fieldNames.length));
    }
  }

  final functions = [
    for (final fn in fns)
      _FnCompiler(functionIndex, functionReturns, structs).compile(fn),
  ];
  return Module(functions, types: types);
}

/// The name of a type reference (`Int`, `Double`, …), or null.
String? _typeRefName(TypeRef? type) => type is NamedType ? type.name : null;

/// Layout of a struct type: its index in the module type table, its field
/// names in declaration order (which fixes the field indices), and each
/// field's type name.
class _StructInfo {
  final int index;
  final List<String> fieldNames;
  final Map<String, String?> fieldTypes;
  _StructInfo(this.index, this.fieldNames, this.fieldTypes);

  int fieldIndexOf(String name) => fieldNames.indexOf(name);
}

/// Compiles one function: tracks local slots and emits its instruction stream.
class _FnCompiler {
  final Map<String, int> functionIndex;
  final Map<String, String?> functionReturns;
  final Map<String, _StructInfo> structs;
  final List<Instr> _code = [];
  final Map<String, int> _slots = {};
  // Static type (by name) of each local, used to pick typed opcodes. Until the
  // checker annotates the AST, codegen derives these from declarations and a
  // bottom-up [_typeOf]; this is the seam where checker-provided types will
  // later plug in.
  final Map<String, String?> _localTypes = {};
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

  _FnCompiler(this.functionIndex, this.functionReturns, this.structs);

  FuncDef compile(FnDecl fn) {
    _returnsResult = _typeRefName(fn.returnType) == 'Result';
    for (final p in fn.params) {
      _declareLocal(p.name);
      _localTypes[p.name] = _typeName(p.type);
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
    return FuncDef(fn.name, _paramCount, _localCount, _code);
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

  // --- Statements ---

  void _block(Block block) {
    for (final stmt in block.stmts) {
      _stmt(stmt);
    }
  }

  void _stmt(Stmt stmt) {
    switch (stmt) {
      case LetStmt(:final name, :final type, :final value):
        // Evaluate the initializer before declaring the binding, so the
        // initializer can't see the (not-yet-bound) name.
        _expr(value);
        final slot = _declareLocal(name);
        _localTypes[name] = type != null ? _typeName(type) : _typeOf(value);
        _emit(Store(slot));
      case AssignStmt(:final target, :final value):
        switch (target) {
          case IdentExpr(:final name):
            final slot = _slots[name];
            if (slot == null) {
              throw CodegenException(
                  'assignment to unknown local: $name', stmt.span);
            }
            _expr(value);
            _emit(Store(slot));
          case FieldExpr(:final object, :final field):
            // field.set pops the value then the receiver: push receiver first.
            final info = _structOf(object, stmt.span);
            _expr(object);
            _expr(value);
            _emit(FieldSet(_fieldIndex(info, field, stmt.span)));
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

  /// `for x in start..end` lowers to a counter loop (end exclusive, evaluated
  /// once). Only range iteration is supported for now; iterating collections
  /// arrives with the iterator protocol.
  void _forStmt(Pattern pattern, Expr iterable, Block body) {
    if (iterable is! RangeExpr) {
      throw CodegenException(
          'only range iteration (a..b) is supported', iterable.span);
    }
    final varName = switch (pattern) {
      IdentPattern(:final name) => name,
      WildcardPattern() => null,
      _ => throw CodegenException(
          'unsupported for-loop pattern: ${pattern.runtimeType}',
          iterable.span),
    };

    // counter = start
    _expr(iterable.start);
    final counter = varName != null ? _declareLocal(varName) : _freshSlot();
    if (varName != null) _localTypes[varName] = 'Int';
    _emit(Store(counter));
    // limit = end (evaluated once, into a hidden slot)
    _expr(iterable.end);
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
    // counter += 1
    _emit(Load(counter));
    _emit(const ConstInt(1));
    _emit(const Simple(Op.addI64));
    _emit(Store(counter));
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
      case StringExpr():
        _stringExpr(expr);
      case IdentExpr(:final name):
        if (name == 'None') {
          _emit(const EnumNew(_tyOption, _tagNone, 0));
          break;
        }
        final slot = _slots[name];
        if (slot == null) {
          throw CodegenException('not a local variable: $name', expr.span);
        }
        _emit(Load(slot));
      case UnaryExpr():
        _unaryExpr(expr);
      case BinaryExpr():
        _binaryExpr(expr);
      case StructExpr():
        _structExpr(expr);
      case FieldExpr(:final object, :final field):
        final info = _structOf(object, expr.span);
        _expr(object);
        _emit(FieldGet(_fieldIndex(info, field, expr.span)));
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
      default:
        throw CodegenException(
            'unsupported expression: ${expr.runtimeType}', expr.span);
    }
  }

  /// `expr?` — propagate `Err`/`None`. The same lowering serves both `Result`
  /// and `Option` because the failing variant tag is 1 for each (`Err`/`None`)
  /// and the payload to unwrap is field 0 (`Ok`/`Some`).
  void _propagateExpr(PropagateExpr e) {
    _expr(e.inner); // a Result/Option on the stack
    _emit(const Simple(Op.dup));
    _emit(const Simple(Op.enumTag));
    _emit(const ConstInt(_tagErr)); // == _tagNone
    _emit(const Simple(Op.eqI64));
    final ok = _newLabel();
    _emitJump(_Jk.ifFalse, ok);
    _emit(const Simple(Op.return_)); // failing: return the value as-is
    _bind(ok);
    _emit(const EnumGet(0)); // success: unwrap the payload
  }

  /// `match` on a `Result`/`Option`: store the subject, then a tag-check chain.
  /// The final arm is the fall-through (matches always, given exhaustiveness),
  /// so a value is produced on every path that doesn't return/throw.
  void _matchExpr(MatchExpr e) {
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
      _emit(ConstInt(_variantTag(pattern.name, e.span)));
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
  /// subject in [subjectSlot].
  void _bindArm(Pattern pattern, int subjectSlot, SourceSpan span) {
    switch (pattern) {
      case ConstructorPattern(:final args):
        for (var k = 0; k < args.length; k++) {
          final arg = args[k];
          switch (arg) {
            case IdentPattern(:final name):
              _emit(Load(subjectSlot));
              _emit(EnumGet(k));
              _emit(Store(_declareLocal(name)));
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

  /// The fixed variant tag for a `Result`/`Option` constructor name.
  int _variantTag(String name, SourceSpan span) => switch (name) {
        'Ok' || 'Some' => 0,
        'Err' || 'None' => 1,
        _ => throw CodegenException(
            'unknown variant `$name` (user-defined enums not yet supported)',
            span),
      };

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
    // agree. Equality/ordering on non-primitives dispatches to `Eq` — deferred.
    final operandType = _typeOf(e.left);
    if (operandType != 'Int' && operandType != 'Double' && operandType != 'Bool') {
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

  /// Best-effort static type name of an expression, for opcode selection.
  String? _typeOf(Expr e) => switch (e) {
        IntLiteral() => 'Int',
        FloatLiteral() => 'Double',
        BoolLiteral() => 'Bool',
        StringExpr() => 'String',
        IdentExpr(:final name) => name == 'None' ? 'Option' : _localTypes[name],
        UnaryExpr(:final op, :final operand) =>
          op == '!' ? 'Bool' : _typeOf(operand),
        BinaryExpr(:final op, :final left) =>
          (_comparison.contains(op) || op == '&&' || op == '||')
              ? 'Bool'
              : _typeOf(left),
        CallExpr(:final callee) when callee is IdentExpr => switch (callee.name) {
          'Ok' || 'Err' => 'Result',
          'Some' => 'Option',
          _ => _returnTypeOf(callee.name),
        },
        StructExpr(:final typeName) => typeName,
        FieldExpr(:final object, :final field) =>
          structs[_typeOf(object)]?.fieldTypes[field],
        _ => null,
      };

  /// The (typeId, variantTag) for a `Result`/`Option` constructor, or null if
  /// [name] is not one.
  (int, int)? _enumCtor(String name) => switch (name) {
        'Ok' => (_tyResult, _tagOk),
        'Err' => (_tyResult, _tagErr),
        'Some' => (_tyOption, _tagSome),
        _ => null,
      };

  /// Static result type of calling [name] — a user function's declared return
  /// type, or a known native's.
  String? _returnTypeOf(String name) {
    if (functionReturns.containsKey(name)) return functionReturns[name];
    return switch (name) {
      'stringify' || 'str_concat' => 'String',
      _ => null, // println/print → Unit (no usable value type)
    };
  }

  String? _typeName(TypeRef? type) => _typeRefName(type);

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

  void _stringPiece(StringPart part, SourceSpan span) {
    switch (part) {
      case TextPart(:final text):
        _emit(ConstStr(text));
      case InterpPart(:final expr):
        _expr(expr);
        final type = _typeOf(expr);
        if (type == 'String') {
          // already a string; nothing to convert
        } else if (type == 'Int' || type == 'Double' || type == 'Bool') {
          _emit(const CallNative('stringify', 1));
        } else {
          throw CodegenException(
              'cannot interpolate ${type ?? 'value'} '
              '(Display dispatch not yet supported)',
              span);
        }
    }
  }

  /// `T { f: e, ... }` — push field values in declaration order (which fixes
  /// the field indices the runtime addresses), then allocate the struct.
  void _structExpr(StructExpr expr) {
    final info = structs[expr.typeName];
    if (info == null) {
      throw CodegenException('unknown struct type: ${expr.typeName}', expr.span);
    }
    for (final fieldName in info.fieldNames) {
      final entry =
          expr.fields.where((f) => f.$1 == fieldName).firstOrNull;
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

  void _callExpr(CallExpr expr) {
    final callee = expr.callee;
    if (callee is! IdentExpr) {
      throw CodegenException(
          'unsupported call target: ${callee.runtimeType}', expr.span);
    }
    final name = callee.name;

    // Result/Option constructors build an enum from their single payload.
    final ctor = _enumCtor(name);
    if (ctor != null) {
      if (expr.args.length != 1) {
        throw CodegenException('$name expects one argument', expr.span);
      }
      _expr(expr.args.single.value);
      _emit(EnumNew(ctor.$1, ctor.$2, 1));
      return;
    }

    // Arguments are pushed left-to-right; the bytecode is positional (named
    // arguments are resolved to positions by the checker).
    for (final arg in expr.args) {
      _expr(arg.value);
    }
    final fnIndex = functionIndex[name];
    if (fnIndex != null) {
      _emit(Call(fnIndex, expr.args.length));
    } else if (_natives.contains(name)) {
      _emit(CallNative(name, expr.args.length));
    } else {
      throw CodegenException('unknown function: $name', expr.span);
    }
  }
}
