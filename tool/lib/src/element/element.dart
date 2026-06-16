import 'namespace.dart';
import 'types.dart';

/// A resolved declaration — a node in the *element model*, which is built as a
/// separate stage over the parsed AST (see `resolver.dart`).
///
/// Where the AST records syntax (a [TypeRef] is just a name + args), elements
/// carry *resolved* member types ([Type]) and cross-references to the
/// declarations they name.
sealed class Element {
  String get name;
}

/// Common supertype of everything that can be the target of an [InterfaceType]:
/// structs, enums, interfaces, and the built-in generic types.
sealed class TypeDefElement extends Element {
  /// Names of the declared generic type parameters, e.g. `['K', 'V']`.
  List<String> get typeParameters;

  /// Methods declared in `impl` blocks for this type. Filled during
  /// resolution; empty for built-ins.
  List<MethodElement> get methods;

  /// Names of interfaces this type implements, from `impl Interface for Type`
  /// blocks. Filled during resolution; the checker validates each conformance.
  final List<String> interfaces = [];

  MethodElement? method(String name) {
    for (final m in methods) {
      if (m.name == name) return m;
    }
    return null;
  }

  /// Whether this type declares it implements [interfaceName].
  bool implementsInterface(String interfaceName) =>
      interfaces.contains(interfaceName);
}

class StructElement extends TypeDefElement {
  @override
  final String name;
  @override
  final List<String> typeParameters;

  /// Field name -> resolved field type. Filled during resolution.
  final Map<String, Type> fields = {};
  @override
  final List<MethodElement> methods = [];

  StructElement(this.name, {this.typeParameters = const []});

  @override
  String toString() => 'struct $name';
}

class EnumElement extends TypeDefElement {
  @override
  final String name;
  @override
  final List<String> typeParameters;

  /// Variants, in declaration order. Filled during resolution.
  final List<EnumVariantElement> variants = [];
  @override
  final List<MethodElement> methods = [];

  EnumElement(this.name, {this.typeParameters = const []});

  EnumVariantElement? variant(String name) {
    for (final v in variants) {
      if (v.name == name) return v;
    }
    return null;
  }

  @override
  String toString() => 'enum $name';
}

class EnumVariantElement {
  final String name;

  /// Resolved positional payload types; empty for a payload-free variant.
  final List<Type> fields;
  const EnumVariantElement(this.name, this.fields);
}

class InterfaceElement extends TypeDefElement {
  @override
  final String name;
  @override
  final List<String> typeParameters;
  @override
  final List<MethodElement> methods = [];

  /// Names of interfaces this one extends (`interface Error: Display + Debug`).
  /// Filled during resolution; the relation is acyclic (checked there).
  final List<String> superInterfaces = [];

  /// Method names declared *directly* on this interface (not inherited). After
  /// resolution [methods] also carries the super-interfaces' methods (flattened
  /// for lookup/dispatch); conformance requires only these own methods, since
  /// the inherited ones are satisfied by implementing the super separately.
  final Set<String> ownMethods = {};

  InterfaceElement(this.name, {this.typeParameters = const []});

  @override
  String toString() => 'interface $name';
}

/// A built-in type definition (`Int` and friends are primitives, but the
/// generic built-ins `List`/`Map`/`Set`/`Result`/`Option` and the opaque
/// `Error`/`Args` are modelled as elements so they can back an [InterfaceType]).
class BuiltinTypeElement extends TypeDefElement {
  @override
  final String name;
  @override
  final List<String> typeParameters;
  @override
  final List<MethodElement> methods = [];

  BuiltinTypeElement(this.name, {this.typeParameters = const []});

  @override
  String toString() => 'builtin $name';
}

class ParameterElement {
  /// External argument label; null when suppressed (`_`).
  final String? label;
  final bool isSelf;
  final String name;
  final Type type;
  final bool hasDefault;
  const ParameterElement({
    this.label,
    this.isSelf = false,
    required this.name,
    required this.type,
    this.hasDefault = false,
  });
}

class FunctionElement extends Element {
  @override
  final String name;
  final List<String> typeParameters;

  /// Each generic parameter's interface bounds, e.g. `{T: [Display]}` for
  /// `fn f<T: Display>(...)`. Used to enforce bounds at call sites.
  final Map<String, List<String>> typeParameterBounds;
  final List<ParameterElement> parameters;
  final Type returnType;

  FunctionElement(
    this.name, {
    this.typeParameters = const [],
    this.typeParameterBounds = const {},
    required this.parameters,
    required this.returnType,
  });

  @override
  String toString() {
    final ps = parameters.map((p) => '${p.name}: ${p.type}').join(', ');
    return 'fn $name($ps) -> $returnType';
  }
}

/// A method declared in an `impl` block. [isStatic] is true when there is no
/// `self` parameter (e.g. `Point.origin()`).
class MethodElement extends FunctionElement {
  final TypeDefElement owner;
  final bool isStatic;

  MethodElement(
    super.name, {
    required this.owner,
    required this.isStatic,
    super.typeParameters,
    super.typeParameterBounds,
    required super.parameters,
    required super.returnType,
  });
}

class ConstElement extends Element {
  @override
  final String name;
  final Type type;
  ConstElement(this.name, this.type);
}

/// The resolved element model for a program plus its imports: the top-level
/// declarations, with all member types resolved.
class LibraryElement {
  final Map<String, TypeDefElement> typeDefs;
  final Map<String, FunctionElement> functions;
  final Map<String, ConstElement> consts;

  /// Per-file free functions (declaring file -> name -> element), so a bare
  /// function reference resolves **same-file-first** — a private helper resolves
  /// to its own file's definition even when another co-loaded file declares a
  /// same-named one. [functions] above is the cross-file fallback (last-wins).
  /// Mirrors codegen's `_fileFunctions`/`_globalFunctions`.
  final Map<String?, Map<String, FunctionElement>> fileFunctions;

  /// Resolve free function [name] referenced from [file]: the file's own
  /// function if it has one, else the cross-file fallback.
  FunctionElement? functionFor(String? file, String name) =>
      fileFunctions[file]?[name] ?? functions[name];

  /// Module aliases brought in by `import std.x` (the value side, e.g. `fs`).
  final Set<String> modules;

  /// Namespace (import alias / trailing path segment) -> the public surface it
  /// exposes, for the program being compiled. Empty when imports aren't
  /// structured (e.g. tests/LSP that don't load an import tree), in which case
  /// name resolution falls back to the flat tables above.
  final Map<String, LibraryNamespace> namespaces;

  LibraryElement({
    required this.typeDefs,
    required this.functions,
    required this.consts,
    required this.modules,
    this.fileFunctions = const {},
    this.namespaces = const {},
  });
}
