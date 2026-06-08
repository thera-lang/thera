import 'element.dart';
import 'types.dart';

/// The built-in methods on primitive types, backed by runtime natives. This is
/// the single source of truth shared by:
///
/// - the inference pass (`inference.dart`), which uses [builtinReturns] to
///   compute a method call's generic-aware result type, and
/// - codegen (`codegen/codegen.dart`), which uses [builtinMethodNatives] to
///   pick the native to emit.
///
/// Both maps are keyed by `(receiverKind, method)`; a receiver kind is a
/// primitive name (`String`). A test asserts the two stay in lock-step (see
/// `builtins_test.dart`).
///
/// The generic collection/enum methods (`List`/`Map`/`Option`) used to live here
/// too; they are now ordinary `native fn`s declared in `sdk/std/core/`
/// (list.hawk/map.hawk/option.hawk) and resolved through the element model. Only
/// `String` remains, pending the primitive-receiver method resolution that lets
/// it move as well.

/// `(receiverKind, method)` -> runtime native name.
const Map<String, Map<String, String>> builtinMethodNatives = {
  'String': {
    'len': 'str_len',
    'byte_len': 'str_byte_len',
    'is_empty': 'str_is_empty',
    'trim': 'str_trim',
    'contains': 'str_contains',
    'starts_with': 'str_starts_with',
    'ends_with': 'str_ends_with',
    'to_uppercase': 'str_to_uppercase',
    'to_lowercase': 'str_to_lowercase',
    'lines': 'str_lines',
    'split_whitespace': 'str_split_whitespace',
    'split': 'str_split',
  },
};

/// Computes a built-in method's return type from the receiver's type arguments
/// and the call's argument types. E.g. `List<T>.get` -> `Option<T>`.
typedef BuiltinReturn = Type Function(
    List<Type> receiverArgs, List<Type> argTypes);

/// `(receiverKind, method)` -> return-type computation. Built against [typeDefs]
/// so the constructed `Option`/`List`/`Result` types reference the same element
/// instances inference uses (interface-type equality is by element identity).
Map<String, Map<String, BuiltinReturn>> builtinReturns(
    Map<String, TypeDefElement> typeDefs) {
  Type list(Type t) => InterfaceType(typeDefs['List']!, [t]);

  const int_ = PrimitiveType.int_;
  const bool_ = PrimitiveType.bool_;
  const string = PrimitiveType.string;

  return {
    'String': {
      'len': (r, a) => int_,
      'byte_len': (r, a) => int_,
      'is_empty': (r, a) => bool_,
      'trim': (r, a) => string,
      'contains': (r, a) => bool_,
      'starts_with': (r, a) => bool_,
      'ends_with': (r, a) => bool_,
      'to_uppercase': (r, a) => string,
      'to_lowercase': (r, a) => string,
      'lines': (r, a) => list(string),
      'split_whitespace': (r, a) => list(string),
      'split': (r, a) => list(string),
    },
  };
}
