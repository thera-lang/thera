import 'package:hawk/src/lexer.dart';
import 'package:test/test.dart';

/// Serialize a token stream as `kind:lexeme` lines. This is the canonical form
/// the Hawk lexer port (pkgs/cli/lexer) is diffed against: the Hawk
/// `lexer_test.hawk` asserts the same kinds and lexemes for these same inputs,
/// so this test pins the Dart oracle's behavior the port transcribes. If the
/// Dart lexer ever drifts from what the Hawk tests expect, this catches it on
/// the Dart side.
List<String> lex(String src) {
  final r = Lexer(src).tokenize();
  return [for (final t in r.tokens) '${t.kind.name}:${t.lexeme}'];
}

void main() {
  test('keywords and identifiers', () {
    expect(lex('fn foo let x'), [
      'kwFn:fn',
      'identifier:foo',
      'kwLet:let',
      'identifier:x',
      'eof:',
    ]);
  });

  test('a keyword near-miss is an identifier', () {
    expect(lex('match'), ['kwMatch:match', 'eof:']);
    expect(lex('matches'), ['identifier:matches', 'eof:']);
  });

  test('operators — maximal munch over prefixes', () {
    expect(lex('+ += -> => .. == != <= >= && || & | ^ ~'), [
      'plus:+',
      'plusEq:+=',
      'arrow:->',
      'fatArrow:=>',
      'dotDot:..',
      'eqEq:==',
      'bangEq:!=',
      'ltEq:<=',
      'gtEq:>=',
      'ampAmp:&&',
      'pipePipe:||',
      'amp:&',
      'pipe:|',
      'caret:^',
      'tilde:~',
      'eof:',
    ]);
  });

  test('numbers — int, float, hex; dot needs a trailing digit', () {
    expect(lex('0 42 3.14 0xFF 0X1a 7.0'), [
      'intLiteral:0',
      'intLiteral:42',
      'floatLiteral:3.14',
      'intLiteral:0xFF',
      'intLiteral:0X1a',
      'floatLiteral:7.0',
      'eof:',
    ]);
    expect(lex('3.foo'), [
      'intLiteral:3',
      'dot:.',
      'identifier:foo',
      'eof:',
    ]);
  });

  test('strings — escapes decode, interpolation is captured verbatim', () {
    // Raw Dart strings so the backslashes/`${}` reach the lexer under test.
    expect(lex(r"'a\nb\t\\\''"), ['stringLiteral:a\nb\t\\\'', 'eof:']);
    expect(lex(r"'\x41'"), ['stringLiteral:A', 'eof:']);
    expect(lex(r"'\u{48}'"), ['stringLiteral:H', 'eof:']);
    expect(lex(r"'a${1 + 2}b'"), [r'stringLiteral:a${1 + 2}b', 'eof:']);
    // A `}` inside a nested string within `${...}` must not close it early.
    // Source under test: '${"x}"}' (escaped here, not raw, for the inner ").
    expect(lex('\'\${"x}"}\''), ['stringLiteral:\${"x}"}', 'eof:']);
  });

  test('comments and whitespace are skipped', () {
    expect(lex('fn  // a comment\n  x'), [
      'kwFn:fn',
      'identifier:x',
      'eof:',
    ]);
  });

  test('underscore vs identifier', () {
    expect(lex('_'), ['underscore:_', 'eof:']);
    expect(lex('_foo'), ['identifier:_foo', 'eof:']);
  });

  test('error messages match the Hawk port', () {
    String firstError(String src) => Lexer(src).tokenize().errors.first.message;
    expect(firstError("'abc"), 'unterminated string literal');
    expect(firstError('#'), 'unexpected character: #');
    expect(firstError('0x'), 'hex literal needs at least one digit after 0x');
    expect(firstError(r"'\d'"), r"unknown escape sequence: '\d'");
    expect(firstError(r"'\xZZ'"), r"'\x' needs exactly two hex digits");
  });
}
