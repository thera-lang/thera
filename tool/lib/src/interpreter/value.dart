import 'dart:collection';

import '../ast.dart';
import 'environment.dart';

/// The runtime representation of every Aero value.
sealed class Value {
  const Value();

  /// User-facing string (Display).
  String display();

  /// Developer-facing string (Debug).
  String debug() => display();

  /// Whether this value is truthy for use in boolean contexts.
  bool get isTruthy {
    return switch (this) {
      BoolValue(:final v) => v,
      _ => true,
    };
  }
}

class IntValue extends Value {
  final int v;
  const IntValue(this.v);
  @override
  String display() => '$v';
  @override
  bool operator ==(Object other) => other is IntValue && other.v == v;
  @override
  int get hashCode => v.hashCode;
}

class FloatValue extends Value {
  final double v;
  const FloatValue(this.v);
  @override
  String display() => '$v';
  @override
  bool operator ==(Object other) => other is FloatValue && other.v == v;
  @override
  int get hashCode => v.hashCode;
}

class BoolValue extends Value {
  final bool v;
  const BoolValue(this.v);
  static const trueVal = BoolValue(true);
  static const falseVal = BoolValue(false);
  factory BoolValue.of(bool v) => v ? trueVal : falseVal;
  @override
  String display() => '$v';
  @override
  bool operator ==(Object other) => other is BoolValue && other.v == v;
  @override
  int get hashCode => v.hashCode;
}

class StringValue extends Value {
  final String v;
  const StringValue(this.v);
  @override
  String display() => v;
  @override
  String debug() => '"$v"';
  @override
  bool operator ==(Object other) => other is StringValue && other.v == v;
  @override
  int get hashCode => v.hashCode;
}

class ListValue extends Value {
  final List<Value> items;
  ListValue(this.items);
  @override
  String display() => '[${items.map((i) => i.debug()).join(', ')}]';
  @override
  bool operator ==(Object other) =>
      other is ListValue &&
      other.items.length == items.length &&
      List.generate(items.length, (i) => items[i] == other.items[i])
          .every((b) => b);
  @override
  int get hashCode => Object.hashAll(items);
}

class MapValue extends Value {
  final LinkedHashMap<Value, Value> entries;
  MapValue(this.entries);

  factory MapValue.empty() => MapValue(LinkedHashMap());

  @override
  String display() {
    final es = entries.entries
        .map((e) => '${e.key.debug()}: ${e.value.display()}')
        .join(', ');
    return '{$es}';
  }

  @override
  String debug() {
    final es = entries.entries
        .map((e) => '${e.key.debug()}: ${e.value.debug()}')
        .join(', ');
    return '{$es}';
  }
}

class StructValue extends Value {
  final String typeName;
  final Map<String, Value> fields;
  StructValue(this.typeName, this.fields);
  @override
  String display() {
    final fs =
        fields.entries.map((e) => '${e.key}: ${e.value.display()}').join(', ');
    return '$typeName { $fs }';
  }

  @override
  String debug() {
    final fs =
        fields.entries.map((e) => '${e.key}: ${e.value.debug()}').join(', ');
    return '$typeName { $fs }';
  }
}

// Result<T, E>
class ResultValue extends Value {
  final bool isOk;
  final Value inner;
  const ResultValue.ok(this.inner) : isOk = true;
  const ResultValue.err(this.inner) : isOk = false;
  @override
  String display() =>
      isOk ? 'Ok(${inner.display()})' : 'Err(${inner.display()})';
  @override
  String debug() => isOk ? 'Ok(${inner.debug()})' : 'Err(${inner.debug()})';
}

// Option<T>
class OptionValue extends Value {
  final Value? inner; // null == None
  const OptionValue.some(Value v) : inner = v;
  const OptionValue.none() : inner = null;
  bool get isSome => inner != null;
  bool get isNone => inner == null;
  @override
  String display() => isSome ? 'Some(${inner!.display()})' : 'None';
  @override
  String debug() => isSome ? 'Some(${inner!.debug()})' : 'None';
}

// Unit / ()
class VoidValue extends Value {
  const VoidValue();
  static const instance = VoidValue();
  @override
  String display() => '()';
}

// Aero-defined function closure
class FnValue extends Value {
  final FnDecl decl;
  final Environment closure;
  FnValue(this.decl, this.closure);
  @override
  String display() => '<fn ${decl.name}>';
}

// Lambda: u => u.name
class LambdaValue extends Value {
  final List<String> params;
  final Expr body;
  final Environment closure;
  LambdaValue(this.params, this.body, this.closure);
  @override
  String display() => '<lambda>';
}

// Native (Dart-side) function
class NativeFnValue extends Value {
  final String name;
  final Value Function(List<Value> args, Map<String, Value> namedArgs) fn;
  NativeFnValue(this.name, this.fn);
  @override
  String display() => '<native $name>';
}

// ADT enum variant value: e.g. TokenKind.Ident("foo") or Direction.North
class EnumValue extends Value {
  final String typeName;
  final String variantName;
  final List<Value> fields;
  EnumValue(this.typeName, this.variantName, this.fields);

  @override
  String display() {
    if (fields.isEmpty) return variantName;
    return '$variantName(${fields.map((f) => f.display()).join(', ')})';
  }

  @override
  String debug() {
    if (fields.isEmpty) return '$typeName.$variantName';
    return '$typeName.$variantName(${fields.map((f) => f.debug()).join(', ')})';
  }

  @override
  bool operator ==(Object other) =>
      other is EnumValue &&
      typeName == other.typeName &&
      variantName == other.variantName &&
      fields.length == other.fields.length &&
      _fieldsEqual(other.fields);

  bool _fieldsEqual(List<Value> other) {
    for (var i = 0; i < fields.length; i++) {
      if (fields[i] != other[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(typeName, variantName, Object.hashAll(fields));
}

// Range a..b — a lazy sequence
class RangeValue extends Value {
  final int start;
  final int end;
  const RangeValue(this.start, this.end);
  @override
  String display() => '$start..$end';
}

// The runtime representation of the Args object passed to main().
class ArgsValue extends StructValue {
  final List<String> _cliPositionals;
  final Map<String, String> _cliFlags;

  ArgsValue(List<String> positionals, Map<String, String> flags)
      : _cliPositionals = positionals,
        _cliFlags = flags,
        super('Args', {});

  String? getFlag(String name) => _cliFlags[name];
  String? getPositional(int index) =>
      index < _cliPositionals.length ? _cliPositionals[index] : null;
  List<String> allPositionals() => List.unmodifiable(_cliPositionals);
}
