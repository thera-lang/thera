import 'package:lsp_server/lsp_server.dart';

import '../ast.dart';
import '../token.dart';

List<DocumentSymbol> buildSymbols(Program program, String source) {
  final symbols = <DocumentSymbol>[];
  for (final decl in program.decls) {
    switch (decl) {
      case FnDecl():
        symbols.add(DocumentSymbol(
          name: decl.name,
          // TODO: Look into using the function's signature as the detail string.
          detail: decl.isPub ? 'pub' : null,
          kind: SymbolKind.Function,
          range: _declRange(decl, source),
          selectionRange: _spanToRange(decl.nameSpan),
        ));
      case TypeDecl():
        symbols.add(DocumentSymbol(
          name: decl.name,
          detail: decl.isPub ? 'pub' : null,
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
                    // TODO: Look into using the function's signature as the detail string.
                    detail: m.isPub ? 'pub' : null,
                    kind: SymbolKind.Method,
                    range: _declRange(m, source),
                    selectionRange: _spanToRange(m.nameSpan),
                  ))
              .toList(),
        ));
      case InterfaceDecl():
        symbols.add(DocumentSymbol(
          name: decl.name,
          detail: decl.isPub ? 'pub' : null,
          kind: SymbolKind.Interface,
          range: _declRange(decl, source),
          selectionRange: _spanToRange(decl.nameSpan),
          children: decl.methods
              .map((m) => DocumentSymbol(
                    name: m.name,
                    // TODO: Look into using the function's signature as the detail string.
                    detail: m.isPub ? 'pub' : null,
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
          detail: decl.isPub ? 'pub' : null,
          kind: SymbolKind.Constant,
          range: _declRange(decl, source),
          selectionRange: _spanToRange(decl.span),
        ));
      case EnumDecl():
        symbols.add(DocumentSymbol(
          name: decl.name,
          detail: decl.isPub ? 'pub' : null,
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

Range _declRange(Decl decl, String source) {
  return _spanToRange(decl.span);
}

Range _spanToRange(SourceSpan span) {
  return Range(
    start: _spanToPosition(span),
    end: _spanToEndPosition(span),
  );
}

Position _spanToPosition(SourceSpan span) {
  return Position(line: span.line - 1, character: span.column - 1);
}

Position _spanToEndPosition(SourceSpan span) {
  final (line, column) = span.endLineColumn;
  return Position(line: line - 1, character: column - 1);
}
