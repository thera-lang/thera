import '../ast.dart';
import '../token.dart';

SourceSpan? getSpan(dynamic node) {
  if (node is NamedNode) return node.nameSpan;
  if (node is AstNode) return node.span;
  if (node is SourceSpan) return node;
  return null;
}

SourceSpan? getFullSpan(dynamic node) {
  if (node is AstNode) return node.span;
  if (node is SourceSpan) return node;
  return null;
}

int getNodeStartOffset(dynamic node) {
  final span = getFullSpan(node);
  return span?.offset ?? 0;
}

int getNodeEndOffset(dynamic node, String source) {
  if (node == null) return 0;
  final span = getFullSpan(node);
  if (span != null) {
    return span.offset + span.length;
  }
  return 0;
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

  if (node is NamedNode && contains(node.nameSpan)) {
    list.add(node.nameSpan);
    return true;
  }

  if (node is AstNode) {
    for (final child in node.childNodes) {
      if (collectAncestors(child, offset, source, list)) {
        return true;
      }
    }
  }

  return true;
}

bool nodeContainsOffset(dynamic node, int offset, String source) {
  if (node == null) return false;
  if (node is Program) return true;
  final span = getFullSpan(node);
  if (span == null) return false;
  return offset >= span.offset && offset <= span.offset + span.length;
}

bool spanContains(SourceSpan span, int offset) {
  return offset >= span.offset && offset <= span.offset + span.length;
}
