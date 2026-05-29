import 'token.dart';

// --- Top-level ---

class Program {
  final List<Decl> decls;
  Program(this.decls);

  String describe([String indent = '']) {
    final buf = StringBuffer('Program\n');
    for (final d in decls) {
      buf.write(d.describe('$indent  '));
    }
    return buf.toString();
  }
}

// --- Declarations ---

sealed class Decl {
  final SourceSpan span;
  Decl(this.span);

  String describe([String indent = '']);
}

class ImportDecl extends Decl {
  final String path; // e.g. 'std.fs' or 'wordcount'
  final String? alias;
  ImportDecl(super.span, {required this.path, this.alias});

  @override
  String describe([String indent = '']) =>
      '${indent}Import($path${alias != null ? ' as $alias' : ''})\n';
}

class FnDecl extends Decl {
  final List<Decorator> decorators;
  final bool isNative;
  final String name;
  final SourceSpan nameSpan;
  final List<TypeParam> typeParams;
  final List<Param> params;
  final TypeRef? returnType;
  final Block? body; // null for native fn
  FnDecl(
    super.span, {
    required this.decorators,
    required this.isNative,
    required this.name,
    required this.nameSpan,
    this.typeParams = const [],
    required this.params,
    this.returnType,
    this.body,
  });

  @override
  String describe([String indent = '']) {
    final buf = StringBuffer();
    for (final d in decorators) {
      buf.write('$indent${d.describe()}\n');
    }
    final kw = isNative ? 'NativeFn' : 'Fn';
    final ret = returnType != null ? ' -> ${returnType!.describe()}' : '';
    final ps = params.map((p) => p.describe()).join(', ');
    buf.write('$indent$kw $name($ps)$ret\n');
    if (body != null) buf.write(body!.describe('$indent  '));
    return buf.toString();
  }
}

class TypeDecl extends Decl {
  final String name;
  final SourceSpan nameSpan;
  final List<(String, TypeRef)> fields;
  TypeDecl(super.span, {required this.name, required this.nameSpan, required this.fields});

  @override
  String describe([String indent = '']) {
    final fs = fields.map((f) => '${f.$1}: ${f.$2.describe()}').join(', ');
    return '${indent}Type $name { $fs }\n';
  }
}

class ImplDecl extends Decl {
  final String typeName;
  final SourceSpan nameSpan; // span of typeName
  final String? interfaceName; // null = inherent impl
  final List<FnDecl> methods;
  ImplDecl(super.span,
      {required this.typeName, required this.nameSpan, this.interfaceName, required this.methods});

  @override
  String describe([String indent = '']) {
    final header = interfaceName != null
        ? 'Impl $interfaceName for $typeName'
        : 'Impl $typeName';
    final buf = StringBuffer('$indent$header\n');
    for (final m in methods) {
      buf.write(m.describe('$indent  '));
    }
    return buf.toString();
  }
}

class InterfaceDecl extends Decl {
  final String name;
  final SourceSpan nameSpan;
  final List<FnDecl> methods;
  InterfaceDecl(super.span, {required this.name, required this.nameSpan, required this.methods});

  @override
  String describe([String indent = '']) {
    final buf = StringBuffer('${indent}Interface $name\n');
    for (final m in methods) {
      buf.write(m.describe('$indent  '));
    }
    return buf.toString();
  }
}

class ConstDecl extends Decl {
  final String name;
  final TypeRef? type;
  final Expr value;
  ConstDecl(super.span, {required this.name, this.type, required this.value});

  @override
  String describe([String indent = '']) => '${indent}Const $name\n';
}

class EnumVariant {
  final String name;
  final SourceSpan span; // span of the variant name
  final List<TypeRef> fields; // positional payload types; empty = no payload
  const EnumVariant(this.name, {required this.span, this.fields = const []});
}

class EnumDecl extends Decl {
  final String name;
  final SourceSpan nameSpan;
  final List<EnumVariant> variants;
  EnumDecl(super.span, {required this.name, required this.nameSpan, required this.variants});

  @override
  String describe([String indent = '']) {
    final vs = variants.map((v) {
      if (v.fields.isEmpty) return v.name;
      return '${v.name}(${v.fields.map((f) => f.describe()).join(', ')})';
    }).join(', ');
    return '${indent}Enum $name { $vs }\n';
  }
}

// --- Helpers attached to declarations ---

class Decorator {
  final String name;
  final List<Expr> args;
  Decorator(this.name, {this.args = const []});

  String describe() =>
      '@$name${args.isEmpty ? '' : '(${args.map((a) => a.describe()).join(', ')})'}';
}

class TypeParam {
  final String name;
  final List<String> bounds; // e.g. ['Eq', 'Debug']
  const TypeParam(this.name, {this.bounds = const []});

  String describe() => bounds.isEmpty ? name : '$name: ${bounds.join(' + ')}';
}

class Param {
  // External label: null means suppressed (_); equal to name means no separate
  // external label was given (default: label == name).
  final String? label;
  final bool isSelf; // true if this is the `self` parameter
  final String name;
  final TypeRef? type;
  final Expr? defaultValue;
  const Param({
    this.label,
    this.isSelf = false,
    required this.name,
    this.type,
    this.defaultValue,
  });

  String describe() {
    if (isSelf) return 'self';
    final lbl = label == null ? '_' : (label == name ? '' : '$label ');
    final t = type != null ? ': ${type!.describe()}' : '';
    return '$lbl$name$t';
  }
}

// --- Type references ---

sealed class TypeRef {
  const TypeRef();
  String describe();
}

class NamedType extends TypeRef {
  final String name;
  final List<TypeRef> args;
  final SourceSpan? span; // null for synthetically constructed types
  NamedType(this.name, {this.args = const [], this.span});

  @override
  String describe() {
    if (args.isEmpty) return name;
    return '$name<${args.map((a) => a.describe()).join(', ')}>';
  }
}

class VoidType extends TypeRef {
  const VoidType();

  @override
  String describe() => '()';
}

// --- Statements ---

sealed class Stmt {
  final SourceSpan span;
  Stmt(this.span);

  String describe([String indent = '']);
}

class LetStmt extends Stmt {
  final bool isMut;
  final String name;
  final TypeRef? type;
  final Expr value;
  LetStmt(super.span,
      {required this.isMut,
      required this.name,
      this.type,
      required this.value});

  @override
  String describe([String indent = '']) {
    final kw = isMut ? 'let mut' : 'let';
    final t = type != null ? ': ${type!.describe()}' : '';
    return '$indent$kw $name$t = ${value.describe()}\n';
  }
}

class ReturnStmt extends Stmt {
  final Expr? value;
  ReturnStmt(super.span, {this.value});

  @override
  String describe([String indent = '']) =>
      '${indent}return${value != null ? ' ${value!.describe()}' : ''}\n';
}

class ThrowStmt extends Stmt {
  final Expr value;
  ThrowStmt(super.span, {required this.value});

  @override
  String describe([String indent = '']) =>
      '${indent}throw ${value.describe()}\n';
}

class ExprStmt extends Stmt {
  final Expr expr;
  ExprStmt(super.span, this.expr);

  @override
  String describe([String indent = '']) => '$indent${expr.describe()}\n';
}

// x = expr  /  x.field = expr  /  x[i] = expr
class AssignStmt extends Stmt {
  final Expr target; // must be IdentExpr, FieldExpr, or IndexExpr
  final Expr value;
  AssignStmt(super.span, {required this.target, required this.value});

  @override
  String describe([String indent = '']) =>
      '$indent${target.describe()} = ${value.describe()}\n';
}

class IfStmt extends Stmt {
  final Expr condition;
  final Block then;
  final Block? else_;
  IfStmt(super.span, {required this.condition, required this.then, this.else_});

  @override
  String describe([String indent = '']) {
    final buf = StringBuffer('${indent}if ${condition.describe()}\n');
    buf.write(then.describe('$indent  '));
    if (else_ != null) {
      buf.write('${indent}else\n');
      buf.write(else_!.describe('$indent  '));
    }
    return buf.toString();
  }
}

class ForStmt extends Stmt {
  final Pattern pattern;
  final Expr iterable;
  final Block body;
  ForStmt(super.span,
      {required this.pattern, required this.iterable, required this.body});

  @override
  String describe([String indent = '']) {
    final buf = StringBuffer(
        '${indent}for ${pattern.describe()} in ${iterable.describe()}\n');
    buf.write(body.describe('$indent  '));
    return buf.toString();
  }
}

class WhileStmt extends Stmt {
  final Expr condition;
  final Block body;
  WhileStmt(super.span, {required this.condition, required this.body});

  @override
  String describe([String indent = '']) {
    final buf = StringBuffer('${indent}while ${condition.describe()}\n');
    buf.write(body.describe('$indent  '));
    return buf.toString();
  }
}

class Block {
  final SourceSpan span;    // the { token
  final SourceSpan endSpan; // the } token
  final List<Stmt> stmts;
  Block(this.span, this.endSpan, this.stmts);

  String describe([String indent = '']) {
    final buf = StringBuffer('${indent}Block\n');
    for (final s in stmts) {
      buf.write(s.describe('$indent  '));
    }
    return buf.toString();
  }
}

// --- Patterns ---

sealed class Pattern {
  const Pattern();
  String describe();
}

class WildcardPattern extends Pattern {
  const WildcardPattern();
  @override
  String describe() => '_';
}

class IdentPattern extends Pattern {
  final String name;
  IdentPattern(this.name);
  @override
  String describe() => name;
}

class ConstructorPattern extends Pattern {
  final String name;
  final List<Pattern> args;
  ConstructorPattern(this.name, this.args);
  @override
  String describe() => args.isEmpty
      ? name
      : '$name(${args.map((a) => a.describe()).join(', ')})';
}

class LiteralPattern extends Pattern {
  final Expr literal;
  LiteralPattern(this.literal);
  @override
  String describe() => literal.describe();
}

// --- Expressions ---

sealed class Expr {
  final SourceSpan span;
  Expr(this.span);

  String describe();
}

class IntLiteral extends Expr {
  final int value;
  IntLiteral(super.span, this.value);
  @override
  String describe() => '$value';
}

class FloatLiteral extends Expr {
  final double value;
  FloatLiteral(super.span, this.value);
  @override
  String describe() => '$value';
}

class BoolLiteral extends Expr {
  final bool value;
  BoolLiteral(super.span, this.value);
  @override
  String describe() => '$value';
}

// A string literal with optional interpolation segments.
class StringExpr extends Expr {
  final List<StringPart> parts;
  StringExpr(super.span, this.parts);

  @override
  String describe() {
    final inner = parts
        .map((p) => switch (p) {
              TextPart(:final text) => text,
              InterpPart(:final expr) => '\${${expr.describe()}}',
            })
        .join();
    return '"$inner"';
  }
}

sealed class StringPart {}

class TextPart extends StringPart {
  final String text;
  TextPart(this.text);
}

class InterpPart extends StringPart {
  final Expr expr;
  InterpPart(this.expr);
}

class ListExpr extends Expr {
  final List<Expr> items;
  ListExpr(super.span, this.items);
  @override
  String describe() => '[${items.map((e) => e.describe()).join(', ')}]';
}

class MapExpr extends Expr {
  final List<(Expr, Expr)> entries; // (key, value) pairs
  MapExpr(super.span, this.entries);
  @override
  String describe() {
    final es = entries.map((e) => '${e.$1.describe()}: ${e.$2.describe()}').join(', ');
    return '{$es}';
  }
}

class StructExpr extends Expr {
  final String typeName;
  final List<(String, Expr)> fields;
  StructExpr(super.span, {required this.typeName, required this.fields});
  @override
  String describe() {
    final fs = fields.map((f) => '${f.$1}: ${f.$2.describe()}').join(', ');
    return '$typeName { $fs }';
  }
}

class IdentExpr extends Expr {
  final String name;
  IdentExpr(super.span, this.name);
  @override
  String describe() => name;
}

class CallExpr extends Expr {
  final Expr callee;
  final List<TypeRef> typeArgs;
  final List<CallArg> args;
  CallExpr(super.span,
      {required this.callee, this.typeArgs = const [], required this.args});
  @override
  String describe() {
    final ta = typeArgs.isEmpty
        ? ''
        : '<${typeArgs.map((t) => t.describe()).join(', ')}>';
    final as_ = args.map((a) => a.describe()).join(', ');
    return '${callee.describe()}$ta($as_)';
  }
}

class CallArg {
  final String? label;
  final Expr value;
  const CallArg({this.label, required this.value});

  String describe() =>
      label != null ? '$label: ${value.describe()}' : value.describe();
}

class FieldExpr extends Expr {
  final Expr object;
  final String field;
  FieldExpr(super.span, {required this.object, required this.field});
  @override
  String describe() => '${object.describe()}.$field';
}

class IndexExpr extends Expr {
  final Expr object;
  final Expr index;
  IndexExpr(super.span, {required this.object, required this.index});
  @override
  String describe() => '${object.describe()}[${index.describe()}]';
}

class BinaryExpr extends Expr {
  final Expr left;
  final String op;
  final Expr right;
  BinaryExpr(super.span,
      {required this.left, required this.op, required this.right});
  @override
  String describe() => '(${left.describe()} $op ${right.describe()})';
}

class UnaryExpr extends Expr {
  final String op;
  final Expr operand;
  UnaryExpr(super.span, {required this.op, required this.operand});
  @override
  String describe() => '($op${operand.describe()})';
}

class PropagateExpr extends Expr {
  final Expr inner;
  PropagateExpr(super.span, this.inner);
  @override
  String describe() => '${inner.describe()}?';
}

class RangeExpr extends Expr {
  final Expr start;
  final Expr end;
  RangeExpr(super.span, {required this.start, required this.end});
  @override
  String describe() => '${start.describe()}..${end.describe()}';
}

class MatchExpr extends Expr {
  final Expr subject;
  final List<MatchArm> arms;
  MatchExpr(super.span, {required this.subject, required this.arms});
  @override
  String describe() {
    final as_ = arms.map((a) => a.describe()).join(', ');
    return 'match ${subject.describe()} { $as_ }';
  }
}

class MatchArm {
  final Pattern pattern;
  final Expr body;
  const MatchArm({required this.pattern, required this.body});

  String describe() => '${pattern.describe()} => ${body.describe()}';
}

class LambdaExpr extends Expr {
  final List<String> params;
  final Expr body;
  LambdaExpr(super.span, {required this.params, required this.body});
  @override
  String describe() {
    final ps = params.length == 1 ? params[0] : '(${params.join(', ')})';
    return '$ps => ${body.describe()}';
  }
}

class BlockExpr extends Expr {
  final Block block;
  BlockExpr(super.span, this.block);
  @override
  String describe() => 'block{...}';
}

// return and throw as expressions (for use in match arm bodies, etc.)
class ReturnExpr extends Expr {
  final Expr? value;
  ReturnExpr(super.span, {this.value});
  @override
  String describe() => 'return${value != null ? ' ${value!.describe()}' : ''}';
}

class ThrowExpr extends Expr {
  final Expr value;
  ThrowExpr(super.span, this.value);
  @override
  String describe() => 'throw ${value.describe()}';
}
