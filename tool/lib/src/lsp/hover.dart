import 'package:lsp_server/lsp_server.dart';

import '../ast.dart';
import '../token.dart';
import 'ast_utils.dart';

Hover? handleHover(Program program, int offset, String text) {
  final ancestors = findAncestors(program, offset, text);
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
}

String _describeFnDecl(FnDecl decl) {
  final paramsStr = decl.params.map((p) => p.describe()).join(', ');
  final retStr =
      decl.returnType != null ? ' -> ${decl.returnType!.describe()}' : '';
  return 'fn ${decl.name}($paramsStr)$retStr';
}

String _describeTypeDecl(TypeDecl decl) {
  final fieldsStr =
      decl.fields.map((f) => '  ${f.$1}: ${f.$2.describe()}').join('\n');
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
    final retStr =
        m.returnType != null ? ' -> ${m.returnType!.describe()}' : '';
    return '  fn ${m.name}($paramsStr)$retStr';
  }).join('\n');
  return 'interface ${decl.name} {\n$methodsStr\n}';
}

String _describeConstDecl(ConstDecl decl) {
  final typeStr = decl.type != null ? ': ${decl.type!.describe()}' : '';
  return 'const ${decl.name}$typeStr = ...';
}

Range _spanToRange(SourceSpan span) {
  return Range(
    start: Position(line: span.line - 1, character: span.column - 1),
    end:
        Position(line: span.line - 1, character: span.column - 1 + span.length),
  );
}
