import 'dart:async';
import 'dart:io';

import 'package:lsp_server/lsp_server.dart';

import '../ast.dart';
import '../checker/type_checker.dart';
import '../element/namespace.dart';
import '../element/types.dart';
import '../lexer.dart';
import '../loader.dart';
import '../parser.dart';
import '../source_provider.dart';
import '../token.dart';

class LspServer {
  final SourceProvider sourceProvider = SourceProvider();

  /// Run the server over stdin/stdout (production entry point).
  Future<void> run() async {
    final connection = Connection(stdin, stdout);
    bind(connection);
    await connection.listen();
  }

  /// Register all handlers on [connection]. Separated from [run] so that
  /// tests can drive the server over in-memory streams.
  void bind(Connection connection) {
    connection.onInitialize((params) async {
      return InitializeResult(
        capabilities: ServerCapabilities(
          textDocumentSync: Either2.t1(TextDocumentSyncKind.Full),
          documentSymbolProvider: Either2.t1(true),
          hoverProvider: Either2.t1(true),
          definitionProvider: Either2.t1(true),
        ),
        serverInfo: InitializeResultServerInfo(
          name: 'hawk',
          version: '0.1.0',
        ),
      );
    });

    connection.onNotification('initialized', (_) async {});

    connection.onNotification('textDocument/didOpen', (params) async {
      final doc = params['textDocument'].asMap;
      final uri = doc['uri'] as String;
      final text = doc['text'] as String;
      sourceProvider.addOverlay(_uriToPath(uri), text);
      _publishDiagnostics(connection, uri, text);
    });

    connection.onNotification('textDocument/didChange', (params) async {
      final uri = params['textDocument'].asMap['uri'] as String;
      final changes = params['contentChanges'].asList;
      if (changes.isNotEmpty) {
        final text = (changes.last as Map)['text'] as String;
        sourceProvider.addOverlay(_uriToPath(uri), text);
        _publishDiagnostics(connection, uri, text);
      }
    });

    connection.onNotification('textDocument/didClose', (params) async {
      final path = _uriToPath(params['textDocument'].asMap['uri'] as String);
      sourceProvider.removeOverlay(path);
    });

    connection.onRequest('textDocument/documentSymbol', (params) async {
      final uri = params['textDocument'].asMap['uri'] as String;
      final text = _sourceForUri(uri);
      if (text == null) return <DocumentSymbol>[];
      final program = _parse(text);
      if (program == null) return <DocumentSymbol>[];
      program.filePath = _uriToPath(uri);
      return _buildSymbols(program, text);
    });

    connection.onRequest('textDocument/hover', (params) async {
      final uri = params['textDocument'].asMap['uri'] as String;
      final pos = params['position'].asMap;
      final line = pos['line'] as int;
      final character = pos['character'] as int;

      final text = _sourceForUri(uri);
      if (text == null) return null;

      final analysis = _analyze(uri, text);
      if (analysis == null) return null;

      final offset = _positionToOffset(text, Position(line: line, character: character));
      final program = analysis.program;
      final ancestors = _findAncestors(program, offset, text);
      if (ancestors.isEmpty) return null;
      var node = ancestors.last;
      if (node is SourceSpan && ancestors.length > 1) {
        node = ancestors[ancestors.length - 2];
      }

      if (node is Expr && node.resolvedType != null) {
        final typeStr = node.resolvedType.toString();
        final markdown = '```hawk\n$typeStr\n```';
        return Hover(
          contents: Either2.t1(MarkupContent(
            kind: MarkupKind.Markdown,
            value: markdown,
          )),
          range: _spanToRange(node.span),
        );
      }

      if (node is Decl) {
        final String description;
        if (node is FnDecl) {
          description = _describeFnDecl(node);
        } else if (node is TypeDecl) {
          description = _describeTypeDecl(node);
        } else if (node is EnumDecl) {
          description = _describeEnumDecl(node);
        } else if (node is InterfaceDecl) {
          description = _describeInterfaceDecl(node);
        } else if (node is ConstDecl) {
          description = _describeConstDecl(node);
        } else {
          description = '';
        }
        if (description.isNotEmpty) {
          final markdown = '```hawk\n$description\n```';
          return Hover(
            contents: Either2.t1(MarkupContent(
              kind: MarkupKind.Markdown,
              value: markdown,
            )),
            range: _spanToRange(node.span),
          );
        }
      }

      if (node is Param) {
        final typeStr = node.type != null ? node.type!.describe() : 'Unknown';
        final markdown = '```hawk\n${node.name}: $typeStr\n```';
        return Hover(
          contents: Either2.t1(MarkupContent(
            kind: MarkupKind.Markdown,
            value: markdown,
          )),
          range: _spanToRange(node.nameSpan),
        );
      }

      if (node is LetStmt) {
        final typeStr = node.type != null ? node.type!.describe() : 'Unknown';
        final mutStr = node.isMut ? 'mut ' : '';
        final markdown = '```hawk\nlet $mutStr${node.name}: $typeStr\n```';
        return Hover(
          contents: Either2.t1(MarkupContent(
            kind: MarkupKind.Markdown,
            value: markdown,
          )),
          range: _spanToRange(node.nameSpan),
        );
      }

      return null;
    });

    connection.onRequest('textDocument/definition', (params) async {
      final uri = params['textDocument'].asMap['uri'] as String;
      final pos = params['position'].asMap;
      final line = pos['line'] as int;
      final character = pos['character'] as int;

      final text = _sourceForUri(uri);
      if (text == null) return null;

      final analysis = _analyze(uri, text);
      if (analysis == null) return null;

      final offset = _positionToOffset(text, Position(line: line, character: character));
      final ancestors = _findAncestors(analysis.program, offset, text);
      if (ancestors.isEmpty) return null;

      final node = ancestors.last;
      final defNode = _resolveDefinition(node, ancestors, offset, analysis.program, analysis.imports);
      if (defNode != null) {
        return _nodeToLocation(defNode, analysis.program, analysis.imports);
      }

      return null;
    });

    connection.onRequest('shutdown', (_) async => null);

    connection.onNotification('exit', (_) async => exit(0));
  }

  // --- diagnostics ---

  void _publishDiagnostics(Connection connection, String uri, String text) {
    final diagnostics = <Diagnostic>[];

    final lexResult = Lexer(text).tokenize();
    for (final err in lexResult.errors) {
      diagnostics.add(_lexErrorToDiagnostic(err));
    }

    if (!lexResult.hasErrors) {
      final parseResult = Parser(lexResult.tokens).parse();
      for (final err in parseResult.errors) {
        diagnostics.add(_parseErrorToDiagnostic(err));
      }

      if (!parseResult.hasErrors) {
        // Link the import closure (including the auto-imported `std.core`
        // prelude) the same way the CLI does, so cross-file symbols and the
        // prelude methods on built-in types (e.g. List.map/filter/fold) resolve
        // and lambda arguments to them are typed from context. Without this the
        // checker would, for example, flag `nums.map(n => …)` as un-inferrable.
        final imports = _importsFor(uri, parseResult.program);
        final checker = TypeChecker();
        for (final imported in imports.programs) {
          checker.addProgram(imported);
        }
        final checkResult =
            checker.check(parseResult.program, namespaces: imports.namespaces);
        for (final err in checkResult.errors) {
          diagnostics.add(_checkErrorToDiagnostic(err));
        }
      }
    }

    connection.sendDiagnostics(
      PublishDiagnosticsParams(uri: Uri.parse(uri), diagnostics: diagnostics),
    );
  }

  /// The import closure for the document at [uri] (a `file://` URI). Imports are
  /// resolved from disk relative to the file's path; the in-memory [program] is
  /// used for the primary file. Returns an empty closure for a non-file or
  /// unresolvable URI (the prelude/imports simply won't link).
  LoadedImports _importsFor(String uri, Program program) {
    final String path;
    try {
      final parsed = Uri.parse(uri);
      if (parsed.scheme != 'file') return _noImports;
      path = parsed.toFilePath();
    } catch (_) {
      return _noImports;
    }
    return loadImports(path, program);
  }

  static const LoadedImports _noImports =
      (programs: <Program>[], namespaces: <String, LibraryNamespace>{});

  Diagnostic _lexErrorToDiagnostic(LexError err) {
    return Diagnostic(
      range: _spanToRange(err.span),
      severity: DiagnosticSeverity.Error,
      message: err.message,
      source: 'hawk',
    );
  }

  Diagnostic _parseErrorToDiagnostic(ParseError err) {
    return Diagnostic(
      range: _spanToRange(err.span),
      severity: DiagnosticSeverity.Error,
      message: err.message,
      source: 'hawk',
    );
  }

  Diagnostic _checkErrorToDiagnostic(CheckError err) {
    return Diagnostic(
      range: _spanToRange(err.span),
      severity: DiagnosticSeverity.Error,
      message: err.message,
      source: 'hawk',
    );
  }

  // --- document symbols ---

  List<DocumentSymbol> _buildSymbols(Program program, String source) {
    final symbols = <DocumentSymbol>[];
    for (final decl in program.decls) {
      switch (decl) {
        case FnDecl():
          symbols.add(DocumentSymbol(
            name: decl.name,
            kind: SymbolKind.Function,
            range: _declRange(decl, source),
            selectionRange: _spanToRange(decl.nameSpan),
          ));
        case TypeDecl():
          symbols.add(DocumentSymbol(
            name: decl.name,
            kind: SymbolKind.Class,
            range: _declRange(decl, source),
            selectionRange: _spanToRange(decl.nameSpan),
          ));
        case ImplDecl():
          final label = decl.interfaceName != null
              ? '${decl.interfaceName} for ${decl.typeName}'
              : decl.typeName;
          symbols.add(DocumentSymbol(
            name: label,
            kind: SymbolKind.Interface,
            range: _declRange(decl, source),
            selectionRange: _spanToRange(decl.nameSpan),
            children: decl.methods
                .map((m) => DocumentSymbol(
                      name: m.name,
                      kind: SymbolKind.Method,
                      range: _declRange(m, source),
                      selectionRange: _spanToRange(m.nameSpan),
                    ))
                .toList(),
          ));
        case InterfaceDecl():
          symbols.add(DocumentSymbol(
            name: decl.name,
            kind: SymbolKind.Interface,
            range: _declRange(decl, source),
            selectionRange: _spanToRange(decl.nameSpan),
            children: decl.methods
                .map((m) => DocumentSymbol(
                      name: m.name,
                      kind: SymbolKind.Method,
                      range: _declRange(m, source),
                      selectionRange: _spanToRange(m.nameSpan),
                    ))
                .toList(),
          ));
        case ImportDecl():
          break;
        case ConstDecl():
          symbols.add(DocumentSymbol(
            name: decl.name,
            kind: SymbolKind.Constant,
            range: _declRange(decl, source),
            selectionRange: _spanToRange(decl.span),
          ));
        case EnumDecl():
          symbols.add(DocumentSymbol(
            name: decl.name,
            kind: SymbolKind.Enum,
            range: _declRange(decl, source),
            selectionRange: _spanToRange(decl.nameSpan),
            children: [
              for (final v in decl.variants)
                DocumentSymbol(
                  name: v.name,
                  kind: SymbolKind.EnumMember,
                  range: _spanToRange(v.span),
                  selectionRange: _spanToRange(v.span),
                ),
            ],
          ));
      }
    }
    return symbols;
  }

  // The full range of a declaration: from the keyword to the end of its body.
  Range _declRange(Decl decl, String source) {
    final endSpan = switch (decl) {
      FnDecl(:final body) when body != null => body.endSpan,
      // Body-less fn (interface stub / native fn): range ends at the name so
      // that selectionRange (also the name) is always contained within range.
      FnDecl(:final nameSpan) => nameSpan,
      ImplDecl() => _findClosingBrace(decl.span, source),
      InterfaceDecl() => _findClosingBrace(decl.span, source),
      TypeDecl() => _findClosingBrace(decl.span, source),
      EnumDecl() => _findClosingBrace(decl.span, source),
      _ => decl.span,
    };
    return Range(
      start: _spanToPosition(decl.span),
      end: _spanToEndPosition(endSpan),
    );
  }

  // For declarations whose closing brace we don't store directly, find the
  // last } in the source after the declaration start. This is a fallback —
  // for FnDecl with a body we use the body.endSpan directly.
  SourceSpan _findClosingBrace(SourceSpan start, String source) {
    // Walk forward from start.offset to find the matching closing brace.
    int depth = 0;
    for (int i = start.offset; i < source.length; i++) {
      if (source[i] == '{')
        depth++;
      else if (source[i] == '}') {
        depth--;
        if (depth == 0) {
          // Compute line/col for this position.
          int line = start.line;
          int col = start.column;
          for (int j = start.offset; j < i; j++) {
            if (source[j] == '\n') {
              line++;
              col = 1;
            } else {
              col++;
            }
          }
          return SourceSpan(
              source: source, offset: i, length: 1, line: line, column: col);
        }
      }
    }
    return start;
  }

  // --- span / range helpers ---

  Range _spanToRange(SourceSpan span) {
    return Range(
      start: _spanToPosition(span),
      end: _spanToEndPosition(span),
    );
  }

  Position _spanToPosition(SourceSpan span) {
    // Lexer uses 1-based lines and columns; LSP uses 0-based.
    return Position(line: span.line - 1, character: span.column - 1);
  }

  Position _spanToEndPosition(SourceSpan span) {
    return Position(
        line: span.line - 1, character: span.column - 1 + span.length);
  }

  // --- utilities ---

  Program? _parse(String text) {
    final lexResult = Lexer(text).tokenize();
    if (lexResult.hasErrors) return null;
    final parseResult = Parser(lexResult.tokens).parse();
    if (parseResult.hasErrors) return null;
    return parseResult.program;
  }

  String? _sourceForUri(String uri) {
    final path = _uriToPath(uri);
    if (sourceProvider.hasOverlay(path)) return sourceProvider.read(path);
    try {
      return sourceProvider.read(path);
    } catch (_) {
      return null;
    }
  }

  String _uriToPath(String uri) => Uri.parse(uri).toFilePath();

  ({Program program, LoadedImports imports, TypeChecker checker})? _analyze(String uri, String text) {
    final program = _parse(text);
    if (program == null) return null;
    program.filePath = _uriToPath(uri);

    final imports = _importsFor(uri, program);
    final checker = TypeChecker();
    for (final imported in imports.programs) {
      checker.addProgram(imported);
    }
    checker.check(program, namespaces: imports.namespaces);
    return (program: program, imports: imports, checker: checker);
  }

  int _positionToOffset(String source, Position position) {
    final lines = source.split('\n');
    int offset = 0;
    for (int i = 0; i < position.line && i < lines.length; i++) {
      offset += lines[i].length + 1; // +1 for the '\n'
    }
    if (position.line < lines.length) {
      final lineText = lines[position.line];
      final charOffset = position.character < lineText.length ? position.character : lineText.length;
      offset += charOffset;
    }
    return offset;
  }

  bool _spanContains(SourceSpan span, int offset) {
    return offset >= span.offset && offset <= span.offset + span.length;
  }

  List<dynamic> _findAncestors(dynamic node, int offset, String source) {
    final list = <dynamic>[];
    _collectAncestors(node, offset, source, list);
    return list;
  }

  bool _nodeContainsOffset(dynamic node, int offset, String source) {
    if (node == null) return false;
    if (node is Program) return true;
    final start = _getNodeStartOffset(node);
    final end = _getNodeEndOffset(node, source);
    return offset >= start && offset <= end;
  }

  int _getNodeStartOffset(dynamic node) {
    if (node is Param) return node.nameSpan.offset;
    if (node is TypeRef && node is NamedType && node.span != null) return node.span!.offset;
    if (node is Decl) return node.span.offset;
    if (node is Stmt) return node.span.offset;
    if (node is Expr) return node.span.offset;
    if (node is Block) return node.span.offset;
    if (node is SourceSpan) return node.offset;
    return 0;
  }

  int _getNodeEndOffset(dynamic node, String source) {
    if (node == null) return 0;

    if (node is Block) {
      return node.endSpan.offset + node.endSpan.length;
    }
    if (node is ImplDecl) {
      final closing = _findClosingBrace(node.span, source);
      return closing.offset + closing.length;
    }
    if (node is InterfaceDecl) {
      final closing = _findClosingBrace(node.span, source);
      return closing.offset + closing.length;
    }
    if (node is TypeDecl) {
      final closing = _findClosingBrace(node.span, source);
      return closing.offset + closing.length;
    }
    if (node is EnumDecl) {
      final closing = _findClosingBrace(node.span, source);
      return closing.offset + closing.length;
    }

    int maxEnd = 0;
    final span = _getSpan(node);
    if (span != null) {
      maxEnd = span.offset + span.length;
    }

    _forEachChild(node, (child) {
      final childEnd = _getNodeEndOffset(child, source);
      if (childEnd > maxEnd) {
        maxEnd = childEnd;
      }
    });

    return maxEnd;
  }

  void _forEachChild(dynamic node, void Function(dynamic) callback) {
    if (node == null) return;
    if (node is Program) {
      for (final d in node.decls) callback(d);
    } else if (node is FnDecl) {
      for (final d in node.decorators) callback(d);
      callback(node.nameSpan);
      for (final p in node.params) callback(p);
      if (node.returnType != null) callback(node.returnType);
      if (node.body != null) callback(node.body);
    } else if (node is TypeDecl) {
      callback(node.nameSpan);
      for (final f in node.fields) callback(f.$2);
    } else if (node is ImplDecl) {
      callback(node.nameSpan);
      for (final m in node.methods) callback(m);
    } else if (node is InterfaceDecl) {
      callback(node.nameSpan);
      for (final m in node.methods) callback(m);
    } else if (node is ConstDecl) {
      callback(node.nameSpan);
      if (node.type != null) callback(node.type);
      callback(node.value);
    } else if (node is EnumDecl) {
      callback(node.nameSpan);
      for (final v in node.variants) callback(v);
    } else if (node is EnumVariant) {
      for (final f in node.fields) callback(f);
    } else if (node is Decorator) {
      for (final arg in node.args) callback(arg);
    } else if (node is Param) {
      callback(node.nameSpan);
      if (node.type != null) callback(node.type);
      if (node.defaultValue != null) callback(node.defaultValue);
    } else if (node is NamedType) {
      for (final arg in node.args) callback(arg);
    } else if (node is FunctionTypeRef) {
      for (final p in node.params) callback(p);
      callback(node.returnType);
    } else if (node is LetStmt) {
      callback(node.nameSpan);
      if (node.type != null) callback(node.type);
      callback(node.value);
    } else if (node is ReturnStmt) {
      if (node.value != null) callback(node.value);
    } else if (node is ThrowStmt) {
      callback(node.value);
    } else if (node is ExprStmt) {
      callback(node.expr);
    } else if (node is AssignStmt) {
      callback(node.target);
      callback(node.value);
    } else if (node is IfStmt) {
      callback(node.condition);
      callback(node.then);
      if (node.else_ != null) callback(node.else_);
    } else if (node is ForStmt) {
      callback(node.iterable);
      callback(node.body);
    } else if (node is WhileStmt) {
      callback(node.condition);
      callback(node.body);
    } else if (node is Block) {
      for (final s in node.stmts) callback(s);
    } else if (node is ConstructorPattern) {
      for (final arg in node.args) callback(arg);
    } else if (node is LiteralPattern) {
      callback(node.literal);
    } else if (node is StringExpr) {
      for (final p in node.parts) {
        if (p is InterpPart) callback(p.expr);
      }
    } else if (node is ListExpr) {
      for (final item in node.items) callback(item);
    } else if (node is MapExpr) {
      for (final entry in node.entries) {
        callback(entry.$1);
        callback(entry.$2);
      }
    } else if (node is StructExpr) {
      for (final field in node.fields) {
        callback(field.$2);
      }
    } else if (node is CallExpr) {
      callback(node.callee);
      for (final arg in node.args) callback(arg.value);
    } else if (node is FieldExpr) {
      callback(node.object);
    } else if (node is IndexExpr) {
      callback(node.object);
      callback(node.index);
    } else if (node is BinaryExpr) {
      callback(node.left);
      callback(node.right);
    } else if (node is UnaryExpr) {
      callback(node.operand);
    } else if (node is PropagateExpr) {
      callback(node.inner);
    } else if (node is RangeExpr) {
      callback(node.start);
      callback(node.end);
    } else if (node is MatchExpr) {
      callback(node.subject);
      for (final arm in node.arms) {
        callback(arm);
      }
    } else if (node is MatchArm) {
      callback(node.pattern);
      callback(node.body);
    } else if (node is LambdaExpr) {
      for (final p in node.params) {
        if (p.type != null) callback(p.type);
      }
      callback(node.body);
    } else if (node is BlockExpr) {
      callback(node.block);
    } else if (node is ReturnExpr) {
      if (node.value != null) callback(node.value);
    } else if (node is ThrowExpr) {
      callback(node.value);
    }
  }

  bool _collectAncestors(dynamic node, int offset, String source, List<dynamic> list) {
    if (node == null) return false;

    bool contains(SourceSpan span) {
      return _spanContains(span, offset);
    }

    if (!_nodeContainsOffset(node, offset, source)) return false;

    list.add(node);

    if (node is Program) {
      for (final decl in node.decls) {
        if (_collectAncestors(decl, offset, source, list)) return true;
      }
    } else if (node is FnDecl) {
      if (contains(node.nameSpan)) {
        list.add(node.nameSpan);
        return true;
      }
      for (final p in node.params) {
        if (_collectAncestors(p, offset, source, list)) return true;
      }
      if (_collectAncestors(node.body, offset, source, list)) return true;
    } else if (node is ImplDecl) {
      if (contains(node.nameSpan)) {
        list.add(node.nameSpan);
        return true;
      }
      for (final m in node.methods) {
        if (_collectAncestors(m, offset, source, list)) return true;
      }
    } else if (node is InterfaceDecl) {
      if (contains(node.nameSpan)) {
        list.add(node.nameSpan);
        return true;
      }
      for (final m in node.methods) {
        if (_collectAncestors(m, offset, source, list)) return true;
      }
    } else if (node is TypeDecl) {
      if (contains(node.nameSpan)) {
        list.add(node.nameSpan);
        return true;
      }
      for (final (_, typeRef) in node.fields) {
        if (_collectAncestors(typeRef, offset, source, list)) return true;
      }
    } else if (node is ConstDecl) {
      if (contains(node.nameSpan)) {
        list.add(node.nameSpan);
        return true;
      }
      if (_collectAncestors(node.type, offset, source, list)) return true;
      if (_collectAncestors(node.value, offset, source, list)) return true;
    } else if (node is EnumDecl) {
      if (contains(node.nameSpan)) {
        list.add(node.nameSpan);
        return true;
      }
      for (final v in node.variants) {
        if (contains(v.span)) {
          list.add(v);
          return true;
        }
        for (final field in v.fields) {
          if (_collectAncestors(field, offset, source, list)) return true;
        }
      }
    } else if (node is Param) {
      if (contains(node.nameSpan)) {
        list.add(node.nameSpan);
        return true;
      }
      if (_collectAncestors(node.type, offset, source, list)) return true;
      if (_collectAncestors(node.defaultValue, offset, source, list)) return true;
    } else if (node is Block) {
      for (final stmt in node.stmts) {
        if (_collectAncestors(stmt, offset, source, list)) return true;
      }
    } else if (node is LetStmt) {
      if (contains(node.nameSpan)) {
        list.add(node.nameSpan);
        return true;
      }
      if (_collectAncestors(node.type, offset, source, list)) return true;
      if (_collectAncestors(node.value, offset, source, list)) return true;
    } else if (node is ReturnStmt) {
      if (_collectAncestors(node.value, offset, source, list)) return true;
    } else if (node is ThrowStmt) {
      if (_collectAncestors(node.value, offset, source, list)) return true;
    } else if (node is ExprStmt) {
      if (_collectAncestors(node.expr, offset, source, list)) return true;
    } else if (node is AssignStmt) {
      if (_collectAncestors(node.target, offset, source, list)) return true;
      if (_collectAncestors(node.value, offset, source, list)) return true;
    } else if (node is IfStmt) {
      if (_collectAncestors(node.condition, offset, source, list)) return true;
      if (_collectAncestors(node.then, offset, source, list)) return true;
      if (_collectAncestors(node.else_, offset, source, list)) return true;
    } else if (node is ForStmt) {
      if (_collectAncestors(node.iterable, offset, source, list)) return true;
      if (_collectAncestors(node.body, offset, source, list)) return true;
    } else if (node is WhileStmt) {
      if (_collectAncestors(node.condition, offset, source, list)) return true;
      if (_collectAncestors(node.body, offset, source, list)) return true;
    } else if (node is CallExpr) {
      if (_collectAncestors(node.callee, offset, source, list)) return true;
      for (final arg in node.args) {
        if (_collectAncestors(arg.value, offset, source, list)) return true;
      }
    } else if (node is FieldExpr) {
      if (_collectAncestors(node.object, offset, source, list)) return true;
    } else if (node is IndexExpr) {
      if (_collectAncestors(node.object, offset, source, list)) return true;
      if (_collectAncestors(node.index, offset, source, list)) return true;
    } else if (node is BinaryExpr) {
      if (_collectAncestors(node.left, offset, source, list)) return true;
      if (_collectAncestors(node.right, offset, source, list)) return true;
    } else if (node is UnaryExpr) {
      if (_collectAncestors(node.operand, offset, source, list)) return true;
    } else if (node is PropagateExpr) {
      if (_collectAncestors(node.inner, offset, source, list)) return true;
    } else if (node is RangeExpr) {
      if (_collectAncestors(node.start, offset, source, list)) return true;
      if (_collectAncestors(node.end, offset, source, list)) return true;
    } else if (node is ListExpr) {
      for (final item in node.items) {
        if (_collectAncestors(item, offset, source, list)) return true;
      }
    } else if (node is MapExpr) {
      for (final (k, v) in node.entries) {
        if (_collectAncestors(k, offset, source, list)) return true;
        if (_collectAncestors(v, offset, source, list)) return true;
      }
    } else if (node is StructExpr) {
      for (final (_, v) in node.fields) {
        if (_collectAncestors(v, offset, source, list)) return true;
      }
    } else if (node is StringExpr) {
      for (final part in node.parts) {
        if (part is InterpPart) {
          if (_collectAncestors(part.expr, offset, source, list)) return true;
        }
      }
    } else if (node is MatchExpr) {
      if (_collectAncestors(node.subject, offset, source, list)) return true;
      for (final arm in node.arms) {
        if (_collectAncestors(arm.body, offset, source, list)) return true;
      }
    } else if (node is LambdaExpr) {
      if (_collectAncestors(node.body, offset, source, list)) return true;
    } else if (node is BlockExpr) {
      if (_collectAncestors(node.block, offset, source, list)) return true;
    } else if (node is ReturnExpr) {
      if (_collectAncestors(node.value, offset, source, list)) return true;
    } else if (node is ThrowExpr) {
      if (_collectAncestors(node.value, offset, source, list)) return true;
    } else if (node is NamedType) {
      for (final arg in node.args) {
        if (_collectAncestors(arg, offset, source, list)) return true;
      }
    }

    return true;
  }

  String _describeFnDecl(FnDecl decl) {
    final paramsStr = decl.params.map((p) => p.describe()).join(', ');
    final retStr = decl.returnType != null ? ' -> ${decl.returnType!.describe()}' : '';
    return 'fn ${decl.name}($paramsStr)$retStr';
  }

  String _describeTypeDecl(TypeDecl decl) {
    final fieldsStr = decl.fields.map((f) => '  ${f.$1}: ${f.$2.describe()}').join('\n');
    return 'type ${decl.name} = {\n$fieldsStr\n}';
  }

  String _describeEnumDecl(EnumDecl decl) {
    final variantsStr = decl.variants.map((v) {
      if (v.fields.isEmpty) return '  ${v.name}';
      return '  ${v.name}(${v.fields.map((f) => f.describe()).join(', ')})';
    }).join('\n');
    return 'enum ${decl.name} {\n$variantsStr\n}';
  }

  String _describeInterfaceDecl(InterfaceDecl decl) {
    final methodsStr = decl.methods.map((m) {
      final paramsStr = m.params.map((p) => p.describe()).join(', ');
      final retStr = m.returnType != null ? ' -> ${m.returnType!.describe()}' : '';
      return '  fn ${m.name}($paramsStr)$retStr';
    }).join('\n');
    return 'interface ${decl.name} {\n$methodsStr\n}';
  }

  String _describeConstDecl(ConstDecl decl) {
    final typeStr = decl.type != null ? ': ${decl.type!.describe()}' : '';
    return 'const ${decl.name}$typeStr = ...';
  }

  dynamic _resolveDefinition(
      dynamic node, List<dynamic> ancestors, int offset, Program program, LoadedImports imports) {
    if (node == null) return null;

    if (node is SourceSpan && ancestors.length > 1) {
      node = ancestors[ancestors.length - 2];
    }

    if (node is IdentExpr) {
      final name = node.name;
      final localDecl = _findLocalDecl(name, ancestors, offset);
      if (localDecl != null) return localDecl;
      final globalDecl = _findGlobalDecl(name, program, imports);
      if (globalDecl != null) return globalDecl;
    }

    if (node is NamedType) {
      final name = node.name;
      final globalDecl = _findGlobalDecl(name, program, imports);
      if (globalDecl != null) return globalDecl;
    }

    if (node is FieldExpr) {
      final name = node.field;
      final recvType = node.object.resolvedType;
      if (recvType is InterfaceType) {
        final globalDecl = _findGlobalDecl(recvType.element.name, program, imports);
        if (globalDecl is TypeDecl) {
          for (final f in globalDecl.fields) {
            if (f.$1 == name) return f.$2;
          }
        } else if (globalDecl is EnumDecl) {
          for (final v in globalDecl.variants) {
            if (v.name == name) return v;
          }
        }
        final methodDecl = _findMethodDecl(recvType.element.name, name, program, imports);
        if (methodDecl != null) return methodDecl;
      }
    }

    return null;
  }

  dynamic _findLocalDecl(String name, List<dynamic> ancestors, int offset) {
    for (int i = ancestors.length - 1; i >= 0; i--) {
      final node = ancestors[i];
      if (node is FnDecl) {
        for (final p in node.params) {
          if (p.name == name) return p;
        }
      }
      if (node is Block) {
        for (final stmt in node.stmts) {
          if (stmt is LetStmt && stmt.name == name) {
            final stmtEnd = stmt.span.offset + stmt.span.length;
            if (stmtEnd <= offset) return stmt;
          }
        }
      }
    }
    return null;
  }

  dynamic _findGlobalDecl(String name, Program program, LoadedImports imports) {
    for (final decl in program.decls) {
      if (_isMatchingDecl(decl, name)) return decl;
    }
    for (final prog in imports.programs) {
      for (final decl in prog.decls) {
        if (_isMatchingDecl(decl, name)) return decl;
      }
    }
    return null;
  }

  bool _isMatchingDecl(Decl decl, String name) {
    if (decl is FnDecl && decl.name == name) return true;
    if (decl is TypeDecl && decl.name == name) return true;
    if (decl is EnumDecl && decl.name == name) return true;
    if (decl is InterfaceDecl && decl.name == name) return true;
    if (decl is ConstDecl && decl.name == name) return true;
    return false;
  }

  dynamic _findMethodDecl(String typeName, String methodName, Program program, LoadedImports imports) {
    final allProgs = [program, ...imports.programs];
    for (final prog in allProgs) {
      for (final decl in prog.decls) {
        if (decl is ImplDecl && decl.typeName == typeName) {
          for (final m in decl.methods) {
            if (m.name == methodName) return m;
          }
        }
      }
    }
    return null;
  }

  Location? _nodeToLocation(dynamic node, Program program, LoadedImports imports) {
    if (node == null) return null;
    final span = _getSpan(node);
    if (span == null) return null;
    final filePath = _findFilePathForNode(node, program, imports);
    if (filePath == null) return null;
    return Location(
      uri: Uri.file(filePath),
      range: _spanToRange(span),
    );
  }

  SourceSpan? _getSpan(dynamic node) {
    if (node is FnDecl) return node.nameSpan;
    if (node is TypeDecl) return node.nameSpan;
    if (node is ImplDecl) return node.nameSpan;
    if (node is InterfaceDecl) return node.nameSpan;
    if (node is ConstDecl) return node.nameSpan;
    if (node is EnumDecl) return node.nameSpan;
    if (node is LetStmt) return node.nameSpan;
    if (node is Param) return node.nameSpan;
    if (node is Decl) return node.span;
    if (node is Stmt) return node.span;
    if (node is Expr) return node.span;
    if (node is TypeRef) {
      if (node is NamedType) return node.span;
    }
    if (node is EnumVariant) return node.span;
    if (node is SourceSpan) return node;
    return null;
  }

  String? _findFilePathForNode(dynamic node, Program program, LoadedImports imports) {
    if (node is Param || node is LetStmt || node is Stmt || node is Expr || node is SourceSpan) {
      return program.filePath;
    }
    final allProgs = [program, ...imports.programs];
    for (final prog in allProgs) {
      for (final decl in prog.decls) {
        if (decl == node) return prog.filePath;
        if (decl is EnumDecl) {
          for (final v in decl.variants) {
            if (v == node) return prog.filePath;
          }
        }
        if (decl is ImplDecl) {
          for (final m in decl.methods) {
            if (m == node) return prog.filePath;
          }
        }
        if (decl is InterfaceDecl) {
          for (final m in decl.methods) {
            if (m == node) return prog.filePath;
          }
        }
      }
    }
    return null;
  }
}
