import 'package:hawk/src/ast.dart';
import 'package:hawk/src/element/inference.dart';
import 'package:hawk/src/element/namespace.dart';
import 'package:hawk/src/element/resolver.dart';
import 'package:hawk/src/element/types.dart';
import 'package:hawk/src/lexer.dart';
import 'package:hawk/src/parser.dart';
import 'package:test/test.dart';

Program _parse(String source) {
  final lex = Lexer(source).tokenize();
  expect(lex.hasErrors, isFalse, reason: 'lex errors: ${lex.errors}');
  final p = Parser(lex.tokens).parse();
  expect(p.hasErrors, isFalse, reason: 'parse errors: ${p.errors}');
  return p.program;
}

/// Like [inferred] but with namespaced imports: each entry of [libs] is an
/// import-path -> library-source, so qualified access (`ns.member`) resolves.
Program inferredWith(String source, Map<String, String> libs) {
  final imports = {
    for (final e in libs.entries) e.key: LibrarySource(_parse(e.value)),
  };
  final program = _parse(source);
  final root = LibrarySource(program, imports: imports);
  final lib = buildLibrary(program,
      imports: [for (final s in imports.values) s.program],
      namespaces: namespacesFor(root));
  Inferrer(lib).inferProgram(program);
  return program;
}

/// Parse [source], run inference, and return a function for querying the
/// resolved type of the *last* expression matching a predicate. Most tests
/// wrap the expression of interest in `let probe = <expr>;` and read the
/// initializer's type via [letType].
Program inferred(String source, {List<String> imports = const []}) {
  Program parse(String src) {
    final lex = Lexer(src).tokenize();
    expect(lex.hasErrors, isFalse, reason: 'lex errors: ${lex.errors}');
    final p = Parser(lex.tokens).parse();
    expect(p.hasErrors, isFalse, reason: 'parse errors: ${p.errors}');
    return p.program;
  }

  final program = parse(source);
  final lib =
      buildLibrary(program, imports: [for (final src in imports) parse(src)]);
  Inferrer(lib).inferProgram(program);
  return program;
}

/// The resolved type of the initializer of the let-binding named [name],
/// searched across all function bodies.
Type letType(Program program, String name) {
  Type? found;
  void walkBlock(Block b) {
    for (final s in b.stmts) {
      if (s is LetStmt && s.name == name) found = s.value.resolvedType;
      switch (s) {
        case IfStmt(:final then, :final else_):
          walkBlock(then);
          if (else_ != null) walkBlock(else_);
        case ForStmt(:final body):
          walkBlock(body);
        case WhileStmt(:final body):
          walkBlock(body);
        default:
          break;
      }
    }
  }

  for (final decl in program.decls) {
    if (decl is FnDecl && decl.body != null) walkBlock(decl.body!);
    if (decl is ImplDecl) {
      for (final m in decl.methods) {
        if (m.body != null) walkBlock(m.body!);
      }
    }
  }
  return found!;
}

void main() {
  group('literals and operators', () {
    test('int / string / bool literals', () {
      final p = inferred('fn f() { let a = 1; let b = "x"; let c = true; }');
      expect(letType(p, 'a'), PrimitiveType.int_);
      expect(letType(p, 'b'), PrimitiveType.string);
      expect(letType(p, 'c'), PrimitiveType.bool_);
    });

    test('comparison is Bool, arithmetic follows operand', () {
      final p = inferred('fn f() { let a = 1 < 2; let b = 1 + 2; }');
      expect(letType(p, 'a'), PrimitiveType.bool_);
      expect(letType(p, 'b'), PrimitiveType.int_);
    });

    test('the void literal is the unit type', () {
      final p = inferred('fn f() { let u = void; }');
      expect(letType(p, 'u'), PrimitiveType.unit);
    });
  });

  group('constructors', () {
    test('Some / Ok / None carry element types', () {
      final p = inferred('''
fn f() {
  let s = Some(5);
  let o = Ok(true);
  let n = None;
}
''');
      expect(letType(p, 's').toString(), 'Option<Int>');
      expect((letType(p, 'o') as InterfaceType).element.name, 'Result');
      expect((letType(p, 'o') as InterfaceType).typeArguments.first,
          PrimitiveType.bool_);
      expect((letType(p, 'n') as InterfaceType).element.name, 'Option');
    });
  });

  group('through generics (the payoff)', () {
    test('Option.unwrap_or sees the element type', () {
      final p = inferred('fn f() { let x = Some(5).unwrap_or(0); }');
      expect(letType(p, 'x'), PrimitiveType.int_);
    });

    test('? on a Result yields the ok type', () {
      final p = inferred('''
fn g() -> Result<Int, Error> { return Ok(1); }
fn f() -> Result<Int, Error> { let x = g()?; return Ok(x); }
''');
      expect(letType(p, 'x'), PrimitiveType.int_);
    });

    test('list indexing yields the element type', () {
      final p = inferred('fn f(xs: List<String>) { let x = xs[0]; }');
      expect(letType(p, 'x'), PrimitiveType.string);
    });

    test('list .get yields Option<element>', () {
      final p = inferred('fn f(xs: List<Int>) { let x = xs.get(0); }');
      expect(letType(p, 'x').toString(), 'Option<Int>');
    });

    test('map .get yields Option<value>', () {
      final p = inferred('fn f(m: Map<String, Int>) { let x = m.get("k"); }');
      expect(letType(p, 'x').toString(), 'Option<Int>');
    });

    test('match Some(x) binds x to the element type', () {
      final p = inferred('''
fn f(opt: Option<Int>) -> Int {
  let r = match opt {
    Some(x) => x + 1,
    None => 0,
  };
  return r;
}
''');
      expect(letType(p, 'r'), PrimitiveType.int_);
    });
  });

  group('structs and fields', () {
    test('struct literal and field access', () {
      final p = inferred('''
type Point = { x: Int, y: Int }
fn f() { let p = Point { x: 1, y: 2 }; let xx = p.x; }
''');
      expect((letType(p, 'p') as InterfaceType).element.name, 'Point');
      expect(letType(p, 'xx'), PrimitiveType.int_);
    });

    test('generic struct recovers its type argument and field type', () {
      final p = inferred('''
type Box<T> = { value: T }
fn f() { let b = Box { value: 7 }; let v = b.value; }
''');
      expect(letType(p, 'b').toString(), 'Box<Int>');
      expect(letType(p, 'v'), PrimitiveType.int_);
    });
  });

  group('calls and methods', () {
    test('function return type', () {
      final p = inferred('''
fn area(_ r: Int) -> Int { return r; }
fn f() { let a = area(3); }
''');
      expect(letType(p, 'a'), PrimitiveType.int_);
    });

    test('string method returns', () {
      final p =
          inferred('fn f(s: String) { let n = s.len(); let u = s.trim(); }');
      expect(letType(p, 'n'), PrimitiveType.int_);
      expect(letType(p, 'u'), PrimitiveType.string);
    });

    test('enum construction and .name()', () {
      final p = inferred('''
enum Shape { Circle(Int), Square }
fn f() { let c = Shape.Circle(5); let n = c.name(); }
''');
      expect((letType(p, 'c') as InterfaceType).element.name, 'Shape');
      expect(letType(p, 'n'), PrimitiveType.string);
    });

    test('static method call resolves through the type name', () {
      // `Type.method(...)` — the receiver is a type, not a value. A chain off
      // the result must still resolve (regression: `Args.new(...).option(...)`).
      final p = inferred('''
type Args = { items: List<String> }
impl Args {
  fn new(_ items: List<String>) -> Args { return Args { items: items }; }
  fn first(self) -> Option<String> { return self.items.get(0); }
}
fn f(xs: List<String>) {
  let a = Args.new(xs);
  let v = Args.new(xs).first().unwrap_or("none");
}
''');
      expect((letType(p, 'a') as InterfaceType).element.name, 'Args');
      expect(letType(p, 'v'), PrimitiveType.string);
    });

    test('user method return type with generic receiver', () {
      final p = inferred('''
type Box<T> = { value: T }
impl Box<T> {
  fn get(self) -> T { return self.value; }
}
fn f() { let b = Box { value: "hi" }; let v = b.get(); }
''');
      expect(letType(p, 'v'), PrimitiveType.string);
    });

    test('static method on a built-in type resolves', () {
      final p = inferred('''
impl String { fn greeting() -> String { return 'hi'; } }
fn f() {
  let s = String.greeting();
  let n = String.greeting().len();
}
''');
      expect(letType(p, 's'), PrimitiveType.string);
      expect(letType(p, 'n'), PrimitiveType.int_);
    });
  });

  group('qualified (namespaced) access', () {
    test('ns.fn() resolves the imported function return type', () {
      final p = inferredWith(
        "import 'm';\nfn f() { let x = m.answer(); }",
        {'m': 'pub fn answer() -> Int { return 42; }'},
      );
      expect(letType(p, 'x'), PrimitiveType.int_);
    });

    test('ns.Type.staticMethod() resolves', () {
      final p = inferredWith(
        "import 'm';\nfn f() { let b = m.Box.make(); }",
        {
          'm': 'pub type Box = { v: Int }\n'
              'impl Box { fn make() -> Box { return Box { v: 0 }; } }',
        },
      );
      expect((letType(p, 'b') as InterfaceType).element.name, 'Box');
    });

    test('ns.Enum.Variant() resolves to the enum type', () {
      final p = inferredWith(
        "import 'm';\nfn f() { let c = m.Color.Rgb(1); }",
        {'m': 'pub enum Color { Red, Rgb(Int) }'},
      );
      expect((letType(p, 'c') as InterfaceType).element.name, 'Color');
    });

    test('ns.CONST resolves the const type', () {
      final p = inferredWith(
        "import 'm';\nfn f() { let n = m.ANSWER; }",
        {'m': 'pub const ANSWER: Int = 42;'},
      );
      expect(letType(p, 'n'), PrimitiveType.int_);
    });

    test('a chain off a qualified static call still resolves', () {
      // m.Args.new(...).first() — exercises ns.Type.method then a chained call.
      final p = inferredWith(
        "import 'm';\nfn f(xs: List<String>) { let v = m.Args.new(xs).first(); }",
        {
          'm': 'pub type Args = { items: List<String> }\n'
              'impl Args {\n'
              '  fn new(_ items: List<String>) -> Args { return Args { items: items }; }\n'
              '  fn first(self) -> Option<String> { return self.items.get(0); }\n'
              '}',
        },
      );
      expect(letType(p, 'v').toString(), 'Option<String>');
    });
  });

  group('function types and closures', () {
    test('a function-typed parameter resolves', () {
      final p = inferred(
          'fn apply(f: (Int) -> Int, x: Int) -> Int { let r = f(x); return r; }');
      expect(letType(p, 'r'), PrimitiveType.int_);
    });

    test('a lambda binding infers a function type', () {
      final p = inferred('fn f() { let g = n => n + 1; }');
      final g = letType(p, 'g');
      expect(g, isA<FunctionType>());
      expect((g as FunctionType).returnType, PrimitiveType.int_);
    });

    test('calling a let-bound lambda yields its return type', () {
      final p = inferred('fn f() { let g = n => n + 1; let r = g(5); }');
      expect(letType(p, 'r'), PrimitiveType.int_);
    });

    test('a function-typed return annotation resolves', () {
      final p =
          inferred('fn pick(f: (Int) -> Int) -> (Int) -> Int { return f; }\n'
              'fn f(g: (Int) -> Int) { let h = pick(g); }');
      expect(letType(p, 'h').toString(), '(Int) -> Int');
    });

    test('an annotated lambda parameter resolves its type', () {
      // `(n: Int) => n * n` — both operands are the param, so without the
      // annotation the body type is unknown; the annotation pins it to Int.
      final p = inferred('fn f() { let sq = (n: Int) => n * n; }');
      final t = letType(p, 'sq') as FunctionType;
      expect(t.parameterTypes.single, PrimitiveType.int_);
      expect(t.returnType, PrimitiveType.int_);
    });

    test('a generic method binds its own type param from a closure argument',
        () {
      // `map<U>` recovers `U` from the lambda's result type: here `n > 0` is
      // Bool, so `[1, 2].map(...)` is List<Bool>, not List<?>.
      final p = inferred('''
impl List<T> {
  fn map<U>(self, _ f: (T) -> U) -> List<U> { let r = []; return r; }
}
fn f() { let bools = [1, 2].map(n => n > 0); }
''');
      expect(letType(p, 'bools').toString(), 'List<Bool>');
    });
  });
}
