import '../ast.dart';
import '../element/inference.dart';
import '../element/resolver.dart';
import '../element/types.dart';
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

/// Type-checks a Hawk [Program].
///
/// Call [addProgram] to pre-register symbols from imported files (their
/// declarations become visible but are not themselves checked). Then call
/// [check] on the primary program.
class TypeChecker {
  // Value-level names that are always in scope.
  static const _builtinValues = <String>{
    'println',
    'print',
    'eprintln',
    'Ok',
    'Err',
    'Some',
    'None',
  };

  final _typeDecls = <String, TypeDecl>{};
  final _enumDecls = <String, EnumDecl>{};
  final _fnDecls = <String, FnDecl>{};
  final _moduleNames = <String>{};
  final _constNames = <String>{};
  final _errors = <CheckError>[];

  // Imported programs (pre-registered via [addProgram]); fed to the element
  // model so cross-module types/functions resolve during inference.
  final _importPrograms = <Program>[];

  // A type resolver over the element model, built per [check] run. Used to
  // resolve type references and for type-mismatch diagnostics over the
  // inference-annotated AST.
  late TypeResolver _resolver;

  // ---- public API ----

  /// Pre-register symbols from an imported [program]. Its declarations become
  /// visible to [check] but are not themselves checked for errors.
  void addProgram(Program program) {
    _importPrograms.add(program);
    _collectSymbols(program);
  }

  /// Register a stdlib module alias (e.g. 'fs' from `import std.fs`).
  void addModule(String name) => _moduleNames.add(name);

  CheckResult check(Program program) {
    _errors.clear();
    _collectSymbols(program);

    // Build the resolved element model and annotate every expression with its
    // inferred type, so the checks below can compare against expected types.
    final library = buildLibrary(program, imports: _importPrograms);
    _resolver = TypeResolver(library.typeDefs);
    Inferrer(library).inferProgram(program);

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
          break; // methods resolve via the element model
        case ImportDecl():
          // Register the module alias so `fs.read_text(...)` resolves `fs`.
          _moduleNames.add(decl.alias ?? decl.path.split('.').last);
        case InterfaceDecl():
          break;
        case ConstDecl():
          _constNames.add(decl.name);
        case EnumDecl():
          _enumDecls[decl.name] = decl;
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
          final typeParams = {for (final tp in decl.typeParams) tp.name};
          for (final m in decl.methods) {
            _checkFn(m, selfType: selfType, outerTypeParams: typeParams);
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
        case EnumDecl():
          final typeParams = {for (final tp in decl.typeParams) tp.name};
          for (final v in decl.variants) {
            for (final f in v.fields) {
              _checkTypeRef(f, decl.span, typeParams: typeParams);
            }
          }
      }
    }
  }

  void _checkTypeDecl(TypeDecl decl) {
    final typeParams = {for (final tp in decl.typeParams) tp.name};
    for (final (_, fieldType) in decl.fields) {
      _checkTypeRef(fieldType, decl.span, typeParams: typeParams);
    }
  }

  void _checkFn(FnDecl fn,
      {TypeRef? selfType, Set<String> outerTypeParams = const {}}) {
    final typeParams = {
      ...outerTypeParams,
      for (final tp in fn.typeParams) tp.name,
    };
    _checkFnSig(fn, typeParams: typeParams);
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

  void _checkFnSig(FnDecl fn, {Set<String> typeParams = const {}}) {
    for (final p in fn.params) {
      if (p.type != null)
        _checkTypeRef(p.type!, fn.span, typeParams: typeParams);
    }
    if (fn.returnType != null) {
      _checkTypeRef(fn.returnType!, fn.span, typeParams: typeParams);
    }
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
        if (type != null) {
          _expectType(value.resolvedType, _resolver.resolve(type),
              "binding '$name'", stmt.span);
        }

      case ReturnStmt(:final value):
        if (value != null) _checkExpr(value, scope, returnType: returnType);
        if (value != null && returnType != null) {
          _checkReturn(value, returnType, stmt.span);
        }

      case AssignStmt(:final target, :final value):
        _checkExpr(target, scope);
        _checkExpr(value, scope, returnType: returnType);

      case ExprStmt(:final expr):
        _checkExpr(expr, scope, returnType: returnType);

      case IfStmt(:final condition, :final then, :final else_):
        _checkExpr(condition, scope);
        _checkCondition(condition);
        _checkBlock(then, scope, returnType: returnType);
        if (else_ != null) _checkBlock(else_, scope, returnType: returnType);

      case ForStmt(:final pattern, :final iterable, :final body):
        _checkExpr(iterable, scope);
        final bodyScope = _Scope.from(scope);
        _bindPattern(pattern, null, bodyScope);
        _checkBlock(body, bodyScope, returnType: returnType);

      case WhileStmt(:final condition, :final body):
        _checkExpr(condition, scope);
        _checkCondition(condition);
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

      case ReturnExpr(:final value, :final span):
        if (value != null) _checkExpr(value, scope, returnType: returnType);
        if (value != null && returnType != null) {
          _checkReturn(value, returnType, span);
        }

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
      return;
    }

    // Check each argument's type against its parameter. A labeled argument maps
    // to the like-labeled parameter; an unlabeled one to the parameter in that
    // position. Skip when the parameter is untyped (leniency covers the rest).
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      final param = arg.label != null
          ? _paramByLabel(params, arg.label!)
          : (i < params.length ? params[i] : null);
      if (param?.type != null) {
        _expectType(arg.value.resolvedType, _resolver.resolve(param!.type!),
            'argument to "${fn.name}"', span);
      }
    }
  }

  Param? _paramByLabel(List<Param> params, String label) {
    for (final p in params) {
      if (p.label == label) return p;
    }
    return null;
  }

  // ---- type reference checking ----

  void _checkTypeRef(TypeRef typeRef, SourceSpan fallback,
      {Set<String> typeParams = const {}}) {
    switch (typeRef) {
      case NamedType(:final name, :final args, :final span):
        // A name is known if the resolver maps it to something concrete — a
        // primitive, a type parameter in scope, or a declared/built-in type
        // (in the element model). `Self` is always allowed inside an impl.
        final resolved = _resolver.resolve(NamedType(name), typeParams: typeParams);
        if (name != 'Self' && resolved is UnknownType) {
          _error('unknown type: $name', span ?? fallback);
        }
        for (final arg in args) {
          _checkTypeRef(arg, fallback, typeParams: typeParams);
        }
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
      _constNames.contains(name) ||
      _typeDecls.containsKey(name) || // static dispatch: TypeName.method()
      _enumDecls.containsKey(name); // enum variant access: EnumName.Variant

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

  // ---- type-mismatch diagnostics (over inference-annotated expressions) ----

  /// Report when [actual] (an expression's inferred type) is not assignable to
  /// [expected]. A no-op when [actual] is null/unknown — [isAssignable] is
  /// deliberately lenient so the checker never reports a *false* mismatch.
  void _expectType(
      Type? actual, Type expected, String context, SourceSpan span) {
    if (actual == null) return;
    if (!isAssignable(actual, expected)) {
      _error('$context: expected $expected, found $actual', span);
    }
  }

  /// A loop/branch condition must be `Bool`.
  void _checkCondition(Expr condition) {
    final t = condition.resolvedType;
    if (t == null) return;
    if (!isAssignable(t, PrimitiveType.bool_)) {
      _error('condition must be Bool, found $t', condition.span);
    }
  }

  /// Check `return value;` against the declared return type [returnTypeRef].
  /// Allows the implicit `Ok` wrap — returning a `T` from a `Result<T, E>`
  /// function.
  void _checkReturn(Expr value, TypeRef returnTypeRef, SourceSpan span) {
    final actual = value.resolvedType;
    if (actual == null) return;
    final expected = _resolver.resolve(returnTypeRef);
    if (isAssignable(actual, expected)) return;
    if (expected is InterfaceType &&
        expected.element.name == 'Result' &&
        expected.typeArguments.isNotEmpty &&
        isAssignable(actual, expected.typeArguments.first)) {
      return; // implicit Ok(value)
    }
    _error('return type mismatch: expected $expected, found $actual', span);
  }

  void _error(String message, SourceSpan span) =>
      _errors.add(CheckError(message, span));
}
