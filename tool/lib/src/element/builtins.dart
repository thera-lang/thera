import 'element.dart';
import 'types.dart';

/// The built-in methods on primitive/collection types, backed by runtime
/// natives. This is the single source of truth shared by:
///
/// - the inference pass (`inference.dart`), which uses [builtinReturns] to
///   compute a method call's generic-aware result type, and
/// - codegen (`codegen/codegen.dart`), which uses [builtinMethodNatives] to
///   pick the native to emit.
///
/// Both maps are keyed by `(receiverKind, method)`; a receiver kind is a
/// primitive name (`String`) or a built-in generic's name (`List`/`Map`/
/// `Option`). A test asserts the two stay in lock-step (see
/// `builtins_test.dart`).

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
  'List': {
    'len': 'list_len',
    'get': 'list_get',
    'join': 'list_join',
  },
  'Map': {
    'len': 'map_len',
    'get': 'map_get',
    'has': 'map_has',
    'keys': 'map_keys',
    'values': 'map_values',
    'remove': 'map_remove',
    'is_empty': 'map_is_empty',
  },
  'Option': {
    'ok_or': 'option_ok_or',
    'unwrap_or': 'option_unwrap_or',
    'is_some': 'option_is_some',
    'is_none': 'option_is_none',
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
  Type arg(List<Type> args, int i) =>
      i < args.length ? args[i] : const UnknownType();
  Type option(Type t) => InterfaceType(typeDefs['Option']!, [t]);
  Type list(Type t) => InterfaceType(typeDefs['List']!, [t]);
  Type result(Type t, Type e) => InterfaceType(typeDefs['Result']!, [t, e]);

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
    'List': {
      'len': (r, a) => int_,
      'get': (r, a) => option(arg(r, 0)),
      'join': (r, a) => string,
    },
    'Map': {
      'len': (r, a) => int_,
      'get': (r, a) => option(arg(r, 1)),
      'remove': (r, a) => option(arg(r, 1)),
      'has': (r, a) => bool_,
      'is_empty': (r, a) => bool_,
      'keys': (r, a) => list(arg(r, 0)),
      'values': (r, a) => list(arg(r, 1)),
    },
    'Option': {
      'ok_or': (r, a) =>
          result(arg(r, 0), a.isEmpty ? const UnknownType() : a.first),
      'unwrap_or': (r, a) => arg(r, 0),
      'is_some': (r, a) => bool_,
      'is_none': (r, a) => bool_,
    },
  };
}
