import 'dart:async';

import 'package:aero/src/lsp/server.dart';
import 'package:lsp_server/lsp_server.dart';
import 'package:test/test.dart';

/// Drives [LspServer] over in-memory pipes with a second [Connection] acting
/// as the client, so the real JSON-RPC + wire format is exercised end to end.
void main() {
  late StreamController<List<int>> clientToServer;
  late StreamController<List<int>> serverToClient;
  late Connection serverConn;
  late Connection clientConn;
  late StreamController<Map<String, dynamic>> diagnostics;

  setUp(() {
    clientToServer = StreamController<List<int>>();
    serverToClient = StreamController<List<int>>();

    serverConn = Connection(clientToServer.stream, serverToClient.sink);
    LspServer().bind(serverConn);

    clientConn = Connection(serverToClient.stream, clientToServer.sink);

    // Capture server -> client diagnostics. Must register before listen().
    diagnostics = StreamController<Map<String, dynamic>>.broadcast();
    clientConn.onNotification('textDocument/publishDiagnostics', (params) async {
      diagnostics.add(Map<String, dynamic>.from(params.value as Map));
    });

    unawaited(serverConn.listen());
    unawaited(clientConn.listen());
  });

  tearDown(() async {
    await clientConn.close();
    await serverConn.close();
    await clientToServer.close();
    await serverToClient.close();
    await diagnostics.close();
  });

  // --- helpers ---

  Future<dynamic> initialize() => clientConn.sendRequest('initialize', {
        'processId': null,
        'rootUri': null,
        'capabilities': <String, dynamic>{},
      });

  void didOpen(String uri, String text) {
    clientConn.sendNotification('textDocument/didOpen', {
      'textDocument': {
        'uri': uri,
        'languageId': 'aero',
        'version': 1,
        'text': text,
      },
    });
  }

  Future<dynamic> documentSymbol(String uri) =>
      clientConn.sendRequest('textDocument/documentSymbol', {
        'textDocument': {'uri': uri},
      });

  /// Open [text] and wait for the diagnostics the server publishes in
  /// response, so subsequent requests see the overlay deterministically.
  Future<Map<String, dynamic>> openAndAwaitDiagnostics(
      String uri, String text) async {
    final next = diagnostics.stream.firstWhere((d) => d['uri'] == uri);
    didOpen(uri, text);
    return next;
  }

  // --- initialize ---

  test('initialize advertises documentSymbol and full text sync', () async {
    final result = await initialize();
    final caps = result['capabilities'] as Map;
    expect(caps['documentSymbolProvider'], isTrue);
    expect(caps['textDocumentSync'], TextDocumentSyncKind.Full.toJson());
    expect((result['serverInfo'] as Map)['name'], 'aero');
  });

  // --- diagnostics ---

  group('diagnostics', () {
    test('clean file produces no diagnostics', () async {
      await initialize();
      final diag = await openAndAwaitDiagnostics(
        'file:///clean.aero',
        'fn main() -> Int {\n  return 0;\n}\n',
      );
      expect(diag['diagnostics'], isEmpty);
    });

    test('parse error is reported with a range', () async {
      await initialize();
      // Missing closing brace / body — a parse error.
      final diag = await openAndAwaitDiagnostics(
        'file:///broken.aero',
        'fn main() -> Int {\n  return\n',
      );
      final items = diag['diagnostics'] as List;
      expect(items, isNotEmpty);
      final first = items.first as Map;
      expect(first['severity'], DiagnosticSeverity.Error.toJson());
      expect(first['source'], 'aero');
      expect(first['range'], isA<Map>());
      expect((first['message'] as String), isNotEmpty);
    });

    test('re-opening with fixed content clears diagnostics', () async {
      await initialize();
      final broken = await openAndAwaitDiagnostics(
        'file:///fix.aero',
        'fn main() -> Int {\n  return\n',
      );
      expect(broken['diagnostics'], isNotEmpty);

      final fixed = await openAndAwaitDiagnostics(
        'file:///fix.aero',
        'fn main() -> Int {\n  return 0;\n}\n',
      );
      expect(fixed['diagnostics'], isEmpty);
    });
  });

  // --- document symbols ---

  group('documentSymbol', () {
    test('top-level functions become Function symbols', () async {
      await initialize();
      const uri = 'file:///fns.aero';
      await openAndAwaitDiagnostics(uri, '''
fn first() -> Int {
  return 1;
}

fn second(x: Int) -> Int {
  return x;
}
''');
      final symbols = (await documentSymbol(uri)) as List;
      expect(symbols.map((s) => s['name']), ['first', 'second']);
      expect(symbols.every((s) => s['kind'] == SymbolKind.Function.toJson()),
          isTrue);
    });

    test('type, impl with method children, and interface', () async {
      await initialize();
      const uri = 'file:///shapes.aero';
      await openAndAwaitDiagnostics(uri, '''
type Point = {
  x: Int,
  y: Int,
}

interface Display {
  fn display(self) -> String;
}

impl Display for Point {
  fn display(self) -> String {
    return 'point';
  }
}
''');
      final symbols = (await documentSymbol(uri)) as List;
      final byName = {for (final s in symbols) s['name']: s as Map};

      expect(byName.keys, containsAll(['Point', 'Display', 'Display for Point']));

      expect(byName['Point']!['kind'], SymbolKind.Struct.toJson());

      final iface = byName['Display']!;
      expect(iface['kind'], SymbolKind.Interface.toJson());
      expect((iface['children'] as List).map((c) => c['name']), ['display']);

      final impl = byName['Display for Point']!;
      expect(impl['kind'], SymbolKind.Namespace.toJson());
      final methods = impl['children'] as List;
      expect(methods.map((c) => c['name']), ['display']);
      expect(methods.first['kind'], SymbolKind.Method.toJson());
    });

    test('selectionRange points at the name, not the keyword', () async {
      await initialize();
      const uri = 'file:///sel.aero';
      // 'fn ' is 3 chars, so 'main' starts at character 3 on line 0.
      await openAndAwaitDiagnostics(uri, 'fn main() -> Int {\n  return 0;\n}\n');
      final symbols = (await documentSymbol(uri)) as List;
      final main = symbols.single as Map;
      final sel = main['selectionRange'] as Map;
      expect((sel['start'] as Map)['line'], 0);
      expect((sel['start'] as Map)['character'], 3);
      expect((sel['end'] as Map)['character'], 3 + 'main'.length);
    });

    test('unknown document yields no symbols', () async {
      await initialize();
      final symbols = (await documentSymbol('file:///missing.aero')) as List;
      expect(symbols, isEmpty);
    });
  });
}
