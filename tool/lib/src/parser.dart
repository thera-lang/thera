import 'ast.dart';
import 'lexer.dart';
import 'token.dart';

class ParseError {
  final String message;
  final SourceSpan span;
  ParseError(this.message, this.span);

  @override
  String toString() => '$span: $message';
}

class ParseResult {
  final Program program;
  final List<ParseError> errors;
  ParseResult(this.program, this.errors);

  bool get hasErrors => errors.isNotEmpty;
}

class Parser {
  final List<Token> _tokens;
  int _pos = 0;
  final List<ParseError> _errors = [];

  Parser(this._tokens);

  // ---- public entry point ----

  ParseResult parse() {
    final decls = <Decl>[];
    while (!_atEnd) {
      try {
        decls.add(_parseDecl());
      } catch (_) {
        // _error() already recorded; sync to next declaration boundary.
        _syncToDecl();
      }
    }
    return ParseResult(Program(decls), _errors);
  }

  // ---- token navigation ----

  bool get _atEnd => _current.isEof;

  Token get _current => _tokens[_pos];
  Token get _next =>
      _pos + 1 < _tokens.length ? _tokens[_pos + 1] : _tokens.last;

  Token _advance() {
    final t = _tokens[_pos];
    if (!_atEnd) _pos++;
    return t;
  }

  bool _check(TokenKind kind) => _current.kind == kind;

  bool _match(TokenKind kind) {
    if (_check(kind)) {
      _advance();
      return true;
    }
    return false;
  }

  Token _expect(TokenKind kind, String description) {
    if (_check(kind)) return _advance();
    _fail(
        'expected $description, found ${_current.span.text.isEmpty ? _current.kind.name : '"${_current.span.text}"'}');
  }

  // Records an error and throws to unwind to the nearest try/catch.
  Never _fail(String message, [SourceSpan? span]) {
    final s = span ?? _current.span;
    _errors.add(ParseError(message, s));
    throw _ParseFail();
  }

  void _syncToDecl() {
    // Skip tokens until we're at something that can start a top-level decl.
    while (!_atEnd) {
      final k = _current.kind;
      if (k == TokenKind.kwFn ||
          k == TokenKind.kwType ||
          k == TokenKind.kwImpl ||
          k == TokenKind.kwInterface ||
          k == TokenKind.kwImport ||
          k == TokenKind.kwNative ||
          k == TokenKind.at) {
        return;
      }
      _advance();
    }
  }

  // ---- declarations ----

  Decl _parseDecl() {
    // Decorators before fn/type/impl/interface
    final decorators = <Decorator>[];
    while (_check(TokenKind.at)) {
      decorators.add(_parseDecorator());
    }

    final k = _current.kind;

    if (k == TokenKind.kwImport) {
      if (decorators.isNotEmpty) {
        _fail('decorators are not allowed on import declarations');
      }
      return _parseImport();
    }
    if (k == TokenKind.kwNative) {
      return _parseFnDecl(decorators, isNative: true);
    }
    if (k == TokenKind.kwFn) {
      return _parseFnDecl(decorators, isNative: false);
    }
    if (k == TokenKind.kwType) {
      if (decorators.isNotEmpty)
        _fail('decorators are not allowed on type declarations');
      return _parseTypeDecl();
    }
    if (k == TokenKind.kwImpl) {
      if (decorators.isNotEmpty)
        _fail('decorators are not allowed on impl blocks');
      return _parseImplDecl();
    }
    if (k == TokenKind.kwInterface) {
      if (decorators.isNotEmpty)
        _fail('decorators are not allowed on interface declarations');
      return _parseInterfaceDecl();
    }

    _fail('expected a declaration (fn, type, impl, interface, import)');
  }

  Decorator _parseDecorator() {
    _expect(TokenKind.at, '@');
    final name = _expect(TokenKind.identifier, 'decorator name').lexeme;
    final args = <Expr>[];
    if (_match(TokenKind.lParen)) {
      while (!_check(TokenKind.rParen) && !_atEnd) {
        args.add(_parseExpr());
        if (!_match(TokenKind.comma)) break;
      }
      _expect(TokenKind.rParen, ')');
    }
    return Decorator(name, args: args);
  }

  ImportDecl _parseImport() {
    final startSpan = _advance().span; // consume 'import'
    // Import path is either a dot-separated module path (std.fs) or a quoted
    // string ('wordcount').
    String path;
    if (_check(TokenKind.stringLiteral)) {
      path = _advance().value!;
    } else {
      // module.path form: identifier ('.' identifier)*
      final buf =
          StringBuffer(_expect(TokenKind.identifier, 'module path').lexeme);
      while (_check(TokenKind.dot)) {
        _advance();
        buf.write('.');
        buf.write(_expect(TokenKind.identifier, 'module name segment').lexeme);
      }
      path = buf.toString();
    }
    String? alias;
    if (_match(TokenKind.kwAs)) {
      alias = _expect(TokenKind.identifier, 'alias name').lexeme;
    }
    _match(TokenKind.semi);
    return ImportDecl(startSpan, path: path, alias: alias);
  }

  FnDecl _parseFnDecl(List<Decorator> decorators, {required bool isNative}) {
    if (isNative) _advance(); // 'native'
    final start = _expect(TokenKind.kwFn, 'fn');
    final nameTok = _expect(TokenKind.identifier, 'function name');
    final name = nameTok.lexeme;
    final typeParams = _parseTypeParams();
    _expect(TokenKind.lParen, '(');
    final params = _parseParamList();
    _expect(TokenKind.rParen, ')');
    TypeRef? returnType;
    if (_match(TokenKind.arrow)) {
      returnType = _parseTypeRef();
    }
    Block? body;
    if (_check(TokenKind.lBrace)) {
      body = _parseBlock();
    } else {
      _match(TokenKind.semi); // optional trailing semicolon on body-less fn
    }
    return FnDecl(
      start.span,
      decorators: decorators,
      isNative: isNative,
      name: name,
      nameSpan: nameTok.span,
      typeParams: typeParams,
      params: params,
      returnType: returnType,
      body: body,
    );
  }

  List<TypeParam> _parseTypeParams() {
    if (!_check(TokenKind.lt)) return const [];
    _advance(); // <
    final params = <TypeParam>[];
    while (!_check(TokenKind.gt) && !_atEnd) {
      final name = _expect(TokenKind.identifier, 'type parameter name').lexeme;
      final bounds = <String>[];
      if (_match(TokenKind.colon)) {
        bounds.add(_expect(TokenKind.identifier, 'bound name').lexeme);
        while (_check(TokenKind.plus)) {
          _advance();
          bounds.add(_expect(TokenKind.identifier, 'bound name').lexeme);
        }
      }
      params.add(TypeParam(name, bounds: bounds));
      if (!_match(TokenKind.comma)) break;
    }
    _expect(TokenKind.gt, '>');
    return params;
  }

  List<Param> _parseParamList() {
    final params = <Param>[];
    while (!_check(TokenKind.rParen) && !_atEnd) {
      params.add(_parseParam());
      if (!_match(TokenKind.comma)) break;
    }
    return params;
  }

  Param _parseParam() {
    // self parameter
    if (_check(TokenKind.kwSelf)) {
      _advance();
      return const Param(isSelf: true, name: 'self');
    }

    // Pattern for the external label:
    //   _  name  : type         → suppressed label, internal name = name
    //   name     : type         → label == name (default)
    //   label name : type       → separate external label and internal name
    //   _ name default value : type  (handled by checking for two identifiers)

    String? label;
    String name;

    if (_check(TokenKind.underscore)) {
      _advance(); // _
      label = null; // suppressed
      name = _expect(TokenKind.identifier, 'parameter name').lexeme;
    } else if (_check(TokenKind.identifier)) {
      final first = _advance().lexeme;
      if (_check(TokenKind.identifier)) {
        // external internal form: e.g. 'default value'
        label = first;
        name = _advance().lexeme;
      } else {
        // single identifier: label == name
        label = first;
        name = first;
      }
    } else {
      _fail('expected parameter name or _');
    }

    TypeRef? type;
    if (_match(TokenKind.colon)) {
      type = _parseTypeRef();
    }

    Expr? defaultValue;
    if (_match(TokenKind.eq)) {
      defaultValue = _parseExpr();
    }

    return Param(
        label: label, name: name, type: type, defaultValue: defaultValue);
  }

  TypeDecl _parseTypeDecl() {
    final start = _advance(); // 'type'
    final nameTok = _expect(TokenKind.identifier, 'type name');
    _expect(TokenKind.eq, '=');
    _expect(TokenKind.lBrace, '{');
    final fields = <(String, TypeRef)>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      final fname = _expect(TokenKind.identifier, 'field name').lexeme;
      _expect(TokenKind.colon, ':');
      final ftype = _parseTypeRef();
      fields.add((fname, ftype));
      if (!_match(TokenKind.comma)) break;
    }
    _expect(TokenKind.rBrace, '}');
    return TypeDecl(start.span, name: nameTok.lexeme, nameSpan: nameTok.span, fields: fields);
  }

  ImplDecl _parseImplDecl() {
    final start = _advance(); // 'impl'
    final firstTok = _expect(TokenKind.identifier, 'type or interface name');
    String typeName;
    SourceSpan nameSpan;
    String? interfaceName;
    if (_match(TokenKind.kwFor)) {
      // impl Interface for Type { ... }
      interfaceName = firstTok.lexeme;
      final typeNameTok = _expect(TokenKind.identifier, 'type name');
      typeName = typeNameTok.lexeme;
      nameSpan = typeNameTok.span;
    } else {
      // impl Type { ... }
      typeName = firstTok.lexeme;
      nameSpan = firstTok.span;
    }
    _expect(TokenKind.lBrace, '{');
    final methods = <FnDecl>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      final decos = <Decorator>[];
      while (_check(TokenKind.at)) decos.add(_parseDecorator());
      final isNative = _match(TokenKind.kwNative);
      if (!_check(TokenKind.kwFn)) _fail('expected fn in impl block');
      methods.add(_parseFnDecl(decos, isNative: isNative));
    }
    _expect(TokenKind.rBrace, '}');
    return ImplDecl(start.span,
        typeName: typeName, nameSpan: nameSpan, interfaceName: interfaceName, methods: methods);
  }

  InterfaceDecl _parseInterfaceDecl() {
    final start = _advance(); // 'interface'
    final nameTok = _expect(TokenKind.identifier, 'interface name');
    _expect(TokenKind.lBrace, '{');
    final methods = <FnDecl>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      if (!_check(TokenKind.kwFn)) _fail('expected fn in interface');
      methods.add(_parseFnDecl([], isNative: false));
    }
    _expect(TokenKind.rBrace, '}');
    return InterfaceDecl(start.span, name: nameTok.lexeme, nameSpan: nameTok.span, methods: methods);
  }

  // ---- type references ----

  TypeRef _parseTypeRef() {
    // () = void/unit
    if (_check(TokenKind.lParen)) {
      _advance();
      _expect(TokenKind.rParen, ')');
      return const VoidType();
    }
    final name = _expect(TokenKind.identifier, 'type name').lexeme;
    final args = <TypeRef>[];
    if (_check(TokenKind.lt)) {
      _advance(); // <
      while (!_check(TokenKind.gt) && !_atEnd) {
        args.add(_parseTypeRef());
        if (!_match(TokenKind.comma)) break;
      }
      _expect(TokenKind.gt, '>');
    }
    return NamedType(name, args: args);
  }

  // ---- block and statements ----

  Block _parseBlock() {
    final start = _expect(TokenKind.lBrace, '{');
    final stmts = <Stmt>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      stmts.add(_parseStmt());
    }
    final end = _expect(TokenKind.rBrace, '}');
    return Block(start.span, end.span, stmts);
  }

  Stmt _parseStmt() {
    final k = _current.kind;

    if (k == TokenKind.kwLet) return _parseLetStmt();
    if (k == TokenKind.kwReturn) return _parseReturnStmt();
    if (k == TokenKind.kwThrow) return _parseThrowStmt();
    if (k == TokenKind.kwIf) return _parseIfStmt();
    if (k == TokenKind.kwFor) return _parseForStmt();
    if (k == TokenKind.kwWhile) return _parseWhileStmt();

    // Expression statement
    final start = _current.span;
    final expr = _parseExpr();
    _match(TokenKind.semi);
    return ExprStmt(start, expr);
  }

  LetStmt _parseLetStmt() {
    final start = _advance(); // 'let'
    final isMut = _match(TokenKind.kwMut);
    final name = _expect(TokenKind.identifier, 'variable name').lexeme;
    TypeRef? type;
    if (_match(TokenKind.colon)) type = _parseTypeRef();
    _expect(TokenKind.eq, '=');
    final value = _parseExpr();
    _match(TokenKind.semi);
    return LetStmt(start.span,
        isMut: isMut, name: name, type: type, value: value);
  }

  ReturnStmt _parseReturnStmt() {
    final start = _current.span;
    final expr = _parseExpr() as ReturnExpr; // primary handles kwReturn
    _match(TokenKind.semi);
    return ReturnStmt(start, value: expr.value);
  }

  ThrowStmt _parseThrowStmt() {
    final start = _current.span;
    final expr = _parseExpr() as ThrowExpr; // primary handles kwThrow
    _match(TokenKind.semi);
    return ThrowStmt(start, value: expr.value);
  }

  IfStmt _parseIfStmt() {
    final start = _advance(); // 'if'
    final condition = _parseExprNoBrace();
    final then = _parseBlock();
    Block? else_;
    if (_match(TokenKind.kwElse)) {
      if (_check(TokenKind.kwIf)) {
        final inner = _parseIfStmt();
        // Synthetic block: reuse the if's span for both start and end.
        else_ = Block(inner.span, inner.span, [inner]);
      } else {
        else_ = _parseBlock();
      }
    }
    return IfStmt(start.span, condition: condition, then: then, else_: else_);
  }

  ForStmt _parseForStmt() {
    final start = _advance(); // 'for'
    final pattern = _parsePattern();
    _expect(TokenKind.kwIn, 'in');
    final iterable = _parseExprNoBrace();
    final body = _parseBlock();
    return ForStmt(start.span,
        pattern: pattern, iterable: iterable, body: body);
  }

  WhileStmt _parseWhileStmt() {
    final start = _advance(); // 'while'
    final condition = _parseExprNoBrace();
    final body = _parseBlock();
    return WhileStmt(start.span, condition: condition, body: body);
  }

  // ---- patterns ----

  Pattern _parsePattern() {
    if (_check(TokenKind.underscore)) {
      _advance();
      return const WildcardPattern();
    }
    if (_check(TokenKind.identifier)) {
      final name = _advance().lexeme;
      if (_check(TokenKind.lParen)) {
        _advance();
        final args = <Pattern>[];
        while (!_check(TokenKind.rParen) && !_atEnd) {
          args.add(_parsePattern());
          if (!_match(TokenKind.comma)) break;
        }
        _expect(TokenKind.rParen, ')');
        return ConstructorPattern(name, args);
      }
      return IdentPattern(name);
    }
    if (_check(TokenKind.kwTrue) ||
        _check(TokenKind.kwFalse) ||
        _check(TokenKind.intLiteral) ||
        _check(TokenKind.stringLiteral)) {
      return LiteralPattern(_parsePrimary());
    }
    _fail('expected a pattern');
  }

  // ---- expressions ----

  // Full expression parser (struct literals allowed).
  Expr _parseExpr() => _parseOr();

  // Expression parser that stops before `{` — used for if/for/while/match
  // conditions so that `if foo { ... }` doesn't try to parse `foo { ... }` as
  // a struct literal.
  Expr _parseExprNoBrace() => _parseOr(allowStructLiteral: false);

  Expr _parseOr({bool allowStructLiteral = true}) {
    var left = _parseAnd(allowStructLiteral: allowStructLiteral);
    while (_check(TokenKind.pipePipe)) {
      final op = _advance().span.text;
      final right = _parseAnd(allowStructLiteral: allowStructLiteral);
      left = BinaryExpr(left.span, left: left, op: op, right: right);
    }
    return left;
  }

  Expr _parseAnd({bool allowStructLiteral = true}) {
    var left = _parseEquality(allowStructLiteral: allowStructLiteral);
    while (_check(TokenKind.ampAmp)) {
      final op = _advance().span.text;
      final right = _parseEquality(allowStructLiteral: allowStructLiteral);
      left = BinaryExpr(left.span, left: left, op: op, right: right);
    }
    return left;
  }

  Expr _parseEquality({bool allowStructLiteral = true}) {
    var left = _parseComparison(allowStructLiteral: allowStructLiteral);
    while (_check(TokenKind.eqEq) || _check(TokenKind.bangEq)) {
      final op = _advance().span.text;
      final right = _parseComparison(allowStructLiteral: allowStructLiteral);
      left = BinaryExpr(left.span, left: left, op: op, right: right);
    }
    return left;
  }

  Expr _parseComparison({bool allowStructLiteral = true}) {
    var left = _parseRange(allowStructLiteral: allowStructLiteral);
    while (_check(TokenKind.lt) ||
        _check(TokenKind.gt) ||
        _check(TokenKind.ltEq) ||
        _check(TokenKind.gtEq)) {
      final op = _advance().span.text;
      final right = _parseRange(allowStructLiteral: allowStructLiteral);
      left = BinaryExpr(left.span, left: left, op: op, right: right);
    }
    return left;
  }

  Expr _parseRange({bool allowStructLiteral = true}) {
    final left = _parseAddition(allowStructLiteral: allowStructLiteral);
    if (_check(TokenKind.dotDot)) {
      _advance();
      final right = _parseAddition(allowStructLiteral: allowStructLiteral);
      return RangeExpr(left.span, start: left, end: right);
    }
    return left;
  }

  Expr _parseAddition({bool allowStructLiteral = true}) {
    var left = _parseMultiplication(allowStructLiteral: allowStructLiteral);
    while (_check(TokenKind.plus) || _check(TokenKind.minus)) {
      final op = _advance().span.text;
      final right =
          _parseMultiplication(allowStructLiteral: allowStructLiteral);
      left = BinaryExpr(left.span, left: left, op: op, right: right);
    }
    return left;
  }

  Expr _parseMultiplication({bool allowStructLiteral = true}) {
    var left = _parseUnary(allowStructLiteral: allowStructLiteral);
    while (_check(TokenKind.star) ||
        _check(TokenKind.slash) ||
        _check(TokenKind.percent)) {
      final op = _advance().span.text;
      final right = _parseUnary(allowStructLiteral: allowStructLiteral);
      left = BinaryExpr(left.span, left: left, op: op, right: right);
    }
    return left;
  }

  Expr _parseUnary({bool allowStructLiteral = true}) {
    if (_check(TokenKind.bang) || _check(TokenKind.minus)) {
      final op = _advance();
      final operand = _parseUnary(allowStructLiteral: allowStructLiteral);
      return UnaryExpr(op.span, op: op.span.text, operand: operand);
    }
    return _parsePostfix(allowStructLiteral: allowStructLiteral);
  }

  Expr _parsePostfix({bool allowStructLiteral = true}) {
    var expr = _parsePrimary(allowStructLiteral: allowStructLiteral);
    while (true) {
      if (_check(TokenKind.dot)) {
        _advance();
        final field = _expect(TokenKind.identifier, 'field or method name');
        expr = FieldExpr(expr.span, object: expr, field: field.lexeme);
        // If followed by ( or <, this is a method call (handled below on next
        // iteration, since expr is now a FieldExpr).
      } else if (_check(TokenKind.lParen)) {
        final args = _parseCallArgs();
        expr = CallExpr(expr.span, callee: expr, args: args);
      } else if (_check(TokenKind.lt) && _looksLikeTypeArgList()) {
        final typeArgs = _parseTypeArgList();
        // Expect ( immediately after type args for a generic call.
        if (_check(TokenKind.lParen)) {
          final args = _parseCallArgs();
          expr =
              CallExpr(expr.span, callee: expr, typeArgs: typeArgs, args: args);
        } else {
          // Not a call — treat the < as a comparison operator (put it back by
          // not consuming it). Since we already consumed it, insert a synthetic
          // BinaryExpr. This path is rare and we can improve it later.
          _fail('expected ( after type argument list');
        }
      } else if (_check(TokenKind.lBracket)) {
        _advance();
        final index = _parseExpr();
        _expect(TokenKind.rBracket, ']');
        expr = IndexExpr(expr.span, object: expr, index: index);
      } else if (_check(TokenKind.question)) {
        _advance();
        expr = PropagateExpr(expr.span, expr);
      } else {
        break;
      }
    }
    return expr;
  }

  List<CallArg> _parseCallArgs() {
    _expect(TokenKind.lParen, '(');
    final args = <CallArg>[];
    while (!_check(TokenKind.rParen) && !_atEnd) {
      // Labeled arg: ident ':'  expr
      // Unlabeled:   expr
      String? label;
      if (_check(TokenKind.identifier) && _next.kind == TokenKind.colon) {
        label = _advance().lexeme;
        _advance(); // ':'
      }
      final val = _parseExpr();
      args.add(CallArg(label: label, value: val));
      if (!_match(TokenKind.comma)) break;
    }
    _expect(TokenKind.rParen, ')');
    return args;
  }

  // Heuristic: after `<`, look for `TypeName>` or `TypeName, TypeName>`.
  // Returns true if this looks like a type argument list rather than comparison.
  bool _looksLikeTypeArgList() {
    // We need to peek ahead past the < to see if it looks like `TypeName>` or
    // `TypeName, TypeName>`.  Simple: expect lt, identifier, (comma identifier)*, gt.
    var i = _pos + 1; // position after <
    if (i >= _tokens.length) return false;
    while (true) {
      final t = _tokens[i];
      if (t.kind != TokenKind.identifier) return false;
      i++;
      if (i >= _tokens.length) return false;
      final after = _tokens[i];
      if (after.kind == TokenKind.gt) return true;
      if (after.kind == TokenKind.comma) {
        i++;
        continue;
      }
      // Handle nested generics like Result<T, E> — look for matching >
      if (after.kind == TokenKind.lt) return false; // too complex for now
      return false;
    }
  }

  List<TypeRef> _parseTypeArgList() {
    _advance(); // <
    final args = <TypeRef>[];
    while (!_check(TokenKind.gt) && !_atEnd) {
      args.add(_parseTypeRef());
      if (!_match(TokenKind.comma)) break;
    }
    _expect(TokenKind.gt, '>');
    return args;
  }

  Expr _parsePrimary({bool allowStructLiteral = true}) {
    final t = _current;

    switch (t.kind) {
      case TokenKind.intLiteral:
        _advance();
        return IntLiteral(t.span, int.parse(t.span.text));

      case TokenKind.floatLiteral:
        _advance();
        return FloatLiteral(t.span, double.parse(t.span.text));

      case TokenKind.stringLiteral:
        _advance();
        final parts = _splitStringParts(t.value!, t.span);
        return StringExpr(t.span, parts);

      case TokenKind.kwTrue:
        _advance();
        return BoolLiteral(t.span, true);

      case TokenKind.kwFalse:
        _advance();
        return BoolLiteral(t.span, false);

      case TokenKind.kwSelf:
        _advance();
        return IdentExpr(t.span, 'self');

      case TokenKind.lParen:
        _advance();
        // () = unit value
        if (_check(TokenKind.rParen)) {
          _advance();
          return StructExpr(t.span, typeName: '()', fields: []);
        }
        final inner = _parseExpr();
        _expect(TokenKind.rParen, ')');
        return inner;

      case TokenKind.lBracket:
        return _parseListLiteral();

      case TokenKind.lBrace:
        return BlockExpr(t.span, _parseBlock());

      case TokenKind.kwMatch:
        return _parseMatchExpr();

      case TokenKind.kwReturn:
        _advance();
        Expr? retVal;
        if (!_check(TokenKind.semi) &&
            !_check(TokenKind.rBrace) &&
            !_check(TokenKind.comma) &&
            !_atEnd) {
          retVal = _parseExpr();
        }
        return ReturnExpr(t.span, value: retVal);

      case TokenKind.kwThrow:
        _advance();
        return ThrowExpr(t.span, _parseExpr());

      case TokenKind.identifier:
        _advance();
        final name = t.lexeme;

        // Lambda: ident => expr
        if (_check(TokenKind.fatArrow)) {
          _advance();
          final body = _parseExpr();
          return LambdaExpr(t.span, params: [name], body: body);
        }

        // Struct literal: TypeName { field: expr, ... }
        // Only allowed when allowStructLiteral is true and the next token is {.
        if (allowStructLiteral && _check(TokenKind.lBrace)) {
          return _parseStructLiteral(name, t.span);
        }

        return IdentExpr(t.span, name);

      default:
        _fail('unexpected token: "${t.span.text}"');
    }
  }

  Expr _parseListLiteral() {
    final start = _advance(); // [
    final items = <Expr>[];
    while (!_check(TokenKind.rBracket) && !_atEnd) {
      items.add(_parseExpr());
      if (!_match(TokenKind.comma)) break;
    }
    _expect(TokenKind.rBracket, ']');
    return ListExpr(start.span, items);
  }

  Expr _parseStructLiteral(String typeName, SourceSpan span) {
    _advance(); // {
    final fields = <(String, Expr)>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      final fname = _expect(TokenKind.identifier, 'field name').lexeme;
      _expect(TokenKind.colon, ':');
      final fval = _parseExpr();
      fields.add((fname, fval));
      if (!_match(TokenKind.comma)) break;
    }
    _expect(TokenKind.rBrace, '}');
    return StructExpr(span, typeName: typeName, fields: fields);
  }

  Expr _parseMatchExpr() {
    final start = _advance(); // 'match'
    final subject = _parseExprNoBrace();
    _expect(TokenKind.lBrace, '{');
    final arms = <MatchArm>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      final pattern = _parsePattern();
      _expect(TokenKind.fatArrow, '=>');
      // Arm body: either a block { ... } or an expression.
      final Expr body;
      if (_check(TokenKind.lBrace)) {
        body = BlockExpr(_current.span, _parseBlock());
      } else {
        body = _parseExpr();
      }
      _match(TokenKind.comma);
      arms.add(MatchArm(pattern: pattern, body: body));
    }
    _expect(TokenKind.rBrace, '}');
    return MatchExpr(start.span, subject: subject, arms: arms);
  }

  // ---- string interpolation splitting ----

  // Split the raw string content (as captured by the lexer) into TextPart and
  // InterpPart segments.  ${...} nesting is handled correctly.
  List<StringPart> _splitStringParts(String raw, SourceSpan parentSpan) {
    final parts = <StringPart>[];
    var i = 0;
    final buf = StringBuffer();

    while (i < raw.length) {
      if (raw[i] == r'$' && i + 1 < raw.length && raw[i + 1] == '{') {
        if (buf.isNotEmpty) {
          parts.add(TextPart(buf.toString()));
          buf.clear();
        }
        i += 2; // skip ${
        final interpStart = i;
        var depth = 1;
        while (i < raw.length && depth > 0) {
          if (raw[i] == '{')
            depth++;
          else if (raw[i] == '}') depth--;
          i++;
        }
        // raw[interpStart .. i-1] is the expression source (closing } excluded).
        final exprSource = raw.substring(interpStart, i - 1);
        final lexResult = Lexer(exprSource).tokenize();
        final parseResult = Parser(lexResult.tokens).parse();
        // The interpolation should be a single expression statement.
        if (parseResult.program.decls.isEmpty && lexResult.tokens.length > 1) {
          // Re-parse as expression — treat the source as a statement-expression.
          final p2 = Parser(lexResult.tokens);
          final expr = p2._parseExpr();
          parts.add(InterpPart(expr));
        } else if (parseResult.program.decls.isEmpty) {
          // Empty interpolation — emit empty text
          parts.add(TextPart(''));
        } else {
          // Best effort: use what we parsed
          final decl = parseResult.program.decls.first;
          if (decl is FnDecl) {
            parts.add(TextPart(exprSource));
          } else {
            parts.add(TextPart(exprSource));
          }
        }
      } else {
        buf.writeCharCode(raw.codeUnitAt(i));
        i++;
      }
    }
    if (buf.isNotEmpty) parts.add(TextPart(buf.toString()));
    return parts;
  }
}

// Sentinel exception used internally to unwind on error.
class _ParseFail implements Exception {}
