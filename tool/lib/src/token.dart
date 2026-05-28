enum TokenKind {
  // Literals
  intLiteral,
  floatLiteral,
  stringLiteral, // raw content between quotes; may contain ${...} segments

  // Keywords
  kwAs,
  kwElse,
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
  kwReturn,
  kwSelf,
  kwThrow,
  kwTrue,
  kwType,
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
  'else': TokenKind.kwElse,
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
  'return': TokenKind.kwReturn,
  'self': TokenKind.kwSelf,
  'throw': TokenKind.kwThrow,
  'true': TokenKind.kwTrue,
  'type': TokenKind.kwType,
  'while': TokenKind.kwWhile,
};

TokenKind? keywordKind(String text) => _keywords[text];

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

  String get text => source.substring(offset, offset + length);

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
