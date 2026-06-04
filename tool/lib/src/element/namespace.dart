import '../ast.dart';

/// The visibility/namespace layer of the element model.
///
/// Separate from the resolved-type table in `resolver.dart` (which stays a flat
/// typing substrate): this layer answers *name-resolution* questions — which
/// public names an import's namespace exposes, with barrel re-exports flattened
/// in — computed from the AST's `pub` markers. The actual resolved elements are
/// still looked up in the flat table by name.

/// A loaded library and the libraries its imports resolve to, keyed by the
/// import path exactly as written (so a namespace can be derived per import and
/// barrels can be followed). For a barrel, the `pub import` entries here are
/// what gets re-exported.
class LibrarySource {
  final Program program;
  final Map<String, LibrarySource> imports;
  LibrarySource(this.program, {this.imports = const {}});
}

/// The public surface a library exposes through its namespace: the set of
/// public symbol names, plus any names exported by more than one re-exported
/// library (a barrel collision — the author's to resolve).
class LibraryNamespace {
  final Set<String> names;
  final Set<String> collisions;
  const LibraryNamespace(this.names, this.collisions);

  bool exposes(String name) => names.contains(name);
}

/// The namespaces bound by [root]'s own imports: import namespace (the alias, or
/// the trailing path segment) -> the imported library's public surface.
Map<String, LibraryNamespace> namespacesFor(LibrarySource root) {
  final result = <String, LibraryNamespace>{};
  for (final decl in root.program.decls) {
    if (decl is! ImportDecl) continue;
    final child = root.imports[decl.path];
    if (child == null) continue; // unresolved import; reported elsewhere
    result[_namespaceOf(decl)] = publicSurfaceOf(child);
  }
  return result;
}

/// The public surface of [lib]: its own `pub` declarations plus the flattened
/// public surfaces of its `pub import`s.
LibraryNamespace publicSurfaceOf(LibrarySource lib) {
  final names = <String>{};
  final collisions = <String>{};
  void add(String name) {
    if (!names.add(name)) collisions.add(name);
  }

  void collect(LibrarySource source, Set<Program> visited) {
    if (!visited.add(source.program)) return; // guard re-export cycles
    for (final decl in source.program.decls) {
      final name = _publicName(decl);
      if (name != null) add(name);
    }
    for (final decl in source.program.decls) {
      if (decl is ImportDecl && decl.isPub) {
        final child = source.imports[decl.path];
        if (child != null) collect(child, visited);
      }
    }
  }

  collect(lib, <Program>{});
  return LibraryNamespace(names, collisions);
}

/// The namespace an import binds: its explicit alias, or the trailing segment
/// of its path (`std.fs` -> `fs`, `'util/strings'` -> `strings`).
String _namespaceOf(ImportDecl decl) =>
    decl.alias ?? decl.path.split(RegExp(r'[./]')).last;

/// The public top-level name a declaration contributes, or null when it is
/// private or has no name (impl blocks, imports).
String? _publicName(Decl decl) => switch (decl) {
      FnDecl(:final isPub, :final name) when isPub => name,
      TypeDecl(:final isPub, :final name) when isPub => name,
      EnumDecl(:final isPub, :final name) when isPub => name,
      ConstDecl(:final isPub, :final name) when isPub => name,
      InterfaceDecl(:final isPub, :final name) when isPub => name,
      _ => null,
    };
