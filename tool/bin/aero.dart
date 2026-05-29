import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:aero/src/ast.dart';
import 'package:aero/src/interpreter/interpreter.dart';
import 'package:aero/src/lexer.dart';
import 'package:aero/src/parser.dart';

void main(List<String> args) async {
  final runner = CommandRunner<void>('aero', 'The Aero language toolchain.')
    ..addCommand(ParseCommand())
    ..addCommand(RunCommand())
    ..addCommand(TestCommand());

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
    final exitCode = Interpreter().execute(program, programArgs, baseDir: File(path).parent.path);
    exit(exitCode);
  }
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
      totalFailures += Interpreter().runTests(program, path, verbose: verbose);
    }
    exit(totalFailures > 0 ? 1 : 0);
  }
}
