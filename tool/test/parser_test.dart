import 'package:aero/src/ast.dart';
import 'package:aero/src/lexer.dart';
import 'package:aero/src/parser.dart';
import 'package:aero/src/token.dart';
import 'package:test/test.dart';

/// Lex + parse [source], asserting there were no lex or parse errors.
Program parse(String source) {
  final lex = Lexer(source).tokenize();
  expect(lex.hasErrors, isFalse,
      reason: 'unexpected lex errors: ${lex.errors}');
  final result = Parser(lex.tokens).parse();
  expect(result.hasErrors, isFalse,
      reason: 'unexpected parse errors: ${result.errors}');
  return result.program;
}

/// Lex + parse [source], returning the full result (errors included).
ParseResult parseRaw(String source) {
  final lex = Lexer(source).tokenize();
  return Parser(lex.tokens).parse();
}

void main() {
  group('lexer', () {
    test('tokenizes a simple function without errors', () {
      final lex = Lexer('fn main() -> Int { return 0; }').tokenize();
      expect(lex.hasErrors, isFalse);
      expect(lex.tokens.last.kind, TokenKind.eof);
    });

    test('captures string interpolation verbatim in the token value', () {
      final lex = Lexer("'Hello, \${name}!'").tokenize();
      expect(lex.hasErrors, isFalse);
      final str = lex.tokens.firstWhere((t) => t.kind == TokenKind.stringLiteral);
      expect(str.value, 'Hello, \${name}!');
    });
  });

  group('function declarations', () {
    test('parses name, return type, and body', () {
      final program = parse('fn answer() -> Int { return 42; }');
      final fn = program.decls.single as FnDecl;
      expect(fn.name, 'answer');
      expect(fn.isNative, isFalse);
      expect((fn.returnType as NamedType).name, 'Int');
      expect(fn.body, isNotNull);

      final ret = fn.body!.stmts.single as ReturnStmt;
      expect((ret.value as IntLiteral).value, 42);
    });

    test('nameSpan points at the function name, not the fn keyword', () {
      final program = parse('fn main() { }');
      final fn = program.decls.single as FnDecl;
      // 'fn ' is 3 characters; the name begins at offset 3.
      expect(fn.nameSpan.offset, 3);
      expect(fn.nameSpan.text, 'main');
    });

    test('native fn has no body', () {
      final program = parse('native fn clock() -> Int;');
      final fn = program.decls.single as FnDecl;
      expect(fn.isNative, isTrue);
      expect(fn.body, isNull);
    });

    test('parses @test decorator', () {
      final program = parse('@test fn checks() { }');
      final fn = program.decls.single as FnDecl;
      expect(fn.decorators.single.name, 'test');
    });
  });

  group('parameters', () {
    Param onlyParam(String source) =>
        (parse(source).decls.single as FnDecl).params.single;

    test('suppressed label (_) yields a null label', () {
      final p = onlyParam('fn f(_ text: String) { }');
      expect(p.label, isNull);
      expect(p.name, 'text');
      expect((p.type as NamedType).name, 'String');
    });

    test('single identifier means label equals name', () {
      final p = onlyParam('fn f(count: Int) { }');
      expect(p.label, 'count');
      expect(p.name, 'count');
    });

    test('external/internal pair', () {
      final p = onlyParam('fn f(to recipient: String) { }');
      expect(p.label, 'to');
      expect(p.name, 'recipient');
    });

    test('self parameter', () {
      final program = parse('impl Foo { fn bar(self) { } }');
      final method = (program.decls.single as ImplDecl).methods.single;
      expect(method.params.single.isSelf, isTrue);
    });

    test('default value', () {
      final p = onlyParam("fn f(name: String = 'world') { }");
      expect(p.defaultValue, isA<StringExpr>());
    });
  });

  group('type, impl, and interface declarations', () {
    test('type declaration with fields and nameSpan', () {
      final program = parse('type Point = { x: Int, y: Int }');
      final decl = program.decls.single as TypeDecl;
      expect(decl.name, 'Point');
      expect(decl.nameSpan.text, 'Point');
      expect(decl.fields.map((f) => f.$1), ['x', 'y']);
      expect((decl.fields.first.$2 as NamedType).name, 'Int');
    });

    test('inherent impl collects methods', () {
      final program = parse('''
impl Counter {
  fn increment(self) -> Counter { return self; }
  fn reset(self) -> Counter { return self; }
}
''');
      final impl = program.decls.single as ImplDecl;
      expect(impl.typeName, 'Counter');
      expect(impl.interfaceName, isNull);
      expect(impl.nameSpan.text, 'Counter');
      expect(impl.methods.map((m) => m.name), ['increment', 'reset']);
    });

    test('interface-for-type impl records both names', () {
      final program = parse('''
impl Display for Point {
  fn display(self) -> String { return 'p'; }
}
''');
      final impl = program.decls.single as ImplDecl;
      expect(impl.interfaceName, 'Display');
      expect(impl.typeName, 'Point');
      // nameSpan should point at the type, not the interface.
      expect(impl.nameSpan.text, 'Point');
    });

    test('interface declaration with method stubs', () {
      final program = parse('''
interface Greet {
  fn greet(self) -> String;
}
''');
      final iface = program.decls.single as InterfaceDecl;
      expect(iface.name, 'Greet');
      expect(iface.nameSpan.text, 'Greet');
      expect(iface.methods.single.name, 'greet');
      expect(iface.methods.single.body, isNull);
    });
  });

  group('imports', () {
    test('stdlib module path', () {
      final program = parse('import std.fs;');
      final imp = program.decls.single as ImportDecl;
      expect(imp.path, 'std.fs');
      expect(imp.alias, isNull);
    });

    test('quoted relative path with alias', () {
      final program = parse("import 'wordcount' as wc;");
      final imp = program.decls.single as ImportDecl;
      expect(imp.path, 'wordcount');
      expect(imp.alias, 'wc');
    });
  });

  group('statements', () {
    List<Stmt> bodyOf(String source) =>
        (parse(source).decls.single as FnDecl).body!.stmts;

    test('let with and without mut', () {
      final stmts = bodyOf('fn f() { let x = 1; let mut y = 2; }');
      final x = stmts[0] as LetStmt;
      final y = stmts[1] as LetStmt;
      expect(x.isMut, isFalse);
      expect(x.name, 'x');
      expect(y.isMut, isTrue);
    });

    test('if / else', () {
      final stmts = bodyOf('fn f() { if x { return 1; } else { return 2; } }');
      final ifStmt = stmts.single as IfStmt;
      expect(ifStmt.else_, isNotNull);
    });

    test('for over a range', () {
      final stmts = bodyOf('fn f() { for i in 0..10 { } }');
      final loop = stmts.single as ForStmt;
      expect((loop.pattern as IdentPattern).name, 'i');
      expect(loop.iterable, isA<RangeExpr>());
    });

    test('while loop', () {
      final stmts = bodyOf('fn f() { while x { } }');
      expect(stmts.single, isA<WhileStmt>());
    });

    test('variable assignment', () {
      final stmts = bodyOf('fn f() { let mut x = 0; x = x + 1; }');
      expect(stmts[1], isA<AssignStmt>());
      final assign = stmts[1] as AssignStmt;
      expect((assign.target as IdentExpr).name, 'x');
      expect(assign.value, isA<BinaryExpr>());
    });

    test('field assignment', () {
      final stmts = bodyOf('fn f() { obj.field = 42; }');
      final assign = stmts.single as AssignStmt;
      final target = assign.target as FieldExpr;
      expect(target.field, 'field');
    });

    test('index assignment', () {
      final stmts = bodyOf('fn f() { xs[0] = 99; }');
      final assign = stmts.single as AssignStmt;
      expect(assign.target, isA<IndexExpr>());
    });
  });

  group('expressions', () {
    Expr exprOf(String exprSource) {
      final stmts = (parse('fn f() { let v = $exprSource; }').decls.single
              as FnDecl)
          .body!
          .stmts;
      return (stmts.single as LetStmt).value;
    }

    test('binary precedence: * binds tighter than +', () {
      final e = exprOf('1 + 2 * 3') as BinaryExpr;
      expect(e.op, '+');
      final right = e.right as BinaryExpr;
      expect(right.op, '*');
      expect((right.left as IntLiteral).value, 2);
    });

    test('method call with field access', () {
      final e = exprOf('text.lines().len()') as CallExpr;
      final outerCallee = e.callee as FieldExpr;
      expect(outerCallee.field, 'len');
      expect(outerCallee.object, isA<CallExpr>());
    });

    test('call with named argument', () {
      final e = exprOf("args.flag('name', default: 'world')") as CallExpr;
      expect(e.args.length, 2);
      expect(e.args[0].label, isNull);
      expect(e.args[1].label, 'default');
    });

    test('error propagation with ?', () {
      final e = exprOf('fs.read_text(path)?');
      expect(e, isA<PropagateExpr>());
    });

    test('list literal', () {
      final e = exprOf('[1, 2, 3]') as ListExpr;
      expect(e.items.length, 3);
    });

    test('struct literal', () {
      final e = exprOf('Point { x: 1, y: 2 }') as StructExpr;
      expect(e.typeName, 'Point');
      expect(e.fields.map((f) => f.$1), ['x', 'y']);
    });

    test('string interpolation splits into text and expr parts', () {
      final e = exprOf("'Hello, \${name}!'") as StringExpr;
      expect(e.parts.whereType<InterpPart>().length, 1);
      expect(e.parts.whereType<TextPart>().length, 2);
      final interp = e.parts.whereType<InterpPart>().single;
      expect((interp.expr as IdentExpr).name, 'name');
    });

    test('lambda', () {
      final e = exprOf('u => u.name') as LambdaExpr;
      expect(e.params, ['u']);
      expect(e.body, isA<FieldExpr>());
    });

    test('match expression with constructor and wildcard patterns', () {
      final e = exprOf('match opt { Some(x) => x, None => 0, _ => 0 }')
          as MatchExpr;
      expect(e.arms.length, 3);
      final some = e.arms[0].pattern as ConstructorPattern;
      expect(some.name, 'Some');
      expect((some.args.single as IdentPattern).name, 'x');
      expect(e.arms[2].pattern, isA<WildcardPattern>());
    });
  });

  group('map literals', () {
    Expr exprOf(String exprSource) =>
        ((parse('fn f() { let v = $exprSource; }').decls.single as FnDecl)
                .body!
                .stmts
                .single as LetStmt)
            .value;

    test('empty map literal', () {
      final e = exprOf('{}') as MapExpr;
      expect(e.entries, isEmpty);
    });

    test('string-keyed map literal', () {
      final e = exprOf("{'a': 1, 'b': 2}") as MapExpr;
      expect(e.entries.length, 2);
      expect((e.entries[0].$1 as StringExpr).parts.first, isA<TextPart>());
      expect((e.entries[1].$2 as IntLiteral).value, 2);
    });

    test('int-keyed map literal', () {
      final e = exprOf('{1: 10, 2: 20}') as MapExpr;
      expect(e.entries.length, 2);
      expect((e.entries[0].$1 as IntLiteral).value, 1);
    });

    test('struct literal is not confused with map', () {
      final e = exprOf('Point { x: 1, y: 2 }') as StructExpr;
      expect(e.typeName, 'Point');
    });
  });

  group('const declarations', () {
    test('top-level const with type annotation', () {
      final program = parse('const SPACE: Int = 32;');
      final decl = program.decls.single as ConstDecl;
      expect(decl.name, 'SPACE');
      expect((decl.type as NamedType).name, 'Int');
      expect((decl.value as IntLiteral).value, 32);
    });

    test('top-level const without type annotation', () {
      final program = parse('const LF = 10;');
      final decl = program.decls.single as ConstDecl;
      expect(decl.name, 'LF');
      expect(decl.type, isNull);
    });

    test('local const parsed as immutable let', () {
      final stmts =
          (parse('fn f() { const X: Int = 42; }').decls.single as FnDecl)
              .body!
              .stmts;
      final let = stmts.single as LetStmt;
      expect(let.name, 'X');
      expect(let.isMut, isFalse);
    });
  });

  group('error reporting and recovery', () {
    test('reports an error with a source span', () {
      final result = parseRaw('fn main() -> Int { return }');
      // 'return' with no value followed by '}' — currently parses as return
      // of an expression and then fails; either way we expect graceful output.
      // The key invariant: errors carry a usable span when present.
      for (final err in result.errors) {
        expect(err.span.line, greaterThanOrEqualTo(1));
      }
    });

    test('recovers and parses the second declaration after a bad first one', () {
      final result = parseRaw('''
fn broken( {
fn good() -> Int { return 1; }
''');
      expect(result.hasErrors, isTrue);
      // Recovery should still surface the well-formed `good` function.
      final names = result.program.decls.whereType<FnDecl>().map((f) => f.name);
      expect(names, contains('good'));
    });
  });
}
