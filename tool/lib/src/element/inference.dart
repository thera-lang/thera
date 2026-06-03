import '../ast.dart';
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

  Inferrer(this.library) : _resolver = TypeResolver(library.typeDefs);

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
        scope[p.name] = _resolver.resolve(p.type,
            typeParams: tps, selfType: selfType);
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
        final inferred = _infer(value, scope,
            typeParams: typeParams, selfType: selfType);
        scope[name] = type == null
            ? inferred
            : _resolver.resolve(type, typeParams: typeParams, selfType: selfType);
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
        _inferBlock(body, bodyScope, typeParams: typeParams, selfType: selfType);
      case WhileStmt(:final condition, :final body):
        _infer(condition, scope, typeParams: typeParams, selfType: selfType);
        _inferBlock(body, scope, typeParams: typeParams, selfType: selfType);
    }
  }

  /// Bind a for-loop pattern. Iterating a `List<T>` or `Range` binds the
  /// element type; a range binds `Int`.
  void _bindForPattern(Pattern pattern, Type iterType, Map<String, Type> scope) {
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
    final type = _inferExpr(expr, scope, typeParams: typeParams, selfType: selfType);
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
          return InterfaceType(_builtin('Map'),
              const [UnknownType(), UnknownType()]);
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
        // Bare enum variant: `Enum.Variant` (no payload).
        final asEnum = _enumVariantType(object, field, const []);
        if (asEnum != null) return asEnum;
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
        return FunctionType(
            [for (final _ in params) const UnknownType()], ret);

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
          final fn = library.functions[callee.name];
          if (fn != null) return _instantiateReturn(fn, argTypes);
          return const UnknownType();
      }
    }

    if (callee is FieldExpr) {
      // Enum construction: `Enum.Variant(payload...)`.
      final enumType = _enumVariantType(callee.object, callee.field, argTypes);
      if (enumType != null) return enumType;

      // Static method on a type: `Type.method(...)` (e.g. `Args.new(...)`,
      // `Point.origin()`). The receiver is a type name, not a value.
      final obj = callee.object;
      if (obj is IdentExpr && !scope.containsKey(obj.name)) {
        final typeDef = library.typeDefs[obj.name];
        final method = typeDef?.method(callee.field);
        if (method != null && method.isStatic) return method.returnType;
      }

      // `e.name()` on an enum value -> String.
      final recvType =
          _infer(callee.object, scope, typeParams: typeParams, selfType: selfType);
      if (callee.field == 'name' && recvType is InterfaceType &&
          recvType.element is EnumElement) {
        return PrimitiveType.string;
      }

      // Module function: `fs.read_text(...)`.
      final mod = _moduleReturn(callee.object, callee.field);
      if (mod != null) return mod;

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

    _infer(callee, scope, typeParams: typeParams, selfType: selfType);
    return const UnknownType();
  }

  // --- pattern binding ---

  void _bindMatchPattern(Pattern pattern, Type subject, Map<String, Type> scope) {
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

  /// If [object] names a declared enum and [variant] is one of its variants,
  /// the constructed enum type (with type args recovered from [argTypes]).
  InterfaceType? _enumVariantType(
      Expr object, String variant, List<Type> argTypes) {
    if (object is! IdentExpr) return null;
    final element = library.typeDefs[object.name];
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

  /// Return type of a built-in method on a primitive/collection [recv].
  Type? _builtinMethodReturn(Type recv, String method, List<Type> argTypes) {
    if (recv == PrimitiveType.string) {
      return switch (method) {
        'len' || 'byte_len' => PrimitiveType.int_,
        'is_empty' || 'contains' || 'starts_with' || 'ends_with' =>
          PrimitiveType.bool_,
        'trim' || 'to_uppercase' || 'to_lowercase' => PrimitiveType.string,
        'lines' || 'split_whitespace' || 'split' => _list(PrimitiveType.string),
        _ => null,
      };
    }
    if (recv is! InterfaceType) return null;
    switch (recv.element.name) {
      case 'List':
        return switch (method) {
          'len' => PrimitiveType.int_,
          'get' => _option(_arg(recv, 0)),
          'join' => PrimitiveType.string,
          _ => null,
        };
      case 'Map':
        return switch (method) {
          'len' => PrimitiveType.int_,
          'get' || 'remove' => _option(_arg(recv, 1)),
          'has' => PrimitiveType.bool_,
          'is_empty' => PrimitiveType.bool_,
          'keys' => _list(_arg(recv, 0)),
          'values' => _list(_arg(recv, 1)),
          _ => null,
        };
      case 'Option':
        return switch (method) {
          'ok_or' => _result(_arg(recv, 0),
              argTypes.isEmpty ? const UnknownType() : argTypes.first),
          'unwrap_or' => _arg(recv, 0),
          'is_some' || 'is_none' => PrimitiveType.bool_,
          _ => null,
        };
    }
    return null;
  }

  /// Return type of an imported `std.*` module function, e.g. `fs.read_text`.
  Type? _moduleReturn(Expr object, String method) {
    if (object is! IdentExpr || !library.modules.contains(object.name)) {
      return null;
    }
    const fns = {
      'fs': {'read_text', 'write_text'},
    };
    if (fns[object.name]?.contains(method) ?? false) {
      return _result(PrimitiveType.string, InterfaceType(_builtin('Error')));
    }
    return null;
  }

  static const _comparison = {'==', '!=', '<', '<=', '>', '>='};
}
