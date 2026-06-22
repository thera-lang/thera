# Conformance coverage map

**What this is:** the registry that maps each testable unit of the language
**spec** to a stable logical ID and its conformance-test status. It is the
breadth-first index for [`tests/lang/`](../tests/lang/README.md): a test cites a
logical ID in its `//! spec:` directive (e.g. `//! spec: expr-precedence`), and
this table says where that ID is defined in the spec and how well it's covered.

Citing a logical ID — rather than a raw doc anchor — keeps test citations stable
when headings are reworded: only this table moves. The harness's coverage report
(planned) diffs the `//! spec:` directives found in `tests/lang/` against this
table to find untested IDs.

The companion docs are [language.md](language.md) (semantics), [grammar.md](grammar.md)
(syntax), and [scoping.md](scoping.md) (name resolution).

## Status legend

| Mark | Meaning                                                              |
| ---- | ------------------------------------------------------------------- |
| ✓    | covered — a passing conformance test pins this                      |
| ◐    | partial — some cases covered, more to write                         |
| ✗    | none — no test yet                                                  |
| ⓧ    | xfail — spec is ahead of the implementation (a test exists, `xfail`) |
| ⚠    | mismatch — spec and implementation disagree; see [Findings](#findings) |

## Lexical & literals

| ID                  | Spec (grammar.md)        | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `lex-comments`      | Comments & whitespace    | `//` line comments only; no block comments                 | ✓      |
| `lex-int`           | Literals                 | decimal + `0x` hex; hex wraps into signed `Int`            | ✓      |
| `lex-float`         | Literals                 | digits both sides of `.`; no `1.` / `.5` / exponent        | ✓      |
| `lex-string-escape` | Literals                 | the 7 escapes + `\xNN` + `\u{…}`; unknown escape = error    | ✓      |
| `lex-string-interp` | Literals                 | `${expr}` interpolation                                    | ✓      |
| `lex-bool-unit`     | Literals                 | `true` / `false` / `void` keywords in expression position  | ✓      |

## Expressions & operators

| ID                  | Spec (grammar.md)        | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `expr-precedence`   | Operator precedence      | arithmetic/comparison precedence & left-assoc              | ✓      |
| `expr-unary`        | Operator precedence      | prefix `!` `-` `~`, right-assoc                            | ✓      |
| `expr-logical`      | Operator precedence      | `&&` `\|\|` and short-circuit evaluation                    | ✓      |
| `expr-bitwise`      | Operator precedence      | `&` `\|` `^` `~` (Int)                                      | ✓      |
| `expr-shift`        | Operator precedence      | `<<` `>>` (arith) `>>>` (logical), mask 0..63, Int-only     | ✓      |
| `expr-comparison`   | Operator precedence      | `== != < > <= >=`                                          | ✓      |
| `expr-range`        | Operator precedence      | `a..b`, non-associative                                    | ◐      |
| `expr-concat`       | language.md Types        | `+` concatenates strings                                   | ✓      |
| `expr-tail`         | language.md Tail exprs   | `if`/`match` as values (tail expression)                   | ✓      |
| `expr-semicolon`    | language.md Tail exprs   | `;` discards a tail; bare tail only in expr position       | ◐      |
| `expr-if-needs-else`| language.md Tail exprs   | `let x = if c { 1 }` (no else) is an error                 | ✓      |

## Types & values

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `type-primitives`   | Types → Primitives       | Int/Double/Bool/String/Void behavior                       | ✗      |
| `type-string-noindex`| Types → Primitives      | `s[i]` on a String is disallowed                          | ✗      |
| `type-list`         | Collections              | `List<T>` literal, `len`, indexing                        | ✗      |
| `type-map`          | Collections              | `Map<K,V>` literal, keyed access                          | ✗      |
| `type-set`          | Collections              | `Set<T>` uniqueness via `Set.from`                        | ✗      |
| `type-bytes`        | Types → Bytes            | `Bytes` immutability, `BytesBuilder`                      | ✗      |
| `type-struct`       | Structs                  | `type` decl, struct literal, field access                 | ✗      |
| `type-struct-immut` | Structs                  | struct fields immutable by default                        | ✗      |

## Variables & semantics

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `var-let-mut`       | Variables                | immutable by default; `mut` allows reassign                | ✗      |
| `var-let-immutable` | Variables                | reassigning a `let` is an error                            | ✗      |
| `var-references`    | Variables                | heap values are shared references                          | ✗      |

## Functions

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `fn-decl`           | Functions                | params, return type, default `Void` return                | ✗      |
| `fn-named-params`   | Named parameters         | label-by-name, `_` suppression, `external internal`        | ✗      |
| `fn-default-params` | Named parameters         | default parameter values                                  | ✗      |
| `fn-lambda`         | Functions                | `n => …` and `(a, b) => …` forms                          | ✗      |
| `fn-lambda-infer`   | Functions → Param types  | lambda param type from context; error when undetermined    | ✗      |
| `fn-closures`       | Functions                | capture by value; captured `mut` is shared                 | ✗      |
| `fn-types`          | Functions                | `(T) -> R` function-typed values                          | ✗      |

## Control flow

| ID                  | Spec                     | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `cf-if`             | Control flow             | `if`/`else` statement form                                | ✗      |
| `cf-for`            | Control flow             | `for x in` over lists and ranges                          | ✗      |
| `cf-while`          | grammar.md Statements    | `while` loop                                              | ✗      |
| `cf-match`          | grammar.md Patterns      | match dispatch; exhaustiveness assumption                  | ✗      |
| `cf-match-nested`   | grammar.md Patterns      | nested constructor patterns bind at leaves                 | ✗      |
| `cf-match-literal`  | grammar.md Patterns      | int/string/bool literal patterns (not float)               | ✗      |
| `cf-break-continue` | grammar.md Not-yet       | `break`/`continue` (unimplemented)                        | ⓧ      |

## Error handling

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `err-result-option` | Error handling / Option  | `Result`/`Option` as qualified-constructed prelude enums   | ✗      |
| `err-propagate`     | Error handling           | `?` propagates `Err` to the caller                        | ✗      |
| `err-throw`         | Error handling → throw   | `throw e` ≡ `return Result.Err(e)`                        | ✗      |
| `err-constructor`   | Error handling           | `error('…') -> Error` (lowercase) builds the simple error  | ⚠      |
| `err-implicit-ok`   | Error handling → throw   | `return n` implicitly `Result.Ok(n)`                      | ✗      |
| `fault-index`       | Runtime faults           | out-of-range list index / missing map key trap             | ✗      |
| `fault-div-zero`    | Runtime faults           | integer divide-by-zero traps                              | ✗      |
| `fault-get-checked` | Collections → get        | `.get(i)` returns `Option` instead of trapping            | ✗      |
| `int-wraps`         | Runtime faults           | `Int` arithmetic wraps (no overflow trap)                 | ✗      |

## Interfaces

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `iface-impl`        | Interfaces               | `impl Iface for T` checked for every method               | ✗      |
| `iface-inherent`    | Inherent methods         | `impl T { … }` inherent methods                           | ✗      |
| `iface-static`      | Static methods           | no-`self` methods called on the type                      | ✗      |
| `iface-display`     | Display and Debug        | `${}` requires `Display`; missing impl = error            | ✗      |
| `iface-debug`       | Display and Debug        | structural `Debug` derive for structs                     | ✗      |
| `iface-eq`          | Display and Debug        | `==` structural by default; explicit `impl Eq` overrides   | ✗      |
| `iface-inherit`     | Interface inheritance    | `interface E: Display + Debug` obligations & widened set   | ✗      |
| `iface-dispatch`    | Dispatch                 | dynamic dispatch for interface-typed values & bounds       | ✗      |
| `generic-bounds`    | Interfaces / Dispatch    | `<T: Eq + Debug>` enforced at call sites                  | ✗      |

## Imports, scoping & visibility

| ID                  | Spec (scoping.md)        | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `name-undefined`    | scoping.md               | a bare unknown name is a diagnostic                       | ◐      |
| `mod-import-ns`     | Imports                  | last path segment becomes the namespace                   | ✗      |
| `mod-import-as`     | Imports                  | `import … as alias` rebinds the prefix                    | ✗      |
| `mod-import-under`  | Imports                  | `import … as _` brings names in unqualified                | ✗      |
| `mod-prelude`       | Imports                  | `std.core` names available unqualified                    | ✗      |
| `mod-qualified-only`| scoping.md               | bare cross-library reference is rejected                  | ⓧ      |
| `vis-pub`           | Visibility               | non-`pub` top-level is file-private (enforced)            | ⓧ      |
| `vis-barrel`        | Visibility               | `pub import` re-exports; barrel conflict fails            | ✗      |
| `vis-whitebox-test` | Visibility / Testing     | `foo_test.hawk` sees `foo.hawk` privates                  | ✗      |

## Entry point & misc

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `entry-main`        | Entry point              | `main` signatures; `Int` return is the exit code          | ✗      |
| `entry-main-err`    | Entry point              | an `Err` result exits non-zero, message to stderr         | ✗      |
| `decorators`        | Decorators / annotations | `@name(args)` parse & attach (e.g. `@test`)               | ✗      |

## Findings

Discrepancies surfaced by the reconciliation pass — spec or implementation bugs
to fix, each ideally captured by a conformance test once resolved.

- **`err-constructor` — spec writes `Error('…')`, the API is `error('…')`.**
  The real prelude constructor is the lowercase `error(_ message: String) -> Error`
  (`sdk/std/core/error.hawk`); the corpus uses it 60×. But language.md still
  shows the capitalized `Error('usage: …')` in three examples (Error handling,
  Option, Command-line arguments), and an `args.hawk` doc-comment copies it.
  Worse, `hawk check` accepts `Error('x')` silently (checker leniency on an
  unknown callee), so the wrong form type-checks. Fix the docs; the silent-accept
  is a separate analysis gap (relates to the Unknown-leniency work).

- **`mod-qualified-only`, `vis-pub` — specified but not enforced.** Qualified-only
  cross-library access and `pub` visibility are documented as the rules but the
  resolver does not yet reject violations (tracked in scoping.md → Implementation
  gaps; the corpus is already migrated and guarded at 0 bare refs). Marked ⓧ
  until Phase 3 enforcement lands.

- **field access on a non-struct value** (e.g. `5.x`) slips past `check` and is
  caught only at codegen — a known analysis gap (deferred). A `check`-mode test
  under `type-struct` should pin the intended diagnostic once fixed.

- **`Double` Display for integral values — RESOLVED.** Integral `Double`s now
  render *with* a decimal point (`1.0` → `1.0`, not `1`), so `Double` output is
  visually distinct from `Int`. Specified in language.md (Types → Primitives),
  implemented in the runtime via the shared `value::format_double` (used by the
  `Display`, error-message, and `Debug` renderers), and pinned by `lex-float`.
