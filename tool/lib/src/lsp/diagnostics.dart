import 'package:lsp_server/lsp_server.dart';

import '../ast.dart';
import '../checker/type_checker.dart';
import '../lexer.dart';
import '../loader.dart';
import '../parser.dart';
import '../token.dart';

void publishDiagnostics(
  Connection connection,
  String uri,
  String text,
  LoadedImports Function(String uri, Program program) importsResolver,
) {
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
      final imports = importsResolver(uri, parseResult.program);
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

Diagnostic _lexErrorToDiagnostic(LexError err) {
  return Diagnostic(
    range: spanToRange(err.span),
    severity: DiagnosticSeverity.Error,
    message: err.message,
    source: 'hawk',
  );
}

Diagnostic _parseErrorToDiagnostic(ParseError err) {
  return Diagnostic(
    range: spanToRange(err.span),
    severity: DiagnosticSeverity.Error,
    message: err.message,
    source: 'hawk',
  );
}

Diagnostic _checkErrorToDiagnostic(CheckError err) {
  return Diagnostic(
    range: spanToRange(err.span),
    severity: DiagnosticSeverity.Error,
    message: err.message,
    source: 'hawk',
  );
}

Range spanToRange(SourceSpan span) {
  final (endLine, endColumn) = span.endLineColumn;
  return Range(
    start: Position(line: span.line - 1, character: span.column - 1),
    end: Position(line: endLine - 1, character: endColumn - 1),
  );
}
