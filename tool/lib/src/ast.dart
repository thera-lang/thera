import 'element/types.dart';
import 'token.dart';

// --- Base AST Node Classes ---

abstract class AstNode {
  SourceSpan get span;
  Iterable<AstNode> get childNodes;
}

abstract interface class NamedNode implements AstNode {
  String get name;
  SourceSpan get nameSpan;
}

// --- Top-level ---

class Program extends AstNode {
  final List<Decl> decls;
  String? filePath;

  Program(this.decls);

  @override
  SourceSpan get span {
    if (decls.isEmpty) {
      return const SourceSpan(
          source: '', offset: 0, length: 0, line: 1, column: 1);
    }
    return SourceSpan.cover(decls.first.span, decls.last.span);
  }

  @override
  Iterable<AstNode> get childNodes => decls;

  String describe([String indent = '']) {
    final buf = StringBuffer('Program\n');
    for (final d in decls) {
      buf.write(d.describe('$indent  '));
    }
    return buf.toString();
  }
}

// --- Declarations ---

sealed class Decl extends AstNode {
  @override
  final SourceSpan span;

  Decl(this.span);

  String describe([String indent = '']);
}

class ImportDecl extends Decl {
  final String path; // e.g. 'std.fs' or 'wordcount'
  final String? alias;
  final bool isPub; // `pub import` re-exports the target's public symbols

  ImportDecl(super.span, {required this.path, this.alias, this.isPub = false});

  @override
  Iterable<AstNode> get childNodes => const [];

  @override
  String describe([String indent = '']) =>
      '$indent${isPub ? 'pub ' : ''}Import($path${alias != null ? ' as $alias' : ''})\n';
}

class FnDecl extends Decl implements NamedNode {
  final List<Decorator> decorators;
  final bool isPub;
  final bool isNative;
  @override
  final String name;
  @override
  final SourceSpan nameSpan;
  final List<TypeParam> typeParams;
  final List<Param> params;
  final TypeRef? returnType;
  final Block? body; // null for native fn
  FnDecl(
    super.span, {
    required this.decorators,
    this.isPub = false,
    required this.isNative,
    required this.name,
    required this.nameSpan,
    this.typeParams = const [],
    required this.params,
    this.returnType,
    this.body,
  });

  @override
  Iterable<AstNode> get childNodes => [
        ...decorators,
        ...typeParams,
        ...params,
        if (returnType != null) returnType!,
        if (body != null) body!,
      ];

  @override
  String describe([String indent = '']) {
    final buf = StringBuffer();
    for (final d in decorators) {
      buf.write('$indent${d.describe()}\n');
    }
    final pub = isPub ? 'pub ' : '';
    final kw = '$pub${isNative ? 'NativeFn' : 'Fn'}';
    final ret = returnType != null ? ' -> ${returnType!.describe()}' : '';
    final ps = params.map((p) => p.describe()).join(', ');
    buf.write('$indent$kw $name($ps)$ret\n');
    if (body != null) buf.write(body!.describe('$indent  '));
    return buf.toString();
  }
}

class TypeDecl extends Decl implements NamedNode {
  final bool isPub;
  @override
  final String name;
  @override
  final SourceSpan nameSpan;
  final List<TypeParam> typeParams;
  final List<(String, TypeRef)> fields;
  TypeDecl(super.span,
      {this.isPub = false,
      required this.name,
      required this.nameSpan,
      this.typeParams = const [],
      required this.fields});

  @override
  Iterable<AstNode> get childNodes => [
        ...typeParams,
        for (final f in fields) f.$2,
      ];

  @override
  String describe([String indent = '']) {
    final tps = typeParams.isEmpty
        ? ''
        : '<${typeParams.map((t) => t.describe()).join(', ')}>';
    final fs = fields.map((f) => '${f.$1}: ${f.$2.describe()}').join(', ');
    return '$indent${isPub ? 'pub ' : ''}Type $name$tps { $fs }\n';
  }
}

class ImplDecl extends Decl implements NamedNode {
  final String typeName;
  @override
  final SourceSpan nameSpan; // span of typeName
  final List<TypeParam> typeParams; // generic params, e.g. impl Box<T>
  final String? interfaceName; // null = inherent impl
  final List<TypeRef> interfaceArgs; // the interface's type args, e.g. <Int> in
  // `impl Iterator<Int> for RangeIter`; empty for a non-generic interface.
  final List<FnDecl> methods;
  ImplDecl(super.span,
      {required this.typeName,
      required this.nameSpan,
      this.typeParams = const [],
      this.interfaceName,
      this.interfaceArgs = const [],
      required this.methods});

  @override
  String get name => typeName;

  @override
  Iterable<AstNode> get childNodes => [
        ...typeParams,
        ...methods,
      ];

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

class InterfaceDecl extends Decl implements NamedNode {
  final bool isPub;
  @override
  final String name;
  @override
  final SourceSpan nameSpan;
  final List<TypeParam>
      typeParams; // generic params, e.g. interface Iterator<T>
  final List<String>
      superInterfaces; // extended interfaces, e.g. Display + Debug
  final List<FnDecl> methods;
  InterfaceDecl(super.span,
      {this.isPub = false,
      required this.name,
      required this.nameSpan,
      this.typeParams = const [],
      this.superInterfaces = const [],
      required this.methods});

  @override
  Iterable<AstNode> get childNodes => [...typeParams, ...methods];

  @override
  String describe([String indent = '']) {
    final tps = typeParams.isEmpty
        ? ''
        : '<${typeParams.map((t) => t.name).join(', ')}>';
    final sup =
        superInterfaces.isEmpty ? '' : ': ${superInterfaces.join(' + ')}';
    final buf =
        StringBuffer('$indent${isPub ? 'pub ' : ''}Interface $name$tps$sup\n');
    for (final m in methods) {
      buf.write(m.describe('$indent  '));
    }
    return buf.toString();
  }
}

class ConstDecl extends Decl implements NamedNode {
  final bool isPub;
  @override
  final String name;
  @override
  final SourceSpan nameSpan;
  final TypeRef? type;
  final Expr value;
  ConstDecl(super.span,
      {this.isPub = false,
      required this.name,
      required this.nameSpan,
      this.type,
      required this.value});

  @override
  Iterable<AstNode> get childNodes => [
        if (type != null) type!,
        value,
      ];

  @override
  String describe([String indent = '']) =>
      '$indent${isPub ? 'pub ' : ''}Const $name\n';
}

class EnumVariant extends AstNode implements NamedNode {
  @override
  final String name;
  @override
  final SourceSpan span;
  @override
  final SourceSpan nameSpan;
  final List<TypeRef> fields; // positional payload types; empty = no payload
  EnumVariant(this.name,
      {required this.span, SourceSpan? nameSpan, this.fields = const []})
      : this.nameSpan = nameSpan ?? span;

  @override
  Iterable<AstNode> get childNodes => fields;
}

class EnumDecl extends Decl implements NamedNode {
  final bool isPub;
  @override
  final String name;
  @override
  final SourceSpan nameSpan;
  final List<TypeParam> typeParams;
  final List<EnumVariant> variants;
  EnumDecl(super.span,
      {this.isPub = false,
      required this.name,
      required this.nameSpan,
      this.typeParams = const [],
      required this.variants});

  @override
  Iterable<AstNode> get childNodes => [
        ...typeParams,
        ...variants,
      ];

  @override
  String describe([String indent = '']) {
    final tps = typeParams.isEmpty
        ? ''
        : '<${typeParams.map((t) => t.describe()).join(', ')}>';
    final vs = variants.map((v) {
      if (v.fields.isEmpty) return v.name;
      return '${v.name}(${v.fields.map((f) => f.describe()).join(', ')})';
    }).join(', ');
    return '$indent${isPub ? 'pub ' : ''}Enum $name$tps { $vs }\n';
  }
}

// --- Helpers attached to declarations ---

class Decorator extends AstNode {
  @override
  final SourceSpan span;
  final String name;
  final List<Expr> args;
  Decorator(this.span, this.name, {this.args = const []});

  @override
  Iterable<AstNode> get childNodes => args;

  String describe() =>
      '@$name${args.isEmpty ? '' : '(${args.map((a) => a.describe()).join(', ')})'}';
}

class TypeParam extends AstNode {
  @override
  final SourceSpan span;
  final String name;
  final List<String> bounds; // e.g. ['Eq', 'Debug']
  TypeParam(this.span, this.name, {this.bounds = const []});

  @override
  Iterable<AstNode> get childNodes => const [];

  String describe() => bounds.isEmpty ? name : '$name: ${bounds.join(' + ')}';
}

class Param extends AstNode implements NamedNode {
  // External label: null means suppressed (_); equal to name means no separate
  // external label was given (default: label == name).
  final String? label;
  final bool isSelf; // true if this is the `self` parameter
  @override
  final String name;
  @override
  final SourceSpan nameSpan;
  final TypeRef? type;
  final Expr? defaultValue;
  @override
  final SourceSpan span;

  Param({
    SourceSpan? span,
    this.label,
    this.isSelf = false,
    required this.name,
    required this.nameSpan,
    this.type,
    this.defaultValue,
  }) : this.span = span ??
            SourceSpan.cover(
                nameSpan, defaultValue?.span ?? type?.span ?? nameSpan);

  @override
  Iterable<AstNode> get childNodes => [
        if (type != null) type!,
        if (defaultValue != null) defaultValue!,
      ];

  String describe() {
    if (isSelf) return 'self';
    final lbl = label == null ? '_' : (label == name ? '' : '$label ');
    final t = type != null ? ': ${type!.describe()}' : '';
    return '$lbl$name$t';
  }
}

// --- Type references ---

sealed class TypeRef extends AstNode {
  @override
  final SourceSpan span;
  TypeRef(this.span);
  String describe();
}

class NamedType extends TypeRef {
  final String name;
  final List<TypeRef> args;

  /// The import namespace a qualified type reference was written with, e.g.
  /// `time` in `time.Clock`, or null for a bare `Clock`. Resolution is by
  /// [name] against the flat type table (imported types share one namespace),
  /// so the qualifier is carried for diagnostics and to mirror the value-side
  /// `ns.member` syntax; it does not change which type is resolved.
  final String? namespace;

  NamedType(this.name, {this.args = const [], this.namespace, SourceSpan? span})
      : super(span ??
            const SourceSpan(
                source: '', offset: 0, length: 0, line: 1, column: 1));

  @override
  Iterable<AstNode> get childNodes => args;

  @override
  String describe() {
    final qualified = namespace == null ? name : '$namespace.$name';
    if (args.isEmpty) return qualified;
    return '$qualified<${args.map((a) => a.describe()).join(', ')}>';
  }
}

/// A function type, e.g. `(Int, String) -> Bool` or `() -> Int`. The type of a
/// lambda value or a function-typed parameter.
class FunctionTypeRef extends TypeRef {
  final List<TypeRef> params;
  final TypeRef returnType;
  FunctionTypeRef(this.params, this.returnType, [SourceSpan? span])
      : super(span ??
            const SourceSpan(
                source: '', offset: 0, length: 0, line: 1, column: 1));

  @override
  Iterable<AstNode> get childNodes => [
        ...params,
        returnType,
      ];

  @override
  String describe() =>
      '(${params.map((p) => p.describe()).join(', ')}) -> ${returnType.describe()}';
}

// --- Statements ---

sealed class Stmt extends AstNode {
  @override
  final SourceSpan span;
  Stmt(this.span);

  String describe([String indent = '']);
}

class LetStmt extends Stmt implements NamedNode {
  final bool isMut;
  @override
  final String name;
  @override
  final SourceSpan nameSpan;
  final TypeRef? type;
  final Expr value;
  LetStmt(super.span,
      {required this.isMut,
      required this.name,
      required this.nameSpan,
      this.type,
      required this.value});

  @override
  Iterable<AstNode> get childNodes => [
        if (type != null) type!,
        value,
      ];

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
  Iterable<AstNode> get childNodes => [
        if (value != null) value!,
      ];

  @override
  String describe([String indent = '']) =>
      '${indent}return${value != null ? ' ${value!.describe()}' : ''}\n';
}

class ThrowStmt extends Stmt {
  final Expr value;
  ThrowStmt(super.span, {required this.value});

  @override
  Iterable<AstNode> get childNodes => [value];

  @override
  String describe([String indent = '']) =>
      '${indent}throw ${value.describe()}\n';
}

class ExprStmt extends Stmt {
  final Expr expr;

  ExprStmt(super.span, this.expr);

  @override
  Iterable<AstNode> get childNodes => [expr];

  @override
  String describe([String indent = '']) => '$indent${expr.describe()}\n';
}

// x = expr  /  x.field = expr  /  x[i] = expr
class AssignStmt extends Stmt {
  final Expr target; // must be IdentExpr, FieldExpr, or IndexExpr
  final Expr value;
  AssignStmt(super.span, {required this.target, required this.value});

  @override
  Iterable<AstNode> get childNodes => [target, value];

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
  Iterable<AstNode> get childNodes => [
        condition,
        then,
        if (else_ != null) else_!,
      ];

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
  Iterable<AstNode> get childNodes => [
        pattern,
        iterable,
        body,
      ];

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
  Iterable<AstNode> get childNodes => [
        condition,
        body,
      ];

  @override
  String describe([String indent = '']) {
    final buf = StringBuffer('${indent}while ${condition.describe()}\n');
    buf.write(body.describe('$indent  '));
    return buf.toString();
  }
}

class Block extends AstNode {
  final SourceSpan startSpan;
  final SourceSpan endSpan;
  final List<Stmt> stmts;
  Block(this.startSpan, this.endSpan, this.stmts);

  @override
  SourceSpan get span => SourceSpan.cover(startSpan, endSpan);

  @override
  Iterable<AstNode> get childNodes => stmts;

  String describe([String indent = '']) {
    final buf = StringBuffer('${indent}Block\n');
    for (final s in stmts) {
      buf.write(s.describe('$indent  '));
    }
    return buf.toString();
  }
}

// --- Patterns ---

sealed class Pattern extends AstNode {
  @override
  final SourceSpan span;
  Pattern(this.span);
  String describe();
}

class WildcardPattern extends Pattern {
  WildcardPattern(super.span);

  @override
  Iterable<AstNode> get childNodes => const [];

  @override
  String describe() => '_';
}

class IdentPattern extends Pattern {
  final String name;
  IdentPattern(super.span, this.name);

  @override
  Iterable<AstNode> get childNodes => const [];

  @override
  String describe() => name;
}

class ConstructorPattern extends Pattern {
  final String name;
  final List<Pattern> args;
  ConstructorPattern(super.span, this.name, this.args);

  @override
  Iterable<AstNode> get childNodes => args;

  @override
  String describe() => args.isEmpty
      ? name
      : '$name(${args.map((a) => a.describe()).join(', ')})';
}

class LiteralPattern extends Pattern {
  final Expr literal;
  LiteralPattern(super.span, this.literal);

  @override
  Iterable<AstNode> get childNodes => [literal];

  @override
  String describe() => literal.describe();
}

// --- Expressions ---

sealed class Expr extends AstNode {
  @override
  final SourceSpan span;

  Expr(this.span);

  /// The resolved semantic type of this expression, filled in by the inference
  /// pass (`element/inference.dart`). Null before inference runs (or when the
  /// type could not be determined — see [UnknownType] for the latter once a
  /// pass has annotated the tree).
  Type? resolvedType;

  String describe();
}

class IntLiteral extends Expr {
  final int value;
  IntLiteral(super.span, this.value);

  @override
  Iterable<AstNode> get childNodes => const [];

  @override
  String describe() => '$value';
}

class FloatLiteral extends Expr {
  final double value;
  FloatLiteral(super.span, this.value);

  @override
  Iterable<AstNode> get childNodes => const [];

  @override
  String describe() => '$value';
}

class BoolLiteral extends Expr {
  final bool value;
  BoolLiteral(super.span, this.value);

  @override
  Iterable<AstNode> get childNodes => const [];

  @override
  String describe() => '$value';
}

/// The unit value (`void`) — the single value of the `Void` type, written e.g.
/// `Ok(void)` in a `Result<Void, E>` function.
class UnitLiteral extends Expr {
  UnitLiteral(super.span);

  @override
  Iterable<AstNode> get childNodes => const [];

  @override
  String describe() => 'void';
}

// A string literal with optional interpolation segments.
class StringExpr extends Expr {
  final List<StringPart> parts;
  StringExpr(super.span, this.parts);

  @override
  Iterable<AstNode> get childNodes => parts;

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

sealed class StringPart extends AstNode {}

class TextPart extends StringPart {
  final String text;
  @override
  final SourceSpan span;
  TextPart(this.span, this.text);

  @override
  Iterable<AstNode> get childNodes => const [];
}

class InterpPart extends StringPart {
  final Expr expr;
  @override
  final SourceSpan span;
  InterpPart(this.span, this.expr);

  @override
  Iterable<AstNode> get childNodes => [expr];
}

class ListExpr extends Expr {
  final List<Expr> items;
  ListExpr(super.span, this.items);

  @override
  Iterable<AstNode> get childNodes => items;

  @override
  String describe() => '[${items.map((e) => e.describe()).join(', ')}]';
}

class MapExpr extends Expr {
  final List<(Expr, Expr)> entries; // (key, value) pairs
  MapExpr(super.span, this.entries);

  @override
  Iterable<AstNode> get childNodes => [
        for (final entry in entries) ...[entry.$1, entry.$2],
      ];

  @override
  String describe() {
    final es =
        entries.map((e) => '${e.$1.describe()}: ${e.$2.describe()}').join(', ');
    return '{$es}';
  }
}

class StructExpr extends Expr {
  final String typeName;
  final List<(String, Expr)> fields;
  StructExpr(super.span, {required this.typeName, required this.fields});

  @override
  Iterable<AstNode> get childNodes => fields.map((f) => f.$2);

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
  Iterable<AstNode> get childNodes => const [];

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
  Iterable<AstNode> get childNodes => [
        callee,
        ...typeArgs,
        ...args,
      ];

  @override
  String describe() {
    final ta = typeArgs.isEmpty
        ? ''
        : '<${typeArgs.map((t) => t.describe()).join(', ')}>';
    final as_ = args.map((a) => a.describe()).join(', ');
    return '${callee.describe()}$ta($as_)';
  }
}

class CallArg extends AstNode {
  @override
  final SourceSpan span;
  final String? label;
  final Expr value;
  CallArg(this.span, {this.label, required this.value});

  @override
  Iterable<AstNode> get childNodes => [value];

  String describe() =>
      label != null ? '$label: ${value.describe()}' : value.describe();
}

class FieldExpr extends Expr {
  final Expr object;
  final String field;
  FieldExpr(super.span, {required this.object, required this.field});

  @override
  Iterable<AstNode> get childNodes => [object];

  @override
  String describe() => '${object.describe()}.$field';
}

class IndexExpr extends Expr {
  final Expr object;
  final Expr index;
  IndexExpr(super.span, {required this.object, required this.index});

  @override
  Iterable<AstNode> get childNodes => [object, index];

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
  Iterable<AstNode> get childNodes => [left, right];

  @override
  String describe() => '(${left.describe()} $op ${right.describe()})';
}

class UnaryExpr extends Expr {
  final String op;
  final Expr operand;
  UnaryExpr(super.span, {required this.op, required this.operand});

  @override
  Iterable<AstNode> get childNodes => [operand];

  @override
  String describe() => '($op${operand.describe()})';
}

class PropagateExpr extends Expr {
  final Expr inner;
  PropagateExpr(super.span, this.inner);

  @override
  Iterable<AstNode> get childNodes => [inner];

  @override
  String describe() => '${inner.describe()}?';
}

class RangeExpr extends Expr {
  final Expr start;
  final Expr end;
  RangeExpr(super.span, {required this.start, required this.end});

  @override
  Iterable<AstNode> get childNodes => [start, end];

  @override
  String describe() => '${start.describe()}..${end.describe()}';
}

class MatchExpr extends Expr {
  final Expr subject;
  final List<MatchArm> arms;
  MatchExpr(super.span, {required this.subject, required this.arms});

  @override
  Iterable<AstNode> get childNodes => [
        subject,
        ...arms,
      ];

  @override
  String describe() {
    final as_ = arms.map((a) => a.describe()).join(', ');
    return 'match ${subject.describe()} { $as_ }';
  }
}

class MatchArm extends AstNode {
  @override
  final SourceSpan span;
  final Pattern pattern;
  final Expr body;
  MatchArm(this.span, {required this.pattern, required this.body});

  @override
  Iterable<AstNode> get childNodes => [pattern, body];

  String describe() => '${pattern.describe()} => ${body.describe()}';
}

/// A single lambda parameter: a name with an optional type annotation. The type
/// is null when omitted (`n => …`), filled by inference from context (or a hard
/// error if neither annotation nor context determines it).
class LambdaParam extends AstNode {
  @override
  final SourceSpan span;
  final String name;
  final TypeRef? type;
  LambdaParam(this.span, this.name, {this.type});

  @override
  Iterable<AstNode> get childNodes => [
        if (type != null) type!,
      ];

  String describe() => type == null ? name : '$name: ${type!.describe()}';
}

class LambdaExpr extends Expr {
  final List<LambdaParam> params;
  final Expr body;

  /// The resolved type of each parameter, filled by the inference pass (from the
  /// annotation or the expected/contextual type). Null before inference; an
  /// element is [UnknownType] when neither annotation nor context determined it
  /// (the checker reports that as an error).
  List<Type>? resolvedParamTypes;

  LambdaExpr(super.span, {required this.params, required this.body});

  @override
  Iterable<AstNode> get childNodes => [
        ...params,
        body,
      ];

  @override
  String describe() {
    // The bare single-param form `n => …` only when it has no annotation.
    final ps = params.length == 1 && params[0].type == null
        ? params[0].name
        : '(${params.map((p) => p.describe()).join(', ')})';
    return '$ps => ${body.describe()}';
  }
}

class BlockExpr extends Expr {
  final Block block;
  BlockExpr(super.span, this.block);

  @override
  Iterable<AstNode> get childNodes => [block];

  @override
  String describe() => 'block{...}';
}

// return and throw as expressions (for use in match arm bodies, etc.)
class ReturnExpr extends Expr {
  final Expr? value;
  ReturnExpr(super.span, {this.value});

  @override
  Iterable<AstNode> get childNodes => [
        if (value != null) value!,
      ];

  @override
  String describe() => 'return${value != null ? ' ${value!.describe()}' : ''}';
}

class ThrowExpr extends Expr {
  final Expr value;
  ThrowExpr(super.span, this.value);

  @override
  Iterable<AstNode> get childNodes => [value];

  @override
  String describe() => 'throw ${value.describe()}';
}
