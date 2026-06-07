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
/// Assumes a dev checkout: `runtime/target/debug/hawk` under the repo root (the
/// same directory that holds `sdk/std/`).
String? _findRuntimeBinary() {
  final root = findSdkRoot();
  if (root == null) return null;
  final bin = '$root/runtime/target/debug/hawk';
  return File(bin).existsSync() ? bin : null;
}

/// Compile the program at [path] to bytecode bytes, type-checking before
/// lowering (codegen assumes a well-typed program). Prints diagnostics and
/// exits non-zero on any lex/parse/type/codegen error.
List<int> _emitBytes(String path) {
  final program = _loadProgram(path);
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
          'runtime/target/debug/hawk. Build it first: run `cargo build` in '
          'the runtime/ directory.');
      exit(1);
    }

    final dir = Directory.systemTemp.createTempSync('hawk_run');
    File('${dir.path}/out.hawkbc').writeAsBytesSync(bytes);
    final process = await Process.start(
      runtime,
      ['run', '${dir.path}/out.hawkbc', ...programArgs],
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
  String get description => 'Run @test functions in one or more files (TBD).';

  @override
  String get invocation => 'hawk test <file>...';

  @override
  void run() {
    // The @test runner has not been reimplemented on the bytecode pipeline
    // (the legacy tree-walking interpreter, which ran an older dialect, was
    // retired). Fail fast rather than silently doing nothing.
    stderr.writeln('hawk test: not yet available. The @test runner needs to be '
        'reimplemented on the bytecode pipeline (compile with the Dart '
        'front-end, execute on the Rust runtime); this is TBD.');
    exit(2);
  }
}
