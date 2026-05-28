import 'dart:io';

import 'package:aero/src/ast.dart';
import 'package:aero/src/interpreter/interpreter.dart';
import 'package:aero/src/lexer.dart';
import 'package:aero/src/parser.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    _printUsage();
    exit(1);
  }

  final command = args[0];
  final rest = args.sublist(1);

  switch (command) {
    case 'parse':
      _runParse(rest);
    case 'run':
      _runFile(rest);
    case 'test':
      _runTests(rest);
    default:
      stderr.writeln('aero: unknown command: $command');
      _printUsage();
      exit(1);
  }
}

void _printUsage() {
  stderr.writeln('usage: aero <command> [options]');
  stderr.writeln('');
  stderr.writeln('commands:');
  stderr.writeln('  parse <file>            lex and parse <file>, print the AST');
  stderr.writeln('  run   <file> [-- args]  run <file>; args after -- are passed to main');
  stderr.writeln('  test  <file>...         run @test functions in <file>');
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

void _runParse(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: aero parse <file>');
    exit(1);
  }
  stdout.write(_loadProgram(args[0]).describe());
}

void _runTests(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: aero test <file>... [--verbose]');
    exit(1);
  }
  final verbose = args.contains('--verbose');
  final files = args.where((a) => !a.startsWith('--')).toList();
  var totalFailures = 0;
  for (final path in files) {
    final program = _loadProgram(path);
    totalFailures += Interpreter().runTests(program, path, verbose: verbose);
  }
  exit(totalFailures > 0 ? 1 : 0);
}

void _runFile(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: aero run <file> [-- program-args]');
    exit(1);
  }
  final path = args[0];
  // Everything after '--' (or after the filename if no '--') is passed to main.
  final sep = args.indexOf('--');
  final programArgs = sep >= 0 ? args.sublist(sep + 1) : args.sublist(1);

  final program = _loadProgram(path);
  final exitCode = Interpreter().execute(program, programArgs);
  exit(exitCode);
}
