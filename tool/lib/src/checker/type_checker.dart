import '../ast.dart';
import '../element/element.dart';
import '../element/inference.dart';
import '../element/namespace.dart';
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
/// Call [addProgram] to pre-register imported files (their declarations become
/// visible to the element model but are not themselves checked). Then call
/// [check] on the primary program.
class TypeChecker {
  final _errors = <CheckError>[];

  // Imported programs (pre-registered via [addProgram]); fed to the element
  // model so cross-module types/functions resolve.
  final _importPrograms = <Program>[];

  // The resolved element model and a type resolver over it, built per [check]
  // run. The element model is the single source of top-level symbols (types,
  // functions, consts, modules); the resolver maps type references to types and
  // backs the type-mismatch diagnostics over the inference-annotated AST.
  late LibraryElement _library;
  late TypeResolver _resolver;

  LibraryElement get library => _library;
  TypeResolver get resolver => _resolver;

  // ---- public API ----

  /// Pre-register an imported [program] so its declarations resolve in [check].
  void addProgram(Program program) => _importPrograms.add(program);

  CheckResult check(Program program,
      {Map<String, LibraryNamespace> namespaces = const {}}) {
    _errors.clear();

    // Build the resolved element model (the single source of top-level symbols)
    // and annotate every expression with its inferred type, so the checks below
    // can resolve names and compare against expected types.
    _library =
        buildLibrary(program, imports: _importPrograms, namespaces: namespaces);
    _resolver = TypeResolver(_library.typeDefs);
    Inferrer(_library).inferProgram(program);

    _checkProgram(program);
    return CheckResult(List.unmodifiable(_errors));
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
          if (decl.interfaceName != null) _checkConformance(decl);
        case InterfaceDecl():
          _checkInterfaceDecl(decl);
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

  /// Validate an `impl Interface for Type` block: the named interface must
  /// exist, and the block must provide every interface method with a matching
  /// signature (with `Self` standing for the implementing type).
  /// Validate an `interface Sub: Super + … { … }` declaration: each method
  /// signature is well-formed, every super names an interface, and the
  /// inheritance relation has no cycle.
  void _checkInterfaceDecl(InterfaceDecl decl) {
    // The interface's own type parameters are in scope in its method signatures
    // (e.g. `T` in `interface Iterator<T> { fn next(self) -> Option<T>; }`),
    // along with any the method itself declares.
    final ifaceTypeParams = {for (final tp in decl.typeParams) tp.name};
    for (final m in decl.methods) {
      _checkFnSig(m, typeParams: {
        ...ifaceTypeParams,
        for (final tp in m.typeParams) tp.name,
      });
    }
    for (final superName in decl.superInterfaces) {
      final superDef = _library.typeDefs[superName];
      if (superDef == null) {
        _error('unknown super-interface: $superName', decl.nameSpan);
      } else if (superDef is! InterfaceElement) {
        _error("'$superName' is not an interface", decl.nameSpan);
      }
    }
    if (decl.superInterfaces.contains(decl.name) || _extendsCycle(decl.name)) {
      _error("interface '${decl.name}' extends itself (inheritance cycle)",
          decl.nameSpan);
    }
  }

  /// Whether interface [name] participates in a mutual/longer inheritance cycle
  /// — reachable as a super of one of its own (transitive) supers. Uses the
  /// resolver-computed closures (`superInterfaces`); a direct self-reference is
  /// handled by the caller (the closure excludes the type's own name).
  bool _extendsCycle(String name) {
    final start = _library.typeDefs[name];
    if (start is! InterfaceElement) return false;
    for (final s in start.superInterfaces) {
      final sd = _library.typeDefs[s];
      if (sd is InterfaceElement && sd.superInterfaces.contains(name)) {
        return true;
      }
    }
    return false;
  }

  void _checkConformance(ImplDecl decl) {
    final ifaceName = decl.interfaceName!;
    final ifaceDef = _library.typeDefs[ifaceName];
    if (ifaceDef == null) {
      _error('unknown interface: $ifaceName', decl.nameSpan);
      return;
    }
    if (ifaceDef is! InterfaceElement) {
      _error("'$ifaceName' is not an interface", decl.nameSpan);
      return;
    }
    final owner = _library.typeDefs[decl.typeName];
    if (owner == null) return; // unknown target type — reported elsewhere

    // What `Self` denotes in the interface's signatures: the implementing type.
    final implType = TypeResolver.primitiveType(decl.typeName) ??
        InterfaceType(owner, [
          for (final tp in decl.typeParams) TypeParameterType(tp.name),
        ]);
    final selfType = InterfaceType(ifaceDef);

    // Bind the interface's type parameters to the args supplied at the impl
    // (`impl Iterator<Int> for …` → {T: Int}), so a method like
    // `next(self) -> Option<T>` is compared as `Option<Int>`. The args resolve
    // in the impl's own type-param scope, so `impl Iterator<T> for ListIter<T>`
    // binds the interface's `T` to the impl's `T`.
    final ifaceParams = ifaceDef.typeParameters;
    if (decl.interfaceArgs.length != ifaceParams.length) {
      _error(
          "interface '$ifaceName' takes ${ifaceParams.length} type "
          "argument(s), but ${decl.interfaceArgs.length} were given",
          decl.nameSpan);
      return;
    }
    final implTps = {for (final tp in decl.typeParams) tp.name};
    final ifaceBindings = <String, Type>{
      for (var i = 0; i < ifaceParams.length; i++)
        ifaceParams[i]: _resolver.resolve(decl.interfaceArgs[i],
            typeParams: implTps, selfType: implType),
    };

    final provided = {for (final m in decl.methods) m.name};
    // Only the interface's *own* methods are required in this impl; inherited
    // super-interface methods are satisfied by implementing the super (checked
    // below), not re-declared here.
    for (final im in ifaceDef.methods) {
      if (!ifaceDef.ownMethods.contains(im.name)) continue;
      if (!provided.contains(im.name)) {
        _error("missing method '${im.name}' required by interface '$ifaceName'",
            decl.nameSpan);
        continue;
      }
      final om = owner.method(im.name);
      if (om == null) continue; // resolved elsewhere; body checked already
      if (!_signaturesMatch(im, om, selfType, implType, ifaceBindings)) {
        _error(
            "method '${im.name}' does not match its declaration in interface "
            "'$ifaceName'",
            decl.nameSpan);
      }
    }

    // Inherited obligation: implementing a sub-interface requires implementing
    // each super-interface too (`impl Error for T` ⇒ T must be Display + Debug).
    // `Eq`/`Debug` are satisfied structurally; others need an explicit impl.
    for (final superName in ifaceDef.superInterfaces) {
      if (!_satisfiesBound(implType, superName)) {
        _error(
            "'${decl.typeName}' implements '$ifaceName', which extends "
            "'$superName', but does not implement '$superName'",
            decl.nameSpan);
      }
    }
  }

  /// Whether impl method [om] matches interface method [im], treating `Self`
  /// (which resolves to [selfType] inside the interface) as [implType].
  bool _signaturesMatch(MethodElement im, MethodElement om, Type selfType,
      Type implType, Map<String, Type> ifaceBindings) {
    if (im.isStatic != om.isStatic) return false;
    final iParams = im.parameters.where((p) => !p.isSelf).toList();
    final oParams = om.parameters.where((p) => !p.isSelf).toList();
    if (iParams.length != oParams.length) return false;
    // Apply the interface's type-arg bindings, then `Self` -> implementing type.
    Type expect(Type t) =>
        _selfToImpl(substitute(t, ifaceBindings), selfType, implType);
    for (var i = 0; i < iParams.length; i++) {
      if (!_typeMatches(expect(iParams[i].type), oParams[i].type)) {
        return false;
      }
    }
    return _typeMatches(expect(im.returnType), om.returnType);
  }

  /// Substitute `Self` (== [selfType]) with [implType] throughout [t].
  Type _selfToImpl(Type t, Type selfType, Type implType) {
    if (t == selfType) return implType;
    if (t is InterfaceType) {
      return InterfaceType(t.element, [
        for (final a in t.typeArguments) _selfToImpl(a, selfType, implType),
      ]);
    }
    if (t is FunctionType) {
      return FunctionType(
        [for (final p in t.parameterTypes) _selfToImpl(p, selfType, implType)],
        _selfToImpl(t.returnType, selfType, implType),
      );
    }
    return t;
  }

  /// Lenient type equality for conformance: an unknown matches anything (a
  /// separate diagnostic already explains the unresolved type).
  bool _typeMatches(Type a, Type b) =>
      a is UnknownType || b is UnknownType || a == b;

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
    // The tail expression (expression-position blocks only) is checked in the
    // scope the statements built; its value is the block's value.
    final tail = block.tail;
    if (tail != null) {
      // A tail is value position, so an `if` tail must have an `else` (a primary
      // `if` is already else-checked by the parser; this catches the tail form).
      if (tail is IfExpr && tail.else_ == null) {
        _error('an `if` used as a value needs an `else` branch', tail.span);
      }
      _checkExpr(tail, scope, returnType: returnType);
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
          final fn = _library.functions[callee.name];
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
        final element = _library.typeDefs[typeName];
        if (element is StructElement) {
          for (final (fieldName, fieldValue) in fields) {
            if (!element.fields.containsKey(fieldName)) {
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

      case LambdaExpr(
          :final params,
          :final body,
          :final span,
          :final resolvedParamTypes
        ):
        final lambdaScope = _Scope.from(scope);
        final resolved = resolvedParamTypes;
        for (var i = 0; i < params.length; i++) {
          final p = params[i];
          if (p.type != null) {
            _checkTypeRef(p.type!, span);
          } else if (resolved != null &&
              i < resolved.length &&
              resolved[i] is UnknownType) {
            // No annotation and nothing in the surrounding context determined
            // the type — we don't guess.
            _error(
                "cannot infer the type of lambda parameter '${p.name}'; add a "
                'type annotation, e.g. (${p.name}: Int) => ...',
                span);
          }
          lambdaScope[p.name] = null;
        }
        _checkExpr(body, lambdaScope);

      case BlockExpr(:final block):
        _checkBlock(block, scope, returnType: returnType);

      case IfExpr(:final condition, :final then, :final else_):
        _checkExpr(condition, scope);
        _checkCondition(condition);
        _checkBlock(then, scope, returnType: returnType);
        if (else_ != null) _checkBlock(else_, scope, returnType: returnType);

      case ReturnExpr(:final value, :final span):
        if (value != null) _checkExpr(value, scope, returnType: returnType);
        if (value != null && returnType != null) {
          _checkReturn(value, returnType, span);
        }

      case ThrowExpr(:final value):
        _checkExpr(value, scope, returnType: returnType);

      case IntLiteral() || FloatLiteral() || BoolLiteral() || UnitLiteral():
        break;
    }
  }

  // ---- call checking ----

  void _checkCallArgs(FunctionElement fn, List<CallArg> args, SourceSpan span) {
    final params = fn.parameters.where((p) => !p.isSelf).toList();

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
    final required = params.where((p) => !p.hasDefault).length;
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
    // position. The parameter types are already resolved on the element.
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      final param = arg.label != null
          ? _paramByLabel(params, arg.label!)
          : (i < params.length ? params[i] : null);
      if (param != null) {
        _expectType(arg.value.resolvedType, param.type,
            'argument to "${fn.name}"', span);
      }
    }

    _checkBounds(fn, params, args, span);
  }

  /// Enforce generic bounds at a call site: infer each type parameter's binding
  /// from the arguments, then check the bound type argument satisfies every
  /// declared interface bound (`fn f<T: Display>(x: T)` rejects `f(5)`).
  void _checkBounds(FunctionElement fn, List<ParameterElement> params,
      List<CallArg> args, SourceSpan span) {
    if (fn.typeParameterBounds.isEmpty) return;
    final bindings = <String, Type>{};
    for (var i = 0; i < args.length; i++) {
      final param = args[i].label != null
          ? _paramByLabel(params, args[i].label!)
          : (i < params.length ? params[i] : null);
      final actual = args[i].value.resolvedType;
      if (param != null && actual != null) unify(param.type, actual, bindings);
    }
    fn.typeParameterBounds.forEach((tp, bounds) {
      final arg = bindings[tp];
      if (arg == null) return; // unconstrained here — nothing to check
      for (final bound in bounds) {
        if (!_satisfiesBound(arg, bound)) {
          _error(
            'type argument `$arg` for `$tp` does not implement `$bound` '
            '(required by "${fn.name}")',
            span,
          );
        }
      }
    });
  }

  /// Whether [t] satisfies an interface [bound]:
  /// - the built-in interfaces (`Eq`/`Display`/`Debug`) hold for every primitive
  ///   (they have built-in implementations — that's how `println(5)` works);
  /// - `Eq`/`Debug` additionally hold for any struct/enum (auto-derived);
  /// - any other interface requires an explicit `impl`.
  /// Lenient for unresolved types so it never reports a false mismatch.
  ///
  /// At runtime, a `call.virtual` on a receiver with no impl row falls back to
  /// the built-in structural forms (primitives' Display/Eq/Debug, structs' and
  /// enums' derived eq/debug) — so these type-level facts are backed by real
  /// dispatch (see docs/interfaces.md, Stage E).
  static const _builtinInterfaces = {'Eq', 'Display', 'Debug'};
  bool _satisfiesBound(Type t, String bound) {
    if (t is UnknownType || t is TypeParameterType) return true;
    if (t is PrimitiveType) return _builtinInterfaces.contains(bound);
    // An interface-typed value satisfies a bound it *is* or transitively extends
    // (`Error` extends `Debug`). Dispatch reaches the concrete type's impl at
    // runtime, and conformance guarantees that impl exists.
    if (t is InterfaceType && t.element is InterfaceElement) {
      final iface = t.element as InterfaceElement;
      return iface.name == bound || iface.superInterfaces.contains(bound);
    }
    if (bound == 'Eq' || bound == 'Debug') return true; // structural derive
    return t is InterfaceType && t.element.implementsInterface(bound);
  }

  ParameterElement? _paramByLabel(List<ParameterElement> params, String label) {
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
        final resolved =
            _resolver.resolve(NamedType(name), typeParams: typeParams);
        if (name != 'Self' && resolved is UnknownType) {
          _error('unknown type: $name', span);
        }
        for (final arg in args) {
          _checkTypeRef(arg, fallback, typeParams: typeParams);
        }
      case FunctionTypeRef(:final params, :final returnType):
        for (final p in params) {
          _checkTypeRef(p, fallback, typeParams: typeParams);
        }
        _checkTypeRef(returnType, fallback, typeParams: typeParams);
    }
  }

  // ---- helpers ----

  bool _isDefinedName(String name, _Scope scope) =>
      scope.containsKey(name) ||
      _library.functions.containsKey(name) ||
      _library.modules.contains(name) ||
      _library.consts.containsKey(name) ||
      // Type names appear as values for static dispatch (`TypeName.method()`)
      // and enum variant access (`EnumName.Variant`).
      _library.typeDefs.containsKey(name);

  TypeRef? _inferType(Expr expr, _Scope scope) => switch (expr) {
        IntLiteral() => NamedType('Int'),
        FloatLiteral() => NamedType('Double'),
        BoolLiteral() => NamedType('Bool'),
        StringExpr() => NamedType('String'),
        IdentExpr(:final name) => scope[name],
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
