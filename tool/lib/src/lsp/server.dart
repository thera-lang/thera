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

import 'definition.dart';
import 'diagnostics.dart';
import 'hover.dart';
import 'symbols.dart';

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
      return buildSymbols(program, text);
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

      final offset =
          _positionToOffset(text, Position(line: line, character: character));
      return handleHover(analysis.program, offset, text);
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

      final offset =
          _positionToOffset(text, Position(line: line, character: character));
      return handleDefinition(analysis.program, analysis.imports, offset, text);
    });

    connection.onRequest('shutdown', (_) async => null);

    connection.onNotification('exit', (_) async => exit(0));
  }

  // --- diagnostics ---

  void _publishDiagnostics(Connection connection, String uri, String text) {
    publishDiagnostics(connection, uri, text, _importsFor);
  }

  /// The import closure for the document at [uri] (a `file://` URI). The
  /// in-memory [program] is used for the primary file; imported files are read
  /// through the overlay-aware [_OverlayFileSystem], so unsaved edits to an
  /// imported library are honored too. Returns an empty closure for a non-file
  /// or unresolvable URI (the prelude/imports simply won't link).
  LoadedImports _importsFor(String uri, Program program) {
    final String path;
    try {
      final parsed = Uri.parse(uri);
      if (parsed.scheme != 'file') return _noImports;
      path = parsed.toFilePath();
    } catch (_) {
      return _noImports;
    }
    return loadImports(path, program, fs: _OverlayFileSystem(sourceProvider));
  }

  static const LoadedImports _noImports =
      (programs: <Program>[], namespaces: <String, LibraryNamespace>{});

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

  ({Program program, LoadedImports imports, TypeChecker checker})? _analyze(
      String uri, String text) {
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
      final charOffset = position.character < lineText.length
          ? position.character
          : lineText.length;
      offset += charOffset;
    }
    return offset;
  }
}

/// A [FileSystem] for the loader that reads through the LSP's overlays first
/// (unsaved buffers), falling back to disk — so imported libraries reflect
/// in-flight edits, not just their saved contents.
class _OverlayFileSystem implements FileSystem {
  final SourceProvider _source;
  final FileSystem _disk = const DiskFileSystem();
  _OverlayFileSystem(this._source);

  @override
  String? read(String path) =>
      _source.hasOverlay(path) ? _source.read(path) : _disk.read(path);

  @override
  bool fileExists(String path) =>
      _source.hasOverlay(path) || _disk.fileExists(path);

  @override
  bool directoryExists(String path) => _disk.directoryExists(path);
}
