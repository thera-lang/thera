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

/// Compile a whole program to a module.
Module compileProgram(Program program) {
  // Index every (non-native) function up front, so direct calls can resolve a
  // callee to its table index regardless of declaration order.
  final functionIndex = <String, int>{};
  final fns = <FnDecl>[];
  for (final decl in program.decls) {
    if (decl is FnDecl && !decl.isNative) {
      functionIndex[decl.name] = fns.length;
      fns.add(decl);
    }
  }

  final functions = [
    for (final fn in fns) _FnCompiler(functionIndex).compile(fn),
  ];
  return Module(functions);
}

/// Compiles one function: tracks local slots and emits its instruction stream.
class _FnCompiler {
  final Map<String, int> functionIndex;
  final List<Instr> _code = [];
  final Map<String, int> _slots = {};
  // Static type (by name) of each local, used to pick typed opcodes. Until the
  // checker annotates the AST, codegen derives these from declarations and a
  // bottom-up [_typeOf]; this is the seam where checker-provided types will
  // later plug in.
  final Map<String, String?> _localTypes = {};
  int _localCount = 0;
  int _paramCount = 0;

  // Jump targets are absolute instruction indices, but a forward jump is
  // emitted before its target is known. We emit a placeholder, record a fixup,
  // and backpatch once all labels are bound — the same scheme as the runtime's
  // FnBuilder.
  final List<int?> _labels = []; // label id -> bound instruction index
  final List<_Fixup> _fixups = [];

  _FnCompiler(this.functionIndex);

  FuncDef compile(FnDecl fn) {
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
        if (target is! IdentExpr) {
          throw CodegenException(
              'unsupported assignment target: ${target.runtimeType}',
              stmt.span);
        }
        final slot = _slots[target.name];
        if (slot == null) {
          throw CodegenException(
              'assignment to unknown local: ${target.name}', stmt.span);
        }
        _expr(value);
        _emit(Store(slot));
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
        if (value != null) {
          _expr(value);
        } else {
          _emit(const Simple(Op.constUnit));
        }
        _emit(const Simple(Op.return_));
      case ExprStmt(:final expr):
        // The result of an expression statement is discarded; every expression
        // leaves exactly one slot on the stack, so pop it.
        _expr(expr);
        _emit(const Simple(Op.pop));
      default:
        throw CodegenException(
            'unsupported statement: ${stmt.runtimeType}', stmt.span);
    }
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
        final slot = _slots[name];
        if (slot == null) {
          throw CodegenException('not a local variable: $name', expr.span);
        }
        _emit(Load(slot));
      case UnaryExpr():
        _unaryExpr(expr);
      case BinaryExpr():
        _binaryExpr(expr);
      case CallExpr():
        _callExpr(expr);
      default:
        throw CodegenException(
            'unsupported expression: ${expr.runtimeType}', expr.span);
    }
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
        IdentExpr(:final name) => _localTypes[name],
        UnaryExpr(:final op, :final operand) =>
          op == '!' ? 'Bool' : _typeOf(operand),
        BinaryExpr(:final op, :final left) =>
          (_comparison.contains(op) || op == '&&' || op == '||')
              ? 'Bool'
              : _typeOf(left),
        _ => null,
      };

  /// The name of a type reference (`Int`, `Double`, …), or null.
  String? _typeName(TypeRef? type) =>
      type is NamedType ? type.name : null;

  void _stringExpr(StringExpr expr) {
    // Interpolation lowering arrives with native string ops; for now only
    // plain text literals are supported.
    final buf = StringBuffer();
    for (final part in expr.parts) {
      if (part is TextPart) {
        buf.write(part.text);
      } else {
        throw CodegenException(
            'string interpolation not yet supported', expr.span);
      }
    }
    _emit(ConstStr(buf.toString()));
  }

  void _callExpr(CallExpr expr) {
    final callee = expr.callee;
    if (callee is! IdentExpr) {
      throw CodegenException(
          'unsupported call target: ${callee.runtimeType}', expr.span);
    }
    final name = callee.name;
    for (final arg in expr.args) {
      _expr(arg.value);
    }
    if (_natives.contains(name)) {
      _emit(CallNative(name, expr.args.length));
    } else {
      throw CodegenException('unknown function: $name', expr.span);
    }
  }
}
