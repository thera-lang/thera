/// Resolving and loading a program's import closure (shared by the CLI and the
/// LSP). Imports resolve to a single-file library or a directory barrel and are
/// linked transitively; the result feeds the type-checker and emitter so
/// cross-file symbols — and the auto-imported `std.core` prelude — are visible.
library;

import 'dart:io';

import 'ast.dart';
import 'element/namespace.dart';
import 'lexer.dart';
import 'parser.dart';

/// The loaded import closure of a program: the flat list of imported programs
/// (the typing/linking substrate) and the namespaces the program's own imports
/// bind (alias / trailing segment -> public surface).
typedef LoadedImports = ({
  List<Program> programs,
  Map<String, LibraryNamespace> namespaces,
});

/// The file-system operations the loader needs, injected so import-graph
/// resolution is a pure function of its inputs (and so the LSP can supply
/// unsaved-buffer overlays). The Hawk port supplies this as a `FileSystem`
/// capability (see docs/testability.md); on disk it is [DiskFileSystem], and a
/// test can pass an in-memory map.
abstract interface class FileSystem {
  /// The contents of [path], or null if it can't be read.
  String? read(String path);

  /// Whether [path] exists as a file.
  bool fileExists(String path);

  /// Whether [path] exists as a directory.
  bool directoryExists(String path);
}

/// The default [FileSystem]: reads real files via `dart:io`.
class DiskFileSystem implements FileSystem {
  const DiskFileSystem();

  @override
  String? read(String path) {
    try {
      return File(path).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  bool fileExists(String path) => File(path).existsSync();

  @override
  bool directoryExists(String path) => Directory(path).existsSync();
}

/// The directory portion of [path] — everything before the last `/` (pure string
/// work, so the loader logic needs no `dart:io`). `a/b/c.hawk` -> `a/b`.
String _dirname(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? '' : path.substring(0, i);
}

/// Locate the SDK root by searching upward from the running script.
///
/// Resolution order:
///   1. HAWK_SDK environment variable (if set and contains sdk/std/).
///   2. Walk up from Platform.script looking for a directory that contains
///      sdk/std/ — handles both `dart run tool/bin/hawk.dart` (dev) and a
///      compiled `bin/hawk` binary (distributed).
String? findSdkRoot() {
  final envRoot = Platform.environment['HAWK_SDK'];
  if (envRoot != null && Directory('$envRoot/sdk/std').existsSync()) {
    return envRoot;
  }
  try {
    var dir = Directory(File(Platform.script.toFilePath()).parent.path);
    for (var i = 0; i < 4; i++) {
      if (Directory('${dir.path}/sdk/std').existsSync()) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break; // filesystem root
      dir = parent;
    }
  } catch (_) {}
  return null;
}

/// Resolve a library base path (no extension) to its source file: the
/// single-file form `<base>.hawk`, or, when `<base>` is a directory, its
/// **barrel** `<base>/<name>.hawk` (named after the directory). Returns null if
/// neither exists.
///
/// (Per the visibility spec a base that is *both* a file and a directory is an
/// error; until the resolver moves into the element model this prefers the
/// file. See docs/language.md.)
String? resolveLibraryFile(String base, FileSystem fs) {
  final file = '$base.hawk';
  if (fs.fileExists(file)) return file;
  if (fs.directoryExists(base)) {
    final name = base.split('/').last;
    final barrel = '$base/$name.hawk';
    if (fs.fileExists(barrel)) return barrel;
  }
  return null;
}

/// Lex and parse [path] (read via [fs]), or null if it can't be read or has
/// lex/parse errors (the type-checker surfaces those against the primary
/// program).
Program? parseFileOrNull(String path, FileSystem fs) {
  final source = fs.read(path);
  if (source == null) return null;
  final lexResult = Lexer(source).tokenize();
  if (lexResult.hasErrors) return null;
  final parseResult = Parser(lexResult.tokens).parse();
  if (parseResult.hasErrors) return null;
  parseResult.program.filePath = path;
  return parseResult.program;
}

/// Resolve and parse the import closure of [program] (located at [path]) so the
/// checker/emitter can link those libraries in, and derive the program's import
/// namespaces. Imports resolve transitively (see [resolveLibraryFile]);
/// unparseable/missing imports are skipped (the type-checker reports them). The
/// [program] itself is used as-is (not re-read), so in-memory edits are honored.
///
/// [fs] is the file-system seam (default: real disk); the LSP passes an
/// overlay-aware one. [sdkRoot] locates `std.*` (default: discovered via
/// [findSdkRoot]); passing both makes this a pure function of its inputs.
LoadedImports loadImports(String path, Program program,
    {FileSystem fs = const DiskFileSystem(), String? sdkRoot}) {
  sdkRoot ??= findSdkRoot();
  final order = <Program>[]; // imported programs, deduped, in load order
  final cache = <String, LibrarySource>{}; // resolved file -> library source

  // Resolve an import path to a source file. `std.*` is anchored at the SDK std
  // root (dots become directory separators); any other path is relative to the
  // importing file. The base then resolves to a single-file library or a
  // directory's barrel — see [resolveLibraryFile].
  String? resolve(String importPath, String baseDir) {
    final String base;
    if (importPath.startsWith('std.')) {
      if (sdkRoot == null) return null;
      final rel = importPath.substring('std.'.length).replaceAll('.', '/');
      base = '$sdkRoot/sdk/std/$rel';
    } else {
      base = '$baseDir/$importPath';
    }
    return resolveLibraryFile(base, fs);
  }

  // Resolve [file] to a library source, recursively linking its imports. Cached
  // (and cached *before* recursing, to terminate cycles); each program is added
  // to the flat list exactly once.
  LibrarySource? sourceFor(String file) {
    final cached = cache[file];
    if (cached != null) return cached;
    final prog = parseFileOrNull(file, fs);
    if (prog == null)
      return null; // missing/unparseable; the checker reports it
    final source = LibrarySource(prog);
    cache[file] = source;
    _linkImports(prog, _dirname(file), resolve, sourceFor, source);
    order.add(prog);
    return source;
  }

  // std.core is auto-imported into every program — load it so its types (e.g.
  // Error) and impls (Display for Error), and the prelude methods on built-in
  // types (List.map/filter/fold, String helpers) link. It is the unqualified
  // prelude, not a namespace, so it is not added to the root's imports.
  final core = resolve('std.core', '');
  if (core != null) sourceFor(core);

  // The primary program is already parsed; resolve its imports so its
  // namespaces can be derived.
  final root = LibrarySource(program);
  cache[path] = root;
  _linkImports(program, _dirname(path), resolve, sourceFor, root);

  // Namespaces are the union across every linked module, not just the root's.
  // An imported module's body can itself use a namespace-qualified call into
  // *its* imports (e.g. a tested module's `cli.Args.new`), and codegen lowers
  // every module against one flat table — so it needs all the namespace names,
  // not only the entry program's. The root's bindings win on a name collision.
  final namespaces = {...namespacesFor(root)};
  for (final src in cache.values) {
    namespacesFor(src).forEach((name, surface) {
      namespaces.putIfAbsent(name, () => surface);
    });
  }
  return (programs: order, namespaces: namespaces);
}

/// Resolve each `import` in [prog] and record the child library under the import
/// path on [into].
void _linkImports(
  Program prog,
  String baseDir,
  String? Function(String, String) resolve,
  LibrarySource? Function(String) sourceFor,
  LibrarySource into,
) {
  for (final decl in prog.decls) {
    if (decl is! ImportDecl) continue;
    final file = resolve(decl.path, baseDir);
    if (file == null) continue;
    final child = sourceFor(file);
    if (child != null) into.imports[decl.path] = child;
  }
}
