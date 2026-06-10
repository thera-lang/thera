import 'dart:io';

import 'package:hawk/src/token.dart';
import 'package:test/test.dart';

/// Guards docs/grammar.md against drift from the lexer. The grammar doc is
/// hand-maintained (the parser is the source of truth), so this test keeps the
/// lexical half honest: every reserved keyword must appear in the doc's keyword
/// list, and the doc must not advertise a keyword the lexer doesn't reserve.
void main() {
  // The test runs from the `tool/` package root; the doc is one level up.
  final grammar = File('../docs/grammar.md');

  test('docs/grammar.md exists', () {
    expect(grammar.existsSync(), isTrue,
        reason: 'expected ${grammar.absolute.path}');
  });

  test('every reserved keyword is documented in grammar.md', () {
    final text = grammar.readAsStringSync();
    // The "### Keywords" section lists the spellings as a whitespace-separated
    // block; pull just that block so we don't match a keyword used incidentally
    // in prose elsewhere.
    final section =
        RegExp(r'### Keywords[\s\S]*?```([\s\S]*?)```').firstMatch(text);
    expect(section, isNotNull,
        reason: 'no fenced Keywords block in grammar.md');
    final listed = section!
        .group(1)!
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toSet();

    final reserved = keywordSpellings;
    expect(listed.difference(reserved), isEmpty,
        reason: 'grammar.md lists non-keywords in its Keywords block');
    expect(reserved.difference(listed), isEmpty,
        reason: 'grammar.md is missing reserved keyword(s) — add them to the '
            '### Keywords block');
  });
}
