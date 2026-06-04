import 'package:hawk/src/ast.dart';
import 'package:hawk/src/element/namespace.dart';
import 'package:hawk/src/lexer.dart';
import 'package:hawk/src/parser.dart';
import 'package:test/test.dart';

Program parse(String source) {
  final lex = Lexer(source).tokenize();
  expect(lex.hasErrors, isFalse, reason: 'lex errors: ${lex.errors}');
  final p = Parser(lex.tokens).parse();
  expect(p.hasErrors, isFalse, reason: 'parse errors: ${p.errors}');
  return p.program;
}

LibrarySource lib(String source,
        {Map<String, LibrarySource> imports = const {}}) =>
    LibrarySource(parse(source), imports: imports);

void main() {
  group('publicSurfaceOf', () {
    test('exposes only pub declarations', () {
      final l = lib('''
pub fn exported() { }
fn private_helper() { }
pub type Public = { x: Int }
type Private = { y: Int }
pub const C: Int = 1;
const D: Int = 2;
''');
      final surface = publicSurfaceOf(l);
      expect(surface.names, {'exported', 'Public', 'C'});
      expect(surface.collisions, isEmpty);
    });

    test('a barrel flattens its pub imports', () {
      final dates = lib('pub fn format_date() { }\nfn helper() { }');
      final numbers = lib('pub fn format_number() { }');
      final barrel = lib(
        "pub import 'dates';\npub import 'numbers';\npub fn version() { }",
        imports: {'dates': dates, 'numbers': numbers},
      );
      final surface = publicSurfaceOf(barrel);
      expect(surface.names, {'format_date', 'format_number', 'version'});
      expect(surface.collisions, isEmpty);
    });

    test('a plain (non-pub) import is not re-exported', () {
      final helper = lib('pub fn helper() { }');
      final l = lib(
        "import 'helper';\npub fn main_fn() { }",
        imports: {'helper': helper},
      );
      final surface = publicSurfaceOf(l);
      expect(surface.names, {'main_fn'});
      expect(surface.names, isNot(contains('helper')));
    });

    test('private decls of a re-exported file stay private', () {
      final dates = lib('pub fn format_date() { }\nfn pad() { }');
      final barrel = lib("pub import 'dates';", imports: {'dates': dates});
      expect(publicSurfaceOf(barrel).names, {'format_date'});
    });

    test('a name exported by two re-exports is a collision', () {
      final a = lib('pub fn format() { }');
      final b = lib('pub fn format() { }');
      final barrel = lib(
        "pub import 'a';\npub import 'b';",
        imports: {'a': a, 'b': b},
      );
      final surface = publicSurfaceOf(barrel);
      expect(surface.names, contains('format'));
      expect(surface.collisions, contains('format'));
    });

    test('re-export cycles terminate', () {
      // a pub-imports b; b pub-imports a — build the cycle and ensure no hang.
      final aProg = parse("pub import 'b';\npub fn a_fn() { }");
      final bProg = parse("pub import 'a';\npub fn b_fn() { }");
      final a = LibrarySource(aProg);
      final b = LibrarySource(bProg, imports: {'a': a});
      final aWithB = LibrarySource(aProg, imports: {'b': b});
      expect(publicSurfaceOf(aWithB).names, containsAll(['a_fn', 'b_fn']));
    });
  });

  group('namespacesFor', () {
    test('binds a namespace per import, named by the trailing segment', () {
      final fs = lib('pub fn read_text() { }');
      final strings = lib('pub fn trim() { }');
      final root = lib(
        "import std.fs;\nimport 'util/strings';",
        imports: {'std.fs': fs, 'util/strings': strings},
      );
      final ns = namespacesFor(root);
      expect(ns.keys, containsAll(['fs', 'strings']));
      expect(ns['fs']!.exposes('read_text'), isTrue);
      expect(ns['strings']!.exposes('trim'), isTrue);
    });

    test('an alias overrides the derived namespace', () {
      final fs = lib('pub fn read_text() { }');
      final root = lib('import std.fs as files;', imports: {'std.fs': fs});
      final ns = namespacesFor(root);
      expect(ns.keys, contains('files'));
      expect(ns.containsKey('fs'), isFalse);
    });

    test('importing a barrel exposes its flattened surface', () {
      final dates = lib('pub fn format_date() { }');
      final cli = lib("pub import 'dates';", imports: {'dates': dates});
      final root = lib('import std.cli;', imports: {'std.cli': cli});
      final ns = namespacesFor(root);
      expect(ns['cli']!.exposes('format_date'), isTrue);
    });
  });
}
