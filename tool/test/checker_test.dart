import 'package:hawk/src/checker/type_checker.dart';
import 'package:hawk/src/lexer.dart';
import 'package:hawk/src/parser.dart';
import 'package:test/test.dart';

/// A stand-in for the parts of the `std.core` prelude these hermetic tests
/// depend on: the I/O natives (sdk/std/core/io.hawk) and the Result/Option enums
/// (result.hawk/option.hawk). The real toolchain always links the prelude; these
/// tests link this stub instead of reading the SDK off disk.
const _corePrelude = '''
@extern('println') native fn println<T>(_ value: T) -> Void
@extern('print') native fn print<T>(_ value: T) -> Void
enum Option<T> { Some(T), None }
enum Result<T, E> { Ok(T), Err(E) }
''';

/// Parse [source] and run the type checker on it. Returns the list of error
/// messages (without file/line prefix) for easy assertion.
List<String> check(String source, {List<String> importSources = const []}) {
  final lex = Lexer(source).tokenize();
  expect(lex.hasErrors, isFalse,
      reason: 'unexpected lex errors: ${lex.errors}');
  final parse = Parser(lex.tokens).parse();
  expect(parse.hasErrors, isFalse,
      reason: 'unexpected parse errors: ${parse.errors}');

  final checker = TypeChecker();

  // Link the core prelude stub, then any provided import programs.
  for (final src in [_corePrelude, ...importSources]) {
    final importLex = Lexer(src).tokenize();
    final importParse = Parser(importLex.tokens).parse();
    checker.addProgram(importParse.program);
  }

  return checker.check(parse.program).errors.map((e) => e.message).toList();
}

void main() {
  // ---- valid programs ----

  group('valid programs', () {
    test('empty program', () {
      expect(check(''), isEmpty);
    });

    test('hello world', () {
      expect(
        check('''
fn main(args: Args) -> Result<Int, Error> {
  println('Hello!');
  return Result.Ok(0);
}
'''),
        isEmpty,
      );
    });

    test('struct, impl, and method call', () {
      expect(
        check('''
type Point = { x: Int, y: Int }

impl Point {
  fn origin() -> Point {
    return Point { x: 0, y: 0 };
  }
}
'''),
        isEmpty,
      );
    });

    test('for loop over range', () {
      expect(
        check('fn f() { for i in 0..10 { println(i); } }'),
        isEmpty,
      );
    });

    test('match with constructor patterns', () {
      expect(
        check('''
fn f(opt: Option<Int>) -> Int {
  return match opt {
    Some(x) => x,
    None => 0,
  };
}
'''),
        isEmpty,
      );
    });

    test('stdlib module import', () {
      expect(
        check('''
import std.fs

fn read(_ path: String) -> Result<String, Error> {
  return fs.read_text(path);
}
'''),
        isEmpty,
      );
    });

    test('interface and impl with Self', () {
      expect(
        check('''
interface Eq {
  fn eq(self, other: Self) -> Bool;
}

impl Eq for Int {
  fn eq(self, other: Self) -> Bool {
    return self == other;
  }
}
'''),
        isEmpty,
      );
    });

    test('a Hawk-bodied method on a primitive type checks', () {
      // Regression: `self` in `impl Int` was typed as an interface type wrapping
      // the Int element, while the return type resolved to the primitive — so
      // `return self + self` reported "expected Int, found Int". `self` must be
      // the primitive type, matching the value (and Self).
      expect(
        check('''
impl Int {
  fn double(self) -> Int { return self + self; }
  fn is_even(self) -> Bool { return self % 2 == 0; }
}
'''),
        isEmpty,
      );
    });

    test('lambda in map call is typed from the method signature', () {
      // No annotation on `x`: its type comes from `map`'s `(T) -> U` signature
      // with the receiver `List<Int>`.
      final errors = check('''
impl List<T> {
  fn map<U>(self, _ f: (T) -> U) -> List<U> { let r = []; return r; }
}
fn f(xs: List<Int>) { let ys = xs.map(x => x); }
''');
      print('=== ERRORS IN TEST: $errors');
      expect(
        errors,
        isEmpty,
      );
    });

    test('an un-annotated lambda with no context is an error', () {
      // `let g = n => n * n;` — no annotation, no expected type anywhere.
      expect(
        check('fn f() { let g = n => n * n; }'),
        contains(contains('cannot infer the type of lambda parameter')),
      );
    });

    test('cross-file import resolves symbols', () {
      const importSrc = '''
type Counts = { lines: Int, words: Int }
fn count(_ text: String) -> Counts {
  return Counts { lines: 0, words: 0 };
}
''';
      expect(
        check(
          '''
fn main(args: Args) -> Result<Int, Error> {
  let c = count('hello');
  return Result.Ok(0);
}
''',
          importSources: [importSrc],
        ),
        isEmpty,
      );
    });

    test('generics in return type', () {
      expect(
        check(
            'fn wrap(_ x: Int) -> Result<Int, Error> { return Result.Ok(x); }'),
        isEmpty,
      );
    });
  });

  // ---- unknown type ----

  group('unknown type', () {
    test('unknown param type', () {
      final errors = check('fn f(_ x: Baz) { }');
      expect(errors, contains('unknown type: Baz'));
    });

    test('unknown return type', () {
      final errors = check('fn f() -> Baz { }');
      expect(errors, contains('unknown type: Baz'));
    });

    test('unknown field type in struct', () {
      final errors = check('type Foo = { x: Unknown }');
      expect(errors, contains('unknown type: Unknown'));
    });

    test('unknown type arg inside Result', () {
      final errors = check('fn f() -> Result<Baz, Error> { }');
      expect(errors, contains('unknown type: Baz'));
    });

    test('known user type is not an error', () {
      final errors = check('''
type Point = { x: Int, y: Int }
fn f(_ p: Point) -> Point { return p; }
''');
      expect(errors, isEmpty);
    });

    test('let type annotation with unknown type', () {
      final errors = check('fn f() { let x: Nope = 0; }');
      expect(errors, contains('unknown type: Nope'));
    });
  });

  // ---- undefined name ----

  group('undefined name', () {
    test('call to undefined function', () {
      final errors = check('fn f() { bar(); }');
      expect(errors, contains('undefined name: bar'));
    });

    test('use of undefined variable', () {
      final errors = check('fn f() { let y = x; }');
      expect(errors, contains('undefined name: x'));
    });

    test('builtins are not errors', () {
      final errors = check('''
fn f() {
  println('hi');
  print('no newline');
  let a = Result.Ok(1);
  let b = Result.Err('bad');
  let c = Option.Some(42);
  let d = Option.None;
}
''');
      expect(errors, isEmpty);
    });

    test('function defined later is still visible (two-pass)', () {
      final errors = check('''
fn a() { b(); }
fn b() { }
''');
      expect(errors, isEmpty);
    });

    test('parameter is in scope', () {
      final errors = check('fn f(_ x: Int) { let y = x; }');
      expect(errors, isEmpty);
    });

    test('let binding is in scope after definition', () {
      final errors = check('fn f() { let x = 1; let y = x; }');
      expect(errors, isEmpty);
    });

    test('for loop variable is in scope inside body', () {
      final errors = check('fn f() { for i in 0..3 { let x = i; } }');
      expect(errors, isEmpty);
    });

    test('module alias is in scope', () {
      final errors = check('import std.fs\nfn f() { let x = fs; }');
      expect(errors, isEmpty);
    });
  });

  // ---- argument arity and labels ----

  group('call arity and labels', () {
    test('too few arguments', () {
      final errors = check('''
fn add(a: Int, b: Int) -> Int { return 0; }
fn f() { add(1); }
''');
      expect(errors.any((e) => e.contains('"add"') && e.contains('got 1')),
          isTrue);
    });

    test('too many arguments', () {
      final errors = check('''
fn add(a: Int, b: Int) -> Int { return 0; }
fn f() { add(1, 2, 3); }
''');
      expect(errors.any((e) => e.contains('"add"') && e.contains('got 3')),
          isTrue);
    });

    test('correct arity is not an error', () {
      final errors = check('''
fn add(a: Int, b: Int) -> Int { return 0; }
fn f() { add(1, 2); }
''');
      expect(errors, isEmpty);
    });

    test('argument with default value is optional', () {
      final errors = check('''
fn greet(name: String, times: Int = 1) { }
fn f() { greet(name: 'hi'); }
''');
      expect(errors, isEmpty);
    });

    test('unknown argument label', () {
      final errors = check('''
fn greet(name: String) { }
fn f() { greet(x: 'hi'); }
''');
      expect(errors.any((e) => e.contains('"x"')), isTrue);
    });

    test('correct label is not an error', () {
      final errors = check('''
fn greet(name: String) { }
fn f() { greet(name: 'hi'); }
''');
      expect(errors, isEmpty);
    });

    test('suppressed-label param accepts positional arg', () {
      final errors = check('''
fn print_it(_ msg: String) { }
fn f() { print_it('hello'); }
''');
      expect(errors, isEmpty);
    });
  });

  // ---- struct field checking ----

  group('struct fields', () {
    test('unknown field in struct literal', () {
      final errors = check('''
type Point = { x: Int, y: Int }
fn f() { let p = Point { x: 1, z: 2 }; }
''');
      expect(errors.any((e) => e.contains('"z"')), isTrue);
    });

    test('valid struct literal', () {
      final errors = check('''
type Point = { x: Int, y: Int }
fn f() { let p = Point { x: 1, y: 2 }; }
''');
      expect(errors, isEmpty);
    });
  });

  group('static dispatch', () {
    test('TypeName.method() is valid when type is declared', () {
      expect(
        check('''
type Point = { x: Int, y: Int }
impl Point {
  fn origin() -> Point { return Point { x: 0, y: 0 }; }
}
fn f() { let p = Point.origin(); }
'''),
        isEmpty,
      );
    });

    test('TypeName in field-access position is not an undefined-name error',
        () {
      expect(
        check('''
type Counter = { value: Int }
impl Counter {
  fn zero() -> Counter { return Counter { value: 0 }; }
}
fn f() -> Counter { return Counter.zero(); }
'''),
        isEmpty,
      );
    });
  });

  // ---- LSP integration: checker errors appear in diagnostics ----

  group('generic type parameters', () {
    test('type param T is valid in parameter and return types', () {
      expect(
        check('''
fn identity<T>(_ x: T) -> T { return x; }
'''),
        isEmpty,
      );
    });

    test('multiple type params are each valid', () {
      expect(
        check('''
fn assert_eq<T>(_ actual: T, _ expected: T) -> Result<Void, Error> {
  return Result.Ok(void);
}
'''),
        isEmpty,
      );
    });

    test('type param with bounds does not produce unknown-type error', () {
      expect(
        check('''
fn assert_eq<T: Eq + Debug>(_ actual: T, _ expected: T) -> Result<Void, Error> {
  return Result.Ok(void);
}
'''),
        isEmpty,
      );
    });

    test('unknown type not shadowed by type params is still an error', () {
      expect(
        check('fn f<T>(_ x: Ghost) -> T { return x; }'),
        contains('unknown type: Ghost'),
      );
    });
  });

  group('map literals', () {
    test('empty map is valid', () {
      expect(check("fn f() { let m = {}; }"), isEmpty);
    });

    test('string-keyed map is valid', () {
      expect(
        check("fn f() { let m = {'a': 1, 'b': 2}; }"),
        isEmpty,
      );
    });

    test('map value expressions are checked', () {
      expect(
        check("fn f() { let m = {'k': ghost()}; }"),
        contains('undefined name: ghost'),
      );
    });
  });

  group('const declarations', () {
    test('top-level const is visible as a name', () {
      expect(
        check('''
const SPACE: Int = 32;
fn f() -> Int { return SPACE; }
'''),
        isEmpty,
      );
    });

    test('multiple consts referencing each other', () {
      expect(
        check('''
const LOWER_A: Int = 97;
const LOWER_Z: Int = 122;
fn is_lower(_ cp: Int) -> Bool {
  return cp >= LOWER_A && cp <= LOWER_Z;
}
'''),
        isEmpty,
      );
    });
  });

  group('enum declarations', () {
    test('enum type is valid in type references', () {
      expect(
        check('''
enum Direction { North, South }
fn f(_ d: Direction) -> Direction { return d; }
'''),
        isEmpty,
      );
    });

    test('enum name is valid in expression position', () {
      expect(
        check('''
enum Direction { North, South }
fn f() { let d = Direction.North; }
'''),
        isEmpty,
      );
    });

    test('enum payload type is checked', () {
      expect(
        check('''
enum Shape { Circle(Ghost) }
'''),
        contains('unknown type: Ghost'),
      );
    });
  });

  group('type mismatches', () {
    test('return type mismatch is reported', () {
      expect(check('fn f() -> Int { return true; }'),
          contains('return type mismatch: expected Int, found Bool'));
    });

    test('matching return type is not an error', () {
      expect(check('fn f() -> Int { return 1 + 2; }'), isEmpty);
    });

    test('implicit Ok wrap: returning T from a Result fn is allowed', () {
      expect(check('fn f() -> Result<Int, Error> { return 5; }'), isEmpty);
      expect(check('fn f() -> Result<Int, Error> { return Result.Ok(5); }'),
          isEmpty);
    });

    test('let annotation mismatch is reported', () {
      expect(check("fn f() { let x: Int = 'hi'; }"),
          contains("binding 'x': expected Int, found String"));
    });

    test('matching let annotation is not an error', () {
      expect(check('fn f() { let x: Int = 7; }'), isEmpty);
    });

    test('non-Bool condition is reported', () {
      expect(check('fn f() { if 3 { } }'),
          contains('condition must be Bool, found Int'));
      expect(check('fn f() { while 1 + 1 { } }'),
          contains('condition must be Bool, found Int'));
    });

    test('Bool condition is not an error', () {
      expect(check('fn f(b: Bool) { if b { } while b { } }'), isEmpty);
      expect(check('fn f(x: Int) { if x > 0 { } }'), isEmpty);
    });

    test('unknown types never produce a false mismatch', () {
      // `ghost()` is undefined (reported separately); its unknown result type
      // must not also trigger a return/condition mismatch.
      final errors = check('fn f() -> Int { return ghost(); }');
      expect(errors, contains('undefined name: ghost'));
      expect(errors.any((e) => e.contains('mismatch')), isFalse);
    });

    test('argument type mismatch is reported', () {
      expect(
        check('fn add(a: Int, b: Int) -> Int { return 0; }\n'
            'fn f() { add(1, true); }'),
        contains('argument to "add": expected Int, found Bool'),
      );
    });

    test('labeled argument type mismatch is reported', () {
      expect(
        check("fn greet(name: String) { }\nfn f() { greet(name: 42); }"),
        contains('argument to "greet": expected String, found Int'),
      );
    });

    test('correct argument types are not an error', () {
      expect(
        check('fn add(a: Int, b: Int) -> Int { return 0; }\n'
            'fn f() { add(1, 2); }'),
        isEmpty,
      );
    });

    test('generic function arguments are lenient (no false mismatch)', () {
      expect(
        check('fn identity<T>(_ x: T) -> T { return x; }\n'
            'fn f() { let a = identity(1); let b = identity("hi"); }'),
        isEmpty,
      );
    });

    test('Option/Result element leniency on the error side', () {
      // None infers Option<?>; Ok(x) infers Result<_, ?> — the unspecified
      // side must stay assignable.
      expect(check('fn f() -> Option<Int> { return Option.None; }'), isEmpty);
      expect(check('fn f() -> Result<Int, Error> { return Result.Ok(1); }'),
          isEmpty);
    });
  });

  group('checker errors in LSP diagnostics', () {
    // Re-uses the LSP integration test infrastructure by directly calling the
    // LspServer diagnostics pipeline (via _publishDiagnostics tested in
    // lsp_server_test.dart). Here we verify through the public TypeChecker
    // that both kind of errors are reported.
    test('both unknown-type and undefined-name errors are returned', () {
      final errors = check('''
fn f(_ x: Ghost) {
  haunted();
}
''');
      expect(errors,
          containsAll(['unknown type: Ghost', 'undefined name: haunted']));
    });
  });

  // ---- generic declarations ----

  group('generic declarations', () {
    test('type parameters are in scope in field types', () {
      expect(check('type Box<T> = { value: T }'), isEmpty);
      expect(check('type Pair<K, V> = { k: K, v: V }'), isEmpty);
    });

    test('type parameters are in scope in enum variants', () {
      expect(check('enum Tree<T> { Leaf, Node(T) }'), isEmpty);
    });

    test('impl type parameters are in scope in method signatures', () {
      expect(
        check('type Box<T> = { value: T } '
            'impl Box<T> { fn get(self) -> T { return self.value; } }'),
        isEmpty,
      );
    });

    test('an undeclared type parameter is an unknown type', () {
      expect(check('type Box = { value: T }'), contains('unknown type: T'));
    });
  });

  // ---- interface conformance ----

  group('interface conformance', () {
    const display = 'interface Display { fn display(self) -> String; }';

    test('a complete, matching impl conforms', () {
      expect(
        check('$display\n'
            'type Tag = { n: Int }\n'
            'impl Display for Tag { fn display(self) -> String { return "t"; } }'),
        isEmpty,
      );
    });

    test('a missing interface method is reported', () {
      expect(
        check('$display\ntype Tag = { n: Int }\nimpl Display for Tag { }'),
        contains("missing method 'display' required by interface 'Display'"),
      );
    });

    test('a mismatched parameter type is reported', () {
      final errors = check('''
interface Greet { fn hello(self, _ n: Int) -> String; }
type Tag = { n: Int }
impl Greet for Tag { fn hello(self, _ n: Bool) -> String { return "h"; } }
''');
      expect(
        errors.any((e) =>
            e.contains("method 'hello'") && e.contains("interface 'Greet'")),
        isTrue,
        reason: errors.toString(),
      );
    });

    test('a mismatched return type is reported', () {
      final errors = check('''
interface Greet { fn hello(self) -> String; }
type Tag = { n: Int }
impl Greet for Tag { fn hello(self) -> Int { return 0; } }
''');
      expect(errors.any((e) => e.contains("method 'hello'")), isTrue,
          reason: errors.toString());
    });

    test('impl for an unknown interface is reported', () {
      expect(
        check('type Tag = { n: Int }\nimpl Nope for Tag { }'),
        contains('unknown interface: Nope'),
      );
    });

    test('impl for a non-interface is reported', () {
      expect(
        check('type Foo = { n: Int }\ntype Tag = { n: Int }\n'
            'impl Foo for Tag { }'),
        contains("'Foo' is not an interface"),
      );
    });

    test('conformance works for a primitive (Self = the primitive)', () {
      expect(
        check('interface Eq { fn eq(self, _ other: Self) -> Bool; }\n'
            'impl Eq for Int { fn eq(self, _ other: Self) -> Bool '
            '{ return self == other; } }'),
        isEmpty,
      );
    });
  });

  group('generic bounds', () {
    const display = '''
interface Display { fn display(self) -> String; }
type Dog = { name: String }
impl Display for Dog { fn display(self) -> String { return self.name; } }
type Plain = { n: Int }
fn label<T: Display>(_ x: T) -> String { return x.display(); }
''';

    test('a conforming type argument is accepted', () {
      expect(
          check(
              '$display\nfn m() -> String { return label(Dog { name: "x" }); }'),
          isEmpty);
    });

    test('a non-conforming struct argument is rejected', () {
      expect(
        check('$display\nfn m() -> String { return label(Plain { n: 1 }); }'),
        contains(contains('does not implement `Display`')),
      );
    });

    test('a primitive satisfies the built-in Display bound', () {
      // Primitives carry built-in Display (how println(5) works); the bound
      // holds at the type level even though dispatch on primitives is later.
      expect(check('$display\nfn m() -> String { return label(5); }'), isEmpty);
    });

    test('Eq is satisfied structurally (no explicit impl needed)', () {
      expect(
        check('type P = { n: Int }\n'
            'fn same<T: Eq>(_ a: T, _ b: T) -> Bool { return a == b; }\n'
            'fn m() -> Bool { return same(P { n: 1 }, P { n: 2 }); }'),
        isEmpty,
      );
    });
  });

  group('interface inheritance', () {
    const base = '''
interface Display { fn display(self) -> String; }
interface Named: Display { fn id(self) -> Int; }
''';

    test('implementing a sub-interface and its super is accepted', () {
      expect(
        check('${base}type W = { label: String, n: Int }\n'
            'impl Display for W { fn display(self) -> String { return self.label; } }\n'
            'impl Named for W { fn id(self) -> Int { return self.n; } }'),
        isEmpty,
      );
    });

    test('implementing a sub-interface without its super is rejected', () {
      expect(
        check('${base}type W = { n: Int }\n'
            'impl Named for W { fn id(self) -> Int { return self.n; } }'),
        contains(contains("extends 'Display'")),
      );
    });

    test('a sub-interface value is assignable where the super is expected', () {
      // `show` takes the super (`Display`); a `Named`-typed value flows in.
      expect(
        check('${base}fn show(_ d: Display) -> String { return d.display(); }\n'
            'fn use(_ n: Named) -> String { return show(n); }'),
        isEmpty,
      );
    });

    test('an inherited method resolves on a sub-interface value', () {
      // `display` is declared on the super; calling it on a `Named` value works.
      expect(
        check('${base}fn use(_ n: Named) -> String { return n.display(); }'),
        isEmpty,
      );
    });

    test('an unknown super-interface is reported', () {
      expect(
        check('interface Foo: Nope { fn f(self) -> Int; }'),
        contains('unknown super-interface: Nope'),
      );
    });

    test('a non-interface super is reported', () {
      expect(
        check('type T = { n: Int }\ninterface Foo: T { fn f(self) -> Int; }'),
        contains("'T' is not an interface"),
      );
    });

    test('a self-referential interface is reported as a cycle', () {
      expect(
        check('interface Foo: Foo { fn f(self) -> Int; }'),
        contains(contains('inheritance cycle')),
      );
    });

    test('a mutual inheritance cycle is reported', () {
      expect(
        check('interface A: B { fn a(self) -> Int; }\n'
            'interface B: A { fn b(self) -> Int; }'),
        contains(contains('inheritance cycle')),
      );
    });
  });
}
