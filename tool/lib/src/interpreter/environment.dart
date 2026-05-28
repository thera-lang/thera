import 'value.dart';

class Environment {
  final Environment? _parent;
  final Map<String, Value> _bindings = {};

  Environment([this._parent]);

  factory Environment.child(Environment parent) => Environment(parent);

  /// Return the value bound to [name], searching parent scopes.
  /// Throws [StateError] if not found.
  Value lookup(String name) =>
      tryLookup(name) ?? (throw StateError('undefined: $name'));

  /// Like [lookup] but returns null instead of throwing.
  Value? tryLookup(String name) =>
      _bindings[name] ?? _parent?.tryLookup(name);

  /// Define [name] in this scope.  Shadows any outer binding.
  void define(String name, Value value) {
    _bindings[name] = value;
  }

  /// Assign [value] to the nearest scope that already has [name].
  /// Returns false if [name] is not defined in any scope.
  bool assign(String name, Value value) {
    if (_bindings.containsKey(name)) {
      _bindings[name] = value;
      return true;
    }
    return _parent?.assign(name, value) ?? false;
  }
}
