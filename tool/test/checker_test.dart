import 'package:aero/src/checker/type_checker.dart';
import 'package:aero/src/lexer.dart';
import 'package:aero/src/parser.dart';
import 'package:test/test.dart';

/// Parse [source] and run the type checker on it. Returns the list of error
/// messages (without file/line prefix) for easy assertion.
List<String> check(String source, {List<String> importSources = const []}) {
  final lex = Lexer(source).tokenize();
  expect(lex.hasErrors, isFalse, reason: 'unexpected lex errors: ${lex.errors}');
  final parse = Parser(lex.tokens).parse();
  expect(parse.hasErrors, isFalse,
      reason: 'unexpected parse errors: ${parse.errors}');

  final checker = TypeChecker();

  // Pre-register any provided import programs.
  for (final src in importSources) {
    final importLex = Lexer(src).tokenize();
    final importParse = Parser(importLex.tokens).parse();
    checker.addProgram(importParse.program);
  }

  return checker
      .check(parse.program)
      .errors
      .map((e) => e.message)
      .toList();
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
  return Ok(0);
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

    test('lambda in map call', () {
      expect(
        check('fn f(xs: List<Int>) { let ys = xs.map(x => x); }'),
        isEmpty,
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
  return Ok(0);
}
''',
          importSources: [importSrc],
        ),
        isEmpty,
      );
    });

    test('generics in return type', () {
      expect(
        check('fn wrap(_ x: Int) -> Result<Int, Error> { return Ok(x); }'),
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
  eprintln('err');
  let a = Ok(1);
  let b = Err('bad');
  let c = Some(42);
  let d = None;
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

  // ---- LSP integration: checker errors appear in diagnostics ----

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
      expect(errors, containsAll(['unknown type: Ghost', 'undefined name: haunted']));
    });
  });
}
