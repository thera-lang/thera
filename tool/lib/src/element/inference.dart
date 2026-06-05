import '../ast.dart';
import 'builtins.dart';
import 'element.dart';
import 'resolver.dart';
import 'types.dart';

/// The synthesizing pass: walks a [Program] and annotates every [Expr] with its
/// resolved semantic [Type] (`Expr.resolvedType`), using the element model.
///
/// Unlike the legacy bottom-up `_typeOf` in codegen, this sees *through*
/// generics: `Some(5).unwrap_or(0)` infers `Int`, list indexing infers the
/// element type, and `match opt { Some(x) => ... }` binds `x` to the option's
/// element type.
class Inferrer {
  final LibraryElement library;
  final TypeResolver _resolver;

  final Map<String, Map<String, BuiltinReturn>> _builtinReturns;

  Inferrer(this.library)
      : _resolver = TypeResolver(library.typeDefs),
        _builtinReturns = builtinReturns(library.typeDefs);

  // --- entry points ---

  void inferProgram(Program program) {
    for (final decl in program.decls) {
      switch (decl) {
        case FnDecl():
          _inferFn(decl, selfType: null, outerTypeParams: const {});
        case ImplDecl():
          final owner = library.typeDefs[decl.typeName];
          final selfType = owner == null
              ? null
              : InterfaceType(owner, [
                  for (final tp in decl.typeParams) TypeParameterType(tp.name),
                ]);
          final implParams = {for (final tp in decl.typeParams) tp.name};
          for (final m in decl.methods) {
            _inferFn(m, selfType: selfType, outerTypeParams: implParams);
          }
        case ConstDecl(:final value):
          _infer(value, {});
        case InterfaceDecl():
        case TypeDecl():
        case EnumDecl():
        case ImportDecl():
          break;
      }
    }
  }

  void _inferFn(FnDecl fn,
      {required Type? selfType, required Set<String> outerTypeParams}) {
    if (fn.body == null) return;
    final tps = {...outerTypeParams, for (final tp in fn.typeParams) tp.name};
    final scope = <String, Type>{};
    for (final p in fn.params) {
      if (p.isSelf) {
        if (selfType != null) scope['self'] = selfType;
      } else {
        scope[p.name] =
            _resolver.resolve(p.type, typeParams: tps, selfType: selfType);
      }
    }
    _inferBlock(fn.body!, scope, typeParams: tps, selfType: selfType);
  }

  // --- statements ---

  void _inferBlock(Block block, Map<String, Type> outer,
      {required Set<String> typeParams, Type? selfType}) {
    final scope = Map<String, Type>.from(outer);
    for (final stmt in block.stmts) {
      _inferStmt(stmt, scope, typeParams: typeParams, selfType: selfType);
    }
  }

  void _inferStmt(Stmt stmt, Map<String, Type> scope,
      {required Set<String> typeParams, Type? selfType}) {
    switch (stmt) {
      case LetStmt(:final name, :final type, :final value):
        final inferred =
            _infer(value, scope, typeParams: typeParams, selfType: selfType);
        scope[name] = type == null
            ? inferred
            : _resolver.resolve(type,
                typeParams: typeParams, selfType: selfType);
      case ReturnStmt(:final value):
        if (value != null) {
          _infer(value, scope, typeParams: typeParams, selfType: selfType);
        }
      case ThrowStmt(:final value):
        _infer(value, scope, typeParams: typeParams, selfType: selfType);
      case AssignStmt(:final target, :final value):
        _infer(target, scope, typeParams: typeParams, selfType: selfType);
        _infer(value, scope, typeParams: typeParams, selfType: selfType);
      case ExprStmt(:final expr):
        _infer(expr, scope, typeParams: typeParams, selfType: selfType);
      case IfStmt(:final condition, :final then, :final else_):
        _infer(condition, scope, typeParams: typeParams, selfType: selfType);
        _inferBlock(then, scope, typeParams: typeParams, selfType: selfType);
        if (else_ != null) {
          _inferBlock(else_, scope, typeParams: typeParams, selfType: selfType);
        }
      case ForStmt(:final pattern, :final iterable, :final body):
        final iterType =
            _infer(iterable, scope, typeParams: typeParams, selfType: selfType);
        final bodyScope = Map<String, Type>.from(scope);
        _bindForPattern(pattern, iterType, bodyScope);
        _inferBlock(body, bodyScope,
            typeParams: typeParams, selfType: selfType);
      case WhileStmt(:final condition, :final body):
        _infer(condition, scope, typeParams: typeParams, selfType: selfType);
        _inferBlock(body, scope, typeParams: typeParams, selfType: selfType);
    }
  }

  /// Bind a for-loop pattern. Iterating a `List<T>` or `Range` binds the
  /// element type; a range binds `Int`.
  void _bindForPattern(
      Pattern pattern, Type iterType, Map<String, Type> scope) {
    final Type element;
    if (iterType is InterfaceType &&
        iterType.element.name == 'List' &&
        iterType.typeArguments.isNotEmpty) {
      element = iterType.typeArguments.first;
    } else {
      // Ranges (the only other iterable today) yield Int.
      element = PrimitiveType.int_;
    }
    if (pattern is IdentPattern) scope[pattern.name] = element;
  }

  // --- expressions ---

  Type _infer(Expr expr, Map<String, Type> scope,
      {Set<String> typeParams = const {}, Type? selfType}) {
    final type =
        _inferExpr(expr, scope, typeParams: typeParams, selfType: selfType);
    expr.resolvedType = type;
    return type;
  }

  Type _inferExpr(Expr expr, Map<String, Type> scope,
      {required Set<String> typeParams, Type? selfType}) {
    Type sub(Expr e) =>
        _infer(e, scope, typeParams: typeParams, selfType: selfType);

    switch (expr) {
      case IntLiteral():
        return PrimitiveType.int_;
      case FloatLiteral():
        return PrimitiveType.double_;
      case BoolLiteral():
        return PrimitiveType.bool_;
      case StringExpr(:final parts):
        for (final p in parts) {
          if (p is InterpPart) sub(p.expr);
        }
        return PrimitiveType.string;

      case IdentExpr(:final name):
        if (name == 'None') return _option(const UnknownType());
        final local = scope[name];
        if (local != null) return local;
        final c = library.consts[name];
        if (c != null) return c.type;
        return const UnknownType();

      case UnaryExpr(:final op, :final operand):
        final t = sub(operand);
        return op == '!' ? PrimitiveType.bool_ : t;

      case BinaryExpr(:final op, :final left, :final right):
        final l = sub(left);
        final r = sub(right);
        if (_comparison.contains(op) || op == '&&' || op == '||') {
          return PrimitiveType.bool_;
        }
        return l is UnknownType ? r : l;

      case RangeExpr(:final start, :final end):
        sub(start);
        sub(end);
        return const UnknownType(); // no first-class Range type yet

      case ListExpr(:final items):
        final element = items.isEmpty ? const UnknownType() : sub(items.first);
        for (var i = 1; i < items.length; i++) {
          sub(items[i]);
        }
        return _list(element);

      case MapExpr(:final entries):
        if (entries.isEmpty) {
          return InterfaceType(
              _builtin('Map'), const [UnknownType(), UnknownType()]);
        }
        final key = sub(entries.first.$1);
        final value = sub(entries.first.$2);
        for (var i = 1; i < entries.length; i++) {
          sub(entries[i].$1);
          sub(entries[i].$2);
        }
        return InterfaceType(_builtin('Map'), [key, value]);

      case StructExpr(:final typeName, :final fields):
        final element = library.typeDefs[typeName];
        final bindings = <String, Type>{};
        if (element is StructElement) {
          for (final (fieldName, value) in fields) {
            final valueType = sub(value);
            final declared = element.fields[fieldName];
            if (declared != null) unify(declared, valueType, bindings);
          }
          return InterfaceType(element, [
            for (final tp in element.typeParameters)
              bindings[tp] ?? const UnknownType(),
          ]);
        }
        for (final (_, value) in fields) {
          sub(value);
        }
        return const UnknownType();

      case IndexExpr(:final object, :final index):
        final recv = sub(object);
        sub(index);
        return _indexResult(recv);

      case FieldExpr(:final object, :final field):
        // Bare enum variant: `(ns.)?Enum.Variant` (no payload).
        final asEnum = _enumVariantType(object, field, const [], scope);
        if (asEnum != null) return asEnum;
        // Namespace member: `ns.CONST`.
        if (object is IdentExpr && _isNamespace(object.name, scope)) {
          final c = library.consts[field];
          if (c != null) return c.type;
        }
        final recv = sub(object);
        return _fieldType(recv, field);

      case PropagateExpr(:final inner):
        final t = sub(inner);
        if (t is InterfaceType &&
            (t.element.name == 'Result' || t.element.name == 'Option') &&
            t.typeArguments.isNotEmpty) {
          return t.typeArguments.first;
        }
        return const UnknownType();

      case CallExpr(:final callee, :final args):
        return _inferCall(expr, callee, args, scope,
            typeParams: typeParams, selfType: selfType);

      case MatchExpr(:final subject, :final arms):
        final subjectType = sub(subject);
        Type result = const UnknownType();
        for (final arm in arms) {
          final armScope = Map<String, Type>.from(scope);
          _bindMatchPattern(arm.pattern, subjectType, armScope);
          final armType = _infer(arm.body, armScope,
              typeParams: typeParams, selfType: selfType);
          if (result is UnknownType) result = armType;
        }
        return result;

      case LambdaExpr(:final params, :final body):
        final lambdaScope = Map<String, Type>.from(scope);
        for (final p in params) {
          lambdaScope[p] = const UnknownType();
        }
        final ret = _infer(body, lambdaScope,
            typeParams: typeParams, selfType: selfType);
        return FunctionType([for (final _ in params) const UnknownType()], ret);

      case BlockExpr(:final block):
        _inferBlock(block, scope, typeParams: typeParams, selfType: selfType);
        return const UnknownType();

      case ReturnExpr(:final value):
        if (value != null) sub(value);
        return const UnknownType();

      case ThrowExpr(:final value):
        sub(value);
        return const UnknownType();
    }
  }

  Type _inferCall(
    CallExpr expr,
    Expr callee,
    List<CallArg> args,
    Map<String, Type> scope, {
    required Set<String> typeParams,
    Type? selfType,
  }) {
    final argTypes = [
      for (final a in args)
        _infer(a.value, scope, typeParams: typeParams, selfType: selfType),
    ];

    if (callee is IdentExpr) {
      switch (callee.name) {
        case 'Ok':
          return _result(
              argTypes.isEmpty ? const UnknownType() : argTypes.first,
              const UnknownType());
        case 'Err':
          return _result(const UnknownType(),
              argTypes.isEmpty ? const UnknownType() : argTypes.first);
        case 'Some':
          return _option(
              argTypes.isEmpty ? const UnknownType() : argTypes.first);
        default:
          // A function-typed local/parameter called directly: `f(x)`.
          final local = scope[callee.name];
          if (local is FunctionType) return local.returnType;
          final fn = library.functions[callee.name];
          if (fn != null) return _instantiateReturn(fn, argTypes);
          return const UnknownType();
      }
    }

    if (callee is FieldExpr) {
      final obj = callee.object;

      // Enum construction: `(ns.)?Enum.Variant(payload...)`.
      final enumType = _enumVariantType(obj, callee.field, argTypes, scope);
      if (enumType != null) return enumType;

      // Static method on a (possibly namespaced) type: `(ns.)?Type.method(...)`
      // (e.g. `Args.new(...)`, `Point.origin()`). The receiver is a type, not a
      // value.
      final typeDef = _typeDefFor(obj, scope);
      if (typeDef != null) {
        final method = typeDef.method(callee.field);
        if (method != null && method.isStatic) return method.returnType;
      }

      // Namespace function: `ns.fn(...)`.
      if (obj is IdentExpr && _isNamespace(obj.name, scope)) {
        final fn = library.functions[callee.field];
        if (fn != null) return _instantiateReturn(fn, argTypes);
      }

      // `e.name()` on an enum value -> String.
      final recvType = _infer(callee.object, scope,
          typeParams: typeParams, selfType: selfType);
      if (callee.field == 'name' &&
          recvType is InterfaceType &&
          recvType.element is EnumElement) {
        return PrimitiveType.string;
      }

      // Built-in method on a primitive/collection receiver.
      final builtin = _builtinMethodReturn(recvType, callee.field, argTypes);
      if (builtin != null) return builtin;

      // User method declared in an impl block.
      if (recvType is InterfaceType) {
        final method = recvType.element.method(callee.field);
        if (method != null) {
          return _substituteReceiver(method.returnType, recvType);
        }
      }
      return const UnknownType();
    }

    // Any other callee expression of function type (e.g. an indexed/returned
    // closure): the call yields its return type.
    final calleeType =
        _infer(callee, scope, typeParams: typeParams, selfType: selfType);
    if (calleeType is FunctionType) return calleeType.returnType;
    return const UnknownType();
  }

  // --- pattern binding ---

  void _bindMatchPattern(
      Pattern pattern, Type subject, Map<String, Type> scope) {
    switch (pattern) {
      case IdentPattern(:final name):
        scope[name] = subject;
      case ConstructorPattern(:final name, :final args):
        final fieldTypes = _variantFieldTypes(subject, name);
        for (var i = 0; i < args.length; i++) {
          final t = i < fieldTypes.length ? fieldTypes[i] : const UnknownType();
          _bindMatchPattern(args[i], t, scope);
        }
      case WildcardPattern():
      case LiteralPattern():
        break;
    }
  }

  /// The payload field types of variant [name] for a value of type [subject].
  List<Type> _variantFieldTypes(Type subject, String name) {
    if (subject is! InterfaceType) return const [];
    final element = subject.element;
    if (element.name == 'Option') {
      return name == 'Some' ? [_arg(subject, 0)] : const [];
    }
    if (element.name == 'Result') {
      if (name == 'Ok') return [_arg(subject, 0)];
      if (name == 'Err') return [_arg(subject, 1)];
      return const [];
    }
    if (element is EnumElement) {
      final variant = element.variant(name);
      if (variant == null) return const [];
      final bindings = _receiverBindings(subject);
      return [for (final f in variant.fields) substitute(f, bindings)];
    }
    return const [];
  }

  // --- type helpers ---

  TypeDefElement _builtin(String name) => library.typeDefs[name]!;
  InterfaceType _option(Type t) => InterfaceType(_builtin('Option'), [t]);
  InterfaceType _result(Type t, Type e) =>
      InterfaceType(_builtin('Result'), [t, e]);
  InterfaceType _list(Type t) => InterfaceType(_builtin('List'), [t]);

  Type _arg(InterfaceType t, int i) =>
      i < t.typeArguments.length ? t.typeArguments[i] : const UnknownType();

  /// `Map<String, Type>` mapping the receiver element's type parameters to its
  /// resolved arguments, for instantiating members.
  Map<String, Type> _receiverBindings(InterfaceType recv) {
    final params = recv.element.typeParameters;
    final bindings = <String, Type>{};
    for (var i = 0; i < params.length && i < recv.typeArguments.length; i++) {
      bindings[params[i]] = recv.typeArguments[i];
    }
    return bindings;
  }

  Type _substituteReceiver(Type type, InterfaceType recv) =>
      substitute(type, _receiverBindings(recv));

  Type _instantiateReturn(FunctionElement fn, List<Type> argTypes) {
    final positional = fn.parameters.where((p) => !p.isSelf).toList();
    final bindings = <String, Type>{};
    for (var i = 0; i < argTypes.length && i < positional.length; i++) {
      unify(positional[i].type, argTypes[i], bindings);
    }
    return substitute(fn.returnType, bindings);
  }

  /// Result of `object[index]`: the element type of a `List<T>`, the value type
  /// of a `Map<K, V>`.
  Type _indexResult(Type recv) {
    if (recv is InterfaceType) {
      if (recv.element.name == 'List') return _arg(recv, 0);
      if (recv.element.name == 'Map') return _arg(recv, 1);
    }
    return const UnknownType();
  }

  /// Type of `recv.field` for a struct receiver (with generic args applied).
  Type _fieldType(Type recv, String field) {
    if (recv is InterfaceType && recv.element is StructElement) {
      final declared = (recv.element as StructElement).fields[field];
      if (declared != null) return _substituteReceiver(declared, recv);
    }
    return const UnknownType();
  }

  /// Whether [name] refers to an import namespace here (a known namespace not
  /// shadowed by a local).
  bool _isNamespace(String name, Map<String, Type> scope) =>
      !scope.containsKey(name) && library.namespaces.containsKey(name);

  /// Resolve a (possibly namespace-qualified) type reference in expression
  /// position — `Type` or `ns.Type` — to its element. The type table is flat,
  /// so a qualified `ns.Type` resolves to the same element as bare `Type`.
  TypeDefElement? _typeDefFor(Expr object, Map<String, Type> scope) {
    if (object is IdentExpr && !scope.containsKey(object.name)) {
      return library.typeDefs[object.name];
    }
    if (object is FieldExpr &&
        object.object is IdentExpr &&
        _isNamespace((object.object as IdentExpr).name, scope)) {
      return library.typeDefs[object.field];
    }
    return null;
  }

  /// If [object] names a declared enum (possibly namespace-qualified) and
  /// [variant] is one of its variants, the constructed enum type (with type
  /// args recovered from [argTypes]).
  InterfaceType? _enumVariantType(Expr object, String variant,
      List<Type> argTypes, Map<String, Type> scope) {
    final element = _typeDefFor(object, scope);
    if (element is! EnumElement) return null;
    final v = element.variant(variant);
    if (v == null) return null;
    final bindings = <String, Type>{};
    for (var i = 0; i < argTypes.length && i < v.fields.length; i++) {
      unify(v.fields[i], argTypes[i], bindings);
    }
    return InterfaceType(element, [
      for (final tp in element.typeParameters)
        bindings[tp] ?? const UnknownType(),
    ]);
  }

  /// Return type of a built-in method on a primitive/collection [recv], looked
  /// up in the shared [builtinReturns] table.
  Type? _builtinMethodReturn(Type recv, String method, List<Type> argTypes) {
    final (kind, recvArgs) = switch (recv) {
      PrimitiveType(primitive: Primitive.string) => ('String', const <Type>[]),
      InterfaceType(:final element, :final typeArguments) => (
          element.name,
          typeArguments
        ),
      _ => (null, const <Type>[]),
    };
    if (kind == null) return null;
    final builder = _builtinReturns[kind]?[method];
    return builder?.call(recvArgs, argTypes);
  }

  static const _comparison = {'==', '!=', '<', '<=', '>', '>='};
}
