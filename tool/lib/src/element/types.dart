import 'element.dart';

/// A resolved, *semantic* type: the meaning of a syntactic [TypeRef] (from the
/// AST) after name resolution. Unlike a `TypeRef`, a [Type] knows which
/// declaration it refers to (via an [Element]) and carries resolved type
/// arguments.
///
/// The element/type model is built as a separate stage over the parsed AST;
/// see `resolver.dart`.
sealed class Type {
  const Type();

  @override
  String toString();
}

/// One of the built-in primitive types.
enum Primitive { int_, double_, bool_, string, unit }

class PrimitiveType extends Type {
  final Primitive primitive;
  const PrimitiveType(this.primitive);

  static const int_ = PrimitiveType(Primitive.int_);
  static const double_ = PrimitiveType(Primitive.double_);
  static const bool_ = PrimitiveType(Primitive.bool_);
  static const string = PrimitiveType(Primitive.string);
  static const unit = PrimitiveType(Primitive.unit);

  @override
  String toString() => switch (primitive) {
        Primitive.int_ => 'Int',
        Primitive.double_ => 'Double',
        Primitive.bool_ => 'Bool',
        Primitive.string => 'String',
        Primitive.unit => 'Void',
      };

  @override
  bool operator ==(Object other) =>
      other is PrimitiveType && other.primitive == primitive;

  @override
  int get hashCode => primitive.hashCode;
}

/// A type that refers to a declared (or built-in) type definition, with
/// resolved type arguments. Covers structs, enums, interfaces, and the
/// built-in generic types (`List`, `Map`, `Set`, `Result`, `Option`).
class InterfaceType extends Type {
  final TypeDefElement element;
  final List<Type> typeArguments;
  const InterfaceType(this.element, [this.typeArguments = const []]);

  String get name => element.name;

  @override
  String toString() {
    if (typeArguments.isEmpty) return element.name;
    return '${element.name}<${typeArguments.join(', ')}>';
  }

  @override
  bool operator ==(Object other) =>
      other is InterfaceType &&
      other.element == element &&
      _typeListEq(other.typeArguments, typeArguments);

  @override
  int get hashCode => Object.hash(element, Object.hashAll(typeArguments));
}

/// An as-yet-unbound generic type parameter, e.g. the `T` inside `Box<T>`.
class TypeParameterType extends Type {
  final String name;
  const TypeParameterType(this.name);

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) =>
      other is TypeParameterType && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// A function or closure type.
class FunctionType extends Type {
  final List<Type> parameterTypes;
  final Type returnType;
  const FunctionType(this.parameterTypes, this.returnType);

  @override
  String toString() => '(${parameterTypes.join(', ')}) -> $returnType';

  @override
  bool operator ==(Object other) =>
      other is FunctionType &&
      other.returnType == returnType &&
      _typeListEq(other.parameterTypes, parameterTypes);

  @override
  int get hashCode => Object.hash(returnType, Object.hashAll(parameterTypes));
}

/// The type of an expression the resolver could not determine. Acts as both a
/// top and a bottom for assignability so it never produces cascading errors.
class UnknownType extends Type {
  const UnknownType();

  @override
  String toString() => '?';

  @override
  bool operator ==(Object other) => other is UnknownType;

  @override
  int get hashCode => (UnknownType).hashCode;
}

/// Whether a value of type [source] may be used where [target] is expected.
///
/// Deliberately lenient so the checker never reports a *false* mismatch: an
/// [UnknownType] (the inferrer couldn't determine a type) or a
/// [TypeParameterType] (an un-instantiated generic) on either side is always
/// compatible. Otherwise types must match structurally — same element and
/// (recursively) assignable type arguments.
bool isAssignable(Type source, Type target) {
  if (source is UnknownType || target is UnknownType) return true;
  if (source is TypeParameterType || target is TypeParameterType) return true;
  if (source == target) return true;
  if (source is InterfaceType && target is InterfaceType) {
    if (source.element != target.element) return false;
    if (source.typeArguments.length != target.typeArguments.length) {
      return false;
    }
    for (var i = 0; i < source.typeArguments.length; i++) {
      if (!isAssignable(source.typeArguments[i], target.typeArguments[i])) {
        return false;
      }
    }
    return true;
  }
  return false;
}

/// Replace [TypeParameterType]s named in [bindings] throughout [type].
///
/// Used to instantiate a generic member: e.g. substituting `{T: Int}` into a
/// field declared `List<T>` yields `List<Int>`.
Type substitute(Type type, Map<String, Type> bindings) {
  switch (type) {
    case TypeParameterType(:final name):
      return bindings[name] ?? type;
    case InterfaceType(:final element, :final typeArguments):
      if (typeArguments.isEmpty) return type;
      return InterfaceType(
          element, [for (final a in typeArguments) substitute(a, bindings)]);
    case FunctionType(:final parameterTypes, :final returnType):
      return FunctionType(
        [for (final p in parameterTypes) substitute(p, bindings)],
        substitute(returnType, bindings),
      );
    case PrimitiveType():
    case UnknownType():
      return type;
  }
}

/// Best-effort unification: when [param] is (or contains) a type parameter,
/// record what [actual] binds it to in [bindings]. Used to recover generic
/// type arguments from call/constructor argument types.
void unify(Type param, Type actual, Map<String, Type> bindings) {
  switch (param) {
    case TypeParameterType(:final name):
      if (actual is! UnknownType) bindings.putIfAbsent(name, () => actual);
    case InterfaceType(:final typeArguments):
      if (actual is InterfaceType &&
          actual.typeArguments.length == typeArguments.length) {
        for (var i = 0; i < typeArguments.length; i++) {
          unify(typeArguments[i], actual.typeArguments[i], bindings);
        }
      }
    case PrimitiveType():
    case FunctionType():
    case UnknownType():
      break;
  }
}

bool _typeListEq(List<Type> a, List<Type> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
