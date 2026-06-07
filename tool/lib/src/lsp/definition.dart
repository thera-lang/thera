import 'package:lsp_server/lsp_server.dart';

import '../ast.dart';
import '../element/types.dart';
import '../loader.dart';
import '../token.dart';
import 'ast_utils.dart';

Location? handleDefinition(
    Program program, LoadedImports imports, int offset, String text) {
  final ancestors = findAncestors(program, offset, text);
  if (ancestors.isEmpty) return null;

  final node = ancestors.last;
  final defNode = _resolveDefinition(node, ancestors, offset, program, imports);
  if (defNode != null) {
    return _nodeToLocation(defNode, program, imports);
  }

  return null;
}

dynamic _resolveDefinition(dynamic node, List<dynamic> ancestors, int offset,
    Program program, LoadedImports imports) {
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
      final globalDecl =
          _findGlobalDecl(recvType.element.name, program, imports);
      if (globalDecl is TypeDecl) {
        for (final f in globalDecl.fields) {
          if (f.$1 == name) return f.$2;
        }
      } else if (globalDecl is EnumDecl) {
        for (final v in globalDecl.variants) {
          if (v.name == name) return v;
        }
      }
      final methodDecl =
          _findMethodDecl(recvType.element.name, name, program, imports);
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
  return decl is NamedNode && (decl as NamedNode).name == name;
}

dynamic _findMethodDecl(String typeName, String methodName, Program program,
    LoadedImports imports) {
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

Location? _nodeToLocation(
    dynamic node, Program program, LoadedImports imports) {
  if (node == null) return null;
  final span = getSpan(node);
  if (span == null) return null;
  final filePath = _findFilePathForNode(node, program, imports);
  if (filePath == null) return null;
  return Location(
    uri: Uri.file(filePath),
    range: _spanToRange(span),
  );
}

String? _findFilePathForNode(
    dynamic node, Program program, LoadedImports imports) {
  if (node is Param ||
      node is LetStmt ||
      node is Stmt ||
      node is Expr ||
      node is SourceSpan) {
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

Range _spanToRange(SourceSpan span) {
  return Range(
    start: Position(line: span.line - 1, character: span.column - 1),
    end:
        Position(line: span.line - 1, character: span.column - 1 + span.length),
  );
}
