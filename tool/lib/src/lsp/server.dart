import 'dart:async';
import 'dart:io';

import 'package:lsp_server/lsp_server.dart';

import '../ast.dart';
import '../checker/type_checker.dart';
import '../element/namespace.dart';
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
      return _buildSymbols(program, text);
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
}
