import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:hawk/src/ast.dart';
import 'package:hawk/src/bytecode/encoder.dart';
import 'package:hawk/src/checker/type_checker.dart';
import 'package:hawk/src/codegen/codegen.dart';
import 'package:hawk/src/lexer.dart';
import 'package:hawk/src/loader.dart';
import 'package:hawk/src/lsp/server.dart';
import 'package:hawk/src/parser.dart';

/// The Rust runtime binary in the development repo, or null if it isn't built.
/// Assumes a dev checkout: `runtime/target/debug/hawkrt` under the repo root (the
/// same directory that holds `sdk/std/`).
String? _findRuntimeBinary() {
  final root = findSdkRoot();
  if (root == null) return null;
  final bin = '$root/runtime/target/debug/hawkrt';
  return File(bin).existsSync() ? bin : null;
}

/// Compile the program at [path] to bytecode bytes, type-checking before
/// lowering (codegen assumes a well-typed program). Prints diagnostics and
/// exits non-zero on any lex/parse/type/codegen error.
List<int> _emitBytes(String path) => _compileProgram(path, _loadProgram(path));

/// Compile an already-parsed [program] (located at [path], used to resolve its
/// relative imports) to bytecode bytes. Type-checks before lowering; prints
/// diagnostics and exits non-zero on any type/codegen error. Separated from
/// [_emitBytes] so `hawk test` can compile a synthesized driver program.
List<int> _compileProgram(String path, Program program) {
  final imports = loadImports(path, program);

  final result = _typeCheck(path, program, imports);
  if (result.errors.isNotEmpty) {
    for (final err in result.errors) {
      stderr.writeln(err.format(path));
    }
    exit(1);
  }

  try {
    final module = compileProgram(program,
        imports: imports.programs, namespaces: imports.namespaces);
    return encodeModule(module);
  } on CodegenException catch (e) {
    stderr.writeln('hawk: $path: ${e.message}');
    exit(1);
  }
}

void main(List<String> args) async {
  final runner = CommandRunner<void>('hawk', 'The Hawk language toolchain.')
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

class RunCommand extends Command<void> {
  @override
  String get name => 'run';

  @override
  String get description =>
      'Compile and run <file>; arguments after -- are passed to main.';

  @override
  String get invocation => 'hawk run <file> [-- args]';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('Expected a file argument.');
    }
    final path = rest[0];
    final sep = rest.indexOf('--');
    final programArgs = sep >= 0 ? rest.sublist(sep + 1) : rest.sublist(1);

    // Compile to a temporary .hawkbc (exits non-zero on any error), then
    // execute it on the Rust runtime.
    final bytes = _emitBytes(path);
    final runtime = _findRuntimeBinary();
    if (runtime == null) {
      stderr.writeln('hawk: the Rust runtime was not found at '
          'runtime/target/debug/hawkrt. Build it first: run `cargo build` in '
          'the runtime/ directory.');
      exit(1);
    }

    final dir = Directory.systemTemp.createTempSync('hawk_run');
    File('${dir.path}/out.hawkbc').writeAsBytesSync(bytes);
    final process = await Process.start(
      runtime,
      ['${dir.path}/out.hawkbc', ...programArgs],
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    exit(code);
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
    File(rest[1]).writeAsBytesSync(_emitBytes(rest[0]));
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
    final result = _typeCheck(path, program, loadImports(path, program));
    for (final err in result.errors) {
      stderr.writeln(err.format(path));
    }
    return result.errors.length;
  }
}

/// Type-check [program] (located at [path]). [imports] is its loaded import
/// closure (see [loadImports]); registering those programs lets cross-module
/// names — relative functions, std types like `Args`, and module-qualified
/// access (`fs.read_text`) — resolve via the element model.
CheckResult _typeCheck(String path, Program program, LoadedImports imports) {
  final checker = TypeChecker();
  for (final imported in imports.programs) {
    checker.addProgram(imported);
  }
  return checker.check(program, namespaces: imports.namespaces);
}

// The import-closure loader (`loadImports`, `LoadedImports`, `findSdkRoot`,
// `resolveLibraryFile`) lives in `src/loader.dart` so the LSP shares it.

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
  @override
  String get name => 'test';

  @override
  String get description =>
      'Run @test functions in *_test.hawk files (or a directory of them).';

  @override
  String get invocation => 'hawk test <file|dir>...';

  @override
  Future<void> run() async {
    final targets = argResults!.rest;
    if (targets.isEmpty) usageException('Expected a file or directory.');

    final runtime = _findRuntimeBinary();
    if (runtime == null) {
      stderr.writeln('hawk: the Rust runtime was not found at '
          'runtime/target/debug/hawkrt. Build it first: run `cargo build` in '
          'the runtime/ directory.');
      exit(1);
    }

    final files = _collectTestFiles(targets);
    if (files.isEmpty) {
      stderr.writeln('hawk test: no *_test.hawk files found.');
      exit(1);
    }

    var totalTests = 0;
    var failedFiles = 0;
    final tmp = Directory.systemTemp.createTempSync('hawk_test');
    for (final path in files) {
      final count = await _runTestFile(path, runtime, tmp);
      if (count == null) {
        failedFiles++; // compile/load error (already reported)
      } else {
        totalTests += count.total;
        if (count.failures > 0) failedFiles++;
      }
    }
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}

    stdout.writeln();
    stdout.writeln(failedFiles == 0
        ? 'All tests passed ($totalTests in ${files.length} file'
            '${files.length == 1 ? '' : 's'}).'
        : '$failedFiles of ${files.length} file'
            '${files.length == 1 ? '' : 's'} had failures.');
    exit(failedFiles == 0 ? 0 : 1);
  }

  /// Collect `*_test.hawk` paths from [targets] (files used directly, dirs
  /// searched recursively), de-duplicated and sorted for stable output.
  List<String> _collectTestFiles(List<String> targets) {
    final paths = <String>{};
    for (final target in targets) {
      switch (FileSystemEntity.typeSync(target)) {
        case FileSystemEntityType.file:
          paths.add(target);
        case FileSystemEntityType.directory:
          paths.addAll(Directory(target)
              .listSync(recursive: true)
              .whereType<File>()
              .map((f) => f.path)
              .where((p) => p.endsWith('_test.hawk')));
        default:
          stderr.writeln('hawk test: not found: $target');
          exit(1);
      }
    }
    final sorted = paths.toList()..sort();
    return sorted;
  }

  /// Compile [path]'s `@test` functions with a synthesized driver and run them
  /// on the [runtime]. Per-test results stream to stdout. Returns the test
  /// counts, or null if the file failed to load/compile.
  Future<({int total, int failures})?> _runTestFile(
      String path, String runtime, Directory tmp) async {
    final String source;
    try {
      source = File(path).readAsStringSync();
    } on FileSystemException {
      stderr.writeln('hawk test: cannot read $path');
      return null;
    }

    // Parse once to discover the @test functions.
    final Program program;
    try {
      program = _parseOrThrow(source, path);
    } on _LoadFailed {
      return null;
    }
    final tests = [
      for (final decl in program.decls)
        if (decl is FnDecl && decl.decorators.any((d) => d.name == 'test'))
          decl.name,
    ];

    stdout.writeln(path);
    if (tests.isEmpty) {
      stdout.writeln('  (no @test functions)');
      return (total: 0, failures: 0);
    }

    // Re-parse the source plus a synthesized driver `main` that runs each test.
    final Program combined;
    try {
      combined = _parseOrThrow('$source\n${_testDriver(tests)}', path);
    } on _LoadFailed {
      return null;
    }
    final bytes = _compileProgram(path, combined);
    final out = File('${tmp.path}/test.hawkbc')..writeAsBytesSync(bytes);

    // A unique entry name so the driver never collides with a tested module's
    // own `main` (executables under test keep theirs; it's just dead code here).
    final process = await Process.start(
      runtime,
      ['--entry', '__hawk_test_main', out.path],
      mode: ProcessStartMode.inheritStdio,
    );
    final exitCode = await process.exitCode;
    // `main` returns the failure count; a non-zero, non-count exit (e.g. a
    // runtime trap) still counts as a failure for this file.
    final failures =
        exitCode == 0 ? 0 : (exitCode <= tests.length ? exitCode : 1);
    return (total: tests.length, failures: failures);
  }

  /// The synthesized driver: a `main` that runs each `@test` function, prints a
  /// per-test `ok`/`FAIL` line (with the error on failure), and returns the
  /// number of failures (which becomes the process exit code).
  String _testDriver(List<String> tests) {
    final b = StringBuffer();
    b.writeln('fn __hawk_pass(_ name: String) -> Int {');
    b.writeln("    println('  ok    \${name}');");
    b.writeln('    return 0;');
    b.writeln('}');
    b.writeln('fn __hawk_fail(_ name: String, _ e: Error) -> Int {');
    b.writeln("    println('  FAIL  \${name}');");
    // `e` is typed as the `Error` interface, which is not itself `Display`;
    // render it through its `message()`.
    b.writeln("    println('          \${e.message()}');");
    b.writeln('    return 1;');
    b.writeln('}');
    b.writeln('fn __hawk_test_main() -> Int {');
    b.writeln('    let mut __hawk_failures = 0;');
    for (final t in tests) {
      b.writeln('    let __hawk_r_$t = match $t() {');
      b.writeln("        Ok(_) => __hawk_pass('$t'),");
      b.writeln("        Err(e) => __hawk_fail('$t', e),");
      b.writeln('    };');
      b.writeln('    __hawk_failures = __hawk_failures + __hawk_r_$t;');
    }
    b.writeln('    return __hawk_failures;');
    b.writeln('}');
    return b.toString();
  }
}

/// Lex and parse [source] (labeled [path] for diagnostics), printing lex/parse
/// errors and throwing [_LoadFailed] on failure.
Program _parseOrThrow(String source, String path) {
  final lexResult = Lexer(source).tokenize();
  if (lexResult.hasErrors) {
    for (final err in lexResult.errors) {
      stderr.writeln('$path:$err');
    }
    throw _LoadFailed();
  }
  final parseResult = Parser(lexResult.tokens).parse();
  if (parseResult.hasErrors) {
    for (final err in parseResult.errors) {
      stderr.writeln('$path:$err');
    }
    throw _LoadFailed();
  }
  return parseResult.program;
}
