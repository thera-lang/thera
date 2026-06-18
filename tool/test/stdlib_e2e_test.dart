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
    return Process.runSync(hawkBin, [out, ...args]);
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

  test('eprintln/eprint write to stderr, not stdout', () {
    final r = emitAndRun('eprintln', '''
fn main() -> Int {
    println('out line');
    eprintln('err line');
    eprint('err frag');
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, 'out line\n');
    expect(r.stderr, 'err line\nerr frag');
  });

  test('Bool == / != run end to end (structural eq, not the Int opcode)', () {
    // Regression: Bool is a distinct runtime value, so `==`/`!=` must lower to
    // the structural `eq` native — the `eqI64` opcode rejects a Bool operand.
    // (Surfaced by interface conformance, which compares `is_static` Bools.)
    final r = emitAndRun('booleq', '''
type Flag = { on: Bool }
fn main() -> Int {
    let a = true;
    let b = false;
    println(a == a);
    println(a != b);
    let x = Flag { on: true };
    let y = Flag { on: false };
    println(x.on != y.on);
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, 'true\ntrue\ntrue\n');
  });

  test('a user impl of an interface checks and runs (conformance path)', () {
    // Regression: type-checking a user `impl Iface for T` compares the
    // interface and impl method signatures, including their `is_static` Bools —
    // which previously trapped at runtime when the front-end ran in Hawk.
    final r = emitAndRun('conformance', '''
interface Greet { fn greet(self) -> Int }
type Counter = { n: Int }
impl Greet for Counter { pub fn greet(self) -> Int { return self.n; } }
fn main() -> Int {
    println(Counter { n: 7 }.greet());
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, '7\n');
  });

  test('an interface-typed parameter dispatches dynamically (call.virtual)',
      () {
    // `Display` is the std.core interface; `describe` takes it as a value, so
    // the concrete type is known only at runtime and dispatched via the vtable.
    final r = emitAndRun('dispatch', '''
type Dog = { name: String }
impl Display for Dog { fn display(self) -> String { return 'Dog(\${self.name})'; } }
type Cat = {}
impl Display for Cat { fn display(self) -> String { return 'a cat'; } }
fn describe(_ x: Display) -> String { return x.display(); }
fn main() -> Int {
    println(describe(Dog { name: 'Rex' }));
    println(describe(Cat {}));
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, 'Dog(Rex)\na cat\n');
  });

  test('tail expressions: block-bodied match arms and let-init blocks', () {
    // A `{…}` match arm and a `let`-initializer block each yield their final
    // expression (no `;`), instead of Unit — see docs/language.md. Statements
    // before the tail run for their effects.
    final r = emitAndRun('tailexpr', '''
enum Sign { Zero, Other }
fn classify(_ s: Sign, _ n: Int) -> String {
    let label = match s {
        Zero => { let z = 'zero'; 'is: ' + z },
        Other => {
            let doubled = n * 2;
            'doubled: ' + '\${doubled}'
        },
    };
    return label;
}
fn main() -> Int {
    let x = { let a = 3; a + 4 };   // block-expr tail
    println('\${x}');
    println(classify(Sign.Zero, 0));
    println(classify(Sign.Other, 5));
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, '7\nis: zero\ndoubled: 10\n');
  });

  test('bitwise operators run end to end (and/or/xor/not/shifts)', () {
    final r = emitAndRun('bitwise', '''
fn main() -> Int {
    let a = 12 & 10;       // 8
    let b = 12 | 10;       // 14
    let c = 12 ^ 10;       // 6
    let d = ~0;            // -1
    let e = 1 << 4;        // 16
    let f = -8 >> 1;       // -4  (arithmetic, sign-preserving)
    let g = -1 >>> 60;     // 15  (logical, zero-fill)
    let p = 1 + 1 << 2;    // 8   (shift looser than +)
    println('\${a} \${b} \${c} \${d} \${e} \${f} \${g} \${p}');
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, '8 14 6 -1 16 -4 15 8\n');
  });

  test('nested patterns: constructor destructuring with fall-through', () {
    // A nested constructor pattern (`Bin(Add, Num(a), Num(b))`) destructures
    // several levels deep and binds at the leaves; a non-matching subject falls
    // through to a later arm. Also exercises top-level literal patterns.
    final r = emitAndRun('nested', '''
enum Op { Add, Mul }
enum Expr { Num(Int), Bin(Op, Expr, Expr) }

// Constant-fold a literal `Num + Num`; otherwise leave the expression as-is.
fn fold(_ e: Expr) -> Expr {
    return match e {
        Bin(Add, Num(a), Num(b)) => Expr.Num(a + b),
        Bin(Mul, Num(a), Num(b)) => Expr.Num(a * b),
        other => other,
    };
}
fn value(_ e: Expr) -> Int {
    return match e {
        Num(n) => n,
        _ => -1,
    };
}
fn shape(_ n: Int) -> String {
    return match n {
        0 => 'none',
        1 => 'one',
        _ => 'many',
    };
}
fn main() -> Int {
    println('\${value(fold(Expr.Bin(Op.Add, Expr.Num(2), Expr.Num(3))))}'); // 5
    println('\${value(fold(Expr.Bin(Op.Mul, Expr.Num(4), Expr.Num(5))))}'); // 20
    // A Bin whose operands aren't both Num doesn't match the nested arms → -1.
    let nested = Expr.Bin(Op.Add, Expr.Bin(Op.Add, Expr.Num(1), Expr.Num(1)), Expr.Num(9));
    println('\${value(fold(nested))}'); // -1 (still a Bin, not a Num)
    println(shape(0));
    println(shape(7));
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, '5\n20\n-1\nnone\nmany\n');
  });

  test('if-expressions: value position, else-if chains, and if-tails', () {
    // `if` is usable in value position (docs/language.md stage 2): as a direct
    // value, as an `else if` chain, and as a block/match-arm tail.
    final r = emitAndRun('ifexpr', '''
enum Tag { Zero, Other }
fn max(_ a: Int, _ b: Int) -> Int { return if a > b { a } else { b }; }
fn grade(_ n: Int) -> String {
    return if n >= 90 { 'A' } else if n >= 80 { 'B' } else { 'C' };
}
fn describe(_ t: Tag, _ n: Int) -> String {
    return match t {
        Zero => 'zero',
        Other => {
            let doubled = n * 2;
            if doubled > 10 { 'big' } else { 'small' }   // if as a match-arm tail
        },
    };
}
fn main() -> Int {
    println('\${max(3, 7)}');
    println(grade(95));
    println(grade(85));
    println(grade(50));
    println(describe(Tag.Other, 2));
    println(describe(Tag.Other, 9));
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, '7\nA\nB\nC\nsmall\nbig\n');
  });

  test('a sub-interface dispatches inherited super-interface methods', () {
    // `Named` extends `Display`. A `Named`-typed value exposes the inherited
    // `display()` (and interpolates via it) plus its own `id()`; both dispatch
    // to Widget's concrete impls at runtime.
    final r = emitAndRun('inherit', '''
interface Named: Display { fn id(self) -> Int; }
type Widget = { label: String, n: Int }
impl Display for Widget { fn display(self) -> String { return self.label; } }
impl Named for Widget { fn id(self) -> Int { return self.n; } }
fn show(_ x: Named) -> String { return '\${x} #\${x.id()}'; }
fn main() -> Int {
    println(show(Widget { label: 'ok', n: 7 }));
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, 'ok #7\n');
  });

  test('hawk test runs @test functions and reports pass/fail', () {
    if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
    final dir = Directory.systemTemp.createTempSync('hawk_runner');
    File('${dir.path}/demo_test.hawk').writeAsStringSync('''
import std.testing;
@test
fn test_pass() -> Result<Void, Error> {
    testing.assert_eq(actual: 2 + 2, expected: 4)?;
    return Result.Ok(void);
}
@test
fn test_fail() -> Result<Void, Error> {
    testing.assert_eq(actual: 2 + 2, expected: 5)?;
    return Result.Ok(void);
}
''');
    final r = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'bin/hawk.dart', 'test', dir.path],
    );
    expect(r.exitCode, 1, reason: r.stderr.toString()); // one test failed
    expect(r.stdout, contains('ok    test_pass'));
    expect(r.stdout, contains('FAIL  test_fail'));
    expect(r.stdout, contains('assert_eq failed')); // the rendered message
    expect(r.stdout, contains('had failures'));
  });

  test('hawk test on an all-passing file exits 0', () {
    if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
    final dir = Directory.systemTemp.createTempSync('hawk_runner_ok');
    File('${dir.path}/ok_test.hawk').writeAsStringSync('''
import std.testing;
@test
fn test_ok() -> Result<Void, Error> {
    testing.assert(1 < 2)?;
    return Result.Ok(void);
}
''');
    final r = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'bin/hawk.dart', 'test', dir.path],
    );
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, contains('ok    test_ok'));
    expect(r.stdout, contains('All tests passed'));
  });

  test('testing.assert_eq runs: generic Eq/Debug under dynamic dispatch', () {
    // The @test-runner blocker: assert_eq<T: Eq + Debug> compares via virtual
    // eq and renders the failure message via the structural debug fallback.
    final r = emitAndRun('assert_eq', '''
import std.testing;
type Point = { x: Int, y: Int }
fn main() -> Result<Int, Error> {
    testing.assert_eq(actual: 2 + 2, expected: 4)?;
    testing.assert_eq(actual: Point { x: 1, y: 2 }, expected: Point { x: 1, y: 2 })?;
    testing.assert_eq(actual: Option.Some(7), expected: Option.Some(7))?;
    println('all passed');
    testing.assert_eq(actual: Point { x: 1, y: 2 }, expected: Point { x: 1, y: 3 })?;
    return Result.Ok(0);
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.stdout, 'all passed\n');
    expect(r.exitCode, 1); // the deliberate failure propagates
    expect(r.stderr, contains('assert_eq failed'));
    expect(r.stderr, contains('Point { 1, 2 }')); // structural debug rendering
    expect(r.stderr, contains('Point { 1, 3 }'));
  });

  test('primitives dispatch through the built-in Display/Eq fallbacks', () {
    final r = emitAndRun('prim_dispatch', '''
type Dog = { name: String }
impl Display for Dog { fn display(self) -> String { return 'Dog(\${self.name})'; } }
fn show<T: Display>(_ x: T) -> Void { println(x); }
fn same<T: Eq>(_ a: T, _ b: T) -> Bool { return a == b; }
fn main() -> Int {
    show(5);                       // Int: built-in Display fallback
    show('hi');                    // String likewise
    show(Dog { name: 'Fido' });    // struct: its impl row
    let mut n = 0;
    if same(1, 1) { n = n + 1; }
    if same([1, 2], [1, 2]) { n = n + 2; }
    return n;   // 3
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 3, reason: r.stderr.toString());
    expect(r.stdout, '5\nhi\nDog(Fido)\n');
  });

  test('an explicit impl Eq overrides structural equality under erasure', () {
    final r = emitAndRun('eq_override', '''
type CaseFold = { s: String }
impl Eq for CaseFold {
    fn eq(self, other: Self) -> Bool {
        return self.s.to_lowercase() == other.s.to_lowercase();
    }
}
fn same<T: Eq>(_ a: T, _ b: T) -> Bool { return a == b; }
fn main() -> Int {
    if same(CaseFold { s: 'Hawk' }, CaseFold { s: 'HAWK' }) { return 1; }
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 1, reason: r.stderr.toString());
  });

  test('a generic function bound by Display dispatches dynamically', () {
    final r = emitAndRun('generic_dispatch', '''
type Dog = { name: String }
impl Display for Dog { fn display(self) -> String { return 'Dog(\${self.name})'; } }
type Cat = {}
impl Display for Cat { fn display(self) -> String { return 'a cat'; } }
fn label<T: Display>(_ x: T) -> String { return 'val: \${x.display()}'; }
fn main() -> Int {
    println(label(Dog { name: 'Rex' }));   // erased T, dispatched at runtime
    println(label(Cat {}));
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, 'val: Dog(Rex)\nval: a cat\n');
  });

  test('interface types dispatch in field, return, and List positions', () {
    final r = emitAndRun('dispatch_positions', '''
type Dog = { name: String }
impl Display for Dog { fn display(self) -> String { return 'Dog(\${self.name})'; } }
type Cat = {}
impl Display for Cat { fn display(self) -> String { return 'a cat'; } }
type Box = { item: Display }
fn pick() -> Display { return Cat {}; }
fn main() -> Int {
    let b = Box { item: Dog { name: 'Rex' } };
    println(b.item.display());              // field-typed Display
    println(pick().display());              // return-typed Display
    let xs: List<Display> = [Dog { name: 'Fido' }, Cat {}];
    for x in xs { println(x.display()); }   // List<Display> element
    return 0;
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, 'Dog(Rex)\na cat\nDog(Fido)\na cat\n');
  });

  test('a function-valued struct field is callable as c.field(args)', () {
    // The capability-as-struct-of-closures pattern: inject a fake by
    // constructing the struct with a different closure.
    final r = emitAndRun('cap_field', '''
type Clock = { now: () -> Int }
fn expired(_ c: Clock, _ deadline: Int) -> Bool { return c.now() > deadline; }
fn main() -> Int {
    let fake = Clock { now: () => 42 };
    println('now=\${fake.now()}');             // 42
    println('expired=\${expired(fake, 10)}');  // true (42 > 10)
    return fake.now();                          // 42
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 42, reason: r.stderr.toString());
    expect(r.stdout, 'now=42\nexpired=true\n');
  });

  test('String.to_int/to_double parse end to end', () {
    final r = emitAndRun('parse', '''
fn main() -> Int {
    println('42=\${'42'.to_int().unwrap_or(-1)}');        // 42
    println('bad=\${'oops'.to_int().unwrap_or(-1)}');     // -1
    println('pi=\${'3.14'.to_double().unwrap_or(0.0)}');  // 3.14
    return '  7  '.trim().to_int().unwrap_or(0);          // 7
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 7, reason: r.stderr.toString());
    expect(r.stdout, '42=42\nbad=-1\npi=3.14\n');
  });

  test('std.math + Int/Double methods run end to end', () {
    final r = emitAndRun('math', '''
import std.math;
fn main() -> Int {
    println('abs=\${(-5).abs()}');            // 5 (Int, type-preserving)
    println('max=\${3.max(9)}');              // 9
    println('clamp=\${7.clamp(0, 5)}');       // 5
    println('floor=\${math.floor(3.7)}');     // 3 (Double)
    println('pow=\${math.pow(2.0, 10.0)}');   // 1024
    // Int -> math -> Int bridge: integer square root of 144.
    return math.sqrt(144.0.to_int().to_double()).to_int();   // 12
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 12, reason: r.stderr.toString());
    expect(r.stdout, 'abs=5\nmax=9\nclamp=5\nfloor=3\npow=1024\n');
  });

  test('String.chars()/bytes() and the from_chars round-trip run end to end',
      () {
    final r = emitAndRun('chars', '''
import std.char;
fn main() -> Int {
    let s = 'AbÉ';
    println('chars=\${s.chars().len()}');   // 3 code points
    println('bytes=\${s.bytes().len()}');   // 4 UTF-8 bytes (É is 2)
    println(String.from_chars('hi'.chars()));   // hi (round-trip)
    let mut digits = 0;
    for cp in '4 cats, 12 dogs'.chars() {
        if char.is_digit(cp) { digits = digits + 1; }
    }
    return digits;   // 3
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 3, reason: r.stderr.toString());
    expect(r.stdout, 'chars=3\nbytes=4\nhi\n');
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

  test('std.core auto-loads: error() constructs and interpolates via Display',
      () {
    final r = emitAndRun('core', '''
fn main() -> Result<Int, Error> {
    let e = error('kaboom');
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

    final r = Process.runSync(hawkBin, [out, data]);
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
        throw error('bad');
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

    final r = Process.runSync(hawkBin, [out]);
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

    final r = Process.runSync(hawkBin, [out]);
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(r.stdout, '20\n40\n60\nbig: 2\ntotal: 21\n');
  });

  test('examples/fibers.hawk runs and prints expected output', () {
    if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
    final dir = Directory.systemTemp.createTempSync('hawk_fib');
    final out = '${dir.path}/fibers.hawkbc';
    final emit = Process.runSync(
      Platform.resolvedExecutable,
      ['run', 'bin/hawk.dart', 'emit', '../examples/fibers.hawk', out],
    );
    expect(emit.exitCode, 0, reason: emit.stderr.toString());

    final r = Process.runSync(hawkBin, [out]);
    expect(r.exitCode, 0, reason: r.stderr.toString());
    expect(
        r.stdout,
        'sum of squares 1..5 = 55\n'
        'consumed 10 values, sum = 55\n');
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

    final r = Process.runSync(hawkBin, [out]);
    expect(r.exitCode, 42, reason: r.stderr.toString());
  });
}
