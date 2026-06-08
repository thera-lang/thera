import 'dart:io';

import 'package:hawk/src/ast.dart';
import 'package:hawk/src/bytecode/encoder.dart';
import 'package:hawk/src/bytecode/instr.dart';
import 'package:hawk/src/bytecode/module.dart';
import 'package:hawk/src/codegen/codegen.dart';
import 'package:hawk/src/element/namespace.dart';
import 'package:hawk/src/lexer.dart';
import 'package:hawk/src/parser.dart';
import 'package:test/test.dart';

import 'runtime_harness.dart';

Program parseProgram(String source) {
  final lex = Lexer(source).tokenize();
  expect(lex.hasErrors, isFalse, reason: lex.errors.join('\n'));
  final parsed = Parser(lex.tokens).parse();
  expect(parsed.hasErrors, isFalse, reason: parsed.errors.join('\n'));
  return parsed.program;
}

/// A stand-in for the parts of the `std.core` prelude these in-memory tests
/// depend on: the I/O natives (sdk/std/core/io.hawk) and the Result/Option
/// enums (result.hawk/option.hawk). The real toolchain always links the prelude;
/// these tests link this stub instead of reading the SDK off disk. The native
/// fns register as runtime natives and the enums occupy the reserved type ids
/// 0/1 — neither adds function-table or type-table entries, so module/function
/// assertions are unaffected.
const _corePrelude = '''
@extern('println') native fn println<T>(_ value: T) -> Void
@extern('print') native fn print<T>(_ value: T) -> Void
enum Option<T> { Some(T), None }
enum Result<T, E> { Ok(T), Err(E) }
impl String {
  @extern('str_len')              native fn len(self) -> Int
  @extern('str_byte_len')         native fn byte_len(self) -> Int
  @extern('str_is_empty')         native fn is_empty(self) -> Bool
  @extern('str_trim')             native fn trim(self) -> String
  @extern('str_contains')         native fn contains(self, _ needle: String) -> Bool
  @extern('str_starts_with')      native fn starts_with(self, _ prefix: String) -> Bool
  @extern('str_ends_with')        native fn ends_with(self, _ suffix: String) -> Bool
  @extern('str_to_uppercase')     native fn to_uppercase(self) -> String
  @extern('str_to_lowercase')     native fn to_lowercase(self) -> String
  @extern('str_lines')            native fn lines(self) -> List<String>
  @extern('str_split_whitespace') native fn split_whitespace(self) -> List<String>
  @extern('str_split')            native fn split(self, _ sep: String) -> List<String>
}
impl List<T> {
  @extern('list_len')  native fn len(self) -> Int
  @extern('list_get')  native fn get(self, _ i: Int) -> Option<T>
  @extern('list_join') native fn join(self, _ sep: String) -> String
  @extern('list_push') native fn push(self, _ item: T) -> Void
}
impl Map<K, V> {
  @extern('map_len')      native fn len(self) -> Int
  @extern('map_is_empty') native fn is_empty(self) -> Bool
  @extern('map_has')      native fn has(self, _ key: K) -> Bool
  @extern('map_get')      native fn get(self, _ key: K) -> Option<V>
  @extern('map_remove')   native fn remove(self, _ key: K) -> Option<V>
  @extern('map_keys')     native fn keys(self) -> List<K>
  @extern('map_values')   native fn values(self) -> List<V>
}
impl Option<T> {
  @extern('option_ok_or')     native fn ok_or<E>(self, _ err: E) -> Result<T, E>
  @extern('option_unwrap_or') native fn unwrap_or(self, _ fallback: T) -> T
  @extern('option_is_some')   native fn is_some(self) -> Bool
  @extern('option_is_none')   native fn is_none(self) -> Bool
}''';

Module compile(String source) =>
    compileProgram(parseProgram(source), imports: [parseProgram(_corePrelude)]);

/// Compile [source] with namespaced imports: each entry of [libs] is an
/// import-path -> library source, so qualified access (`ns.member`) resolves.
Module compileWith(String source, Map<String, String> libs) {
  final imports = {
    for (final e in libs.entries) e.key: LibrarySource(parseProgram(e.value)),
  };
  final program = parseProgram(source);
  final root = LibrarySource(program, imports: imports);
  return compileProgram(program,
      imports: [
        parseProgram(_corePrelude),
        for (final s in imports.values) s.program
      ],
      namespaces: namespacesFor(root));
}

/// A minimal `std.fs` library (the `read_text` native, bound via `@extern`),
/// for exercising namespace-qualified native calls.
const _fsLib = "@extern('fs_read_text')\n"
    'pub native fn read_text(_ path: String) -> Result<String, Error>';

const _processLib = '''
pub type ProcessResult = {
    exit_code: Int,
    stdout: String,
    stderr: String,
}

pub type Process = {
    id: Int,
}

@extern('process_wait')
native fn _wait(_ proc: Process) -> Result<Int, Error>

@extern('process_kill')
native fn _kill(_ proc: Process) -> Result<Void, Error>

@extern('process_stdin_write')
native fn _stdin_write(_ proc: Process, _ data: String) -> Result<Void, Error>

@extern('process_stdout_read')
native fn _stdout_read(_ proc: Process) -> Result<String, Error>

@extern('process_stderr_read')
native fn _stderr_read(_ proc: Process) -> Result<String, Error>

impl Process {
    pub fn wait(self) -> Result<Int, Error> {
        return _wait(self);
    }

    pub fn kill(self) -> Result<Void, Error> {
        return _kill(self);
    }

    pub fn stdin_write(self, _ data: String) -> Result<Void, Error> {
        return _stdin_write(self, data);
    }

    pub fn stdout_read(self) -> Result<String, Error> {
        return _stdout_read(self);
    }

    pub fn stderr_read(self) -> Result<String, Error> {
        return _stderr_read(self);
    }
}

@extern('process_run')
pub native fn run(
    _ command: String,
    args: List<String> = [],
    working_dir: Option<String>,
    env: Option<Map<String, String>>,
) -> Result<ProcessResult, Error>

@extern('process_start')
pub native fn start(
    _ command: String,
    args: List<String> = [],
    working_dir: Option<String>,
    env: Option<Map<String, String>>,
) -> Result<Process, Error>
''';

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
      expect(ops[0],
          isA<ConstStr>().having((i) => i.value, 'value', 'hello, world'));
      expect(
          ops[1],
          isA<CallNative>()
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
      expect(m.functions.single.code,
          contains(isA<Simple>().having((i) => i.op, 'op', Op.addF64)));
    });

    test('comparison and unary operators', () {
      final lt =
          compile('fn f() -> Bool { return 1 < 2; }').functions.single.code;
      expect(lt, contains(isA<Simple>().having((i) => i.op, 'op', Op.ltI64)));

      final neg = compile('fn f() -> Int { let x = 5; return -x; }')
          .functions
          .single
          .code;
      expect(neg, contains(isA<Simple>().having((i) => i.op, 'op', Op.negI64)));

      final not =
          compile('fn f() -> Bool { return !true; }').functions.single.code;
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
      final m =
          compile('fn f() -> Int { if true { return 1; } else { return 2; } }');
      final ops = m.functions.single.code;
      // 0 const.bool, 1 jump_if_false->else, 2 const 1, 3 return,
      // 4 jump->end, 5 const 2 (else), 6 return, 7 const.unit, 8 return.
      expect(ops[1], isA<JumpIfFalse>().having((i) => i.target, 'target', 5));
      expect(ops[4], isA<Jump>().having((i) => i.target, 'target', 7));
      expect(ops[5], isA<ConstInt>().having((i) => i.value, 'value', 2));
    });

    test('short-circuit && lowers to branches', () {
      final ops = compile('fn f() -> Bool { return true && false; }')
          .functions
          .single
          .code;
      expect(ops.whereType<JumpIfFalse>(), isNotEmpty);
      // && yields `false` on the short-circuit path.
      expect(ops.whereType<ConstBool>().map((i) => i.value), contains(false));
    });

    test('a direct call resolves to the callee function index', () {
      // helper is declared first (index 0); main calls it.
      final m = compile(
          'fn helper() -> Int { return 1; } fn main() -> Int { return helper(); }');
      final main = m.functions[1];
      expect(
          main.code.first,
          isA<Call>()
              .having((i) => i.func, 'func', 0)
              .having((i) => i.argc, 'argc', 0));
    });

    test('interpolation lowers to stringify + str_concat', () {
      final ops =
          compile("fn f() -> Int { let n = 5; println('n=\${n}'); return 0; }")
              .functions
              .single
              .code;
      expect(
          ops,
          containsAllInOrder([
            isA<ConstStr>().having((i) => i.value, 'value', 'n='),
            isA<Load>(),
            isA<CallNative>().having((i) => i.name, 'name', 'stringify'),
            isA<CallNative>().having((i) => i.name, 'name', 'str_concat'),
          ]));
    });

    test('user enum construction lowers to enum.new', () {
      final ops = compile(
              'enum Color { Red, Green, Blue } fn f() -> Int { let c = Color.Green; return 0; }')
          .functions
          .single
          .code;
      // Green is variant 1, zero fields; ty is a user id (>= 2).
      expect(
          ops,
          contains(isA<EnumNew>()
              .having((i) => i.variant, 'variant', 1)
              .having((i) => i.fieldCount, 'fieldCount', 0)));
      expect(ops.whereType<EnumNew>().first.type, greaterThanOrEqualTo(2));

      final payload = compile(
              'enum Shape { Dot, Circle(Int) } fn f() -> Int { let s = Shape.Circle(5); return 0; }')
          .functions
          .single
          .code;
      expect(
          payload,
          containsAllInOrder([
            isA<ConstInt>().having((i) => i.value, 'value', 5),
            isA<EnumNew>()
                .having((i) => i.variant, 'variant', 1)
                .having((i) => i.fieldCount, 'fieldCount', 1),
          ]));
    });

    test('Result/Option enum decls land on the reserved type ids 0/1', () {
      // When std.core defines Result/Option as ordinary enums, codegen must pin
      // them to the reserved runtime ids (Result = 0, Option = 1) the runtime
      // and the `?`/exit-code conventions depend on — not assign fresh ids.
      // A user enum keeps getting an id >= 2.
      // Result/Option come from the linked core stub; Color is a user enum.
      final ops = compile('''
enum Color { Red, Green }
fn f() -> Int {
  let a = Result.Ok(1);
  let b = Option.Some(2);
  let c = Color.Green;
  return 0;
}
''').functions.single.code;
      final news = ops.whereType<EnumNew>().toList();
      expect(news[0].type, 0, reason: 'Result.Ok -> reserved id 0');
      expect(news[1].type, 1, reason: 'Option.Some -> reserved id 1');
      expect(news[2].type, greaterThanOrEqualTo(2), reason: 'user enum');
    });

    test('interpolating a user type dispatches to its display method', () {
      final m = compile('''
type Tag = { n: Int }
impl Display for Tag { fn display(self) -> String { return 'tag'; } }
fn f() -> Int { let t = Tag { n: 1 }; println('v=\${t}'); return 0; }
''');
      final displayIdx =
          m.functions.indexWhere((fn) => fn.name == 'Tag.display');
      final f = m.functions.firstWhere((fn) => fn.name == 'f');
      // The interpolated piece calls Tag.display, not stringify.
      expect(f.code,
          contains(isA<Call>().having((i) => i.func, 'func', displayIdx)));
      expect(f.code.whereType<CallNative>().map((i) => i.name),
          isNot(contains('stringify')));
    });

    test('println of a Display type renders via its display method', () {
      final m = compile('''
type Tag = { n: Int }
impl Display for Tag { fn display(self) -> String { return 'tag'; } }
fn f() -> Int { let t = Tag { n: 1 }; println(t); return 0; }
''');
      final displayIdx =
          m.functions.indexWhere((fn) => fn.name == 'Tag.display');
      final f = m.functions.firstWhere((fn) => fn.name == 'f').code;
      // Renders via Tag.display, then prints the resulting String.
      expect(
          f,
          containsAllInOrder([
            isA<Call>().having((i) => i.func, 'func', displayIdx),
            isA<CallNative>().having((i) => i.name, 'name', 'println'),
          ]));
    });

    test('println of a primitive passes the value straight to the native', () {
      final f = compile('fn f() -> Int { println(42); return 0; }')
          .functions
          .single
          .code;
      // No display Call — 42 goes directly to println, which renders it.
      expect(
          f,
          containsAllInOrder([
            isA<ConstInt>().having((i) => i.value, 'value', 42),
            isA<CallNative>().having((i) => i.name, 'name', 'println'),
          ]));
    });

    test('interpolating a type that does not implement Display is rejected',
        () {
      // A `display` method alone is not enough — it must be `impl Display for T`.
      expect(
        () => compile('''
type Tag = { n: Int }
impl Tag { fn display(self) -> String { return 'tag'; } }
fn f() -> Int { let t = Tag { n: 1 }; println('v=\${t}'); return 0; }
'''),
        throwsA(isA<CodegenException>()),
      );
    });

    test('Result.Ok constructs a Result enum', () {
      final ops = compile('fn f() -> Int { let x = Result.Ok(0); return 0; }')
          .functions
          .single
          .code;
      expect(
          ops,
          containsAllInOrder([
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
      final ops = compile('fn f() -> Result<Int, Int> { return Result.Ok(5); }')
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
      expect(
          ops,
          containsAllInOrder([
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

    test('struct literal pushes fields in declaration order, then struct.new',
        () {
      // Written y-first, but x is declared first → its value (1) is pushed first.
      final ops = compile('type Point = { x: Int, y: Int } '
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
      final ops = compile('type C = { n: Int } '
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
      expect(
          main.code.whereType<ConstInt>().take(2).map((i) => i.value), [40, 2]);
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
      final ops = compile('fn f() -> Int { let xs = [1, 2, 3]; return 0; }')
          .functions
          .single
          .code;
      expect(
          ops,
          containsAllInOrder([
            isA<ConstInt>().having((i) => i.value, 'v', 1),
            isA<ConstInt>().having((i) => i.value, 'v', 2),
            isA<ConstInt>().having((i) => i.value, 'v', 3),
            isA<ListNew>().having((i) => i.count, 'count', 3),
          ]));
    });

    test('map literal lowers to map_new with 2N args', () {
      final ops = compile('fn f() -> Int { let m = {1: 10, 2: 20}; return 0; }')
          .functions
          .single
          .code;
      expect(
          ops,
          contains(isA<CallNative>()
              .having((i) => i.name, 'name', 'map_new')
              .having((i) => i.argc, 'argc', 4)));
    });

    test('indexing and indexed assignment use the right natives', () {
      final read = compile('fn f() -> Int { let xs = [1]; return xs[0]; }')
          .functions
          .single
          .code;
      expect(
          read,
          contains(
              isA<CallNative>().having((i) => i.name, 'name', 'list_index')));

      final write =
          compile('fn f() -> Int { let mut xs = [1]; xs[0] = 9; return 0; }')
              .functions
              .single
              .code;
      expect(
          write,
          contains(
              isA<CallNative>().having((i) => i.name, 'name', 'list_set')));
    });

    test('map.remove / list.join lower to their natives', () {
      final rm = compile(
              'fn f() -> Int { let mut m = {1: 2}; m.remove(1); return 0; }')
          .functions
          .single
          .code;
      expect(
          rm,
          contains(isA<CallNative>()
              .having((i) => i.name, 'name', 'map_remove')
              .having((i) => i.argc, 'argc', 2)));

      final jn = compile("fn f() -> String { return [1, 2].join('-'); }")
          .functions
          .single
          .code;
      expect(
          jn,
          contains(isA<CallNative>()
              .having((i) => i.name, 'name', 'list_join')
              .having((i) => i.argc, 'argc', 2)));
    });

    test('a collection method lowers to a native with the receiver first', () {
      final ops = compile('fn f() -> Int { let xs = [1, 2]; return xs.len(); }')
          .functions
          .single
          .code;
      // load xs, list_len(self) → argc 1.
      expect(
          ops,
          contains(isA<CallNative>()
              .having((i) => i.name, 'name', 'list_len')
              .having((i) => i.argc, 'argc', 1)));
    });

    test('== on strings lowers to the structural eq native', () {
      final eq = compile("fn f() -> Bool { return 'a' == 'b'; }")
          .functions
          .single
          .code;
      expect(
          eq, contains(isA<CallNative>().having((i) => i.name, 'name', 'eq')));
      expect(eq,
          isNot(contains(isA<Simple>().having((i) => i.op, 'op', Op.eqI64))));

      // `!=` is `eq` then `not`.
      final ne = compile("fn f() -> Bool { return 'a' != 'b'; }")
          .functions
          .single
          .code;
      expect(
          ne,
          containsAllInOrder([
            isA<CallNative>().having((i) => i.name, 'name', 'eq'),
            isA<Simple>().having((i) => i.op, 'op', Op.not),
          ]));
    });

    test('== on a type with an explicit Eq impl dispatches to its eq method',
        () {
      final m = compile('''
type CI = { s: String }
impl Eq for CI { fn eq(self, _ other: Self) -> Bool { return true; } }
fn f(a: CI, b: CI) -> Bool { return a == b; }
''');
      final eqIdx = m.functions.indexWhere((fn) => fn.name == 'CI.eq');
      final f = m.functions.firstWhere((fn) => fn.name == 'f').code;
      // Calls CI.eq directly, not the structural `eq` native.
      expect(f, contains(isA<Call>().having((i) => i.func, 'func', eqIdx)));
      expect(
          f.whereType<CallNative>().map((i) => i.name), isNot(contains('eq')));
    });

    test('== on Int still uses the typed opcode', () {
      final ops =
          compile('fn f() -> Bool { return 1 == 2; }').functions.single.code;
      expect(ops, contains(isA<Simple>().having((i) => i.op, 'op', Op.eqI64)));
    });

    test('a String method lowers to its native with the receiver first', () {
      final ops = compile("fn f() -> Int { let s = 'hi'; return s.len(); }")
          .functions
          .single
          .code;
      expect(
          ops,
          contains(isA<CallNative>()
              .having((i) => i.name, 'name', 'str_len')
              .having((i) => i.argc, 'argc', 1)));
    });

    test('Option.ok_or lowers to option_ok_or (receiver first)', () {
      final ops = compile(
              'fn f() -> Int { let xs = [1]; let r = xs.get(0).ok_or(9); return 0; }')
          .functions
          .single
          .code;
      expect(
          ops,
          contains(isA<CallNative>()
              .having((i) => i.name, 'name', 'option_ok_or')
              .having((i) => i.argc, 'argc', 2)));
    });

    test('a namespace-qualified native call lowers with no receiver', () {
      final ops = compileWith(
        "import std.fs; fn f() -> Int { let r = fs.read_text('/x'); return 0; }",
        {'std.fs': _fsLib},
      ).functions.single.code;
      // just the path argument → argc 1, no receiver pushed.
      expect(
          ops,
          contains(isA<CallNative>()
              .having((i) => i.name, 'name', 'fs_read_text')
              .having((i) => i.argc, 'argc', 1)));
    });

    test('a static native method on a built-in lowers to call.native', () {
      // `impl String { native fn from_chars }` is not a unit; the only function
      // is `f`, and `String.from_chars(...)` lowers to a receiver-less native.
      final ops = compile('''
impl String {
  @extern('str_from_chars') native fn from_chars(_ cps: List<Int>) -> String
}
fn f() -> Int { return String.from_chars([105]).len(); }
''').functions.single.code;
      expect(
          ops,
          contains(isA<CallNative>()
              .having((i) => i.name, 'name', 'str_from_chars')
              .having((i) => i.argc, 'argc', 1)));
    });

    test('an instance native method lowers to call.native, receiver first', () {
      // A user `@extern` instance method (takes `self`) lowers like a built-in
      // method: receiver pushed first, then args. `mylen` is a fresh name (not
      // in the built-in table) so it exercises the nativeInstanceMethods path.
      final ops = compile('''
impl List<T> {
  @extern('list_len') native fn mylen(self) -> Int
}
fn f() -> Int { let xs = [1, 2, 3]; return xs.mylen(); }
''').functions.single.code;
      expect(
          ops,
          containsAllInOrder([
            isA<ListNew>(),
            isA<Store>(),
            isA<Load>(), // receiver
            isA<CallNative>()
                .having((i) => i.name, 'name', 'list_len')
                .having((i) => i.argc, 'argc', 1), // self only
          ]));
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
      expect(runExit('for', '''
fn main() -> Int {
    let mut sum = 0;
    for i in 1..5 {
        sum = sum + i;
    }
    return sum;
}
'''), 10); // 1+2+3+4
    });

    test('while loop', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('while', '''
fn main() -> Int {
    let mut n = 5;
    let mut acc = 0;
    while n > 0 {
        acc = acc + n;
        n = n - 1;
    }
    return acc;
}
'''), 15); // 5+4+3+2+1
    });

    test('if/else picks a branch', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(
          runExit('if',
              'fn main() -> Int { let x = 7; if x > 5 { return 1; } else { return 2; } }'),
          1);
    });

    test('an instance native method runs end to end (receiver + arg)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      // `at` is a user @extern instance method bound to the existing list_get
      // native: receiver + index. `[10,20,30].at(1)` → Some(20) → 20.
      expect(runExit('instance_native', '''
impl List<T> {
  @extern('list_get') native fn at(self, _ i: Int) -> Option<T>
}
fn main() -> Int { return [10, 20, 30].at(1).unwrap_or(0); }
'''), 20);
    });

    test('a Hawk-bodied method on a primitive runs end to end', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      // `impl Int` with a real body: `self` is the primitive, so arithmetic on
      // it lowers to int opcodes. 21.double() == 42.
      expect(runExit('prim_method', '''
impl Int { fn double(self) -> Int { return self + self; } }
fn main() -> Int { let n = 21; return n.double(); }
'''), 42);
    });

    test('println renders a user type via its Display impl', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final m = compile('''
type Point = { x: Int, y: Int }
impl Display for Point {
  fn display(self) -> String { return "(\${self.x}, \${self.y})"; }
}
fn main() -> Int { println(Point { x: 3, y: 4 }); return 0; }
''');
      final tmp = '${Directory.systemTemp.path}/hawk_println_display.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      final r = Process.runSync(hawkBin, ['run', tmp]);
      expect(r.stdout, '(3, 4)\n');
    });

    test('an explicit Eq impl overrides structural equality', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      // Case-insensitive Eq: "Hello" == "HELLO" is true, where structural
      // equality of the structs would be false. Exit 42 proves the impl ran.
      expect(runExit('custom_eq', '''
type CI = { s: String }
impl Eq for CI {
  fn eq(self, _ other: Self) -> Bool {
    return self.s.to_lowercase() == other.s.to_lowercase();
  }
}
fn main() -> Int {
  let a = CI { s: "Hello" };
  let b = CI { s: "HELLO" };
  if a == b { return 42; }
  return 0;
}
'''), 42);
    });

    test('&& short-circuits (the right side, which would trap, is skipped)',
        () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      // If `&&` evaluated its RHS, `10 / 0` would trap (non-zero exit). A clean
      // exit 9 proves the RHS was never reached.
      expect(runExit('and_sc', '''
fn main() -> Int {
    let f = false;
    if f && (10 / 0 > 0) {
        return 1;
    }
    return 9;
}
'''), 9);
    });

    test('recursion (factorial) flows to the exit code', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('fact', '''
fn fact(n: Int) -> Int {
    if n <= 1 { return 1; }
    return n * fact(n - 1);
}
fn main() -> Int {
    return fact(5);
}
'''), 120);
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
      final src =
          safeDiv.replaceAll('DIVIDEND', '84').replaceAll('DIVISOR', '2');
      expect(runExit('ok', src), 42);
    });

    test('match takes the Err branch (throw path)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final src =
          safeDiv.replaceAll('DIVIDEND', '1').replaceAll('DIVISOR', '0');
      expect(runExit('err', src), 7);
    });

    test('? propagates through Result and implicit Ok', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('propagate', '''
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
'''), 42);
    });

    test('Option Some/None construction and match', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('option', '''
fn first_positive(a: Int) -> Option<Int> {
    if a > 0 { return Option.Some(a); }
    return Option.None;
}
fn main() -> Int {
    match first_positive(7) {
        Some(v) => return v,
        None => return 0,
    }
}
'''), 7);
    });

    test('struct literal + field read', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('struct', '''
type Point = { x: Int, y: Int }
fn main() -> Int {
    let p = Point { y: 2, x: 40 };
    return p.x + p.y;
}
'''), 42);
    });

    test('mutable field assignment', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('field_set', '''
type Counter = { n: Int }
fn main() -> Int {
    let mut c = Counter { n: 0 };
    c.n = 42;
    return c.n;
}
'''), 42);
    });

    test('nested struct field access', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('nested', '''
type Point = { x: Int, y: Int }
type Rect = { top_left: Point, w: Int }
fn main() -> Int {
    let r = Rect { top_left: Point { x: 10, y: 20 }, w: 5 };
    return r.top_left.x + r.top_left.y + r.w;
}
'''), 35);
    });

    test('instance method call', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('method', '''
type Point = { x: Int, y: Int }
impl Point {
    fn sum(self) -> Int { return self.x + self.y; }
}
fn main() -> Int {
    let p = Point { x: 40, y: 2 };
    return p.sum();
}
'''), 42);
    });

    test('static method with named (reordered) arguments', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('static', '''
type Point = { x: Int, y: Int }
impl Point {
    fn make(x: Int, y: Int) -> Point { return Point { x: x, y: y }; }
    fn sum(self) -> Int { return self.x + self.y; }
}
fn main() -> Int {
    let p = Point.make(y: 2, x: 40);
    return p.sum();
}
'''), 42);
    });

    test('method call with args, chained on the result', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('chain', '''
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
'''), 42);
    });

    test('user enum: payload match with typed bindings', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('enum_match', '''
enum Shape { Circle(Int), Rect(Int, Int), Square }
fn area(_ s: Shape) -> Int {
    return match s {
        Circle(r) => r * r,
        Rect(w, h) => w * h,
        Square => 1,
    };
}
fn main() -> Int {
    return area(Shape.Circle(6)) + area(Shape.Rect(2, 3));
}
'''), 42); // 36 + 6
    });

    test('user enum: .name() and equality', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('enum_name', '''
enum Dir { North, South, East, West }
fn main() -> Int {
    let d = Dir.South;
    let mut n = 0;
    if d.name() == 'South' { n = n + 1; }
    if d == Dir.South { n = n + 10; }
    if d == Dir.North { n = n + 100; }
    return n;
}
'''), 11); // name matches + equality matches; North branch skipped
    });

    test('the enums.hawk example runs', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final m = compile(File('../examples/enums.hawk').readAsStringSync());
      final tmp = '${Directory.systemTemp.path}/hawk_enums_ex.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      final r = Process.runSync(hawkBin, ['run', tmp]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout, contains('circle area: 25'));
      expect(r.stdout, contains('name: North'));
    });

    test('the structs.hawk example compiles', () {
      final m = compile(File('../examples/structs.hawk').readAsStringSync());
      expect(m.functions, isNotEmpty);
      expect(m.types.map((t) => t.name), containsAll(['Point', 'Rect']));
    });

    test('list literal + indexing', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('list', '''
fn main() -> Int {
    let xs = [10, 20, 12];
    return xs[0] + xs[1] + xs[2];
}
'''), 42);
    });

    test('list mutation, len, and for-in iteration', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('list_iter', '''
fn main() -> Int {
    let mut xs = [1, 2, 3];
    xs[0] = 40;
    let mut total = 0;
    for v in xs {
        total = total + v;
    }
    return total;
}
'''), 45); // 40 + 2 + 3
    });

    test('map literal, indexed assignment, and indexing', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('map', '''
fn main() -> Int {
    let mut m = {1: 0, 2: 2};
    m[1] = 40;
    return m[1] + m[2];
}
'''), 42);
    });

    test('map.has and map.len', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('map_methods', '''
fn main() -> Int {
    let m = {7: 99};
    if m.has(7) {
        return m.len() + m[7];
    }
    return 0;
}
'''), 100); // 1 + 99
    });

    test('list.get returns an Option', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('list_get', '''
fn main() -> Int {
    let xs = [5, 6, 7];
    match xs.get(1) {
        Some(v) => return v,
        None => return 0,
    }
}
'''), 6);
    });

    test('string equality (structural)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('streq', '''
fn main() -> Int {
    let a = 'hello';
    let b = 'hello';
    if a == b { return 1; }
    return 0;
}
'''), 1);
    });

    test('Option.ok_or converts to Result (Some and None)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      const tmpl = '''
fn main() -> Int {
    let xs = [10, 20];
    match xs.get(INDEX).ok_or(99) {
        Ok(v) => return v,
        Err(e) => return e,
    }
}
''';
      expect(runExit('okor_some', tmpl.replaceAll('INDEX', '0')), 10);
      expect(runExit('okor_none', tmpl.replaceAll('INDEX', '5')), 99);
    });

    test('fs.read_text reads a file (and propagates errors with ?)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final dataPath = '${Directory.systemTemp.path}/hawk_fs_data.txt';
      File(dataPath).writeAsStringSync('hello-from-fs');

      Map<String, dynamic> run(String name, String src) {
        final tmp = '${Directory.systemTemp.path}/hawk_$name.hawkbc';
        File(tmp).writeAsBytesSync(
            encodeModule(compileWith(src, {'std.fs': _fsLib})));
        final r = Process.runSync(hawkBin, ['run', tmp]);
        return {'code': r.exitCode, 'out': r.stdout, 'err': r.stderr};
      }

      final ok = run('fs_ok', '''
import std.fs;
fn main() -> Result<Int, Error> {
    let text = fs.read_text('$dataPath')?;
    println(text);
    return Result.Ok(0);
}
''');
      expect(ok['code'], 0);
      expect(ok['out'], 'hello-from-fs\n');

      final err = run('fs_err', '''
import std.fs;
fn main() -> Result<Int, Error> {
    let text = fs.read_text('/no/such/file/zzz')?;
    println(text);
    return Result.Ok(0);
}
''');
      expect(err['code'], 1);
      expect(err['err'], contains('error:'));
    });

    test('process.run and process.start work end to end', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');

      Map<String, dynamic> run(String name, String src) {
        final tmp = '${Directory.systemTemp.path}/hawk_proc_$name.hawkbc';
        File(tmp).writeAsBytesSync(encodeModule(compileWith(src, {
          'std.fs': _fsLib,
          'std.process': _processLib,
        })));
        final r = Process.runSync(hawkBin, ['run', tmp]);
        return {'code': r.exitCode, 'out': r.stdout, 'err': r.stderr};
      }

      // 1. Test process.run with echo
      final rRun = run('echo', '''
import std.process;
fn main() -> Result<Int, Error> {
    let res = process.run('echo', args: ['hello', 'world'])?;
    println(res.stdout.trim());
    return Result.Ok(res.exit_code);
}
''');
      expect(rRun['code'], 0);
      expect(rRun['out'], 'hello world\n');

      // 2. Test process.start with cat and stdin
      final rStart = run('cat', '''
import std.process;
fn main() -> Result<Int, Error> {
    let p = process.start('cat')?;
    p.stdin_write('hello from cat\\n')?;
    let out = p.stdout_read()?;
    println(out.trim());
    p.kill()?;
    return Result.Ok(0);
}
''');
      expect(rStart['code'], 0);
      expect(rStart['out'], 'hello from cat\n');
    });

    test('map.remove mutates; keys()/values()/join work', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');

      String stdout(String name, String src) {
        final tmp = '${Directory.systemTemp.path}/hawk_$name.hawkbc';
        File(tmp).writeAsBytesSync(encodeModule(compile(src)));
        return Process.runSync(hawkBin, ['run', tmp]).stdout as String;
      }

      // remove() drops an entry; len() reflects it.
      expect(
          runExit('map_remove',
              'fn main() -> Int { let mut m = {1: 10, 2: 20}; m.remove(1); return m.len(); }'),
          1);
      // keys()/values() return lists; join() renders them.
      expect(
          stdout('keys',
              "fn main() -> Int { println({1: 10, 2: 20}.keys().join(',')); return 0; }"),
          '1,2\n');
      expect(
          stdout('join',
              "fn main() -> Int { println(['a', 'b', 'c'].join('-')); return 0; }"),
          'a-b-c\n');
    });

    test('Display interpolation renders a user type', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final m = compile('''
type Tag = { n: Int }
impl Display for Tag { fn display(self) -> String { return 'tag'; } }
fn main() -> Int {
    let t = Tag { n: 5 };
    println('value: \${t}');
    return 0;
}
''');
      final tmp = '${Directory.systemTemp.path}/hawk_display.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      final r = Process.runSync(hawkBin, ['run', tmp]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout, 'value: tag\n');
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
      expect(runExit('strcontains', '''
fn main() -> Int {
    let s = 'hello';
    if s.contains('ell') { return 1; }
    return 0;
}
'''), 1);
    });

    test('struct equality (structural)', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('structeq', '''
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
'''), 11);
    });

    // --- entry / args convention ---

    test('a Result-returning main unwraps Ok to the exit code', () {
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      expect(runExit('ret_ok', 'fn main() -> Result<Int, Int> { return 42; }'),
          42);
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
      final m =
          compile('fn main(args: List<String>) -> Int { return args.len(); }');
      final tmp = '${Directory.systemTemp.path}/hawk_argv.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      final r = Process.runSync(hawkBin, ['run', tmp, 'a', 'b', 'c']);
      expect(r.exitCode, 3);
    });
  });

  group('module linking', () {
    test('a cross-module function call resolves to the imported function', () {
      final lib = parseProgram('fn helper() -> Int { return 42; }');
      final root = parseProgram('fn main() -> Int { return helper(); }');
      final m = compileProgram(root, imports: [lib]);

      expect(m.functions.map((f) => f.name), containsAll(['helper', 'main']));
      final helperIdx = m.functions.indexWhere((f) => f.name == 'helper');
      final main = m.functions.firstWhere((f) => f.name == 'main');
      expect(main.code,
          contains(isA<Call>().having((i) => i.func, 'func', helperIdx)));
    });

    test('a generic struct compiles and runs (generics erased)', () {
      late final String? hawkBin = buildRuntime();
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');

      final m = compile('''
type Box<T> = { value: T }
impl Box<T> {
    fn get(self) -> T { return self.value; }
}
fn main() -> Int {
    let b = Box { value: 42 };
    return b.get();
}
''');
      final tmp = '${Directory.systemTemp.path}/hawk_generic.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      expect(Process.runSync(hawkBin, ['run', tmp]).exitCode, 42);
    });

    test('a linked program runs end to end', () {
      late final String? hawkBin = buildRuntime();
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');

      final lib = parseProgram('fn triple(_ n: Int) -> Int { return n * 3; }');
      final root = parseProgram('fn main() -> Int { return triple(14); }');
      final tmp = '${Directory.systemTemp.path}/hawk_linked.hawkbc';
      File(tmp)
          .writeAsBytesSync(encodeModule(compileProgram(root, imports: [lib])));

      expect(Process.runSync(hawkBin, ['run', tmp]).exitCode, 42);
    });
  });

  group('closures (zero-capture)', () {
    test('a lambda lifts to a synthetic unit and pushes a closure', () {
      final m = compile('fn f() { let g = (n: Int) => n + 1; }');
      // Two units: `f` and the lifted lambda. The lambda's body returns n + 1.
      expect(m.functions, hasLength(2));
      final lifted = m.functions[1];
      expect(lifted.paramCount, 1);
      expect(lifted.code,
          contains(isA<Simple>().having((i) => i.op, 'op', Op.addI64)));

      // `f` builds the closure for unit #1 with no captures and binds it.
      final ops = m.functions[0].code;
      final cn = ops.whereType<ClosureNew>().single;
      expect(cn.func, 1);
      expect(cn.captures, 0);
    });

    test('calling a let-bound lambda lowers to call.indirect', () {
      final ops =
          compile('fn f() -> Int { let g = (n: Int) => n + 1; return g(41); }')
              .functions[0]
              .code;
      // The closure is loaded, the argument pushed, then dispatched indirectly.
      final idx = ops.indexWhere((i) => i is CallIndirect);
      expect(idx, greaterThan(0));
      expect((ops[idx] as CallIndirect).argc, 1);
      expect(ops[idx - 2], isA<Load>()); // the closure
      expect(ops[idx - 1], isA<ConstInt>().having((i) => i.value, 'arg', 41));
    });

    test('calling a function-typed parameter lowers to call.indirect', () {
      final ops =
          compile('fn apply(f: (Int) -> Int, x: Int) -> Int { return f(x); }')
              .functions[0]
              .code;
      expect(ops.whereType<CallIndirect>().single.argc, 1);
    });

    test('a zero-capture closure runs end to end', () {
      late final String? hawkBin = buildRuntime();
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final m = compile('''
fn apply(f: (Int) -> Int, x: Int) -> Int { return f(x); }
fn main() -> Int {
    let inc = (n: Int) => n + 1;
    return apply(inc, 41);
}
''');
      final tmp = '${Directory.systemTemp.path}/hawk_closure.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      expect(Process.runSync(hawkBin, ['run', tmp]).exitCode, 42);
    });
  });

  group('closures (capture)', () {
    test('a captured local becomes a leading param and a closure capture', () {
      final m = compile('''
fn f() -> Int {
  let add = 10;
  let g = (n: Int) => n + add;
  return g(5);
}
''');
      // The lifted lambda's params are the captures (add) followed by the
      // lambda's own params (n).
      expect(m.functions[1].paramCount, 2);

      final ops = m.functions[0].code;
      final cn = ops.whereType<ClosureNew>().single;
      expect(cn.func, 1);
      expect(cn.captures, 1);
      // The captured value is loaded immediately before closure.new.
      expect(ops[ops.indexOf(cn) - 1], isA<Load>());
    });

    test('only enclosing locals are captured, not functions or literals', () {
      // The lambda body references `helper` (a top-level function) and `42` (a
      // literal) — neither is a capture, so the closure captures nothing and
      // the lifted lambda takes only its own parameter `n`.
      final m = compile('''
fn helper(_ n: Int) -> Int { return n; }
fn f() -> Int { let g = n => helper(n) + 42; return g(1); }
''');
      final closures = [
        for (final fn in m.functions) ...fn.code.whereType<ClosureNew>(),
      ];
      expect(closures.single.captures, 0);
      expect(m.functions[closures.single.func].paramCount, 1); // just n
    });

    test('a captured mutable local is boxed (cell-backed)', () {
      // The capture is `mut`, so it is stored in a one-field cell: the binding
      // wraps its value in a struct.new, and reads go through field.get.
      final m = compile(
          'fn f() -> Int { let mut c = 0; let g = (n: Int) => n + c; return g(1); }');
      final ops = m.functions[0].code; // f
      // `let mut c = 0` boxes: ConstInt(0), struct.new(cell), store.
      final sn = ops.whereType<StructNew>().single;
      expect(ops[ops.indexOf(sn) - 1],
          isA<ConstInt>().having((i) => i.value, 'init', 0));
      // The lifted lambda reads its captured cell via field.get.
      expect(m.functions[1].code.whereType<FieldGet>(), isNotEmpty);
    });

    test('a mutation through a boxed capture is observed by the closure', () {
      late final String? hawkBin = buildRuntime();
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      // `base` is captured and then reassigned; the closure sees 100, not 10.
      final m = compile('''
fn main() -> Int {
    let mut base = 10;
    let get = n => base + n;
    base = 100;
    return get(5);
}
''');
      final tmp = '${Directory.systemTemp.path}/hawk_box.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      expect(Process.runSync(hawkBin, ['run', tmp]).exitCode, 105);
    });

    test('a non-captured mutable local stays unboxed', () {
      // No lambda captures `x`, so it is a plain local — no cell allocated.
      final m =
          compile('fn f() -> Int { let mut x = 1; x = x + 41; return x; }');
      expect(m.functions.single.code.whereType<StructNew>(), isEmpty);
    });

    test('value capture runs end to end', () {
      late final String? hawkBin = buildRuntime();
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      final m = compile('''
fn apply(f: (Int) -> Int, x: Int) -> Int { return f(x); }
fn main() -> Int {
    let add = 10;
    let g = (n: Int) => n + add;
    return apply(g, 5);
}
''');
      final tmp = '${Directory.systemTemp.path}/hawk_capture.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      expect(Process.runSync(hawkBin, ['run', tmp]).exitCode, 15);
    });

    test('a lambda inside a method capturing self runs end to end', () {
      late final String? hawkBin = buildRuntime();
      if (hawkBin == null) return markTestSkipped('Rust runtime unavailable');
      // f(self.base = 7) with f = n => n + self.base + bump(100) = 7+7+100.
      final m = compile('''
type Box = { base: Int }
impl Box {
  fn add_with(self, _ f: (Int) -> Int) -> Int { return f(self.base); }
  fn run(self) -> Int {
    let bump = 100;
    return self.add_with(n => n + self.base + bump);
  }
}
fn main() -> Int {
    let b = Box { base: 7 };
    return b.run();
}
''');
      final tmp = '${Directory.systemTemp.path}/hawk_self_capture.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(m));
      expect(Process.runSync(hawkBin, ['run', tmp]).exitCode, 114);
    });
  });
}
