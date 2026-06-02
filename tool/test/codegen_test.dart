import 'dart:io';

import 'package:hawk/src/bytecode/encoder.dart';
import 'package:hawk/src/bytecode/instr.dart';
import 'package:hawk/src/bytecode/module.dart';
import 'package:hawk/src/codegen/codegen.dart';
import 'package:hawk/src/lexer.dart';
import 'package:hawk/src/parser.dart';
import 'package:test/test.dart';

import 'runtime_harness.dart';

Module compile(String source) {
  final lex = Lexer(source).tokenize();
  expect(lex.hasErrors, isFalse, reason: lex.errors.join('\n'));
  final parsed = Parser(lex.tokens).parse();
  expect(parsed.hasErrors, isFalse, reason: parsed.errors.join('\n'));
  return compileProgram(parsed.program);
}

void main() {
  group('codegen lowering', () {
    test('println + return lowers to the expected stream', () {
      final m = compile('''
fn main() -> Int {
    println('hello, world');
    return 0;
}
''');
      expect(m.functions, hasLength(1));
      final main = m.functions.single;
      expect(main.name, 'main');
      expect(main.paramCount, 0);

      final ops = main.code;
      expect(ops[0], isA<ConstStr>().having((i) => i.value, 'value', 'hello, world'));
      expect(ops[1], isA<CallNative>()
          .having((i) => i.name, 'name', 'println')
          .having((i) => i.argc, 'argc', 1));
      expect(ops[2], isA<Simple>().having((i) => i.op, 'op', Op.pop));
      expect(ops[3], isA<ConstInt>().having((i) => i.value, 'value', 0));
      expect(ops[4], isA<Simple>().having((i) => i.op, 'op', Op.return_));
    });

    test('a function with no trailing return still ends in one', () {
      final m = compile('fn main() { println(\'hi\'); }');
      final last = m.functions.single.code.last;
      expect(last, isA<Simple>().having((i) => i.op, 'op', Op.return_));
    });

    test('locals and integer arithmetic', () {
      final m = compile('fn f() -> Int { let x = 3; return x * x - 1; }');
      final ops = m.functions.single.code;
      expect(ops[0], isA<ConstInt>().having((i) => i.value, 'value', 3));
      expect(ops[1], isA<Store>().having((i) => i.slot, 'slot', 0));
      expect(ops[2], isA<Load>().having((i) => i.slot, 'slot', 0));
      expect(ops[3], isA<Load>().having((i) => i.slot, 'slot', 0));
      expect(ops[4], isA<Simple>().having((i) => i.op, 'op', Op.mulI64));
      expect(ops[5], isA<ConstInt>().having((i) => i.value, 'value', 1));
      expect(ops[6], isA<Simple>().having((i) => i.op, 'op', Op.subI64));
      expect(ops[7], isA<Simple>().having((i) => i.op, 'op', Op.return_));
    });

    test('a Double binding selects float opcodes', () {
      final m = compile('fn f() -> Double { let x = 1.5; return x + x; }');
      expect(m.functions.single.code, contains(isA<Simple>()
          .having((i) => i.op, 'op', Op.addF64)));
    });

    test('comparison and unary operators', () {
      final lt = compile('fn f() -> Bool { return 1 < 2; }').functions.single.code;
      expect(lt, contains(isA<Simple>().having((i) => i.op, 'op', Op.ltI64)));

      final neg = compile('fn f() -> Int { let x = 5; return -x; }').functions.single.code;
      expect(neg, contains(isA<Simple>().having((i) => i.op, 'op', Op.negI64)));

      final not = compile('fn f() -> Bool { return !true; }').functions.single.code;
      expect(not, contains(isA<Simple>().having((i) => i.op, 'op', Op.not)));
    });

    test('assignment to a mutable local', () {
      final m = compile('fn f() -> Int { let mut x = 1; x = 2; return x; }');
      final ops = m.functions.single.code;
      // let x = 1 (slot 0), then x = 2 re-stores into slot 0.
      expect(ops[1], isA<Store>().having((i) => i.slot, 'slot', 0));
      expect(ops[3], isA<Store>().having((i) => i.slot, 'slot', 0));
    });

    test('if/else lowers to the expected jump structure', () {
      final m = compile('fn f() -> Int { if true { return 1; } else { return 2; } }');
      final ops = m.functions.single.code;
      // 0 const.bool, 1 jump_if_false->else, 2 const 1, 3 return,
      // 4 jump->end, 5 const 2 (else), 6 return, 7 const.unit, 8 return.
      expect(ops[1], isA<JumpIfFalse>().having((i) => i.target, 'target', 5));
      expect(ops[4], isA<Jump>().having((i) => i.target, 'target', 7));
      expect(ops[5], isA<ConstInt>().having((i) => i.value, 'value', 2));
    });

    test('short-circuit && lowers to branches', () {
      final ops =
          compile('fn f() -> Bool { return true && false; }').functions.single.code;
      expect(ops.whereType<JumpIfFalse>(), isNotEmpty);
      // && yields `false` on the short-circuit path.
      expect(ops.whereType<ConstBool>().map((i) => i.value), contains(false));
    });

    test('a direct call resolves to the callee function index', () {
      // helper is declared first (index 0); main calls it.
      final m = compile(
          'fn helper() -> Int { return 1; } fn main() -> Int { return helper(); }');
      final main = m.functions[1];
      expect(main.code.first, isA<Call>()
          .having((i) => i.func, 'func', 0)
          .having((i) => i.argc, 'argc', 0));
    });

    test('interpolation lowers to stringify + str_concat', () {
      final ops = compile(
              "fn f() -> Int { let n = 5; println('n=\${n}'); return 0; }")
          .functions
          .single
          .code;
      expect(ops, containsAllInOrder([
        isA<ConstStr>().having((i) => i.value, 'value', 'n='),
        isA<Load>(),
        isA<CallNative>().having((i) => i.name, 'name', 'stringify'),
        isA<CallNative>().having((i) => i.name, 'name', 'str_concat'),
      ]));
    });

    test('Ok constructs a Result enum', () {
      final ops = compile('fn f() -> Int { let x = Ok(0); return 0; }')
          .functions
          .single
          .code;
      expect(ops, containsAllInOrder([
        isA<ConstInt>().having((i) => i.value, 'value', 0),
        isA<EnumNew>()
            .having((i) => i.type, 'type', 0)
            .having((i) => i.variant, 'variant', 0)
            .having((i) => i.fieldCount, 'fieldCount', 1),
      ]));
    });

    test('bare return in a Result fn implicitly wraps in Ok', () {
      final ops = compile('fn f() -> Result<Int, Int> { return 5; }')
          .functions
          .single
          .code;
      // const 5, enum.new Result/Ok, return — exactly one wrap.
      expect(ops.whereType<EnumNew>(), hasLength(1));
      expect(ops.whereType<EnumNew>().single,
          isA<EnumNew>().having((i) => i.variant, 'variant', 0));
    });

    test('explicit Ok is not double-wrapped', () {
      final ops = compile('fn f() -> Result<Int, Int> { return Ok(5); }')
          .functions
          .single
          .code;
      expect(ops.whereType<EnumNew>(), hasLength(1));
    });

    test('? lowers to dup/enum.tag/enum.get', () {
      final m = compile('''
fn g() -> Result<Int, Int> { return 0; }
fn f() -> Result<Int, Int> { let x = g()?; return x; }
''');
      final ops = m.functions[1].code; // f
      expect(ops, containsAllInOrder([
        isA<Simple>().having((i) => i.op, 'op', Op.dup),
        isA<Simple>().having((i) => i.op, 'op', Op.enumTag),
        isA<EnumGet>().having((i) => i.index, 'index', 0),
      ]));
    });

    test('a struct declaration becomes a type-table entry', () {
      final m = compile(
          'type Point = { x: Int, y: Int } fn f() -> Int { return 0; }');
      expect(m.types, hasLength(1));
      expect(m.types.single.name, 'Point');
      expect(m.types.single.fieldCount, 2);
    });

    test('struct literal pushes fields in declaration order, then struct.new', () {
      // Written y-first, but x is declared first → its value (1) is pushed first.
      final ops = compile(
              'type Point = { x: Int, y: Int } '
              'fn f() -> Int { let p = Point { y: 2, x: 1 }; return p.x; }')
          .functions
          .single
          .code;
      final ints = ops.whereType<ConstInt>().map((i) => i.value).toList();
      expect(ints.take(2), [1, 2]);
      expect(ops, contains(isA<StructNew>().having((i) => i.type, 'type', 0)));
      expect(ops, contains(isA<FieldGet>().having((i) => i.index, 'index', 0)));
    });

    test('field assignment lowers to field.set', () {
      final ops = compile(
              'type C = { n: Int } '
              'fn f() -> Int { let mut c = C { n: 1 }; c.n = 5; return c.n; }')
          .functions
          .single
          .code;
      expect(ops, contains(isA<FieldSet>().having((i) => i.index, 'index', 0)));
    });

    test('named arguments are reordered to parameter order', () {
      final m = compile('''
type Point = { x: Int, y: Int }
impl Point { fn make(x: Int, y: Int) -> Point { return Point { x: x, y: y }; } }
fn main() -> Int { let p = Point.make(y: 2, x: 40); return 0; }
''');
      final main = m.functions.firstWhere((f) => f.name == 'main');
      // Written (y: 2, x: 40), but x is the first parameter → 40 is pushed first.
      expect(main.code.whereType<ConstInt>().take(2).map((i) => i.value),
          [40, 2]);
      expect(main.code, contains(isA<Call>().having((i) => i.argc, 'argc', 2)));
    });

    test('an instance method call pushes self then args', () {
      final m = compile('''
type V = { n: Int }
impl V { fn bump(self, by: Int) -> Int { return self.n + by; } }
fn main() -> Int { let v = V { n: 1 }; return v.bump(5); }
''');
      final main = m.functions.firstWhere((f) => f.name == 'main');
      // self (load v) + one arg → argc 2.
      expect(main.code, contains(isA<Call>().having((i) => i.argc, 'argc', 2)));
    });

    test('method names are mangled as Type.method', () {
      final m = compile(
          'type V = { n: Int } impl V { fn get(self) -> Int { return self.n; } }');
      expect(m.functions.map((f) => f.name), contains('V.get'));
    });

    test('list literal lowers to list.new', () {
      final ops =
          compile('fn f() -> Int { let xs = [1, 2, 3]; return 0; }')
              .functions
              .single
              .code;
      expect(ops, containsAllInOrder([
        isA<ConstInt>().having((i) => i.value, 'v', 1),
        isA<ConstInt>().having((i) => i.value, 'v', 2),
        isA<ConstInt>().having((i) => i.value, 'v', 3),
        isA<ListNew>().having((i) => i.count, 'count', 3),
      ]));
    });

    test('map literal lowers to map_new with 2N args', () {
      final ops =
          compile('fn f() -> Int { let m = {1: 10, 2: 20}; return 0; }')
              .functions
              .single
              .code;
      expect(ops, contains(isA<CallNative>()
          .having((i) => i.name, 'name', 'map_new')
          .having((i) => i.argc, 'argc', 4)));
    });

    test('indexing and indexed assignment use the right natives', () {
      final read = compile(
              'fn f() -> Int { let xs = [1]; return xs[0]; }')
          .functions
          .single
          .code;
      expect(read, contains(
          isA<CallNative>().having((i) => i.name, 'name', 'list_index')));

      final write = compile(
              'fn f() -> Int { let mut xs = [1]; xs[0] = 9; return 0; }')
          .functions
          .single
          .code;
      expect(write, contains(
          isA<CallNative>().having((i) => i.name, 'name', 'list_set')));
    });

    test('a collection method lowers to a native with the receiver first', () {
      final ops = compile('fn f() -> Int { let xs = [1, 2]; return xs.len(); }')
          .functions
          .single
          .code;
      // load xs, list_len(self) → argc 1.
      expect(ops, contains(isA<CallNative>()
          .having((i) => i.name, 'name', 'list_len')
          .having((i) => i.argc, 'argc', 1)));
    });

    test('== on strings lowers to the structural eq native', () {
      final eq = compile("fn f() -> Bool { return 'a' == 'b'; }")
          .functions
          .single
          .code;
      expect(eq, contains(
          isA<CallNative>().having((i) => i.name, 'name', 'eq')));
      expect(eq, isNot(contains(
          isA<Simple>().having((i) => i.op, 'op', Op.eqI64))));

      // `!=` is `eq` then `not`.
      final ne = compile("fn f() -> Bool { return 'a' != 'b'; }")
          .functions
          .single
          .code;
      expect(ne, containsAllInOrder([
        isA<CallNative>().having((i) => i.name, 'name', 'eq'),
        isA<Simple>().having((i) => i.op, 'op', Op.not),
      ]));
    });

    test('== on Int still uses the typed opcode', () {
      final ops = compile('fn f() -> Bool { return 1 == 2; }')
          .functions
          .single
          .code;
      expect(ops, contains(isA<Simple>().having((i) => i.op, 'op', Op.eqI64)));
    });

    test('a String method lowers to its native with the receiver first', () {
      final ops = compile("fn f() -> Int { let s = 'hi'; return s.len(); }")
          .functions
          .single
          .code;
      expect(ops, contains(isA<CallNative>()
          .having((i) => i.name, 'name', 'str_len')
          .having((i) => i.argc, 'argc', 1)));
    });
  });

  group('end-to-end (requires the Rust runtime)', () {
    late final String? hawkBin = buildRuntime();

    test('compiled program prints and exits', () {
      if (hawkBin == null) {
        markTestSkipped('Rust runtime unavailable');
        return;
      }
      final m = compile('''
fn main() -> Int {
    println('hello from hawk');
    return 7;
}
''');
      final tmp = '${Directory.systemTemp.path}/hawk_codegen_e2e.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));

      final r = Process.runSync(hawkBin, ['run', tmp]);
      expect(r.stdout, 'hello from hawk\n');
      expect(r.exitCode, 7);
    });

    test('computed arithmetic flows through to the exit code', () {
      if (hawkBin == null) {
        markTestSkipped('Rust runtime unavailable');
        return;
      }
      final m = compile('''
fn main() -> Int {
    let a = 20;
    let b = 22;
    return a + b;
}
''');
      final tmp = '${Directory.systemTemp.path}/hawk_codegen_arith.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));

      final r = Process.runSync(hawkBin, ['run', tmp]);
      expect(r.exitCode, 42);
    });

    int runExit(String name, String source) {
      final m = compile(source);
      final tmp = '${Directory.systemTemp.path}/hawk_cf_$name.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      return Process.runSync(hawkBin!, ['run', tmp]).exitCode;
    }

    test('for-loop sum', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('for', '''
fn main() -> Int {
    let mut sum = 0;
    for i in 1..5 {
        sum = sum + i;
    }
    return sum;
}
'''),
          10); // 1+2+3+4
    });

    test('while loop', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('while', '''
fn main() -> Int {
    let mut n = 5;
    let mut acc = 0;
    while n > 0 {
        acc = acc + n;
        n = n - 1;
    }
    return acc;
}
'''),
          15); // 5+4+3+2+1
    });

    test('if/else picks a branch', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('if', 'fn main() -> Int { let x = 7; if x > 5 { return 1; } else { return 2; } }'),
          1);
    });

    test('&& short-circuits (the right side, which would trap, is skipped)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      // If `&&` evaluated its RHS, `10 / 0` would trap (non-zero exit). A clean
      // exit 9 proves the RHS was never reached.
      expect(
          runExit('and_sc', '''
fn main() -> Int {
    let f = false;
    if f && (10 / 0 > 0) {
        return 1;
    }
    return 9;
}
'''),
          9);
    });

    test('recursion (factorial) flows to the exit code', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('fact', '''
fn fact(n: Int) -> Int {
    if n <= 1 { return 1; }
    return n * fact(n - 1);
}
fn main() -> Int {
    return fact(5);
}
'''),
          120);
    });

    test('multi-function call + interpolation prints the demo', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final m = compile('''
fn double(n: Int) -> Int { return n * 2; }
fn main() -> Int {
    println('double(21) = \${double(21)}');
    return 0;
}
''');
      final tmp = '${Directory.systemTemp.path}/hawk_demo_src.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      final r = Process.runSync(hawkBin, ['run', tmp]);
      expect(r.stdout, 'double(21) = 42\n');
      expect(r.exitCode, 0);
    });

    // throw + implicit Ok + match over Result, both branches.
    const safeDiv = '''
fn safe_div(a: Int, b: Int) -> Result<Int, Int> {
    if b == 0 { throw 7; }
    return a / b;
}
fn main() -> Int {
    match safe_div(DIVIDEND, DIVISOR) {
        Ok(v) => return v,
        Err(e) => return e,
    }
}
''';

    test('match takes the Ok branch (implicit-Ok success path)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final src = safeDiv.replaceAll('DIVIDEND', '84').replaceAll('DIVISOR', '2');
      expect(runExit('ok', src), 42);
    });

    test('match takes the Err branch (throw path)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final src = safeDiv.replaceAll('DIVIDEND', '1').replaceAll('DIVISOR', '0');
      expect(runExit('err', src), 7);
    });

    test('? propagates through Result and implicit Ok', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('propagate', '''
fn half(x: Int) -> Result<Int, Int> {
    if x % 2 != 0 { throw 9; }
    return x / 2;
}
fn run() -> Result<Int, Int> {
    let a = half(84)?;
    return a;
}
fn main() -> Int {
    match run() {
        Ok(v) => return v,
        Err(e) => return e,
    }
}
'''),
          42);
    });

    test('Option Some/None construction and match', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('option', '''
fn first_positive(a: Int) -> Option<Int> {
    if a > 0 { return Some(a); }
    return None;
}
fn main() -> Int {
    match first_positive(7) {
        Some(v) => return v,
        None => return 0,
    }
}
'''),
          7);
    });

    test('struct literal + field read', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('struct', '''
type Point = { x: Int, y: Int }
fn main() -> Int {
    let p = Point { y: 2, x: 40 };
    return p.x + p.y;
}
'''),
          42);
    });

    test('mutable field assignment', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('field_set', '''
type Counter = { n: Int }
fn main() -> Int {
    let mut c = Counter { n: 0 };
    c.n = 42;
    return c.n;
}
'''),
          42);
    });

    test('nested struct field access', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('nested', '''
type Point = { x: Int, y: Int }
type Rect = { top_left: Point, w: Int }
fn main() -> Int {
    let r = Rect { top_left: Point { x: 10, y: 20 }, w: 5 };
    return r.top_left.x + r.top_left.y + r.w;
}
'''),
          35);
    });

    test('instance method call', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('method', '''
type Point = { x: Int, y: Int }
impl Point {
    fn sum(self) -> Int { return self.x + self.y; }
}
fn main() -> Int {
    let p = Point { x: 40, y: 2 };
    return p.sum();
}
'''),
          42);
    });

    test('static method with named (reordered) arguments', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('static', '''
type Point = { x: Int, y: Int }
impl Point {
    fn make(x: Int, y: Int) -> Point { return Point { x: x, y: y }; }
    fn sum(self) -> Int { return self.x + self.y; }
}
fn main() -> Int {
    let p = Point.make(y: 2, x: 40);
    return p.sum();
}
'''),
          42);
    });

    test('method call with args, chained on the result', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('chain', '''
type Point = { x: Int, y: Int }
impl Point {
    fn translate(self, dx: Int, dy: Int) -> Point {
        return Point { x: self.x + dx, y: self.y + dy };
    }
    fn sum(self) -> Int { return self.x + self.y; }
}
fn main() -> Int {
    let p = Point { x: 10, y: 20 };
    return p.translate(5, 7).sum();
}
'''),
          42);
    });

    test('the structs.hawk example compiles', () {
      final m = compile(File('../examples/structs.hawk').readAsStringSync());
      expect(m.functions, isNotEmpty);
      expect(m.types.map((t) => t.name), containsAll(['Point', 'Rect']));
    });

    test('list literal + indexing', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('list', '''
fn main() -> Int {
    let xs = [10, 20, 12];
    return xs[0] + xs[1] + xs[2];
}
'''),
          42);
    });

    test('list mutation, len, and for-in iteration', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('list_iter', '''
fn main() -> Int {
    let mut xs = [1, 2, 3];
    xs[0] = 40;
    let mut total = 0;
    for v in xs {
        total = total + v;
    }
    return total;
}
'''),
          45); // 40 + 2 + 3
    });

    test('map literal, indexed assignment, and indexing', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('map', '''
fn main() -> Int {
    let mut m = {1: 0, 2: 2};
    m[1] = 40;
    return m[1] + m[2];
}
'''),
          42);
    });

    test('map.has and map.len', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('map_methods', '''
fn main() -> Int {
    let m = {7: 99};
    if m.has(7) {
        return m.len() + m[7];
    }
    return 0;
}
'''),
          100); // 1 + 99
    });

    test('list.get returns an Option', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('list_get', '''
fn main() -> Int {
    let xs = [5, 6, 7];
    match xs.get(1) {
        Some(v) => return v,
        None => return 0,
    }
}
'''),
          6);
    });

    test('string equality (structural)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('streq', '''
fn main() -> Int {
    let a = 'hello';
    let b = 'hello';
    if a == b { return 1; }
    return 0;
}
'''),
          1);
    });

    test('String methods: len, trim, split_whitespace, contains', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('strlen', "fn main() -> Int { return 'hello world'.len(); }"),
          11);
      expect(
          runExit('strtrim',
              "fn main() -> Int { let s = '  hi  '; return s.trim().len(); }"),
          2);
      expect(
          runExit('strsplit',
              "fn main() -> Int { return 'the quick brown fox'.split_whitespace().len(); }"),
          4);
      expect(
          runExit('strcontains', '''
fn main() -> Int {
    let s = 'hello';
    if s.contains('ell') { return 1; }
    return 0;
}
'''),
          1);
    });

    test('struct equality (structural)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('structeq', '''
type P = { x: Int, y: Int }
fn main() -> Int {
    let a = P { x: 1, y: 2 };
    let b = P { x: 1, y: 2 };
    let c = P { x: 9, y: 9 };
    let mut n = 0;
    if a == b { n = n + 1; }
    if a != c { n = n + 10; }
    return n;
}
'''),
          11);
    });

    // --- entry / args convention ---

    test('a Result-returning main unwraps Ok to the exit code', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('ret_ok', 'fn main() -> Result<Int, Int> { return 42; }'), 42);
    });

    test('a Result-returning main reports Err and exits 1', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final m = compile('fn main() -> Result<Int, Int> { throw 7; }');
      final tmp = '${Directory.systemTemp.path}/hawk_ret_err.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      final r = Process.runSync(hawkBin, ['run', tmp]);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('error: 7'));
    });

    test('main receives program arguments as a List<String>', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final m = compile(
          'fn main(args: List<String>) -> Int { return args.len(); }');
      final tmp = '${Directory.systemTemp.path}/hawk_argv.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      final r = Process.runSync(hawkBin, ['run', tmp, 'a', 'b', 'c']);
      expect(r.exitCode, 3);
    });
  });
}
