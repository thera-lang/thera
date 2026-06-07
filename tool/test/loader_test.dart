import 'dart:io';

import 'package:hawk/src/checker/type_checker.dart';
import 'package:hawk/src/lexer.dart';
import 'package:hawk/src/loader.dart';
import 'package:hawk/src/parser.dart';
import 'package:test/test.dart';

/// The analysis path shared by the CLI and the LSP: parse, link the import
/// closure, then type-check with those imports and namespaces. These guard the
/// regression where the LSP checked a program in isolation — so calls to
/// imported (and prelude) methods had no signature, and lambda arguments to
/// them were wrongly reported as un-inferrable.

List<String> checkLinked(String path, String source) {
  final program = Parser(Lexer(source).tokenize().tokens).parse().program;
  final imports = loadImports(path, program);
  final checker = TypeChecker();
  for (final p in imports.programs) {
    checker.addProgram(p);
  }
  return checker
      .check(program, namespaces: imports.namespaces)
      .errors
      .map((e) => e.message)
      .toList();
}

void main() {
  test(
      'a lambda arg to an imported function is typed from the linked signature',
      () {
    final dir = Directory.systemTemp.createTempSync('hawk_loader');
    File('${dir.path}/lib.hawk').writeAsStringSync(
        'pub fn apply(_ f: (Int) -> Int, _ x: Int) -> Int { return f(x); }');
    final appPath = '${dir.path}/app.hawk';
    // `n` has no annotation: its type comes from `apply`'s signature, which is
    // only visible once `lib` is linked.
    const app = "import 'lib';\n"
        'fn main() -> Int { return lib.apply(n => n * 2, 21); }';
    expect(checkLinked(appPath, app), isEmpty);
  });

  test('without linking, the same call is un-inferrable (the bug)', () {
    // The pre-fix LSP behaviour: check the program with no import closure.
    const app = "import 'lib';\n"
        'fn main() -> Int { return lib.apply(n => n * 2, 21); }';
    final program = Parser(Lexer(app).tokenize().tokens).parse().program;
    final errors =
        TypeChecker().check(program).errors.map((e) => e.message).toList();
    expect(
      errors,
      contains(contains('cannot infer the type of lambda parameter')),
    );
  });

  test('the std.core prelude links so List HOFs type-check', () {
    if (findSdkRoot() == null) {
      return markTestSkipped('SDK root not resolvable in this environment');
    }
    // No imports in the source — map/fold come from the auto-linked prelude.
    const src = 'fn main() -> Int {\n'
        '  let doubled = [1, 2, 3].map(n => n * 2);\n'
        '  return doubled.fold(0, (acc, n) => acc + n);\n'
        '}';
    expect(checkLinked('${Directory.current.path}/scratch.hawk', src), isEmpty);
  });
}
