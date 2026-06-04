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
    return Ok(0);
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
    return Ok(0);
}
''', []);
    if (r == null) return markTestSkipped('Rust runtime unavailable');
    expect(r.exitCode, 1);
    expect(r.stderr, contains('need an arg'));
  });

  test('std.core auto-loads: Error constructs and interpolates via Display',
      () {
    final r = emitAndRun('core', '''
fn main() -> Result<Int, Error> {
    let e = Error { message: 'kaboom' };
    println('e = \${e}');
    return Ok(0);
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
