import '../ast.dart';
import '../token.dart';

class CheckError {
  final String message;
  final SourceSpan span;
  CheckError(this.message, this.span);

  @override
  String toString() => '$span: $message';

  String format(String filePath) => '$filePath:$span: $message';
}

class CheckResult {
  final List<CheckError> errors;
  CheckResult(this.errors);
  bool get hasErrors => errors.isNotEmpty;
}

typedef _Scope = Map<String, TypeRef?>;

/// Type-checks an Aero [Program].
///
/// Call [addProgram] to pre-register symbols from imported files (their
/// declarations become visible but are not themselves checked). Then call
/// [check] on the primary program.
class TypeChecker {
  // Types that are always in scope (no import required).
  static const _builtinTypes = <String>{
    'Int', 'Bool', 'Double', 'Float', 'String', 'Void',
    'List', 'Map', 'Set',
    'Result', 'Option',
    'Args', 'Error', 'Self',
  };

  // Value-level names that are always in scope.
  static const _builtinValues = <String>{
    'println', 'print', 'eprintln',
    'Ok', 'Err', 'Some', 'None',
  };

  final _typeDecls = <String, TypeDecl>{};
  final _fnDecls = <String, FnDecl>{};
  final _implMethods = <String, Map<String, FnDecl>>{};
  final _moduleNames = <String>{};
  final _constNames = <String>{};
  final _errors = <CheckError>[];

  // ---- public API ----

  /// Pre-register symbols from an imported [program]. Its declarations become
  /// visible to [check] but are not themselves checked for errors.
  void addProgram(Program program) => _collectSymbols(program);

  /// Register a stdlib module alias (e.g. 'fs' from `import std.fs`).
  void addModule(String name) => _moduleNames.add(name);

  CheckResult check(Program program) {
    _errors.clear();
    _collectSymbols(program);
    _checkProgram(program);
    return CheckResult(List.unmodifiable(_errors));
  }

  // ---- symbol collection ----

  void _collectSymbols(Program program) {
    for (final decl in program.decls) {
      switch (decl) {
        case FnDecl():
          _fnDecls[decl.name] = decl;
        case TypeDecl():
          _typeDecls[decl.name] = decl;
        case ImplDecl():
          _implMethods.putIfAbsent(decl.typeName, () => {});
          for (final m in decl.methods) {
            _implMethods[decl.typeName]![m.name] = m;
          }
        case ImportDecl():
          // Register the module alias so `fs.read_text(...)` resolves `fs`.
          _moduleNames.add(decl.alias ?? decl.path.split('.').last);
        case InterfaceDecl():
          break;
        case ConstDecl():
          _constNames.add(decl.name);
      }
    }
  }

  // ---- declaration checking ----

  void _checkProgram(Program program) {
    for (final decl in program.decls) {
      switch (decl) {
        case FnDecl():
          _checkFn(decl);
        case TypeDecl():
          _checkTypeDecl(decl);
        case ImplDecl():
          final selfType = NamedType(decl.typeName);
          for (final m in decl.methods) {
            _checkFn(m, selfType: selfType);
          }
        case InterfaceDecl():
          for (final m in decl.methods) {
            _checkFnSig(m);
          }
        case ImportDecl():
          break;
        case ConstDecl(:final type, :final value):
          if (type != null) _checkTypeRef(type, decl.span);
          _checkExpr(value, {});
      }
    }
  }

  void _checkTypeDecl(TypeDecl decl) {
    for (final (_, fieldType) in decl.fields) {
      _checkTypeRef(fieldType, decl.span);
    }
  }

  void _checkFn(FnDecl fn, {TypeRef? selfType}) {
    _checkFnSig(fn);
    if (fn.body == null) return;

    final scope = <String, TypeRef?>{};
    for (final p in fn.params) {
      if (p.isSelf) {
        if (selfType != null) scope['self'] = selfType;
      } else {
        scope[p.name] = p.type;
      }
    }
    _checkBlock(fn.body!, scope, returnType: fn.returnType);
  }

  void _checkFnSig(FnDecl fn) {
    for (final p in fn.params) {
      if (p.type != null) _checkTypeRef(p.type!, fn.span);
    }
    if (fn.returnType != null) _checkTypeRef(fn.returnType!, fn.span);
  }

  // ---- block / statement checking ----

  void _checkBlock(Block block, _Scope outer, {TypeRef? returnType}) {
    final scope = _Scope.from(outer);
    for (final stmt in block.stmts) {
      _checkStmt(stmt, scope, returnType: returnType);
    }
  }

  void _checkStmt(Stmt stmt, _Scope scope, {TypeRef? returnType}) {
    switch (stmt) {
      case LetStmt(:final name, :final type, :final value):
        if (type != null) _checkTypeRef(type, stmt.span);
        _checkExpr(value, scope, returnType: returnType);
        scope[name] = type ?? _inferType(value, scope);

      case ReturnStmt(:final value):
        if (value != null) _checkExpr(value, scope, returnType: returnType);

      case AssignStmt(:final target, :final value):
        _checkExpr(target, scope);
        _checkExpr(value, scope, returnType: returnType);

      case ExprStmt(:final expr):
        _checkExpr(expr, scope, returnType: returnType);

      case IfStmt(:final condition, :final then, :final else_):
        _checkExpr(condition, scope);
        _checkBlock(then, scope, returnType: returnType);
        if (else_ != null) _checkBlock(else_, scope, returnType: returnType);

      case ForStmt(:final pattern, :final iterable, :final body):
        _checkExpr(iterable, scope);
        final bodyScope = _Scope.from(scope);
        _bindPattern(pattern, null, bodyScope);
        _checkBlock(body, bodyScope, returnType: returnType);

      case WhileStmt(:final condition, :final body):
        _checkExpr(condition, scope);
        _checkBlock(body, scope, returnType: returnType);

      case ThrowStmt(:final value):
        _checkExpr(value, scope, returnType: returnType);
    }
  }

  // ---- expression checking ----

  void _checkExpr(Expr expr, _Scope scope, {TypeRef? returnType}) {
    switch (expr) {
      case IdentExpr(:final name, :final span):
        if (!_isDefinedName(name, scope)) {
          _error('undefined name: $name', span);
        }

      case CallExpr(:final callee, :final args, :final span):
        _checkExpr(callee, scope);
        for (final a in args) {
          _checkExpr(a.value, scope);
        }
        if (callee is IdentExpr) {
          final fn = _fnDecls[callee.name];
          if (fn != null) _checkCallArgs(fn, args, span);
        }

      case FieldExpr(:final object):
        _checkExpr(object, scope);

      case IndexExpr(:final object, :final index):
        _checkExpr(object, scope);
        _checkExpr(index, scope);

      case BinaryExpr(:final left, :final right):
        _checkExpr(left, scope);
        _checkExpr(right, scope);

      case UnaryExpr(:final operand):
        _checkExpr(operand, scope);

      case PropagateExpr(:final inner):
        _checkExpr(inner, scope);

      case RangeExpr(:final start, :final end):
        _checkExpr(start, scope);
        _checkExpr(end, scope);

      case ListExpr(:final items):
        for (final item in items) _checkExpr(item, scope);

      case MapExpr(:final entries):
        for (final (k, v) in entries) {
          _checkExpr(k, scope);
          _checkExpr(v, scope);
        }

      case StructExpr(:final typeName, :final fields, :final span):
        final typeDecl = _typeDecls[typeName];
        if (typeDecl != null) {
          final validFields = {for (final f in typeDecl.fields) f.$1};
          for (final (fieldName, fieldValue) in fields) {
            if (!validFields.contains(fieldName)) {
              _error('unknown field "$fieldName" on type $typeName', span);
            }
            _checkExpr(fieldValue, scope);
          }
        } else {
          for (final (_, v) in fields) _checkExpr(v, scope);
        }

      case StringExpr(:final parts):
        for (final part in parts) {
          if (part is InterpPart) _checkExpr(part.expr, scope);
        }

      case MatchExpr(:final subject, :final arms):
        _checkExpr(subject, scope);
        for (final arm in arms) {
          final armScope = _Scope.from(scope);
          _bindPattern(arm.pattern, null, armScope);
          _checkExpr(arm.body, armScope, returnType: returnType);
        }

      case LambdaExpr(:final params, :final body):
        final lambdaScope = _Scope.from(scope);
        for (final p in params) lambdaScope[p] = null;
        _checkExpr(body, lambdaScope);

      case BlockExpr(:final block):
        _checkBlock(block, scope, returnType: returnType);

      case ReturnExpr(:final value):
        if (value != null) _checkExpr(value, scope, returnType: returnType);

      case ThrowExpr(:final value):
        _checkExpr(value, scope, returnType: returnType);

      case IntLiteral() || FloatLiteral() || BoolLiteral():
        break;
    }
  }

  // ---- call checking ----

  void _checkCallArgs(FnDecl fn, List<CallArg> args, SourceSpan span) {
    final params = fn.params.where((p) => !p.isSelf).toList();

    // Check that every named argument label is a declared parameter label.
    final validLabels = {
      for (final p in params)
        if (p.label != null) p.label!
    };
    for (final arg in args) {
      if (arg.label != null && !validLabels.contains(arg.label)) {
        _error(
          'unknown argument label "${arg.label}" for "${fn.name}"',
          span,
        );
        return;
      }
    }

    // Check argument count against [required, max] range.
    final required = params.where((p) => p.defaultValue == null).length;
    final max = params.length;
    if (args.length < required || args.length > max) {
      final range = required == max ? '$required' : '$required–$max';
      _error(
        '"${fn.name}" expects $range argument${required == 1 && max == 1 ? '' : 's'}'
        ', got ${args.length}',
        span,
      );
    }
  }

  // ---- type reference checking ----

  void _checkTypeRef(TypeRef typeRef, SourceSpan fallback) {
    switch (typeRef) {
      case NamedType(:final name, :final args, :final span):
        final errorSpan = span ?? fallback;
        if (!_builtinTypes.contains(name) && !_typeDecls.containsKey(name)) {
          _error('unknown type: $name', errorSpan);
        }
        for (final arg in args) _checkTypeRef(arg, fallback);
      case VoidType():
        break;
    }
  }

  // ---- helpers ----

  bool _isDefinedName(String name, _Scope scope) =>
      scope.containsKey(name) ||
      _builtinValues.contains(name) ||
      _fnDecls.containsKey(name) ||
      _moduleNames.contains(name) ||
      _constNames.contains(name);

  TypeRef? _inferType(Expr expr, _Scope scope) => switch (expr) {
        IntLiteral() => NamedType('Int'),
        FloatLiteral() => NamedType('Double'),
        BoolLiteral() => NamedType('Bool'),
        StringExpr() => NamedType('String'),
        IdentExpr(:final name) => scope[name],
        CallExpr(:final callee) when callee is IdentExpr =>
          _fnDecls[callee.name]?.returnType,
        _ => null,
      };

  void _bindPattern(Pattern pattern, TypeRef? type, _Scope scope) {
    switch (pattern) {
      case IdentPattern(:final name):
        scope[name] = type;
      case ConstructorPattern(:final args):
        for (final a in args) _bindPattern(a, null, scope);
      case WildcardPattern() || LiteralPattern():
        break;
    }
  }

  void _error(String message, SourceSpan span) =>
      _errors.add(CheckError(message, span));
}
