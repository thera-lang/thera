import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:aero/src/ast.dart';
import 'package:aero/src/checker/type_checker.dart';
import 'package:aero/src/interpreter/interpreter.dart';
import 'package:aero/src/lexer.dart';
import 'package:aero/src/lsp/server.dart';
import 'package:aero/src/parser.dart';

/// Locate the SDK root by searching upward from the running script.
///
/// Resolution order:
///   1. AERO_SDK environment variable (if set and contains src/std/).
///   2. Walk up from Platform.script looking for a directory that contains
///      src/std/ — handles both `dart run tool/bin/aero.dart` (dev) and a
///      compiled `bin/aero` binary (distributed).
String? _findSdkRoot() {
  final envRoot = Platform.environment['AERO_SDK'];
  if (envRoot != null && Directory('$envRoot/src/std').existsSync()) {
    return envRoot;
  }
  try {
    var dir = Directory(File(Platform.script.toFilePath()).parent.path);
    for (var i = 0; i < 4; i++) {
      if (Directory('${dir.path}/src/std').existsSync()) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break; // filesystem root
      dir = parent;
    }
  } catch (_) {}
  return null;
}

void main(List<String> args) async {
  final runner = CommandRunner<void>('aero', 'The Aero language toolchain.')
    ..addCommand(ParseCommand())
    ..addCommand(RunCommand())
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
    stderr.writeln('aero: $e');
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
  String get invocation => 'aero parse <file>';

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
  String get description => 'Run <file>; arguments after -- are passed to main.';

  @override
  String get invocation => 'aero run <file> [-- args]';

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
    final exitCode = Interpreter(sdkRoot: _findSdkRoot()).execute(program, programArgs, baseDir: File(path).parent.path);
    exit(exitCode);
  }
}

class CheckCommand extends Command<void> {
  @override
  String get name => 'check';

  @override
  String get description =>
      'Type-check <file> or all *.aero files in a directory.';

  @override
  String get invocation => 'aero check <file|dir>...';

  @override
  void run() {
    final targets = argResults!.rest;
    if (targets.isEmpty) usageException('Expected a file or directory.');

    // Collect all .aero paths from the targets (files directly, dirs recursively).
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
              .where((f) => f.path.endsWith('.aero'))
              .map((f) => f.path),
        );
      } else {
        stderr.writeln('aero check: not found: $target');
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

    final checker = TypeChecker();
    final baseDir = File(path).parent.path;

    // Pre-register symbols from imports so cross-file names resolve.
    for (final decl in program.decls) {
      if (decl is! ImportDecl) continue;
      if (decl.path.startsWith('std.')) {
        checker.addModule(decl.alias ?? decl.path.split('.').last);
      } else {
        // Relative file import — load and register its symbols (don't check it).
        final importPath = '$baseDir/${decl.path}.aero';
        try {
          checker.addProgram(_loadProgramQuiet(importPath));
        } on _LoadFailed {
          // Import couldn't be parsed; skip (the missing-file error is
          // only raised at runtime, not at check time).
        }
      }
    }

    final result = checker.check(program);
    for (final err in result.errors) {
      stderr.writeln(err.format(path));
    }
    return result.errors.length;
  }
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
    if (verbose) stderr.writeln('aero: cannot read $path');
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
  String get description => 'Start the Aero LSP server (communicates via stdio).';

  @override
  String get invocation => 'aero lsp';

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
  String get invocation => 'aero test <file>...';

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
      totalFailures += Interpreter(sdkRoot: _findSdkRoot()).runTests(program, path, verbose: verbose);
    }
    exit(totalFailures > 0 ? 1 : 0);
  }
}
