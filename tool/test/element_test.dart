import 'package:hawk/src/ast.dart';
import 'package:hawk/src/element/element.dart';
import 'package:hawk/src/element/namespace.dart';
import 'package:hawk/src/element/resolver.dart';
import 'package:hawk/src/element/types.dart';
import 'package:hawk/src/lexer.dart';
import 'package:hawk/src/parser.dart';
import 'package:test/test.dart';

LibraryElement build(String source, {List<String> imports = const []}) {
  Program parse(String src) {
    final lex = Lexer(src).tokenize();
    expect(lex.hasErrors, isFalse, reason: 'lex errors: ${lex.errors}');
    final p = Parser(lex.tokens).parse();
    expect(p.hasErrors, isFalse, reason: 'parse errors: ${p.errors}');
    return p.program;
  }

  return buildLibrary(parse(source),
      imports: [for (final src in imports) parse(src)]);
}

void main() {
  group('Type model', () {
    test('primitive equality and rendering', () {
      expect(PrimitiveType.int_, equals(PrimitiveType.int_));
      expect(PrimitiveType.int_, isNot(equals(PrimitiveType.bool_)));
      expect(PrimitiveType.int_.toString(), 'Int');
      expect(PrimitiveType.unit.toString(), 'Void');
    });

    test('interface type rendering with args', () {
      final list = BuiltinTypeElement('List', typeParameters: ['T']);
      final t = InterfaceType(list, [PrimitiveType.int_]);
      expect(t.toString(), 'List<Int>');
      expect(InterfaceType(list).toString(), 'List');
    });

    test('interface type equality compares element and args', () {
      final list = BuiltinTypeElement('List', typeParameters: ['T']);
      expect(InterfaceType(list, [PrimitiveType.int_]),
          equals(InterfaceType(list, [PrimitiveType.int_])));
      expect(InterfaceType(list, [PrimitiveType.int_]),
          isNot(equals(InterfaceType(list, [PrimitiveType.bool_]))));
    });

    test('unknown type is its own equality class', () {
      expect(const UnknownType(), equals(const UnknownType()));
    });
  });

  group('TypeResolver', () {
    final resolver = TypeResolver(builtinTypeDefs());

    test('resolves primitives', () {
      expect(resolver.resolve(NamedType('Int')), PrimitiveType.int_);
      expect(resolver.resolve(NamedType('String')), PrimitiveType.string);
      expect(resolver.resolve(NamedType('Float')), PrimitiveType.double_);
      expect(resolver.resolve(const VoidType()), PrimitiveType.unit);
    });

    test('null ref resolves to unknown', () {
      expect(resolver.resolve(null), const UnknownType());
    });

    test('resolves built-in generic with args', () {
      final t = resolver.resolve(NamedType('List', args: [NamedType('Int')]))
          as InterfaceType;
      expect(t.element.name, 'List');
      expect(t.typeArguments, [PrimitiveType.int_]);
    });

    test('type parameter in scope resolves to TypeParameterType', () {
      expect(resolver.resolve(NamedType('T'), typeParams: {'T'}),
          const TypeParameterType('T'));
    });

    test('unknown name resolves to unknown', () {
      expect(resolver.resolve(NamedType('Ghost')), const UnknownType());
    });

    test('Self resolves to the provided self type', () {
      final selfType = InterfaceType(BuiltinTypeElement('Box'));
      expect(resolver.resolve(NamedType('Self'), selfType: selfType), selfType);
    });
  });

  group('buildLibrary', () {
    test('struct fields are resolved to types', () {
      final lib = build('type Point = { x: Int, y: Int }');
      final point = lib.typeDefs['Point'] as StructElement;
      expect(point.fields['x'], PrimitiveType.int_);
      expect(point.fields['y'], PrimitiveType.int_);
    });

    test('generic struct field uses a type parameter', () {
      final lib = build('type Box<T> = { value: T }');
      final box = lib.typeDefs['Box'] as StructElement;
      expect(box.typeParameters, ['T']);
      expect(box.fields['value'], const TypeParameterType('T'));
    });

    test('enum variants carry resolved payload types', () {
      final lib = build('enum Shape { Circle(Int), Empty }');
      final shape = lib.typeDefs['Shape'] as EnumElement;
      expect(shape.variant('Circle')!.fields, [PrimitiveType.int_]);
      expect(shape.variant('Empty')!.fields, isEmpty);
    });

    test('function signature is resolved', () {
      final lib = build('fn add(a: Int, b: Int) -> Int { return 0; }');
      final add = lib.functions['add']!;
      expect(add.parameters.map((p) => p.type), [
        PrimitiveType.int_,
        PrimitiveType.int_,
      ]);
      expect(add.returnType, PrimitiveType.int_);
    });

    test('function with omitted return type is unit', () {
      final lib = build('fn f() { }');
      expect(lib.functions['f']!.returnType, PrimitiveType.unit);
    });

    test('impl methods attach to the type element', () {
      final lib = build('''
type Point = { x: Int, y: Int }
impl Point {
  fn origin() -> Point { return Point { x: 0, y: 0 }; }
  fn x_of(self) -> Int { return self.x; }
}
''');
      final point = lib.typeDefs['Point'] as StructElement;
      final origin = point.method('origin')!;
      expect(origin.isStatic, isTrue);
      expect((origin.returnType as InterfaceType).element, point);

      final xOf = point.method('x_of')!;
      expect(xOf.isStatic, isFalse);
      expect(xOf.returnType, PrimitiveType.int_);
    });

    test('generic impl resolves self type with type arguments', () {
      final lib = build('''
type Box<T> = { value: T }
impl Box<T> {
  fn get(self) -> T { return self.value; }
}
''');
      final box = lib.typeDefs['Box'] as StructElement;
      final get = box.method('get')!;
      expect(get.returnType, const TypeParameterType('T'));
      final selfParam = get.parameters.firstWhere((p) => p.isSelf);
      final selfType = selfParam.type as InterfaceType;
      expect(selfType.element, box);
      expect(selfType.typeArguments, [const TypeParameterType('T')]);
    });

    test('imports are registered and shadowed by the primary program', () {
      final lib = build(
        'type Point = { x: Int, y: Int }',
        imports: ['type Counts = { lines: Int }'],
      );
      expect(lib.typeDefs.containsKey('Counts'), isTrue);
      expect(lib.typeDefs.containsKey('Point'), isTrue);
    });

    test('const type is resolved', () {
      final lib = build('const SPACE: Int = 32;');
      expect(lib.consts['SPACE']!.type, PrimitiveType.int_);
    });

    test('import module alias is recorded', () {
      final lib = build('import std.fs');
      expect(lib.modules, contains('fs'));
    });

    test('built-in generic types are present', () {
      final lib = build('');
      expect(lib.typeDefs['List']!.typeParameters, ['T']);
      expect(lib.typeDefs['Map']!.typeParameters, ['K', 'V']);
      expect(lib.typeDefs['Result']!.typeParameters, ['T', 'E']);
    });

    test('namespaces thread through to the LibraryElement', () {
      final fs = LibrarySource(
          Parser(Lexer('pub fn read_text() { }').tokenize().tokens)
              .parse()
              .program);
      final root = LibrarySource(
          Parser(Lexer('import std.fs;').tokenize().tokens).parse().program,
          imports: {'std.fs': fs});
      final lib = buildLibrary(root.program, namespaces: namespacesFor(root));
      expect(lib.namespaces.keys, contains('fs'));
      expect(lib.namespaces['fs']!.exposes('read_text'), isTrue);
      // Default (no namespaces) stays empty — flat-resolution fallback.
      expect(build('').namespaces, isEmpty);
    });
  });
}
