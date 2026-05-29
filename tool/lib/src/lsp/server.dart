import 'dart:async';
import 'dart:io';

import 'package:lsp_server/lsp_server.dart';

import '../source_provider.dart';

class LspServer {
  final SourceProvider sourceProvider = SourceProvider();

  Future<void> run() async {
    final connection = Connection(stdin, stdout);

    connection.onInitialize((params) async {
      return InitializeResult(
        capabilities: ServerCapabilities(
          textDocumentSync: Either2.t1(TextDocumentSyncKind.Full),
        ),
        serverInfo: InitializeResultServerInfo(
          name: 'aero',
          version: '0.1.0',
        ),
      );
    });

    connection.onNotification('textDocument/didOpen', (params) async {
      final path = _uriToPath(params['textDocument']['uri'] as String);
      final text = params['textDocument']['text'] as String;
      sourceProvider.addOverlay(path, text);
      _publishDiagnostics(connection, params['textDocument']['uri'] as String);
    });

    connection.onNotification('textDocument/didChange', (params) async {
      final path = _uriToPath(params['textDocument']['uri'] as String);
      // With Full sync we always get the full content in the first change event.
      final changes = params['contentChanges'] as List;
      if (changes.isNotEmpty) {
        sourceProvider.addOverlay(path, changes.last['text'] as String);
      }
      _publishDiagnostics(connection, params['textDocument']['uri'] as String);
    });

    connection.onNotification('textDocument/didClose', (params) async {
      final path = _uriToPath(params['textDocument']['uri'] as String);
      sourceProvider.removeOverlay(path);
    });

    connection.onNotification('initialized', (_) async {});

    connection.onRequest('shutdown', (_) async => null);

    connection.onNotification('exit', (_) async => exit(0));

    await connection.listen();
  }

  void _publishDiagnostics(Connection connection, String uri) {
    connection.sendDiagnostics(
      PublishDiagnosticsParams(uri: Uri.parse(uri), diagnostics: []),
    );
  }

  String _uriToPath(String uri) {
    return Uri.parse(uri).toFilePath();
  }
}
