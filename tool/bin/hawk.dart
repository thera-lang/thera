import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:hawk/src/ast.dart';
import 'package:hawk/src/bytecode/encoder.dart';
import 'package:hawk/src/checker/type_checker.dart';
import 'package:hawk/src/bytecode/module.dart';
import 'package:hawk/src/codegen/codegen.dart';
import 'package:hawk/src/element/namespace.dart';
import 'package:hawk/src/interpreter/interpreter.dart';
import 'package:hawk/src/lexer.dart';
import 'package:hawk/src/lsp/server.dart';
import 'package:hawk/src/parser.dart';

/// Locate the SDK root by searching upward from the running script.
///
/// Resolution order:
///   1. HAWK_SDK environment variable (if set and contains sdk/std/).
///   2. Walk up from Platform.script looking for a directory that contains
///      sdk/std/ — handles both `dart run tool/bin/hawk.dart` (dev) and a
///      compiled `bin/hawk` binary (distributed).
String? _findSdkRoot() {
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

void main(List<String> args) async {
  final runner = CommandRunner<void>('hawk', 'The Hawk language toolchain.')
    ..addCommand(ParseCommand())
    ..addCommand(RunCommand())
    ..addCommand(EmitCommand())
    ..addCommand(CheckCommand())
    ..addCommand(TestCommand())
    ..addCommand(LspCommand());

  try {
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln();
    stderr.writeln(e.usage);
    exit(64);
  }
}

Program _loadProgram(String path) {
  final String source;
  try {
    source = File(path).readAsStringSync();
  } on FileSystemException catch (e) {
    stderr.writeln('hawk: $e');
    exit(1);
  }

  final lexResult = Lexer(source).tokenize();
  if (lexResult.hasErrors) {
    for (final err in lexResult.errors) {
      stderr.writeln('$path:$err');
    }
    exit(1);
  }

  final parseResult = Parser(lexResult.tokens).parse();
  if (parseResult.hasErrors) {
    for (final err in parseResult.errors) {
      stderr.writeln('$path:$err');
    }
    exit(1);
  }

  return parseResult.program;
}

class ParseCommand extends Command<void> {
  @override
  String get name => 'parse';

  @override
  String get description => 'Lex and parse <file>, then print the AST.';

  @override
  String get invocation => 'hawk parse <file>';

  @override
  void run() {
    if (argResults!.rest.isEmpty) {
      usageException('Expected a file argument.');
    }
    stdout.write(_loadProgram(argResults!.rest[0]).describe());
  }
}

class RunCommand extends Command<void> {
  RunCommand() {
    // All args after '--' flow through argResults.rest after the filename.
  }

  @override
  String get name => 'run';

  @override
  String get description =>
      'Run <file>; arguments after -- are passed to main.';

  @override
  String get invocation => 'hawk run <file> [-- args]';

  @override
  void run() {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('Expected a file argument.');
    }
    final path = rest[0];
    final sep = rest.indexOf('--');
    final programArgs = sep >= 0 ? rest.sublist(sep + 1) : rest.sublist(1);

    final program = _loadProgram(path);
    final exitCode = Interpreter(sdkRoot: _findSdkRoot())
        .execute(program, programArgs, baseDir: File(path).parent.path);
    exit(exitCode);
  }
}

class EmitCommand extends Command<void> {
  @override
  String get name => 'emit';

  @override
  String get description => 'Compile <file> to bytecode, written to <out>.';

  @override
  String get invocation => 'hawk emit <file> <out.hawkbc>';

  @override
  void run() {
    final rest = argResults!.rest;
    if (rest.length < 2) {
      usageException('Expected <file> and <out> arguments.');
    }
    final path = rest[0];
    final out = rest[1];

    final program = _loadProgram(path);
    final imports = _loadImports(path, program);

    // Type-check before lowering: codegen assumes a well-typed program.
    final result = _typeCheck(path, program, imports);
    if (result.errors.isNotEmpty) {
      for (final err in result.errors) {
        stderr.writeln(err.format(path));
      }
      exit(1);
    }

    final Module module;
    try {
      module = compileProgram(program,
          imports: imports.programs, namespaces: imports.namespaces);
    } on CodegenException catch (e) {
      stderr.writeln('hawk: $path: ${e.message}');
      exit(1);
    }
    File(out).writeAsBytesSync(encodeModule(module));
  }
}

class CheckCommand extends Command<void> {
  @override
  String get name => 'check';

  @override
  String get description =>
      'Type-check <file> or all *.hawk files in a directory.';

  @override
  String get invocation => 'hawk check <file|dir>...';

  @override
  void run() {
    final targets = argResults!.rest;
    if (targets.isEmpty) usageException('Expected a file or directory.');

    // Collect all .hawk paths from the targets (files directly, dirs recursively).
    final paths = <String>[];
    for (final target in targets) {
      final entity = FileSystemEntity.typeSync(target);
      if (entity == FileSystemEntityType.file) {
        paths.add(target);
      } else if (entity == FileSystemEntityType.directory) {
        paths.addAll(
          Directory(target)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.hawk'))
              .map((f) => f.path),
        );
      } else {
        stderr.writeln('hawk check: not found: $target');
        exit(1);
      }
    }

    var totalErrors = 0;
    for (final path in paths) {
      totalErrors += _checkFile(path);
    }
    exit(totalErrors > 0 ? 1 : 0);
  }

  /// Type-check one file; returns the number of errors found.
  int _checkFile(String path) {
    // Load the primary program; lex/parse errors are printed and counted.
    final Program program;
    try {
      program = _loadProgramQuiet(path, verbose: true);
    } on _LoadFailed {
      return 1;
    }
    final result = _typeCheck(path, program, _loadImports(path, program));
    for (final err in result.errors) {
      stderr.writeln(err.format(path));
    }
    return result.errors.length;
  }
}

/// Type-check [program] (located at [path]). [imports] is its loaded import
/// closure (see [_loadImports]); registering those programs lets cross-module
/// names — relative functions, std types like `Args`, and module-qualified
/// access (`fs.read_text`) — resolve via the element model.
CheckResult _typeCheck(String path, Program program, LoadedImports imports) {
  final checker = TypeChecker();
  for (final imported in imports.programs) {
    checker.addProgram(imported);
  }
  return checker.check(program, namespaces: imports.namespaces);
}

/// The loaded import closure of a program: the flat list of imported programs
/// (the typing/linking substrate) and the namespaces the program's own imports
/// bind (alias / trailing segment -> public surface).
typedef LoadedImports = ({
  List<Program> programs,
  Map<String, LibraryNamespace> namespaces,
});

/// Resolve and parse the import closure of [program] (located at [path]) so the
/// emitter can link those libraries in, and derive the program's import
/// namespaces. Imports resolve to a single file or a directory barrel (see
/// [resolveLibraryFile]), transitively; unparseable/missing imports are skipped
/// (the type-checker already reported them).
LoadedImports _loadImports(String path, Program program) {
  final sdkRoot = _findSdkRoot();
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
    return resolveLibraryFile(base);
  }

  // Resolve [file] to a library source, recursively linking its imports. Cached
  // (and cached *before* recursing, to terminate cycles); each program is added
  // to the flat list exactly once.
  LibrarySource? sourceFor(String file) {
    final cached = cache[file];
    if (cached != null) return cached;
    final Program prog;
    try {
      prog = _loadProgramQuiet(file);
    } on _LoadFailed {
      return null; // missing/unparseable; the checker reports it
    }
    final source = LibrarySource(prog);
    cache[file] = source;
    _linkImports(prog, File(file).parent.path, resolve, sourceFor, source);
    order.add(prog);
    return source;
  }

  // std.core is auto-imported into every program — load it so its types (e.g.
  // Error) and impls (Display for Error) link. It is the unqualified prelude,
  // not a namespace, so it is not added to the root's imports.
  final core = resolve('std.core', '');
  if (core != null) sourceFor(core);

  // The primary program is already parsed; resolve its imports so its
  // namespaces can be derived.
  final root = LibrarySource(program);
  cache[path] = root;
  _linkImports(program, File(path).parent.path, resolve, sourceFor, root);

  return (programs: order, namespaces: namespacesFor(root));
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

/// Resolve a library base path (no extension) to its source file: the
/// single-file form `<base>.hawk`, or, when `<base>` is a directory, its
/// **barrel** `<base>/<name>.hawk` (named after the directory). Returns null if
/// neither exists.
///
/// (Per the visibility spec a base that is *both* a file and a directory is an
/// error; until the resolver moves into the element model this prefers the
/// file. See docs/visibility.md.)
String? resolveLibraryFile(String base) {
  final file = '$base.hawk';
  if (File(file).existsSync()) return file;
  if (Directory(base).existsSync()) {
    final name = base.split('/').last;
    final barrel = '$base/$name.hawk';
    if (File(barrel).existsSync()) return barrel;
  }
  return null;
}

/// Thrown by [_loadProgramQuiet] when lex/parse fails.
class _LoadFailed implements Exception {}

/// Like [_loadProgram] but throws [_LoadFailed] instead of calling [exit].
/// When [verbose] is true, lex/parse errors are printed to stderr before throwing.
Program _loadProgramQuiet(String path, {bool verbose = false}) {
  final String source;
  try {
    source = File(path).readAsStringSync();
  } on FileSystemException {
    if (verbose) stderr.writeln('hawk: cannot read $path');
    throw _LoadFailed();
  }
  final lexResult = Lexer(source).tokenize();
  if (lexResult.hasErrors) {
    if (verbose) {
      for (final err in lexResult.errors) stderr.writeln('$path:$err');
    }
    throw _LoadFailed();
  }
  final parseResult = Parser(lexResult.tokens).parse();
  if (parseResult.hasErrors) {
    if (verbose) {
      for (final err in parseResult.errors) stderr.writeln('$path:$err');
    }
    throw _LoadFailed();
  }
  return parseResult.program;
}

class LspCommand extends Command<void> {
  @override
  String get name => 'lsp';

  @override
  String get description =>
      'Start the Hawk LSP server (communicates via stdio).';

  @override
  String get invocation => 'hawk lsp';

  @override
  Future<void> run() => LspServer().run();
}

class TestCommand extends Command<void> {
  TestCommand() {
    argParser.addFlag('verbose', abbr: 'v', help: 'Print passing tests too.');
  }

  @override
  String get name => 'test';

  @override
  String get description => 'Run @test functions in one or more files.';

  @override
  String get invocation => 'hawk test <file>...';

  @override
  void run() {
    final files = argResults!.rest;
    if (files.isEmpty) {
      usageException('Expected at least one file argument.');
    }
    final verbose = argResults!.flag('verbose');
    var totalFailures = 0;
    for (final path in files) {
      final program = _loadProgram(path);
      totalFailures += Interpreter(sdkRoot: _findSdkRoot())
          .runTests(program, path, verbose: verbose);
    }
    exit(totalFailures > 0 ? 1 : 0);
  }
}
