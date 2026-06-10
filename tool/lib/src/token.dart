enum TokenKind {
  // Literals
  intLiteral,
  floatLiteral,
  stringLiteral, // raw content between quotes; may contain ${...} segments

  // Keywords
  kwAs,
  kwConst,
  kwElse,
  kwEnum,
  kwFalse,
  kwFn,
  kwFor,
  kwIf,
  kwImpl,
  kwImport,
  kwIn,
  kwInterface,
  kwLet,
  kwMatch,
  kwMut,
  kwNative,
  kwPub,
  kwReturn,
  kwSelf,
  kwThrow,
  kwTrue,
  kwType,
  kwVoid, // the unit value (the `Void` type's single value)
  kwWhile,

  // Identifiers (type names, Ok, Err, Some, None, user names, etc.)
  identifier,

  // Punctuation
  lBrace, //   {
  rBrace, //   }
  lParen, //   (
  rParen, //   )
  lBracket, // [
  rBracket, // ]
  comma, //    ,
  semi, //     ;
  colon, //    :
  dot, //      .
  dotDot, //   ..
  arrow, //    ->
  fatArrow, // =>
  question, // ?
  at, //       @
  underscore, // _  (used as label suppressor and wildcard pattern)

  // Operators
  plus, //     +
  minus, //    -
  star, //     *
  slash, //    /
  percent, //  %
  plusEq, //   +=
  minusEq, //  -=
  starEq, //   *=
  slashEq, //  /=
  percentEq, // %=
  eq, //       =
  eqEq, //     ==
  bangEq, //   !=
  lt, //       <
  gt, //       >
  ltEq, //     <=
  gtEq, //     >=
  ampAmp, //   &&
  pipePipe, // ||
  bang, //     !

  // Special
  eof,
}

const _keywords = <String, TokenKind>{
  'as': TokenKind.kwAs,
  'const': TokenKind.kwConst,
  'else': TokenKind.kwElse,
  'enum': TokenKind.kwEnum,
  'false': TokenKind.kwFalse,
  'fn': TokenKind.kwFn,
  'for': TokenKind.kwFor,
  'if': TokenKind.kwIf,
  'impl': TokenKind.kwImpl,
  'import': TokenKind.kwImport,
  'in': TokenKind.kwIn,
  'interface': TokenKind.kwInterface,
  'let': TokenKind.kwLet,
  'match': TokenKind.kwMatch,
  'mut': TokenKind.kwMut,
  'native': TokenKind.kwNative,
  'pub': TokenKind.kwPub,
  'return': TokenKind.kwReturn,
  'self': TokenKind.kwSelf,
  'throw': TokenKind.kwThrow,
  'true': TokenKind.kwTrue,
  'type': TokenKind.kwType,
  'void': TokenKind.kwVoid,
  'while': TokenKind.kwWhile,
};

TokenKind? keywordKind(String text) => _keywords[text];

/// Every reserved keyword spelling — the lexer's source of truth. Used by the
/// grammar-doc drift test (`test/grammar_doc_test.dart`) so docs/grammar.md
/// can't omit a keyword the language actually reserves.
Set<String> get keywordSpellings => _keywords.keys.toSet();

class SourceSpan {
  final String source;
  final int offset;
  final int length;
  final int line;
  final int column;

  const SourceSpan({
    required this.source,
    required this.offset,
    required this.length,
    required this.line,
    required this.column,
  });

  factory SourceSpan.cover(SourceSpan start, SourceSpan end) {
    if (start.source.isEmpty) return end;
    if (end.source.isEmpty) return start;
    assert(identical(start.source, end.source) || start.source == end.source);
    final length = end.offset + end.length - start.offset;
    return SourceSpan(
      source: start.source,
      offset: start.offset,
      length: length,
      line: start.line,
      column: start.column,
    );
  }

  String get text => source.substring(offset, offset + length);

  /// The 1-based (line, column) of the position just past this span, computed
  /// by scanning [source]. Correct for multi-line spans — unlike
  /// `column + length`, which assumes the span stays on its start line.
  (int line, int column) get endLineColumn {
    var l = line;
    var c = column;
    final end = offset + length;
    for (var i = offset; i < end && i < source.length; i++) {
      if (source.codeUnitAt(i) == 0x0a) {
        l++;
        c = 1;
      } else {
        c++;
      }
    }
    return (l, c);
  }

  @override
  String toString() => '$line:$column';
}

class Token {
  final TokenKind kind;
  final SourceSpan span;

  // For stringLiteral: content between quotes (${...} kept verbatim).
  // For identifier: the identifier text.
  // null for all other kinds (use span.text).
  final String? value;

  const Token(this.kind, this.span, [this.value]);

  String get lexeme => value ?? span.text;

  bool get isEof => kind == TokenKind.eof;

  @override
  String toString() => 'Token($kind, $span, "${span.text}")';
}
