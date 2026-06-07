import '../ast.dart';
import '../token.dart';

// TODO: introduce an interface / other mechanism to reduce all these if
// statements

SourceSpan? getSpan(dynamic node) {
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

int getNodeStartOffset(dynamic node) {
  if (node is Param) return node.nameSpan.offset;
  if (node is TypeRef && node is NamedType && node.span != null)
    return node.span!.offset;
  if (node is Decl) return node.span.offset;
  if (node is Stmt) return node.span.offset;
  if (node is Expr) return node.span.offset;
  if (node is Block) return node.span.offset;
  if (node is SourceSpan) return node.offset;
  return 0;
}

int getNodeEndOffset(dynamic node, String source) {
  if (node == null) return 0;

  if (node is Block) {
    return node.endSpan.offset + node.endSpan.length;
  }
  if (node is ImplDecl) {
    final closing = findClosingBrace(node.span, source);
    return closing.offset + closing.length;
  }
  if (node is InterfaceDecl) {
    final closing = findClosingBrace(node.span, source);
    return closing.offset + closing.length;
  }
  if (node is TypeDecl) {
    final closing = findClosingBrace(node.span, source);
    return closing.offset + closing.length;
  }
  if (node is EnumDecl) {
    final closing = findClosingBrace(node.span, source);
    return closing.offset + closing.length;
  }

  int maxEnd = 0;
  final span = getSpan(node);
  if (span != null) {
    maxEnd = span.offset + span.length;
  }

  forEachChild(node, (child) {
    final childEnd = getNodeEndOffset(child, source);
    if (childEnd > maxEnd) {
      maxEnd = childEnd;
    }
  });

  return maxEnd;
}

void forEachChild(dynamic node, void Function(dynamic) callback) {
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

List<dynamic> findAncestors(dynamic node, int offset, String source) {
  final list = <dynamic>[];
  collectAncestors(node, offset, source, list);
  return list;
}

bool collectAncestors(
    dynamic node, int offset, String source, List<dynamic> list) {
  if (node == null) return false;

  bool contains(SourceSpan span) {
    return spanContains(span, offset);
  }

  if (!nodeContainsOffset(node, offset, source)) return false;

  list.add(node);

  if (node is Program) {
    for (final decl in node.decls) {
      if (collectAncestors(decl, offset, source, list)) return true;
    }
  } else if (node is FnDecl) {
    if (contains(node.nameSpan)) {
      list.add(node.nameSpan);
      return true;
    }
    for (final p in node.params) {
      if (collectAncestors(p, offset, source, list)) return true;
    }
    if (collectAncestors(node.body, offset, source, list)) return true;
  } else if (node is ImplDecl) {
    if (contains(node.nameSpan)) {
      list.add(node.nameSpan);
      return true;
    }
    for (final m in node.methods) {
      if (collectAncestors(m, offset, source, list)) return true;
    }
  } else if (node is InterfaceDecl) {
    if (contains(node.nameSpan)) {
      list.add(node.nameSpan);
      return true;
    }
    for (final m in node.methods) {
      if (collectAncestors(m, offset, source, list)) return true;
    }
  } else if (node is TypeDecl) {
    if (contains(node.nameSpan)) {
      list.add(node.nameSpan);
      return true;
    }
    for (final (_, typeRef) in node.fields) {
      if (collectAncestors(typeRef, offset, source, list)) return true;
    }
  } else if (node is ConstDecl) {
    if (contains(node.nameSpan)) {
      list.add(node.nameSpan);
      return true;
    }
    if (collectAncestors(node.type, offset, source, list)) return true;
    if (collectAncestors(node.value, offset, source, list)) return true;
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
        if (collectAncestors(field, offset, source, list)) return true;
      }
    }
  } else if (node is Param) {
    if (contains(node.nameSpan)) {
      list.add(node.nameSpan);
      return true;
    }
    if (collectAncestors(node.type, offset, source, list)) return true;
    if (collectAncestors(node.defaultValue, offset, source, list)) return true;
  } else if (node is Block) {
    for (final stmt in node.stmts) {
      if (collectAncestors(stmt, offset, source, list)) return true;
    }
  } else if (node is LetStmt) {
    if (contains(node.nameSpan)) {
      list.add(node.nameSpan);
      return true;
    }
    if (collectAncestors(node.type, offset, source, list)) return true;
    if (collectAncestors(node.value, offset, source, list)) return true;
  } else if (node is ReturnStmt) {
    if (collectAncestors(node.value, offset, source, list)) return true;
  } else if (node is ThrowStmt) {
    if (collectAncestors(node.value, offset, source, list)) return true;
  } else if (node is ExprStmt) {
    if (collectAncestors(node.expr, offset, source, list)) return true;
  } else if (node is AssignStmt) {
    if (collectAncestors(node.target, offset, source, list)) return true;
    if (collectAncestors(node.value, offset, source, list)) return true;
  } else if (node is IfStmt) {
    if (collectAncestors(node.condition, offset, source, list)) return true;
    if (collectAncestors(node.then, offset, source, list)) return true;
    if (collectAncestors(node.else_, offset, source, list)) return true;
  } else if (node is ForStmt) {
    if (collectAncestors(node.iterable, offset, source, list)) return true;
    if (collectAncestors(node.body, offset, source, list)) return true;
  } else if (node is WhileStmt) {
    if (collectAncestors(node.condition, offset, source, list)) return true;
    if (collectAncestors(node.body, offset, source, list)) return true;
  } else if (node is CallExpr) {
    if (collectAncestors(node.callee, offset, source, list)) return true;
    for (final arg in node.args) {
      if (collectAncestors(arg.value, offset, source, list)) return true;
    }
  } else if (node is FieldExpr) {
    if (collectAncestors(node.object, offset, source, list)) return true;
  } else if (node is IndexExpr) {
    if (collectAncestors(node.object, offset, source, list)) return true;
    if (collectAncestors(node.index, offset, source, list)) return true;
  } else if (node is BinaryExpr) {
    if (collectAncestors(node.left, offset, source, list)) return true;
    if (collectAncestors(node.right, offset, source, list)) return true;
  } else if (node is UnaryExpr) {
    if (collectAncestors(node.operand, offset, source, list)) return true;
  } else if (node is PropagateExpr) {
    if (collectAncestors(node.inner, offset, source, list)) return true;
  } else if (node is RangeExpr) {
    if (collectAncestors(node.start, offset, source, list)) return true;
    if (collectAncestors(node.end, offset, source, list)) return true;
  } else if (node is ListExpr) {
    for (final item in node.items) {
      if (collectAncestors(item, offset, source, list)) return true;
    }
  } else if (node is MapExpr) {
    for (final (k, v) in node.entries) {
      if (collectAncestors(k, offset, source, list)) return true;
      if (collectAncestors(v, offset, source, list)) return true;
    }
  } else if (node is StructExpr) {
    for (final (_, v) in node.fields) {
      if (collectAncestors(v, offset, source, list)) return true;
    }
  } else if (node is StringExpr) {
    for (final part in node.parts) {
      if (part is InterpPart) {
        if (collectAncestors(part.expr, offset, source, list)) return true;
      }
    }
  } else if (node is MatchExpr) {
    if (collectAncestors(node.subject, offset, source, list)) return true;
    for (final arm in node.arms) {
      if (collectAncestors(arm.body, offset, source, list)) return true;
    }
  } else if (node is LambdaExpr) {
    if (collectAncestors(node.body, offset, source, list)) return true;
  } else if (node is BlockExpr) {
    if (collectAncestors(node.block, offset, source, list)) return true;
  } else if (node is ReturnExpr) {
    if (collectAncestors(node.value, offset, source, list)) return true;
  } else if (node is ThrowExpr) {
    if (collectAncestors(node.value, offset, source, list)) return true;
  } else if (node is NamedType) {
    for (final arg in node.args) {
      if (collectAncestors(arg, offset, source, list)) return true;
    }
  }

  return true;
}

bool nodeContainsOffset(dynamic node, int offset, String source) {
  if (node == null) return false;
  if (node is Program) return true;
  final start = getNodeStartOffset(node);
  final end = getNodeEndOffset(node, source);
  return offset >= start && offset <= end;
}

bool spanContains(SourceSpan span, int offset) {
  return offset >= span.offset && offset <= span.offset + span.length;
}

SourceSpan findClosingBrace(SourceSpan start, String source) {
  int depth = 0;
  for (int i = start.offset; i < source.length; i++) {
    if (source[i] == '{') {
      depth++;
    } else if (source[i] == '}') {
      depth--;
      if (depth == 0) {
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
