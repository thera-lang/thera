import 'dart:io';

import 'package:hawk/src/bytecode/encoder.dart';
import 'package:hawk/src/bytecode/instr.dart';
import 'package:hawk/src/bytecode/module.dart';
import 'package:hawk/src/bytecode/writer.dart';
import 'package:test/test.dart';

import 'runtime_harness.dart';

void main() {
  group('Writer varints', () {
    test('uvarint matches LEB128', () {
      expect((Writer()..writeUvarint(0)).toBytes(), [0x00]);
      expect((Writer()..writeUvarint(127)).toBytes(), [0x7f]);
      expect((Writer()..writeUvarint(128)).toBytes(), [0x80, 0x01]);
      expect((Writer()..writeUvarint(300)).toBytes(), [0xac, 0x02]);
    });

    test('ivarint matches signed LEB128', () {
      expect((Writer()..writeIvarint(0)).toBytes(), [0x00]);
      expect((Writer()..writeIvarint(-1)).toBytes(), [0x7f]);
      expect((Writer()..writeIvarint(63)).toBytes(), [0x3f]);
      expect((Writer()..writeIvarint(64)).toBytes(), [0xc0, 0x00]);
      expect((Writer()..writeIvarint(-64)).toBytes(), [0x40]);
    });

    test('length-prefixed string', () {
      // 'hi' → length 2, then the two ASCII bytes.
      expect((Writer()..writeStr('hi')).toBytes(), [0x02, 0x68, 0x69]);
    });
  });

  group('cross-toolchain parity (requires the Rust runtime)', () {
    late final String? hawkBin = buildRuntime();

    test('Dart-encoded demo is byte-identical to the runtime emit-demo', () {
      if (hawkBin == null) {
        markTestSkipped('Rust runtime unavailable');
        return;
      }
      final tmp = '${Directory.systemTemp.path}/hawk_emit_demo.hawkbc';
      final r = Process.runSync(hawkBin, ['emit-demo', tmp]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final rustBytes = File(tmp).readAsBytesSync();

      expect(encodeModule(demoModule()), rustBytes);
    });

    test('runtime runs the Dart-emitted demo', () {
      if (hawkBin == null) {
        markTestSkipped('Rust runtime unavailable');
        return;
      }
      final tmp = '${Directory.systemTemp.path}/hawk_dart_demo.hawkbc';
      File(tmp).writeAsBytesSync(encodeModule(demoModule()));

      final r = Process.runSync(hawkBin, [tmp]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      expect(r.stdout, 'double(21) = 42\n');
    });
  });
}

/// The same module as the runtime's `demo_module()` (runtime/src/main.rs):
///   fn double(x) { return x * 2; }
///   fn main() { println('double(21) = ' + stringify(double(21))); return 0; }
Module demoModule() {
  final main = FuncDef('main', 0, 0, const [
    ConstStr('double(21) = '),
    ConstInt(21),
    Call(1, 1), // double(21)  — double is function index 1
    CallNative('stringify', 1),
    CallNative('str_concat', 2),
    CallNative('println', 1),
    Simple(Op.pop), // discard println's Unit
    ConstInt(0), // exit code
    Simple(Op.return_),
  ]);
  final double = FuncDef('double', 1, 1, const [
    Load(0),
    ConstInt(2),
    Simple(Op.mulI64),
    Simple(Op.return_),
  ]);
  return Module([main, double]);
}
