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

    test('unsupported constructs raise CodegenException', () {
      expect(() => compile('fn main() -> Int { let x = 1; return x; }'),
          throwsA(isA<CodegenException>()));
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
  });
}
