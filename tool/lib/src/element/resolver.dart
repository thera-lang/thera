import '../ast.dart';
import 'element.dart';
import 'namespace.dart';
import 'types.dart';

/// Resolves syntactic [TypeRef]s to semantic [Type]s against a set of known
/// type definitions. Stateless apart from the [typeDefs] lookup table; pass a
/// `typeParams` scope and an optional `selfType` per call.
class TypeResolver {
  final Map<String, TypeDefElement> typeDefs;
  TypeResolver(this.typeDefs);

  /// Resolve [ref] to a [Type]. A null ref (e.g. an omitted return type or
  /// un-annotated parameter) resolves to [UnknownType].
  Type resolve(
    TypeRef? ref, {
    Set<String> typeParams = const {},
    Type? selfType,
  }) {
    switch (ref) {
      case null:
        return const UnknownType();
      case NamedType(:final name, :final args):
        final prim = primitiveType(name);
        if (prim != null) return prim;
        if (name == 'Self') return selfType ?? const UnknownType();
        if (typeParams.contains(name)) return TypeParameterType(name);
        final def = typeDefs[name];
        if (def == null) return const UnknownType();
        final resolvedArgs = [
          for (final a in args)
            resolve(a, typeParams: typeParams, selfType: selfType),
        ];
        return InterfaceType(def, resolvedArgs);
      case FunctionTypeRef(:final params, :final returnType):
        return FunctionType(
          [
            for (final p in params)
              resolve(p, typeParams: typeParams, selfType: selfType),
          ],
          resolve(returnType, typeParams: typeParams, selfType: selfType),
        );
    }
  }

  /// The [PrimitiveType] a type name denotes, or null if it isn't a primitive.
  /// Public so the element/inference passes can give `self` in an `impl Int`
  /// (etc.) the same primitive type the value has, rather than wrapping it as an
  /// interface type.
  static Type? primitiveType(String name) => switch (name) {
        'Int' => PrimitiveType.int_,
        'Bool' => PrimitiveType.bool_,
        'Double' || 'Float' => PrimitiveType.double_,
        'String' => PrimitiveType.string,
        'Void' => PrimitiveType.unit,
        _ => null,
      };
}

/// The built-in type-definition elements, by name. These back an
/// [InterfaceType] (the generics) and are the attachment point for `impl`
/// blocks and static-method lookup. A *value* of a primitive type still
/// resolves to [PrimitiveType] (see [TypeResolver]); the primitive entries here
/// exist so `impl String { ... }` attaches and `String.from_chars(...)`
/// resolves.
Map<String, TypeDefElement> builtinTypeDefs() => {
      // Primitives — for impl/static-method attachment only.
      'String': BuiltinTypeElement('String'),
      'Int': BuiltinTypeElement('Int'),
      'Bool': BuiltinTypeElement('Bool'),
      'Double': BuiltinTypeElement('Double'),
      // Generic built-ins.
      'List': BuiltinTypeElement('List', typeParameters: ['T']),
      'Set': BuiltinTypeElement('Set', typeParameters: ['T']),
      'Map': BuiltinTypeElement('Map', typeParameters: ['K', 'V']),
      'Result': BuiltinTypeElement('Result', typeParameters: ['T', 'E']),
      'Option': BuiltinTypeElement('Option', typeParameters: ['T']),
      // Opaque built-ins; real declarations (std.core's Error, std.args's Args)
      // shadow these when linked in.
      'Error': BuiltinTypeElement('Error'),
      'Args': BuiltinTypeElement('Args'),
    };

/// Builds the resolved [LibraryElement] for [program] plus any [imports].
///
/// Two passes: pass 1 registers a skeleton element for every declared type
/// (so mutually-recursive references resolve); pass 2 fills in member types,
/// function signatures, consts, and impl methods using a [TypeResolver] over
/// the complete type table.
LibraryElement buildLibrary(
  Program program, {
  List<Program> imports = const [],
  Map<String, LibraryNamespace> namespaces = const {},
}) {
  final typeDefs = builtinTypeDefs();
  final functions = <String, FunctionElement>{};
  final consts = <String, ConstElement>{};
  final modules = <String>{};

  // Imports are registered first so the primary program can shadow them.
  final programs = [...imports, program];

  // ---- pass 1: skeleton type definitions ----
  for (final p in programs) {
    for (final decl in p.decls) {
      switch (decl) {
        case TypeDecl():
          typeDefs[decl.name] = StructElement(decl.name,
              typeParameters: [for (final tp in decl.typeParams) tp.name]);
        case EnumDecl():
          typeDefs[decl.name] = EnumElement(decl.name,
              typeParameters: [for (final tp in decl.typeParams) tp.name]);
        case InterfaceDecl():
          typeDefs[decl.name] = InterfaceElement(decl.name);
        case ImportDecl():
          modules.add(decl.alias ?? decl.path.split('.').last);
        case FnDecl():
        case ImplDecl():
        case ConstDecl():
          break;
      }
    }
  }

  final resolver = TypeResolver(typeDefs);

  // ---- pass 2: members, signatures, consts ----
  for (final p in programs) {
    for (final decl in p.decls) {
      switch (decl) {
        case TypeDecl():
          final element = typeDefs[decl.name] as StructElement;
          final tps = {for (final tp in decl.typeParams) tp.name};
          for (final (fieldName, fieldType) in decl.fields) {
            element.fields[fieldName] =
                resolver.resolve(fieldType, typeParams: tps);
          }
        case EnumDecl():
          final element = typeDefs[decl.name] as EnumElement;
          final tps = {for (final tp in decl.typeParams) tp.name};
          for (final v in decl.variants) {
            element.variants.add(EnumVariantElement(
              v.name,
              [for (final f in v.fields) resolver.resolve(f, typeParams: tps)],
            ));
          }
        case FnDecl():
          functions[decl.name] = _functionElement(resolver, decl);
        case ConstDecl():
          consts[decl.name] =
              ConstElement(decl.name, resolver.resolve(decl.type));
        case ImplDecl():
          _resolveImpl(resolver, typeDefs, decl);
        case InterfaceDecl():
          final element = typeDefs[decl.name] as InterfaceElement;
          for (final m in decl.methods) {
            element.methods.add(_methodElement(resolver, element, m,
                selfType: InterfaceType(element)));
          }
        case ImportDecl():
          break;
      }
    }
  }

  return LibraryElement(
    typeDefs: typeDefs,
    functions: functions,
    consts: consts,
    modules: modules,
    namespaces: namespaces,
  );
}

void _resolveImpl(
  TypeResolver resolver,
  Map<String, TypeDefElement> typeDefs,
  ImplDecl decl,
) {
  final owner = typeDefs[decl.typeName];
  if (owner == null) return; // unknown target type; checker reports it
  // Record `impl Interface for Type` conformance (the checker validates it).
  if (decl.interfaceName != null &&
      !owner.interfaces.contains(decl.interfaceName)) {
    owner.interfaces.add(decl.interfaceName!);
  }
  final implParams = {for (final tp in decl.typeParams) tp.name};
  // For an `impl Int`/`String`/… the receiver's type is the primitive itself,
  // not an interface type wrapping its element — so `self` and `Self` match the
  // value (and the checker, which resolves `self` via the type name).
  final selfType = TypeResolver.primitiveType(decl.typeName) ??
      InterfaceType(owner, [
        for (final tp in decl.typeParams) TypeParameterType(tp.name),
      ]);
  for (final m in decl.methods) {
    owner.methods.add(_methodElement(resolver, owner, m,
        selfType: selfType, outerTypeParams: implParams));
  }
}

FunctionElement _functionElement(TypeResolver resolver, FnDecl fn) {
  final tps = {for (final tp in fn.typeParams) tp.name};
  return FunctionElement(
    fn.name,
    typeParameters: [for (final tp in fn.typeParams) tp.name],
    parameters: _params(resolver, fn, tps, null),
    returnType: _returnType(resolver, fn.returnType, tps, null),
  );
}

MethodElement _methodElement(
  TypeResolver resolver,
  TypeDefElement owner,
  FnDecl fn, {
  required Type selfType,
  Set<String> outerTypeParams = const {},
}) {
  final tps = {...outerTypeParams, for (final tp in fn.typeParams) tp.name};
  final isStatic = !fn.params.any((p) => p.isSelf);
  return MethodElement(
    fn.name,
    owner: owner,
    isStatic: isStatic,
    typeParameters: [for (final tp in fn.typeParams) tp.name],
    parameters: _params(resolver, fn, tps, selfType),
    returnType: _returnType(resolver, fn.returnType, tps, selfType),
  );
}

/// Resolve a function/method return type. A missing `-> Type` means the
/// function returns [PrimitiveType.unit] (not "unknown"), matching Hawk's
/// implicit-unit-return semantics.
Type _returnType(
  TypeResolver resolver,
  TypeRef? ref,
  Set<String> typeParams,
  Type? selfType,
) {
  if (ref == null) return PrimitiveType.unit;
  return resolver.resolve(ref, typeParams: typeParams, selfType: selfType);
}

List<ParameterElement> _params(
  TypeResolver resolver,
  FnDecl fn,
  Set<String> typeParams,
  Type? selfType,
) {
  final result = <ParameterElement>[];
  for (final p in fn.params) {
    if (p.isSelf) {
      result.add(ParameterElement(
        isSelf: true,
        name: 'self',
        type: selfType ?? const UnknownType(),
      ));
    } else {
      result.add(ParameterElement(
        label: p.label,
        name: p.name,
        type: resolver.resolve(p.type,
            typeParams: typeParams, selfType: selfType),
        hasDefault: p.defaultValue != null,
      ));
    }
  }
  return result;
}
