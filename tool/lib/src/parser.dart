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
      final decl = _parseDeclOrRecover();
      if (decl != null) decls.add(decl);
    }
    return ParseResult(Program(decls), _errors);
  }

  /// Parse one top-level declaration, recovering from a parse error by syncing
  /// to the next declaration boundary (returning null for the failed one). This
  /// is the parser's **single** error-recovery boundary: `_fail` throws
  /// `_ParseFail` from anywhere in the parse, and it is caught only here.
  ///
  /// Hawk port note: Hawk has no exceptions, so this becomes a *panic-flag* loop
  /// — `_fail` records the error and sets a `panicking` flag instead of throwing,
  /// parse helpers short-circuit while it is set, and this boundary syncs to the
  /// next declaration and clears it. The shape — one recovery point at the
  /// declaration boundary — is unchanged; only the unwind mechanism differs.
  Decl? _parseDeclOrRecover() {
    try {
      return _parseDecl();
    } on _ParseFail {
      _syncToDecl(); // the error was already recorded by _fail
      return null;
    }
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
          k == TokenKind.kwPub ||
          k == TokenKind.kwConst ||
          k == TokenKind.kwEnum ||
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

    // Optional `pub` visibility modifier (after decorators, before the keyword).
    final pubTok = _check(TokenKind.kwPub) ? _current : null;
    final isPub = _match(TokenKind.kwPub);

    final SourceSpan declStartSpan;
    if (decorators.isNotEmpty) {
      declStartSpan = decorators.first.span;
    } else if (pubTok != null) {
      declStartSpan = pubTok.span;
    } else {
      declStartSpan = _current.span;
    }

    final k = _current.kind;

    if (k == TokenKind.kwImport) {
      if (decorators.isNotEmpty) {
        _fail('decorators are not allowed on import declarations');
      }
      return _parseImport(isPub, declStartSpan);
    }
    if (k == TokenKind.kwNative) {
      return _parseFnDecl(decorators,
          isNative: true, isPub: isPub, startSpan: declStartSpan);
    }
    if (k == TokenKind.kwFn) {
      return _parseFnDecl(decorators,
          isNative: false, isPub: isPub, startSpan: declStartSpan);
    }
    if (k == TokenKind.kwType) {
      if (decorators.isNotEmpty)
        _fail('decorators are not allowed on type declarations');
      return _parseTypeDecl(isPub: isPub, startSpan: declStartSpan);
    }
    if (k == TokenKind.kwImpl) {
      if (decorators.isNotEmpty)
        _fail('decorators are not allowed on impl blocks');
      if (isPub) {
        _fail('`pub` is not allowed on impl blocks; '
            'mark individual methods `pub` instead');
      }
      return _parseImplDecl(startSpan: declStartSpan);
    }
    if (k == TokenKind.kwInterface) {
      if (decorators.isNotEmpty)
        _fail('decorators are not allowed on interface declarations');
      return _parseInterfaceDecl(isPub: isPub, startSpan: declStartSpan);
    }
    if (k == TokenKind.kwConst) {
      if (decorators.isNotEmpty)
        _fail('decorators are not allowed on const declarations');
      return _parseConstDecl(isPub: isPub, startSpan: declStartSpan);
    }
    if (k == TokenKind.kwEnum) {
      if (decorators.isNotEmpty)
        _fail('decorators are not allowed on enum declarations');
      return _parseEnumDecl(isPub: isPub, startSpan: declStartSpan);
    }

    _fail(
        'expected a declaration (fn, type, impl, interface, import, const, enum)');
  }

  Decorator _parseDecorator() {
    final startTok = _expect(TokenKind.at, '@');
    final nameTok = _expect(TokenKind.identifier, 'decorator name');
    final name = nameTok.lexeme;
    final args = <Expr>[];
    SourceSpan endSpan = nameTok.span;
    if (_match(TokenKind.lParen)) {
      while (!_check(TokenKind.rParen) && !_atEnd) {
        args.add(_parseExpr());
        if (!_match(TokenKind.comma)) break;
      }
      final rParenTok = _expect(TokenKind.rParen, ')');
      endSpan = rParenTok.span;
    }
    return Decorator(SourceSpan.cover(startTok.span, endSpan), name,
        args: args);
  }

  ImportDecl _parseImport(bool isPub, SourceSpan startSpan) {
    _advance(); // consume 'import'
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
    final endSpan = _tokens[_pos - 1].span;
    return ImportDecl(SourceSpan.cover(startSpan, endSpan),
        path: path, alias: alias, isPub: isPub);
  }

  FnDecl _parseFnDecl(List<Decorator> decorators,
      {required bool isNative,
      bool isPub = false,
      required SourceSpan startSpan}) {
    if (isNative) _advance(); // 'native'
    _expect(TokenKind.kwFn, 'fn');
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
    SourceSpan endSpan;
    if (_check(TokenKind.lBrace)) {
      body = _parseBlock();
      endSpan = body.span;
    } else {
      _match(TokenKind.semi); // optional trailing semicolon on body-less fn
      endSpan = _tokens[_pos - 1].span;
    }
    return FnDecl(
      SourceSpan.cover(startSpan, endSpan),
      decorators: decorators,
      isPub: isPub,
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
      final nameTok = _expect(TokenKind.identifier, 'type parameter name');
      final name = nameTok.lexeme;
      final bounds = <String>[];
      SourceSpan endSpan = nameTok.span;
      if (_match(TokenKind.colon)) {
        final firstBound = _expect(TokenKind.identifier, 'bound name');
        bounds.add(firstBound.lexeme);
        endSpan = firstBound.span;
        while (_check(TokenKind.plus)) {
          _advance();
          final nextBound = _expect(TokenKind.identifier, 'bound name');
          bounds.add(nextBound.lexeme);
          endSpan = nextBound.span;
        }
      }
      params.add(TypeParam(SourceSpan.cover(nameTok.span, endSpan), name,
          bounds: bounds));
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
    final startTok = _current;
    // self parameter
    if (_check(TokenKind.kwSelf)) {
      final selfTok = _advance();
      return Param(
          span: selfTok.span,
          isSelf: true,
          name: 'self',
          nameSpan: selfTok.span);
    }

    // Pattern for the external label:
    //   _  name  : type         → suppressed label, internal name = name
    //   name     : type         → label == name (default)
    //   label name : type       → separate external label and internal name
    //   _ name default value : type  (handled by checking for two identifiers)

    String? label;
    String name;
    SourceSpan nameSpan;

    if (_check(TokenKind.underscore)) {
      _advance(); // _
      label = null; // suppressed
      final nameTok = _expect(TokenKind.identifier, 'parameter name');
      name = nameTok.lexeme;
      nameSpan = nameTok.span;
    } else if (_check(TokenKind.identifier)) {
      final firstTok = _advance();
      final first = firstTok.lexeme;
      if (_check(TokenKind.identifier)) {
        // external internal form: e.g. 'default value'
        label = first;
        final nameTok = _advance();
        name = nameTok.lexeme;
        nameSpan = nameTok.span;
      } else {
        // single identifier: label == name
        label = first;
        name = first;
        nameSpan = firstTok.span;
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
        span: SourceSpan.cover(
            startTok.span, defaultValue?.span ?? type?.span ?? nameSpan),
        label: label,
        name: name,
        nameSpan: nameSpan,
        type: type,
        defaultValue: defaultValue);
  }

  TypeDecl _parseTypeDecl({bool isPub = false, required SourceSpan startSpan}) {
    _advance(); // 'type'
    final nameTok = _expect(TokenKind.identifier, 'type name');
    final typeParams = _parseTypeParams();
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
    final rBraceTok = _expect(TokenKind.rBrace, '}');
    return TypeDecl(SourceSpan.cover(startSpan, rBraceTok.span),
        isPub: isPub,
        name: nameTok.lexeme,
        nameSpan: nameTok.span,
        typeParams: typeParams,
        fields: fields);
  }

  /// Parse a possibly-qualified type/interface name, e.g. `Clock` or
  /// `time.Clock`, returning the token for the base name. The namespace is
  /// dropped: lookup is by base name against the flat type table (mirrors the
  /// value-side `ns.member` syntax; the qualifier is for the author's sake).
  Token _parseQualifiedTypeName(String role) {
    var tok = _expect(TokenKind.identifier, role);
    if (_match(TokenKind.dot)) {
      tok = _expect(TokenKind.identifier, '$role after "${tok.lexeme}."');
    }
    return tok;
  }

  ImplDecl _parseImplDecl({required SourceSpan startSpan}) {
    _advance(); // 'impl'
    final firstTok = _parseQualifiedTypeName('type or interface name');
    final firstParams = _parseTypeParams(); // <T> after the first name, if any
    String typeName;
    SourceSpan nameSpan;
    String? interfaceName;
    List<TypeParam> typeParams;
    var interfaceArgs = const <TypeRef>[];
    if (_match(TokenKind.kwFor)) {
      // impl Interface<Args> for Type<T> { ... }. The `<Args>` (parsed above as
      // `firstParams`) are the interface's type arguments. They are simple type
      // names here (`Int`, or the impl's own `T`) — nested args aren't yet
      // supported on an interface in impl position.
      interfaceName = firstTok.lexeme;
      interfaceArgs = [
        for (final tp in firstParams) NamedType(tp.name, span: tp.span),
      ];
      final typeNameTok = _parseQualifiedTypeName('type name');
      typeName = typeNameTok.lexeme;
      nameSpan = typeNameTok.span;
      typeParams = _parseTypeParams();
    } else {
      // impl Type<T> { ... }
      typeName = firstTok.lexeme;
      nameSpan = firstTok.span;
      typeParams = firstParams;
    }
    _expect(TokenKind.lBrace, '{');
    final methods = <FnDecl>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      final methodStartTok = _current;
      final decos = <Decorator>[];
      while (_check(TokenKind.at)) decos.add(_parseDecorator());
      final pubTok = _check(TokenKind.kwPub) ? _current : null;
      final isPub = _match(TokenKind.kwPub);
      // `native` is consumed by _parseFnDecl, so check (don't match) here.
      final isNative = _check(TokenKind.kwNative);
      final SourceSpan methodStartSpan;
      if (decos.isNotEmpty) {
        methodStartSpan = decos.first.span;
      } else if (pubTok != null) {
        methodStartSpan = pubTok.span;
      } else {
        methodStartSpan = methodStartTok.span;
      }
      methods.add(_parseFnDecl(decos,
          isNative: isNative, isPub: isPub, startSpan: methodStartSpan));
    }
    final rBraceTok = _expect(TokenKind.rBrace, '}');
    return ImplDecl(SourceSpan.cover(startSpan, rBraceTok.span),
        typeName: typeName,
        nameSpan: nameSpan,
        typeParams: typeParams,
        interfaceName: interfaceName,
        interfaceArgs: interfaceArgs,
        methods: methods);
  }

  InterfaceDecl _parseInterfaceDecl(
      {bool isPub = false, required SourceSpan startSpan}) {
    _advance(); // 'interface'
    final nameTok = _expect(TokenKind.identifier, 'interface name');
    final typeParams = _parseTypeParams(); // <T> after the name, if any
    // Optional super-interfaces: `interface Error: Display + Debug { … }`. The
    // `+`-joined form mirrors a generic bound (`<T: Eq + Debug>`).
    final superInterfaces = <String>[];
    if (_match(TokenKind.colon)) {
      superInterfaces
          .add(_expect(TokenKind.identifier, 'super-interface').lexeme);
      while (_check(TokenKind.plus)) {
        _advance();
        superInterfaces
            .add(_expect(TokenKind.identifier, 'super-interface').lexeme);
      }
    }
    _expect(TokenKind.lBrace, '{');
    final methods = <FnDecl>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      final methodStartTok = _current;
      final pubTok = _check(TokenKind.kwPub) ? _current : null;
      final mPub = _match(TokenKind.kwPub);
      if (!_check(TokenKind.kwFn)) _fail('expected fn in interface');
      methods.add(_parseFnDecl([],
          isNative: false,
          isPub: mPub,
          startSpan: pubTok?.span ?? methodStartTok.span));
    }
    final rBraceTok = _expect(TokenKind.rBrace, '}');
    return InterfaceDecl(SourceSpan.cover(startSpan, rBraceTok.span),
        isPub: isPub,
        name: nameTok.lexeme,
        nameSpan: nameTok.span,
        typeParams: typeParams,
        superInterfaces: superInterfaces,
        methods: methods);
  }

  // ---- type references ----

  /// Called just after consuming an opening `(` in expression position. Scans
  /// to the matching `)` (tracking nesting, so a function-type annotation like
  /// `(Int) -> Int` inside a parameter is handled) and returns true if it is
  /// immediately followed by `=>` — i.e. this is a lambda parameter list, not a
  /// parenthesized expression.
  bool _parenIsLambdaParams() {
    var depth = 1;
    for (var i = _pos; i < _tokens.length; i++) {
      switch (_tokens[i].kind) {
        case TokenKind.lParen:
          depth++;
        case TokenKind.rParen:
          depth--;
          if (depth == 0) {
            final next =
                i + 1 < _tokens.length ? _tokens[i + 1].kind : TokenKind.eof;
            return next == TokenKind.fatArrow;
          }
        case TokenKind.eof:
          return false;
        default:
          break;
      }
    }
    return false;
  }

  TypeRef _parseTypeRef() {
    // '(' begins a function type '(T1, ...) -> R' (including the zero-arg
    // '() -> R'). The unit type is named `Void`, not `()`.
    if (_check(TokenKind.lParen)) {
      final startTok = _current;
      _advance();
      final params = <TypeRef>[];
      while (!_check(TokenKind.rParen) && !_atEnd) {
        params.add(_parseTypeRef());
        if (!_match(TokenKind.comma)) break;
      }
      _expect(TokenKind.rParen, ')');
      if (_match(TokenKind.arrow)) {
        final returnType = _parseTypeRef();
        return FunctionTypeRef(params, returnType,
            SourceSpan.cover(startTok.span, returnType.span));
      }
      _fail('expected "->" in function type (the unit type is `Void`)');
    }
    final firstTok = _expect(TokenKind.identifier, 'type name');
    // A qualified type reference: `time.Clock`. The first identifier is the
    // import namespace; the type name follows the dot. Mirrors the value-side
    // `ns.member` syntax. Single-level only (namespaces don't nest).
    String? namespace;
    var nameTok = firstTok;
    if (_match(TokenKind.dot)) {
      namespace = firstTok.lexeme;
      nameTok = _expect(TokenKind.identifier, 'type name after "$namespace."');
    }
    final args = <TypeRef>[];
    Token? gtTok;
    if (_check(TokenKind.lt)) {
      _advance(); // <
      while (!_check(TokenKind.gt) && !_atEnd) {
        args.add(_parseTypeRef());
        if (!_match(TokenKind.comma)) break;
      }
      gtTok = _expect(TokenKind.gt, '>');
    }
    final span = gtTok != null
        ? SourceSpan.cover(firstTok.span, gtTok.span)
        : SourceSpan.cover(firstTok.span, nameTok.span);
    return NamedType(nameTok.lexeme,
        args: args, namespace: namespace, span: span);
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
    if (k == TokenKind.kwConst) return _parseConstAsLet();
    if (k == TokenKind.kwReturn) return _parseReturnStmt();
    if (k == TokenKind.kwThrow) return _parseThrowStmt();
    if (k == TokenKind.kwIf) return _parseIfStmt();
    if (k == TokenKind.kwFor) return _parseForStmt();
    if (k == TokenKind.kwWhile) return _parseWhileStmt();

    // Expression statement or assignment (target = value, or target op= value).
    // We parse the left side as an expression, then check for an assignment op.
    final start = _current.span;
    final expr = _parseExpr();
    return _finishExprStmt(start, expr);
  }

  /// Whether [k] begins a statement-leading keyword (so it's parsed as a
  /// statement, never a tail expression). `if` is intentionally excluded: in an
  /// expression block it's parsed as a value-producing [IfExpr] (which may be a
  /// tail), handled directly in [_parseExprBlock].
  bool _isStmtKeyword(TokenKind k) =>
      k == TokenKind.kwLet ||
      k == TokenKind.kwConst ||
      k == TokenKind.kwReturn ||
      k == TokenKind.kwThrow ||
      k == TokenKind.kwFor ||
      k == TokenKind.kwWhile;

  /// Given an already-parsed leading [expr] (at [start]), finish it as an
  /// assignment or an expression statement, consuming the terminating `;`.
  /// Shared by `_parseStmt` and the expression-block parser.
  Stmt _finishExprStmt(SourceSpan start, Expr expr) {
    final compoundOp = _compoundAssignOp(_current.kind);
    if (_check(TokenKind.eq) || compoundOp != null) {
      if (expr is! IdentExpr && expr is! FieldExpr && expr is! IndexExpr) {
        _fail('invalid assignment target');
      }
      _advance(); // consume '=' or the compound operator
      final rhs = _parseExpr();
      _expect(TokenKind.semi, "';'");
      // `target op= rhs` desugars to `target = target op rhs`. The target is a
      // simple lvalue (identifier/field/index), so reusing it as the operand's
      // left side is sound.
      final value = compoundOp == null
          ? rhs
          : BinaryExpr(SourceSpan.cover(expr.span, rhs.span),
              left: expr, op: compoundOp, right: rhs);
      return AssignStmt(start, target: expr, value: value);
    }
    // A block-terminated expression statement (a bare `match` or `if`, ending in
    // `}`) needs no trailing ';', like `if`/`while`/`for`. Everything else
    // requires one — so a missing ';' (e.g. two adjacent string literals) is an
    // error, not a silently-dropped second statement.
    if (expr is MatchExpr || expr is IfExpr) {
      _match(TokenKind.semi);
    } else {
      _expect(TokenKind.semi, "';'");
    }
    return ExprStmt(start, expr);
  }

  /// Parse a block in **expression position** (a `BlockExpr` or a `{…}` match
  /// arm). Identical to [_parseBlock] except a final expression with no trailing
  /// `;` becomes the block's tail (its value) rather than requiring a `;`. The
  /// statement-level [_parseBlock] is unchanged, so function/`if`/`while`/`for`
  /// bodies keep the require-`;` rule. See docs/tailexpr.md.
  Block _parseExprBlock() {
    final start = _expect(TokenKind.lBrace, '{');
    final stmts = <Stmt>[];
    Expr? tail;
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      if (_isStmtKeyword(_current.kind)) {
        stmts.add(_parseStmt());
        continue;
      }
      // A leading `if` is a value-producing expression here: the tail when it's
      // last, otherwise a discarded statement (so `else` is optional — the
      // checker requires it only in tail position). See docs/tailexpr.md.
      if (_check(TokenKind.kwIf)) {
        final ifStart = _current.span;
        final ifExpr = _parseIfExpr(requireElse: false);
        if (_check(TokenKind.rBrace)) {
          tail = ifExpr;
          break;
        }
        _match(TokenKind.semi); // block-terminated; ';' optional
        stmts.add(ExprStmt(ifStart, ifExpr));
        continue;
      }
      final exprStart = _current.span;
      final expr = _parseExpr();
      // A trailing expression immediately before `}`, with no `;`, is the tail.
      if (_check(TokenKind.rBrace)) {
        tail = expr;
        break;
      }
      stmts.add(_finishExprStmt(exprStart, expr));
    }
    final end = _expect(TokenKind.rBrace, '}');
    return Block(start.span, end.span, stmts, tail: tail);
  }

  /// The arithmetic operator a compound-assignment token applies, or null if
  /// [k] is not a compound-assignment operator.
  String? _compoundAssignOp(TokenKind k) => switch (k) {
        TokenKind.plusEq => '+',
        TokenKind.minusEq => '-',
        TokenKind.starEq => '*',
        TokenKind.slashEq => '/',
        TokenKind.percentEq => '%',
        _ => null,
      };

  /// Parse an integer literal lexeme, decimal or `0x`/`0X` hex. Hex is parsed as
  /// an unsigned 64-bit pattern wrapped to Hawk's signed `Int` (so e.g.
  /// `0x9E3779B97F4A7C15` is a valid negative constant), matching the runtime's
  /// two's-complement wrapping arithmetic.
  int _parseIntLiteral(String text, SourceSpan span) {
    // `tryParse` returns null (rather than throwing) on bad input — mirroring
    // Hawk's `String.to_int()` / `Int.parse`, which return `Option`, so the
    // failure handling ports without exceptions.
    if (text.length > 2 &&
        text[0] == '0' &&
        (text[1] == 'x' || text[1] == 'X')) {
      final hex = BigInt.tryParse(text.substring(2), radix: 16);
      if (hex == null) _fail('invalid integer literal: "$text"', span);
      return hex.toSigned(64).toInt();
    }
    final value = int.tryParse(text);
    if (value == null) _fail('invalid integer literal: "$text"', span);
    return value;
  }

  /// Parse a local `const NAME [: Type] = expr;` as an immutable [LetStmt].
  LetStmt _parseConstAsLet() {
    final start = _advance(); // 'const'
    final nameTok = _expect(TokenKind.identifier, 'constant name');
    final name = nameTok.lexeme;
    final nameSpan = nameTok.span;
    TypeRef? type;
    if (_match(TokenKind.colon)) type = _parseTypeRef();
    _expect(TokenKind.eq, '=');
    final value = _parseExpr();
    _expect(TokenKind.semi, "';'");
    final endSpan = _tokens[_pos - 1].span;
    return LetStmt(SourceSpan.cover(start.span, endSpan),
        isMut: false, name: name, nameSpan: nameSpan, type: type, value: value);
  }

  ConstDecl _parseConstDecl(
      {bool isPub = false, required SourceSpan startSpan}) {
    _advance(); // 'const'
    final nameTok = _expect(TokenKind.identifier, 'constant name');
    final name = nameTok.lexeme;
    final nameSpan = nameTok.span;
    TypeRef? type;
    if (_match(TokenKind.colon)) type = _parseTypeRef();
    _expect(TokenKind.eq, '=');
    final value = _parseExpr();
    _match(TokenKind.semi);
    final endSpan = _tokens[_pos - 1].span;
    return ConstDecl(SourceSpan.cover(startSpan, endSpan),
        isPub: isPub, name: name, nameSpan: nameSpan, type: type, value: value);
  }

  EnumDecl _parseEnumDecl({bool isPub = false, required SourceSpan startSpan}) {
    _advance(); // 'enum'
    final nameTok = _expect(TokenKind.identifier, 'enum name');
    final typeParams = _parseTypeParams();
    _expect(TokenKind.lBrace, '{');
    final variants = <EnumVariant>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      final vTok = _expect(TokenKind.identifier, 'variant name');
      final fields = <TypeRef>[];
      SourceSpan endSpan = vTok.span;
      if (_match(TokenKind.lParen)) {
        while (!_check(TokenKind.rParen) && !_atEnd) {
          fields.add(_parseTypeRef());
          if (!_match(TokenKind.comma)) break;
        }
        final rParenTok = _expect(TokenKind.rParen, ')');
        endSpan = rParenTok.span;
      }
      variants.add(EnumVariant(vTok.lexeme,
          span: SourceSpan.cover(vTok.span, endSpan),
          nameSpan: vTok.span,
          fields: fields));
      if (!_match(TokenKind.comma)) break;
    }
    final rBraceTok = _expect(TokenKind.rBrace, '}');
    return EnumDecl(SourceSpan.cover(startSpan, rBraceTok.span),
        isPub: isPub,
        name: nameTok.lexeme,
        nameSpan: nameTok.span,
        typeParams: typeParams,
        variants: variants);
  }

  LetStmt _parseLetStmt() {
    final start = _advance(); // 'let'
    final isMut = _match(TokenKind.kwMut);
    final nameTok = _expect(TokenKind.identifier, 'variable name');
    final name = nameTok.lexeme;
    final nameSpan = nameTok.span;
    TypeRef? type;
    if (_match(TokenKind.colon)) type = _parseTypeRef();
    _expect(TokenKind.eq, '=');
    final value = _parseExpr();
    _expect(TokenKind.semi, "';'");
    final endSpan = _tokens[_pos - 1].span;
    return LetStmt(SourceSpan.cover(start.span, endSpan),
        isMut: isMut, name: name, nameSpan: nameSpan, type: type, value: value);
  }

  ReturnStmt _parseReturnStmt() {
    final expr = _parseExpr() as ReturnExpr; // primary handles kwReturn
    _expect(TokenKind.semi, "';'");
    final endSpan = _tokens[_pos - 1].span;
    return ReturnStmt(SourceSpan.cover(expr.span, endSpan), value: expr.value);
  }

  ThrowStmt _parseThrowStmt() {
    final expr = _parseExpr() as ThrowExpr; // primary handles kwThrow
    _expect(TokenKind.semi, "';'");
    final endSpan = _tokens[_pos - 1].span;
    return ThrowStmt(SourceSpan.cover(expr.span, endSpan), value: expr.value);
  }

  IfStmt _parseIfStmt() {
    final start = _advance(); // 'if'
    final condition = _parseExprNoBrace();
    final then = _parseBlock();
    Block? else_;
    SourceSpan endSpan = then.span;
    if (_match(TokenKind.kwElse)) {
      if (_check(TokenKind.kwIf)) {
        final inner = _parseIfStmt();
        // Synthetic block: reuse the if's span for both start and end.
        else_ = Block(inner.span, inner.span, [inner]);
        endSpan = inner.span;
      } else {
        else_ = _parseBlock();
        endSpan = else_.span;
      }
    }
    return IfStmt(SourceSpan.cover(start.span, endSpan),
        condition: condition, then: then, else_: else_);
  }

  /// Parse `if` in **expression position** (docs/tailexpr.md). The branches are
  /// tail-valued blocks. [requireElse] is set where the `if`'s value is used (a
  /// primary `if`), so a missing `else` — which couldn't produce a value — is a
  /// parse error; it's cleared where the `if` may be a discarded statement.
  IfExpr _parseIfExpr({required bool requireElse}) {
    final start = _advance(); // 'if'
    final condition = _parseExprNoBrace();
    final then = _parseExprBlock();
    Block? else_;
    SourceSpan endSpan = then.span;
    if (_match(TokenKind.kwElse)) {
      if (_check(TokenKind.kwIf)) {
        // `else if …`: the chained `if` is the else block's tail (so it still
        // produces a value). It inherits [requireElse].
        final inner = _parseIfExpr(requireElse: requireElse);
        else_ = Block(inner.span, inner.span, const [], tail: inner);
        endSpan = inner.span;
      } else {
        else_ = _parseExprBlock();
        endSpan = else_.span;
      }
    } else if (requireElse) {
      _fail("an `if` used as a value needs an `else` branch", then.span);
    }
    return IfExpr(SourceSpan.cover(start.span, endSpan),
        condition: condition, then: then, else_: else_);
  }

  ForStmt _parseForStmt() {
    final start = _advance(); // 'for'
    final pattern = _parsePattern();
    _expect(TokenKind.kwIn, 'in');
    final iterable = _parseExprNoBrace();
    final body = _parseBlock();
    return ForStmt(SourceSpan.cover(start.span, body.span),
        pattern: pattern, iterable: iterable, body: body);
  }

  WhileStmt _parseWhileStmt() {
    final start = _advance(); // 'while'
    final condition = _parseExprNoBrace();
    final body = _parseBlock();
    return WhileStmt(SourceSpan.cover(start.span, body.span),
        condition: condition, body: body);
  }

  // ---- patterns ----

  Pattern _parsePattern() {
    if (_check(TokenKind.underscore)) {
      final tok = _advance();
      return WildcardPattern(tok.span);
    }
    if (_check(TokenKind.identifier)) {
      final tok = _advance();
      final name = tok.lexeme;
      if (_check(TokenKind.lParen)) {
        _advance();
        final args = <Pattern>[];
        while (!_check(TokenKind.rParen) && !_atEnd) {
          args.add(_parsePattern());
          if (!_match(TokenKind.comma)) break;
        }
        final rParenTok = _expect(TokenKind.rParen, ')');
        return ConstructorPattern(
            SourceSpan.cover(tok.span, rParenTok.span), name, args);
      }
      // Uppercase-first = zero-arg constructor (variant/struct); lowercase = binding.
      if (name[0].toUpperCase() == name[0])
        return ConstructorPattern(tok.span, name, []);
      return IdentPattern(tok.span, name);
    }
    if (_check(TokenKind.kwTrue) ||
        _check(TokenKind.kwFalse) ||
        _check(TokenKind.intLiteral) ||
        _check(TokenKind.stringLiteral)) {
      final literal = _parsePrimary();
      return LiteralPattern(literal.span, literal);
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
      left = BinaryExpr(SourceSpan.cover(left.span, right.span),
          left: left, op: op, right: right);
    }
    return left;
  }

  Expr _parseAnd({bool allowStructLiteral = true}) {
    var left = _parseEquality(allowStructLiteral: allowStructLiteral);
    while (_check(TokenKind.ampAmp)) {
      final op = _advance().span.text;
      final right = _parseEquality(allowStructLiteral: allowStructLiteral);
      left = BinaryExpr(SourceSpan.cover(left.span, right.span),
          left: left, op: op, right: right);
    }
    return left;
  }

  Expr _parseEquality({bool allowStructLiteral = true}) {
    var left = _parseComparison(allowStructLiteral: allowStructLiteral);
    while (_check(TokenKind.eqEq) || _check(TokenKind.bangEq)) {
      final op = _advance().span.text;
      final right = _parseComparison(allowStructLiteral: allowStructLiteral);
      left = BinaryExpr(SourceSpan.cover(left.span, right.span),
          left: left, op: op, right: right);
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
      left = BinaryExpr(SourceSpan.cover(left.span, right.span),
          left: left, op: op, right: right);
    }
    return left;
  }

  Expr _parseRange({bool allowStructLiteral = true}) {
    final left = _parseAddition(allowStructLiteral: allowStructLiteral);
    if (_check(TokenKind.dotDot)) {
      _advance();
      final right = _parseAddition(allowStructLiteral: allowStructLiteral);
      return RangeExpr(SourceSpan.cover(left.span, right.span),
          start: left, end: right);
    }
    return left;
  }

  Expr _parseAddition({bool allowStructLiteral = true}) {
    var left = _parseMultiplication(allowStructLiteral: allowStructLiteral);
    while (_check(TokenKind.plus) || _check(TokenKind.minus)) {
      final op = _advance().span.text;
      final right =
          _parseMultiplication(allowStructLiteral: allowStructLiteral);
      left = BinaryExpr(SourceSpan.cover(left.span, right.span),
          left: left, op: op, right: right);
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
      left = BinaryExpr(SourceSpan.cover(left.span, right.span),
          left: left, op: op, right: right);
    }
    return left;
  }

  Expr _parseUnary({bool allowStructLiteral = true}) {
    if (_check(TokenKind.bang) || _check(TokenKind.minus)) {
      final op = _advance();
      final operand = _parseUnary(allowStructLiteral: allowStructLiteral);
      return UnaryExpr(SourceSpan.cover(op.span, operand.span),
          op: op.span.text, operand: operand);
    }
    return _parsePostfix(allowStructLiteral: allowStructLiteral);
  }

  Expr _parsePostfix({bool allowStructLiteral = true}) {
    var expr = _parsePrimary(allowStructLiteral: allowStructLiteral);
    while (true) {
      if (_check(TokenKind.dot)) {
        _advance();
        final field = _expect(TokenKind.identifier, 'field or method name');
        expr = FieldExpr(SourceSpan.cover(expr.span, field.span),
            object: expr, field: field.lexeme);
        // If followed by ( or <, this is a method call (handled below on next
        // iteration, since expr is now a FieldExpr).
      } else if (_check(TokenKind.lParen)) {
        final args = _parseCallArgs();
        final endSpan = _tokens[_pos - 1].span;
        expr = CallExpr(SourceSpan.cover(expr.span, endSpan),
            callee: expr, args: args);
      } else if (_check(TokenKind.lt) && _looksLikeTypeArgList()) {
        final typeArgs = _parseTypeArgList();
        // Expect ( immediately after type args for a generic call.
        if (_check(TokenKind.lParen)) {
          final args = _parseCallArgs();
          final endSpan = _tokens[_pos - 1].span;
          expr = CallExpr(SourceSpan.cover(expr.span, endSpan),
              callee: expr, typeArgs: typeArgs, args: args);
        } else {
          // Not a call — treat the < as a comparison operator (put it back by
          // not consuming it). Since we already consumed it, insert a synthetic
          // BinaryExpr. This path is rare and we can improve it later.
          _fail('expected ( after type argument list');
        }
      } else if (_check(TokenKind.lBracket)) {
        _advance();
        final index = _parseExpr();
        final rBracketTok = _expect(TokenKind.rBracket, ']');
        expr = IndexExpr(SourceSpan.cover(expr.span, rBracketTok.span),
            object: expr, index: index);
      } else if (_check(TokenKind.question)) {
        final qTok = _advance();
        expr = PropagateExpr(SourceSpan.cover(expr.span, qTok.span), expr);
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
      SourceSpan? labelSpan;
      if (_check(TokenKind.identifier) && _next.kind == TokenKind.colon) {
        final labelTok = _advance();
        label = labelTok.lexeme;
        labelSpan = labelTok.span;
        _advance(); // ':'
      }
      final val = _parseExpr();
      final span =
          labelSpan != null ? SourceSpan.cover(labelSpan, val.span) : val.span;
      args.add(CallArg(span, label: label, value: val));
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
        return IntLiteral(t.span, _parseIntLiteral(t.span.text, t.span));

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

      case TokenKind.kwVoid:
        _advance();
        return UnitLiteral(t.span);

      case TokenKind.lParen:
        _advance();
        // A `(` here is either a parenthesized (grouped) expression or a lambda
        // parameter list `(a, b: Int) => …`. Disambiguate by looking ahead: a
        // lambda is a `(...)` immediately followed by `=>`.
        if (_parenIsLambdaParams()) {
          final params = <LambdaParam>[];
          while (!_check(TokenKind.rParen) && !_atEnd) {
            final nameTok = _expect(TokenKind.identifier, 'parameter name');
            TypeRef? type;
            if (_match(TokenKind.colon)) type = _parseTypeRef();
            final span = type != null
                ? SourceSpan.cover(nameTok.span, type.span)
                : nameTok.span;
            params.add(LambdaParam(span, nameTok.lexeme, type: type));
            if (!_match(TokenKind.comma)) break;
          }
          _expect(TokenKind.rParen, ')');
          _expect(TokenKind.fatArrow, '=>');
          final body = _parseExpr();
          return LambdaExpr(SourceSpan.cover(t.span, body.span),
              params: params, body: body);
        }
        final inner = _parseExpr();
        _expect(TokenKind.rParen, ')');
        return inner;

      case TokenKind.lBracket:
        return _parseListLiteral();

      case TokenKind.lBrace:
        // Disambiguate map literal `{ expr: expr, ... }` from block `{ stmt... }`.
        // A map literal starts with a string/int literal key followed by ':'.
        // An empty `{}` is also a map literal.
        if (_isMapLiteralStart()) return _parseMapLiteral();
        final block = _parseExprBlock();
        return BlockExpr(SourceSpan.cover(t.span, block.span), block);

      case TokenKind.kwMatch:
        return _parseMatchExpr();

      case TokenKind.kwIf:
        // `if` in expression position is value-producing, so an `else` is
        // required here (docs/tailexpr.md). A statement-position `if` is parsed
        // as an `IfStmt` (via `_parseStmt`), not through here.
        return _parseIfExpr(requireElse: true);

      case TokenKind.kwReturn:
        _advance();
        Expr? retVal;
        if (!_check(TokenKind.semi) &&
            !_check(TokenKind.rBrace) &&
            !_check(TokenKind.comma) &&
            !_atEnd) {
          retVal = _parseExpr();
        }
        return ReturnExpr(SourceSpan.cover(t.span, retVal?.span ?? t.span),
            value: retVal);

      case TokenKind.kwThrow:
        _advance();
        final val = _parseExpr();
        return ThrowExpr(SourceSpan.cover(t.span, val.span), val);

      case TokenKind.identifier:
        _advance();
        final name = t.lexeme;

        // Lambda: ident => expr  (bare, single un-annotated parameter)
        if (_check(TokenKind.fatArrow)) {
          _advance();
          final body = _parseExpr();
          return LambdaExpr(SourceSpan.cover(t.span, body.span),
              params: [LambdaParam(t.span, name)], body: body);
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

  /// Returns true when the current `{` opens a map literal rather than a block.
  /// A map literal is `{}` or `{ key: value, ... }` where the key is a
  /// string or integer literal.
  bool _isMapLiteralStart() {
    // _current is '{'; look one and two positions ahead.
    final peek1 = _pos + 1 < _tokens.length ? _tokens[_pos + 1] : _tokens.last;
    // Empty braces → empty map.
    if (peek1.kind == TokenKind.rBrace) return true;
    // String or int key followed by ':' → map.
    if (peek1.kind == TokenKind.stringLiteral ||
        peek1.kind == TokenKind.intLiteral) {
      final peek2 =
          _pos + 2 < _tokens.length ? _tokens[_pos + 2] : _tokens.last;
      return peek2.kind == TokenKind.colon;
    }
    return false;
  }

  Expr _parseMapLiteral() {
    final start = _advance(); // '{'
    final entries = <(Expr, Expr)>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      final key = _parseExpr();
      _expect(TokenKind.colon, ':');
      final value = _parseExpr();
      entries.add((key, value));
      if (!_match(TokenKind.comma)) break;
    }
    final rBraceTok = _expect(TokenKind.rBrace, '}');
    return MapExpr(SourceSpan.cover(start.span, rBraceTok.span), entries);
  }

  Expr _parseListLiteral() {
    final start = _advance(); // [
    final items = <Expr>[];
    while (!_check(TokenKind.rBracket) && !_atEnd) {
      items.add(_parseExpr());
      if (!_match(TokenKind.comma)) break;
    }
    final rBracketTok = _expect(TokenKind.rBracket, ']');
    return ListExpr(SourceSpan.cover(start.span, rBracketTok.span), items);
  }

  Expr _parseStructLiteral(String typeName, SourceSpan startSpan) {
    _advance(); // {
    final fields = <(String, Expr)>[];
    while (!_check(TokenKind.rBrace) && !_atEnd) {
      final fname = _expect(TokenKind.identifier, 'field name').lexeme;
      _expect(TokenKind.colon, ':');
      final fval = _parseExpr();
      fields.add((fname, fval));
      if (!_match(TokenKind.comma)) break;
    }
    final rBraceTok = _expect(TokenKind.rBrace, '}');
    return StructExpr(SourceSpan.cover(startSpan, rBraceTok.span),
        typeName: typeName, fields: fields);
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
        final blockStartTok = _current;
        final block = _parseExprBlock();
        body =
            BlockExpr(SourceSpan.cover(blockStartTok.span, block.span), block);
      } else {
        body = _parseExpr();
      }
      _match(TokenKind.comma);
      arms.add(MatchArm(SourceSpan.cover(pattern.span, body.span),
          pattern: pattern, body: body));
    }
    final rBraceTok = _expect(TokenKind.rBrace, '}');
    return MatchExpr(SourceSpan.cover(start.span, rBraceTok.span),
        subject: subject, arms: arms);
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
          parts.add(TextPart(parentSpan, buf.toString()));
          buf.clear();
        }
        i += 2; // skip ${
        final interpStart = i;
        var depth = 1;
        while (i < raw.length && depth > 0) {
          final c = raw[i];
          if (c == "'" || c == '"') {
            // Skip a nested string literal (honoring backslash escapes) so its
            // braces and quotes don't affect the interpolation's brace depth.
            i++;
            while (i < raw.length && raw[i] != c) {
              if (raw[i] == '\\') i++; // skip the escaped character
              i++;
            }
            i++; // past the closing quote
          } else {
            if (c == '{') {
              depth++;
            } else if (c == '}') {
              depth--;
            }
            i++;
          }
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
          parts.add(InterpPart(parentSpan, expr));
        } else if (parseResult.program.decls.isEmpty) {
          // Empty interpolation — emit empty text
          parts.add(TextPart(parentSpan, ''));
        } else {
          // Best effort: use what we parsed
          final decl = parseResult.program.decls.first;
          if (decl is FnDecl) {
            parts.add(TextPart(parentSpan, exprSource));
          } else {
            parts.add(TextPart(parentSpan, exprSource));
          }
        }
      } else {
        buf.writeCharCode(raw.codeUnitAt(i));
        i++;
      }
    }
    if (buf.isNotEmpty) parts.add(TextPart(parentSpan, buf.toString()));
    return parts;
  }
}

// Sentinel exception used internally to unwind on error.
class _ParseFail implements Exception {}
