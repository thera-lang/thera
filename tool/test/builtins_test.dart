import 'package:hawk/src/element/builtins.dart';
import 'package:hawk/src/element/resolver.dart';
import 'package:hawk/src/element/types.dart';
import 'package:test/test.dart';

void main() {
  group('builtin method tables stay in lock-step', () {
    final returns = builtinReturns(builtinTypeDefs());

    test('every native-backed method has a return-type computation', () {
      builtinMethodNatives.forEach((kind, methods) {
        for (final method in methods.keys) {
          expect(returns[kind]?[method], isNotNull,
              reason: '$kind.$method has a native but no return type');
        }
      });
    });

    test('every return-type computation has a backing native', () {
      returns.forEach((kind, methods) {
        for (final method in methods.keys) {
          expect(builtinMethodNatives[kind]?[method], isNotNull,
              reason: '$kind.$method has a return type but no native');
        }
      });
    });

    test('return computations build the right types', () {
      // Only String remains here; the generic collection/enum methods moved to
      // Hawk `native fn`s (see sdk/std/core/{list,map,option}.hawk).
      final string = returns['String']!;
      expect(string['len']!(const [], const []), PrimitiveType.int_);
      expect(string['trim']!(const [], const []), PrimitiveType.string);
      // String.split_whitespace -> List<String>
      expect(string['split_whitespace']!(const [], const []).toString(),
          'List<String>');
    });
  });
}
