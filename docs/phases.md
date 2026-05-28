# Aero Toolchain: Implementation Phases

## Implementation language: Dart

Dart chosen over TypeScript for these reasons:

- **Familiarity** — faster iteration in a language the team knows well
- **Single-binary output** — `dart compile exe` produces a self-contained native binary,
  mirroring Aero's own distribution goal
- **Sealed classes + exhaustive switch** — Dart 3's pattern matching is a natural fit
  for AST-heavy compiler code
- **`petitparser`** — available if needed; hand-written recursive descent is sufficient
  for this grammar size

The bootstrap path: Dart → rewrite in Aero once the language is expressive enough to
implement a parser and interpreter.

## Project structure

```
tool/
  pubspec.yaml
  bin/
    aero.dart                  ← CLI: aero parse / run / check
  lib/
    src/
      token.dart               ← Token types and source spans
      lexer.dart               ← Source text → List<Token>
      ast.dart                 ← Sealed AST node hierarchy
      parser.dart              ← Token stream → Program AST
      interpreter/             ← Phase 2
        interpreter.dart
        environment.dart
        value.dart
        builtins.dart
      checker/                 ← Phase 4
        type_checker.dart
  test/
    lexer_test.dart
    parser_test.dart
```

---

## Phase 1 — Lexer + Parser ✅ (current)

**Milestone:** `aero parse examples/hello.aero` prints the AST without errors.

Covers:
- All token types present in existing `.aero` files
- String literals with `${}` interpolation — captured verbatim by the lexer,
  split into segments by the parser
- `native fn` declarations (no body)
- Decorators: `@test`, `@route`, etc.
- Named parameters at declaration sites (`_ name`, `default value`) and call
  sites (`flag: 'verbose'`)
- `for x in a..b` range syntax
- Generics in type refs and function signatures

---

## Phase 2 — AST Interpreter

**Milestone:** `aero run examples/hello.aero` prints `Hello, world!`.

Covers:
- Tree-walking evaluator over the Phase 1 AST
- Runtime `Value` sealed type: `IntValue`, `FloatValue`, `BoolValue`,
  `StringValue`, `ListValue`, `StructValue`, `FnValue`, `ResultValue`,
  `OptionValue`
- `Environment` scope chain (linked list of maps)
- `?` propagation: `PropagateException` thrown in Dart, caught at the nearest
  `Result`-returning function boundary
- `match` pattern binding: constructor patterns (`Ok(x)`, `Some(v)`),
  wildcard, identifier
- Built-in `println`, `print`, `eprintln`

---

## Phase 3 — Standard library + test runner

**Milestone:** `aero test examples/wordcount_test.aero` runs and passes all tests.

Native bindings to implement:
- `std.fs`: `read_text`, `write_text`, `exists`
- `std.process`: `run` (stdout/stderr capture, exit code as `Result`)
- `std.testing`: `assert_eq`, `assert`, `assert_ok`, `assert_err`
- `@test` decorator: collect test functions, run them, report pass/fail

---

## Phase 4 — Type checker

**Milestone:** `aero check examples/` reports type errors with line and column.

Covers:
- Type name resolution (struct fields, return types, generic instantiation)
- Function call arity and label name verification
- `Result`/non-`Result` mismatch at return sites
- Errors reported with `file:line:col: message` format

---

## Phase 5 — Self-hosting prerequisite

**Milestone:** `aero run tool_aero/lexer.aero -- examples/hello.aero` produces tokens.

Blocked on: file I/O, string manipulation, `List`/`Map`, sealed/enum types in
the interpreter, and recursive data structures all working end-to-end.

Once these work, start writing the Aero lexer in Aero itself as the first
self-hosting test.
