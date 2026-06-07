import 'package:hawk/src/ast.dart';
import 'package:hawk/src/parser.dart';
import 'package:hawk/src/lexer.dart';

Program parseProgram(String source) {
  final lex = Lexer(source).tokenize();
  if (lex.hasErrors) {
    print('Lex errors: ${lex.errors}');
  }
  final parsed = Parser(lex.tokens).parse();
  if (parsed.hasErrors) {
    print('Parse errors:');
    for (final err in parsed.errors) {
      print('  $err');
    }
  }
  return parsed.program;
}

void main() {
  final source = 'fn apply(f: (Int) -> Int) { }';
  final prog = parseProgram(source);
  print('Decls count: ${prog.decls.length}');
}
