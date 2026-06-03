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
  int get hashCode =>
      Object.hash(returnType, Object.hashAll(parameterTypes));
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

bool _typeListEq(List<Type> a, List<Type> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
