import 'dart:async';
import 'dart:io';

import 'package:lsp_server/lsp_server.dart';

import '../ast.dart';
import '../lexer.dart';
import '../parser.dart';
import '../source_provider.dart';
import '../token.dart';

class LspServer {
  final SourceProvider sourceProvider = SourceProvider();

  Future<void> run() async {
    final connection = Connection(stdin, stdout);

    connection.onInitialize((params) async {
      return InitializeResult(
        capabilities: ServerCapabilities(
          textDocumentSync: Either2.t1(TextDocumentSyncKind.Full),
          documentSymbolProvider: Either2.t1(true),
        ),
        serverInfo: InitializeResultServerInfo(
          name: 'aero',
          version: '0.1.0',
        ),
      );
    });

    connection.onNotification('initialized', (_) async {});

    connection.onNotification('textDocument/didOpen', (params) async {
      final uri = params['textDocument']['uri'] as String;
      final text = params['textDocument']['text'] as String;
      sourceProvider.addOverlay(_uriToPath(uri), text);
      _publishDiagnostics(connection, uri, text);
    });

    connection.onNotification('textDocument/didChange', (params) async {
      final uri = params['textDocument']['uri'] as String;
      final changes = params['contentChanges'] as List;
      if (changes.isNotEmpty) {
        final text = changes.last['text'] as String;
        sourceProvider.addOverlay(_uriToPath(uri), text);
        _publishDiagnostics(connection, uri, text);
      }
    });

    connection.onNotification('textDocument/didClose', (params) async {
      final path = _uriToPath(params['textDocument']['uri'] as String);
      sourceProvider.removeOverlay(path);
    });

    connection.onRequest('textDocument/documentSymbol', (params) async {
      final uri = params['textDocument']['uri'] as String;
      final text = _sourceForUri(uri);
      if (text == null) return <DocumentSymbol>[];
      final program = _parse(text);
      if (program == null) return <DocumentSymbol>[];
      return _buildSymbols(program, text);
    });

    connection.onRequest('shutdown', (_) async => null);

    connection.onNotification('exit', (_) async => exit(0));

    await connection.listen();
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
    }

    connection.sendDiagnostics(
      PublishDiagnosticsParams(uri: Uri.parse(uri), diagnostics: diagnostics),
    );
  }

  Diagnostic _lexErrorToDiagnostic(LexError err) {
    return Diagnostic(
      range: _spanToRange(err.span),
      severity: DiagnosticSeverity.Error,
      message: err.message,
      source: 'aero',
    );
  }

  Diagnostic _parseErrorToDiagnostic(ParseError err) {
    return Diagnostic(
      range: _spanToRange(err.span),
      severity: DiagnosticSeverity.Error,
      message: err.message,
      source: 'aero',
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
            kind: SymbolKind.Struct,
            range: _declRange(decl, source),
            selectionRange: _spanToRange(decl.nameSpan),
          ));
        case ImplDecl():
          final label = decl.interfaceName != null
              ? '${decl.interfaceName} for ${decl.typeName}'
              : decl.typeName;
          symbols.add(DocumentSymbol(
            name: label,
            kind: SymbolKind.Namespace,
            range: _declRange(decl, source),
            selectionRange: _spanToRange(decl.nameSpan),
            children: decl.methods.map((m) => DocumentSymbol(
              name: m.name,
              kind: SymbolKind.Method,
              range: _declRange(m, source),
              selectionRange: _spanToRange(m.nameSpan),
            )).toList(),
          ));
        case InterfaceDecl():
          symbols.add(DocumentSymbol(
            name: decl.name,
            kind: SymbolKind.Interface,
            range: _declRange(decl, source),
            selectionRange: _spanToRange(decl.nameSpan),
            children: decl.methods.map((m) => DocumentSymbol(
              name: m.name,
              kind: SymbolKind.Method,
              range: _declRange(m, source),
              selectionRange: _spanToRange(m.nameSpan),
            )).toList(),
          ));
        case ImportDecl():
          break;
      }
    }
    return symbols;
  }

  // The full range of a declaration: from the keyword to the end of its body.
  Range _declRange(Decl decl, String source) {
    final endSpan = switch (decl) {
      FnDecl(:final body) when body != null => body.endSpan,
      ImplDecl() => _findClosingBrace(decl.span, source),
      InterfaceDecl() => _findClosingBrace(decl.span, source),
      TypeDecl() => _findClosingBrace(decl.span, source),
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
      if (source[i] == '{') depth++;
      else if (source[i] == '}') {
        depth--;
        if (depth == 0) {
          // Compute line/col for this position.
          int line = start.line;
          int col = start.column;
          for (int j = start.offset; j < i; j++) {
            if (source[j] == '\n') { line++; col = 1; }
            else { col++; }
          }
          return SourceSpan(source: source, offset: i, length: 1, line: line, column: col);
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
    return Position(line: span.line - 1, character: span.column - 1 + span.length);
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
    try { return sourceProvider.read(path); } catch (_) { return null; }
  }

  String _uriToPath(String uri) => Uri.parse(uri).toFilePath();
}
