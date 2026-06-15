import 'token.dart';

class LexError {
  final String message;
  final SourceSpan span;

  LexError(this.message, this.span);

  @override
  String toString() => '$span: $message';
}

class LexResult {
  final List<Token> tokens;
  final List<LexError> errors;

  LexResult(this.tokens, this.errors);

  bool get hasErrors => errors.isNotEmpty;
}

class Lexer {
  final String _source;
  int _pos = 0;
  int _line = 1;
  int _col = 1;
  final List<Token> _tokens = [];
  final List<LexError> _errors = [];

  Lexer(this._source);

  LexResult tokenize() {
    while (!_atEnd) {
      _skipWhitespaceAndComments();
      if (_atEnd) break;
      _scanToken();
    }
    _tokens.add(Token(TokenKind.eof, _spanAt(_pos, 0)));
    return LexResult(_tokens, _errors);
  }

  // --- internal helpers ---

  bool get _atEnd => _pos >= _source.length;

  String get _ch => _atEnd ? '\x00' : _source[_pos];
  String get _peek => (_pos + 1 < _source.length) ? _source[_pos + 1] : '\x00';

  String _advance() {
    final c = _source[_pos++];
    if (c == '\n') {
      _line++;
      _col = 1;
    } else {
      _col++;
    }
    return c;
  }

  bool _match(String expected) {
    if (_atEnd || _ch != expected) return false;
    _advance();
    return true;
  }

  SourceSpan _spanAt(int offset, int length) {
    // For synthetic spans (eof), line/col are current position.
    return SourceSpan(
      source: _source,
      offset: offset,
      length: length,
      line: _line,
      column: _col,
    );
  }

  SourceSpan _spanFrom(int startOffset, int startLine, int startCol) {
    return SourceSpan(
      source: _source,
      offset: startOffset,
      length: _pos - startOffset,
      line: startLine,
      column: startCol,
    );
  }

  void _skipWhitespaceAndComments() {
    while (!_atEnd) {
      final c = _ch;
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        _advance();
      } else if (c == '/' && _peek == '/') {
        while (!_atEnd && _ch != '\n') _advance();
      } else {
        break;
      }
    }
  }

  void _scanToken() {
    final startOffset = _pos;
    final startLine = _line;
    final startCol = _col;
    final c = _advance();

    switch (c) {
      case '{':
        _emit(TokenKind.lBrace, startOffset, startLine, startCol);
      case '}':
        _emit(TokenKind.rBrace, startOffset, startLine, startCol);
      case '(':
        _emit(TokenKind.lParen, startOffset, startLine, startCol);
      case ')':
        _emit(TokenKind.rParen, startOffset, startLine, startCol);
      case '[':
        _emit(TokenKind.lBracket, startOffset, startLine, startCol);
      case ']':
        _emit(TokenKind.rBracket, startOffset, startLine, startCol);
      case ',':
        _emit(TokenKind.comma, startOffset, startLine, startCol);
      case ';':
        _emit(TokenKind.semi, startOffset, startLine, startCol);
      case ':':
        _emit(TokenKind.colon, startOffset, startLine, startCol);
      case '@':
        _emit(TokenKind.at, startOffset, startLine, startCol);
      case '+':
        if (_match('=')) {
          _emitSpan(
              TokenKind.plusEq, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.plus, startOffset, startLine, startCol);
        }
      case '*':
        if (_match('=')) {
          _emitSpan(
              TokenKind.starEq, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.star, startOffset, startLine, startCol);
        }
      case '%':
        if (_match('=')) {
          _emitSpan(
              TokenKind.percentEq, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.percent, startOffset, startLine, startCol);
        }
      case '/':
        if (_match('=')) {
          _emitSpan(
              TokenKind.slashEq, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.slash, startOffset, startLine, startCol);
        }
      case '.':
        if (_match('.')) {
          _emitSpan(
              TokenKind.dotDot, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.dot, startOffset, startLine, startCol);
        }
      case '-':
        if (_match('>')) {
          _emitSpan(
              TokenKind.arrow, _spanFrom(startOffset, startLine, startCol));
        } else if (_match('=')) {
          _emitSpan(
              TokenKind.minusEq, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.minus, startOffset, startLine, startCol);
        }
      case '=':
        if (_match('=')) {
          _emitSpan(
              TokenKind.eqEq, _spanFrom(startOffset, startLine, startCol));
        } else if (_match('>')) {
          _emitSpan(
              TokenKind.fatArrow, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.eq, startOffset, startLine, startCol);
        }
      case '!':
        if (_match('=')) {
          _emitSpan(
              TokenKind.bangEq, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.bang, startOffset, startLine, startCol);
        }
      case '<':
        if (_match('=')) {
          _emitSpan(
              TokenKind.ltEq, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.lt, startOffset, startLine, startCol);
        }
      case '>':
        if (_match('=')) {
          _emitSpan(
              TokenKind.gtEq, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.gt, startOffset, startLine, startCol);
        }
      case '&':
        if (_match('&')) {
          _emitSpan(
              TokenKind.ampAmp, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.amp, startOffset, startLine, startCol);
        }
      case '|':
        if (_match('|')) {
          _emitSpan(
              TokenKind.pipePipe, _spanFrom(startOffset, startLine, startCol));
        } else {
          _emit(TokenKind.pipe, startOffset, startLine, startCol);
        }
      case '^':
        _emit(TokenKind.caret, startOffset, startLine, startCol);
      case '~':
        _emit(TokenKind.tilde, startOffset, startLine, startCol);
      case '?':
        _emit(TokenKind.question, startOffset, startLine, startCol);
      case '"':
      case "'":
        _scanString(c, startOffset, startLine, startCol);
      default:
        if (_isDigit(c)) {
          _scanNumber(startOffset, startLine, startCol);
        } else if (_isAlpha(c) || c == '_') {
          _scanIdent(startOffset, startLine, startCol);
        } else {
          _error('unexpected character: $c', startOffset, startLine, startCol);
        }
    }
  }

  void _scanString(String quote, int startOffset, int startLine, int startCol) {
    final buf = StringBuffer();
    while (!_atEnd && _ch != quote) {
      if (_ch == '\\') {
        final escOffset = _pos;
        final escLine = _line;
        final escCol = _col;
        _advance(); // consume the backslash
        if (_atEnd) break;
        _scanStringEscape(buf, escOffset, escLine, escCol);
      } else if (_ch == r'$' && _peek == '{') {
        // Capture ${...} verbatim so the parser can split interpolations.
        // Track brace depth, but skip over nested string literals so a '}'
        // inside an interpolated string (e.g. `${ m['}'] }`) doesn't close the
        // interpolation early.
        buf.write(r'$');
        _advance(); // $
        buf.write('{');
        _advance(); // {
        int depth = 1;
        while (!_atEnd && depth > 0) {
          final ic = _ch;
          if (ic == "'" || ic == '"') {
            // Copy a nested string literal verbatim, honoring backslash escapes
            // so an escaped quote doesn't end it prematurely.
            buf.write(ic);
            _advance();
            while (!_atEnd && _ch != ic) {
              if (_ch == '\\') {
                buf.write(_ch);
                _advance();
                if (_atEnd) break;
              }
              buf.write(_ch);
              _advance();
            }
            if (!_atEnd) {
              buf.write(_ch); // closing quote
              _advance();
            }
          } else {
            if (ic == '{') {
              depth++;
            } else if (ic == '}') {
              depth--;
            }
            buf.write(ic);
            _advance();
          }
        }
      } else {
        buf.write(_ch);
        _advance();
      }
    }
    if (_atEnd) {
      _error('unterminated string literal', startOffset, startLine, startCol);
    } else {
      _advance(); // closing quote
    }
    final span = _spanFrom(startOffset, startLine, startCol);
    _tokens.add(Token(TokenKind.stringLiteral, span, buf.toString()));
  }

  /// Decode one escape sequence into [buf]. The backslash is already consumed;
  /// `_ch` is the escape character. The position of the backslash ([o]/[l]/[c])
  /// is used for diagnostics. Consumes everything the escape spans.
  ///
  /// Decoded characters go through [_writeLiteral], which re-escapes a literal
  /// `\` or `$` (as `\\` / `\$`) in the captured value. This keeps an escaped
  /// `\${` distinguishable from a real `${…}` interpolation (captured raw): the
  /// value's only *bare* `${` are interpolations, and the parser's splitter
  /// decodes `\\`/`\$` back. Without this, `\$` de-escapes to a bare `$` the
  /// splitter mistakes for interpolation.
  void _scanStringEscape(StringBuffer buf, int o, int l, int c) {
    final e = _ch;
    _advance(); // consume the escape character
    switch (e) {
      case 'n':
        _writeLiteral(buf, 0x0A);
      case 't':
        _writeLiteral(buf, 0x09);
      case 'r':
        _writeLiteral(buf, 0x0D);
      case '\\':
        _writeLiteral(buf, 0x5C);
      case "'":
        _writeLiteral(buf, 0x27);
      case '"':
        _writeLiteral(buf, 0x22);
      case r'$':
        _writeLiteral(buf, 0x24);
      case 'x':
        _scanHexEscape(buf, o, l, c);
      case 'u':
        _scanUnicodeEscape(buf, o, l, c);
      default:
        // An unrecognized escape is an error, not a silent pass-through — a
        // typo like `\d` shouldn't quietly become a literal backslash-d.
        _error("unknown escape sequence: '\\$e'", o, l, c);
        _writeLiteral(
            buf, e.codeUnitAt(0)); // keep scanning; the error fails the parse
    }
  }

  /// Append a decoded text code point to a string-literal buffer, re-escaping a
  /// literal `\` or `$` as `\\` / `\$` (see [_scanStringEscape]).
  void _writeLiteral(StringBuffer buf, int code) {
    if (code == 0x5C || code == 0x24) buf.writeCharCode(0x5C);
    buf.writeCharCode(code);
  }

  /// `\xNN` — exactly two hex digits, a code point in 0x00..0xFF (always a
  /// valid scalar). `_ch` is the first hex digit.
  void _scanHexEscape(StringBuffer buf, int o, int l, int c) {
    var value = 0;
    for (var i = 0; i < 2; i++) {
      if (_atEnd || !_isHexDigit(_ch)) {
        _error(r"'\x' needs exactly two hex digits", o, l, c);
        return;
      }
      value = value * 16 + _hexDigit(_ch);
      _advance();
    }
    _writeLiteral(buf, value);
  }

  /// `\u{...}` — 1..6 hex digits in braces, naming a Unicode scalar value.
  /// `_ch` is the opening brace.
  void _scanUnicodeEscape(StringBuffer buf, int o, int l, int c) {
    if (_ch != '{') {
      _error(r"'\u' must be followed by '{...}'", o, l, c);
      return;
    }
    _advance(); // consume '{'
    var value = 0;
    var digits = 0;
    while (!_atEnd && _ch != '}') {
      if (!_isHexDigit(_ch)) {
        _error(r"invalid hex digit in '\u{...}'", o, l, c);
        return;
      }
      value = value * 16 + _hexDigit(_ch);
      digits++;
      if (digits > 6) {
        _error(r"too many hex digits in '\u{...}' (max 6)", o, l, c);
        return;
      }
      _advance();
    }
    if (_atEnd || digits == 0) {
      _error(r"empty or unterminated '\u{...}' escape", o, l, c);
      return;
    }
    _advance(); // consume '}'
    // Reject surrogates and out-of-range values — not Unicode scalar values.
    if (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) {
      _error(r"invalid Unicode scalar value in '\u{...}'", o, l, c);
      return;
    }
    _writeLiteral(buf, value);
  }

  static int _hexDigit(String c) {
    final code = c.codeUnitAt(0);
    if (code >= 48 && code <= 57) return code - 48; // 0-9
    if (code >= 65 && code <= 70) return code - 65 + 10; // A-F
    return code - 97 + 10; // a-f
  }

  void _scanNumber(int startOffset, int startLine, int startCol) {
    // Hex integer literal: `0x` / `0X` followed by hex digits. The first digit
    // (`0`) is already consumed; check the source for it.
    if (_source[startOffset] == '0' && (_ch == 'x' || _ch == 'X')) {
      _advance(); // x / X
      var sawDigit = false;
      while (!_atEnd && _isHexDigit(_ch)) {
        _advance();
        sawDigit = true;
      }
      final span = _spanFrom(startOffset, startLine, startCol);
      if (!sawDigit) {
        _error('hex literal needs at least one digit after 0x', startOffset,
            startLine, startCol);
      }
      _tokens.add(Token(TokenKind.intLiteral, span));
      return;
    }
    while (!_atEnd && _isDigit(_ch)) _advance();
    var isFloat = false;
    if (!_atEnd && _ch == '.' && _isDigit(_peek)) {
      isFloat = true;
      _advance(); // .
      while (!_atEnd && _isDigit(_ch)) _advance();
    }
    final span = _spanFrom(startOffset, startLine, startCol);
    _tokens.add(
        Token(isFloat ? TokenKind.floatLiteral : TokenKind.intLiteral, span));
  }

  void _scanIdent(int startOffset, int startLine, int startCol) {
    while (!_atEnd && (_isAlphaNum(_ch) || _ch == '_')) _advance();
    final span = _spanFrom(startOffset, startLine, startCol);
    final text = span.text;
    if (text == '_') {
      _tokens.add(Token(TokenKind.underscore, span));
      return;
    }
    final kind = keywordKind(text) ?? TokenKind.identifier;
    _tokens.add(Token(kind, span, kind == TokenKind.identifier ? text : null));
  }

  void _emit(TokenKind kind, int startOffset, int startLine, int startCol) {
    _tokens.add(Token(kind, _spanFrom(startOffset, startLine, startCol)));
  }

  void _emitSpan(TokenKind kind, SourceSpan span) {
    _tokens.add(Token(kind, span));
  }

  void _error(String message, int startOffset, int startLine, int startCol) {
    _errors.add(LexError(message, _spanFrom(startOffset, startLine, startCol)));
  }

  static bool _isDigit(String c) {
    final code = c.codeUnitAt(0);
    return code >= 48 && code <= 57;
  }

  static bool _isHexDigit(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 48 && code <= 57) || // 0-9
        (code >= 65 && code <= 70) || // A-F
        (code >= 97 && code <= 102); // a-f
  }

  static bool _isAlpha(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }

  static bool _isAlphaNum(String c) => _isAlpha(c) || _isDigit(c);
}
