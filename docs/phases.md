# Hawk Toolchain: Implementation Phases

## Implementation language: Dart

Dart chosen over TypeScript for these reasons:

- **Familiarity** — faster iteration in a language the team knows well
- **Single-binary output** — `dart compile exe` produces a self-contained native
  binary, mirroring Hawk's own distribution goal
- **Sealed classes + exhaustive switch** — Dart 3's pattern matching is a
  natural fit for AST-heavy compiler code
- **`petitparser`** — available if needed; hand-written recursive descent is
  sufficient for this grammar size

The bootstrap path: Dart → rewrite in Hawk once the language is expressive
enough to implement a parser and interpreter.

## Project structure

```
<sdk_root>/
  bin/
    hawk.sh                    ← dev entry point (delegates to tool/)
  sdk/std/                     ← stdlib source files
    core.hawk, args.hawk, fs.hawk, ...
  tool/                        ← Dart toolchain (dev only; not in distributed SDK)
    pubspec.yaml
    bin/
      hawk.dart                ← CLI entry point
    lib/sdk/
      token.dart               ← Token types and source spans
      lexer.dart               ← Source text → List<Token>
      ast.dart                 ← Sealed AST node hierarchy
      parser.dart              ← Token stream → Program AST
      source_provider.dart     ← Overlay FS abstraction (for LSP)
      interpreter/             ← Phase 2
        interpreter.dart
        environment.dart
        value.dart
      checker/                 ← Phase 4
        type_checker.dart
      lsp/                     ← LSP server
        server.dart
    test/
      parser_test.dart
      checker_test.dart
      lsp_server_test.dart
```

---

## Phase 1 — Lexer + Parser ✅

**Milestone:** `hawk parse examples/hello.hawk` prints the AST without errors.

Covers:

- All token types present in existing `.hawk` files
- String literals with `${}` interpolation — captured verbatim by the lexer,
  split into segments by the parser
- `native fn` declarations (no body)
- Decorators: `@test`, `@route`, etc.
- Named parameters at declaration sites (`_ name`, `default value`) and call
  sites (`flag: 'verbose'`)
- `for x in a..b` range syntax
- Generics in type refs and function signatures

---

## Phase 2 — AST Interpreter ✅

**Milestone:** `hawk run examples/hello.hawk` prints `Hello, world!`.

Covers:

- Tree-walking evaluator over the Phase 1 AST
- Runtime `Value` sealed type: `IntValue`, `FloatValue`, `BoolValue`,
  `StringValue`, `ListValue`, `StructValue`, `FnValue`, `ResultValue`,
  `OptionValue`
- `Environment` scope chain (linked list of maps)
- `?` propagation: `PropagateException` thrown in Dart, caught at the nearest
  `Result`-returning function boundary
- `match` pattern binding: constructor patterns (`Ok(x)`, `Some(v)`), wildcard,
  identifier
- Built-in `println`, `print`, `eprintln`

---

## Phase 3 — Standard library + test runner ✅

**Milestone:** `hawk test examples/wordcount_test.hawk` runs and passes all
tests.

Native bindings to implement:

- `std.fs`: `read_text`, `write_text`, `exists`
- `std.process`: `run` (stdout/stderr capture, exit code as `Result`)
- `std.testing`: `assert_eq`, `assert`, `assert_ok`, `assert_err`
- `@test` decorator: collect test functions, run them, report pass/fail

---

## Phase 4 — Type checker ✅

**Milestone:** `hawk check examples/` reports type errors with line and column.

Covers:

- Type name resolution (struct fields, return types, generic instantiation)
- Function call arity and label name verification
- `Result`/non-`Result` mismatch at return sites
- Errors reported with `file:line:col: message` format

---

## Phase 5 — Self-hosting prerequisite ✅

**Milestone:** `hawk run tool_hawk/lexer.hawk -- examples/hello.hawk` produces
tokens.

Blocked on:

- [x] file I/O
- [x] string manipulation
- [x] `List`
- [x] `Map`
- [x] implement static dispatch
- [x] enum types in the interpreter
- [x] recursive data structures all working end-to-end

Once these work, start writing the Hawk lexer in Hawk itself as the first
self-hosting test.
