import 'dart:io';

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
  stderr.writeln('  parse <file>   lex and parse <file>, print the AST');
}

void _runParse(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: aero parse <file>');
    exit(1);
  }
  final path = args[0];

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

  stdout.write(parseResult.program.describe());
}
