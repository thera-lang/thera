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

    test('return computations are generic-aware', () {
      // List<Int>.get -> Option<Int>
      final get = returns['List']!['get']!([PrimitiveType.int_], const []);
      expect(get.toString(), 'Option<Int>');
      // Map<String, Int>.values -> List<Int>
      final values = returns['Map']!['values']!(
          [PrimitiveType.string, PrimitiveType.int_], const []);
      expect(values.toString(), 'List<Int>');
      // Option<Int>.unwrap_or(...) -> Int
      final unwrap =
          returns['Option']!['unwrap_or']!([PrimitiveType.int_], const []);
      expect(unwrap, PrimitiveType.int_);
    });
  });
}
