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
  int _localCount = 0;
  int _paramCount = 0;

  _FnCompiler(this.functionIndex);

  FuncDef compile(FnDecl fn) {
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
    return FuncDef(fn.name, _paramCount, _localCount, _code);
  }

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
      case CallExpr():
        _callExpr(expr);
      default:
        throw CodegenException(
            'unsupported expression: ${expr.runtimeType}', expr.span);
    }
  }

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
