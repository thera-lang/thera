import 'dart:io';

import 'package:test/test.dart';

import 'runtime_harness.dart';

/// End-to-end tests that exercise the full pipeline with linked stdlib: emit
/// through the Dart CLI (so `std.*` sources are loaded and linked), then run the
/// resulting `.hawkbc` on the Rust runtime.
void main() {
  late final String? hawkBin = buildRuntime();

  /// Compile [source] via `hawk emit`, then run it with [args]. Returns the
  /// run's ProcessResult, or null if the toolchain is unavailable.
  ProcessResult? emitAndRun(String name, String source, List<String> args) {
    if (hawkBin == null) return null;
    final dir = Directory.systemTemp.createTempSync('hawk_$name');
    File('${dir.path}/prog.hawk').writeAsStringSync(source);
    final out = '${dir.path}/prog.hawkbc';
    final emit = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'bin/hawk.dart', 'emit', '${dir.path}/prog.hawk', out],
    );
    expect(emit.exitCode, 0, reason: 'emit failed: ${emit.stderr}');
    return Process.runSync(hawkBin, ['run', out, ...args]);
  }

  test('std.args (written in Hawk) links and parses a positional', () {
    final r = emitAndRun('args', '''
import std.cli;
fn main(parameters: List<String>) -> Result<Int, Error> {
    let first = cli.Args.new(parameters).positional(0).ok_or('need an arg')?;
    println(first);
    return Result.Ok(0);
}
''', ['alpha', 'beta']);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, 'alpha\n');
  });

  test('a missing positional propagates as an error (exit 1)', () {
    final r = emitAndRun('args_missing', '''
import std.cli;
fn main(parameters: List<String>) -> Result<Int, Error> {
    let first = cli.Args.new(parameters).positional(0).ok_or('need an arg')?;
    println(first);
    return Result.Ok(0);
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 1);
    expect(r.stderr, contains('need an arg'));
  });

  test('std.char constants and predicates run end to end', () {
    final r = emitAndRun('char', '''
import std.char;
fn main() -> Int {
    println('SPACE=\${char.SPACE}');
    if char.is_digit(char.DIGIT_0 + 5) { println('digit'); }
    if char.is_hex_digit(char.LOWER_A) { println('hex'); }
    if !char.is_hex_digit(char.LOWER_Z) { println('not-hex'); }
    return char.to_upper(char.LOWER_A);   // 'A' == 65
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 65, reason: r.stderr.toString());
    expect(r.stdout, 'SPACE=32\ndigit\nhex\nnot-hex\n');
  });

  test('top-level consts (bare + qualified) run end to end', () {
    final r = emitAndRun('consts', '''
const LIMIT: Int = 40;
const GREETING: String = 'hi';
fn main() -> Int {
    println(GREETING);
    println('over \${LIMIT}');
    return LIMIT + 2;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 42, reason: r.stderr.toString());
    expect(r.stdout, 'hi\nover 40\n');
  });

  test('std.path (pure Hawk) computes path pieces end to end', () {
    final r = emitAndRun('path', '''
import std.path;
fn main() -> Result<Int, Error> {
    println(path.join('src', 'main.hawk'));        // src/main.hawk
    println(path.join('src/', 'main.hawk'));       // src/main.hawk
    println(path.join('', 'main.hawk'));           // main.hawk
    println(path.dirname('src/main.hawk'));        // src
    println(path.dirname('main.hawk'));            // .
    println(path.dirname('/usr/bin/hawk'));        // /usr/bin
    println(path.dirname('/file'));                // /
    println(path.basename('/usr/bin/hawk'));       // hawk
    println(path.stem('archive.tar.gz'));          // archive.tar
    println(path.extension('src/main.hawk'));      // .hawk
    println(path.extension('Makefile'));           // (empty)
    println(path.extension('.bashrc'));            // (empty)
    println(path.with_extension('src/main.hawk', 'md'));  // src/main.md
    println(path.components('/usr/bin').join(','));        // ,usr,bin
    return Result.Ok(0);
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(
        r.stdout,
        'src/main.hawk\n'
        'src/main.hawk\n'
        'main.hawk\n'
        'src\n'
        '.\n'
        '/usr/bin\n'
        '/\n'
        'hawk\n'
        'archive.tar\n'
        '.hawk\n'
        '\n'
        '\n'
        'src/main.md\n'
        ',usr,bin\n');
  });

  test('std.path.is_absolute distinguishes absolute vs relative', () {
    final r = emitAndRun('path_abs', '''
import std.path;
fn main() -> Int {
    let mut n = 0;
    if path.is_absolute('/usr/bin') { n = n + 1; }
    if path.is_absolute('src/main') { n = n + 10; }   // false: not added
    return n;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 1, reason: r.stderr.toString());
  });

  test('std.core auto-loads: Error constructs and interpolates via Display',
      () {
    final r = emitAndRun('core', '''
fn main() -> Result<Int, Error> {
    let e = Error { message: 'kaboom' };
    println('e = \${e}');
    return Result.Ok(0);
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, 'e = kaboom\n');
  });

  test('wordcount: std.fs + std.args + String methods, end to end', () {
    if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
    final dir = Directory.systemTemp.createTempSync('hawk_wc');
    final data = '${dir.path}/input.txt';
    File(data).writeAsStringSync('the quick brown fox\njumps over\n');

    final out = '${dir.path}/wordcount.hawkbc';
    final emit = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'bin/hawk.dart', 'emit', '../examples/wordcount.hawk', out],
    );
    expect(emit.exitCode, 0, reason: emit.stderr.toString());

    final r = Process.runSync(hawkBin, ['run', out, data]);
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, '2\tlines\n6\twords\n31\tbytes\n');
  });

  test('List.fold with an un-annotated 2-arg lambda runs end to end', () {
    // `(acc, n) => acc + n` is un-annotated: `acc` is typed from the `0` seed
    // and `n` from the element type. Sum of 1..5 = 15.
    final r = emitAndRun('fold', '''
fn main() -> Int {
    return [1, 2, 3, 4, 5].fold(0, (acc, n) => acc + n);
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 15, reason: r.stderr.toString());
  });

  test('un-annotated lambdas typed from context run end to end', () {
    // None of these lambdas is annotated; each `n` is typed from context (the
    // map signature, the function parameter, the return type, the let
    // annotation). `n * n` would be untypable from its body alone.
    final r = emitAndRun('lambda_ctx', '''
fn apply(f: (Int) -> Int, _ x: Int) -> Int { return f(x); }
fn adder(by: Int) -> (Int) -> Int { return n => n + by; }
fn main() -> Int {
    let squares = [2, 3, 4].map(n => n * n);   // [4, 9, 16]
    let mut total = 0;
    for s in squares { total = total + s; }    // 29
    let viaApply = apply(n => n * 3, 5);        // 15
    let add10 = adder(10);                      // closure from a return
    let viaLet: (Int) -> Int = n => n * n;
    return total + viaApply + add10(2) + viaLet(6);  // 29+15+12+36 = 92
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 92, reason: r.stderr.toString());
  });

  test('annotated and multi-parameter lambdas run end to end', () {
    // (n: Int) => n * n is now well-typed via the annotation; a two-param
    // lambda is passed to a function-typed parameter. 9 + (4+5) = 18.
    final r = emitAndRun('lambda_annot', '''
fn apply2(f: (Int, Int) -> Int, _ a: Int, _ b: Int) -> Int { return f(a, b); }
fn main() -> Int {
    let sq = (n: Int) => n * n;
    let add = (a: Int, b: Int) => a + b;
    return sq(3) + apply2(add, 4, 5);
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 18, reason: r.stderr.toString());
  });

  test('a Result<Void, Error> function with Ok(void) runs end to end', () {
    // Exercises the `void` unit literal through `?` and a Result-returning main.
    final r = emitAndRun('void_unit', '''
fn check(_ ok: Bool) -> Result<Void, Error> {
    if !ok {
        throw Error { message: 'bad' };
    }
    return Result.Ok(void);
}
fn main() -> Result<Int, Error> {
    check(true)?;
    return Result.Ok(7);
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 7, reason: r.stderr.toString());
  });

  test('List.map/filter from the core prelude run end to end', () {
    // filter keeps n > 2 ([3,4,5]); map *10 ([30,40,50]); sum = 120.
    final r = emitAndRun('list_hof', '''
fn main() -> Int {
    let kept = [1, 2, 3, 4, 5].filter(n => n > 2);
    let doubled = kept.map(n => n * 10);
    let mut sum = 0;
    for x in doubled {
        sum = sum + x;
    }
    return sum;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 120, reason: r.stderr.toString());
  });

  test('examples/closures.hawk runs and prints expected output', () {
    if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
    final dir = Directory.systemTemp.createTempSync('hawk_clo');
    final out = '${dir.path}/closures.hawkbc';
    final emit = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'bin/hawk.dart', 'emit', '../examples/closures.hawk', out],
    );
    expect(emit.exitCode, 0, reason: emit.stderr.toString());

    final r = Process.runSync(hawkBin, ['run', out]);
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(
        r.stdout,
        'triple(6)        = 18\n'
        'shift(5)         = 105\n'
        'apply(triple, 9) = 27\n'
        'add10(32)        = 42\n');
  });

  test('examples/list_hof.hawk runs and prints expected output', () {
    if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
    final dir = Directory.systemTemp.createTempSync('hawk_hof');
    final out = '${dir.path}/list_hof.hawkbc';
    final emit = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'bin/hawk.dart', 'emit', '../examples/list_hof.hawk', out],
    );
    expect(emit.exitCode, 0, reason: emit.stderr.toString());

    final r = Process.runSync(hawkBin, ['run', out]);
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, '20\n40\n60\nbig: 2\ntotal: 21\n');
  });

  test('static methods on built-in types run', () {
    // impl on a primitive: `Int.answer()` + a chained call off a String static
    // method (5 + 42 = 47 -> exit code 47).
    final r = emitAndRun('static_builtin', '''
impl Int { fn answer() -> Int { return 42; } }
impl String { fn greeting() -> String { return 'hello'; } }
fn main() -> Int { return Int.answer() + String.greeting().len(); }
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 47, reason: r.stderr.toString());
  });

  test('a native static method on a built-in type runs', () {
    // String.from_chars([104, 105]) == 'hi' -> .len() == 2 -> exit 2.
    final r = emitAndRun('native_static', '''
impl String {
  @extern('str_from_chars') native fn from_chars(_ cps: List<Int>) -> String
}
fn main() -> Int { return String.from_chars([104, 105]).len(); }
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 2, reason: r.stderr.toString());
  });

  test('String.from_chars comes from the auto-loaded core prelude', () {
    // No inline impl — String.from_chars is provided by std/core/string.hawk.
    final r = emitAndRun('core_from_chars', '''
fn main() -> Int { return String.from_chars([72, 105]).len(); }
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 2, reason: r.stderr.toString());
  });

  test('qualified namespace access across files runs end to end', () {
    if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
    final dir = Directory.systemTemp.createTempSync('hawk_ns');
    File('${dir.path}/geo.hawk').writeAsStringSync('''
pub fn area(_ w: Int, _ h: Int) -> Int { return w * h; }
pub type Point = { x: Int, y: Int }
impl Point {
  fn origin() -> Point { return Point { x: 0, y: 0 }; }
}
pub enum Dir { North, South }
''');
    // Exercises ns.fn (geo.area), ns.Type.method (geo.Point.origin), and
    // ns.Enum.Variant (geo.Dir.North). Returns 42 -> exit code 42.
    File('${dir.path}/app.hawk').writeAsStringSync('''
import geo;
fn main() -> Int {
    let p = geo.Point.origin();
    let d = geo.Dir.North;
    return geo.area(6, 7) + p.x;
}
''');
    final out = '${dir.path}/app.hawkbc';
    final emit = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'bin/hawk.dart', 'emit', '${dir.path}/app.hawk', out],
    );
    expect(emit.exitCode, 0, reason: emit.stderr.toString());

    final r = Process.runSync(hawkBin, ['run', out]);
    expect(r.exitCode, 42, reason: r.stderr.toString());
  });
}
