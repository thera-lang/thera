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
| `expr-loc`          | Metaconstants            | `#loc` → `SourceLoc`; as a default param, captures caller  | ✓      |

## Types & values

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `type-primitives`   | Types → Primitives       | Int/Double/Bool/String/Void behavior                       | ✓      |
| `type-string-noindex`| Types → Primitives      | `s[i]` on a String is disallowed                          | ✓      |
| `type-list`         | Collections              | `List<T>` literal, `len`, indexing                        | ✓      |
| `type-map`          | Collections              | `Map<K,V>` literal, keyed access                          | ✓      |
| `type-set`          | Collections              | `Set<T>` uniqueness via `Set.from`                        | ✓      |
| `gen-static-context`| Collections / Generics   | a generic static method (`Set.new()`) infers its owner `T` from call context | ✓ |
| `gen-static-recv-args`| Collections / Generics   | receiver type args on a static call (`Set<String>.new()`) bind the owner parameter | ✓ |
| `type-bytes`        | Types → Bytes            | `Bytes` len / `to_string` / `from_list` / `empty`         | ◐      |
| `type-native`       | Types → Built-ins        | `native type` decl: opaque, impl-extensible, no field layout| ✓     |
| `type-struct`       | Structs                  | `struct` decl, struct literal, field access               | ✓      |
| `type-struct-keyword` | Structs                | the removed `type Name = { … }` form is a parse error      | ✓     |
| `type-struct-immut` | Structs                  | struct fields immutable by default (non-`mut` assign = error)| ✓    |
| `type-mut-field`    | Structs                  | a `mut field: T` may be reassigned after construction     | ✓      |
| `type-field-nonstruct`| Structs                | a bare field access on a non-struct value is rejected     | ✓      |

## Variables & semantics

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `var-let-mut`       | Variables                | immutable by default; `mut` allows reassign                | ✓      |
| `var-let-immutable` | Variables                | reassigning a `let` (or a parameter) is an error          | ✓      |
| `var-references`    | Variables                | heap values are shared references                          | ✓      |
| `module-let-immutable`| module_init.md         | no top-level `let mut`; module globals are immutable       | ✓      |
| `module-let`        | module_init.md           | top-level `let` computed once into a stored global slot     | ⓧ      |

## Functions

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `fn-decl`           | Functions                | params, return type, default `Void` return                | ✓      |
| `fn-named-params`   | Named parameters         | label-by-name, `_` suppression, `external internal`        | ✓      |
| `fn-default-params` | Named parameters         | default parameter values                                  | ✓      |
| `fn-lambda`         | Functions                | `n => …` and `(a, b) => …` forms                          | ✓      |
| `fn-lambda-infer`   | Functions → Param types  | lambda param type from context; error when undetermined    | ✓      |
| `fn-closures`       | Functions                | capture by value; captured `mut` is shared                 | ✓      |
| `fn-types`          | Functions                | `(T) -> R` function-typed values                          | ✓      |

## Control flow

| ID                  | Spec                     | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `cf-if`             | Control flow             | `if`/`else` statement form                                | ✓      |
| `cf-for`            | Control flow             | `for x in` over lists and ranges                          | ✓      |
| `cf-while`          | grammar.md Statements    | `while` loop                                              | ✓      |
| `cf-match`          | grammar.md Patterns      | match dispatch; exhaustiveness assumption                  | ✓      |
| `cf-match-nested`   | grammar.md Patterns      | nested constructor patterns bind at leaves                 | ✓      |
| `cf-match-literal`  | grammar.md Patterns      | int/string/bool literal patterns (not float)               | ✓      |
| `cf-break-continue` | grammar.md Not-yet       | `break`/`continue` (unimplemented)                        | ⓧ      |

## Error handling

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `err-result-option` | Error handling / Option  | `Result`/`Option` as qualified-constructed prelude enums   | ✓      |
| `err-propagate`     | Error handling           | `?` propagates `Err` to the caller                        | ✓      |
| `err-throw`         | Error handling → throw   | `throw e` ≡ `return Result.Err(e)`                        | ✓      |
| `err-constructor`   | Error handling           | `error('…') -> Error` (lowercase) builds the simple error  | ✓      |
| `err-implicit-ok`   | Error handling → throw   | `return n` implicitly `Result.Ok(n)`                      | ✓      |
| `fault-index`       | Runtime faults           | out-of-range list index / missing map key trap             | ✓      |
| `fault-div-zero`    | Runtime faults           | integer divide-by-zero traps                              | ✓      |
| `fault-get-checked` | Collections → get        | `.get(i)` returns `Option` instead of trapping            | ✓      |
| `int-wraps`         | Runtime faults           | `Int` arithmetic wraps (no overflow trap)                 | ✓      |

## Interfaces

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `iface-impl`        | Interfaces               | `impl Iface for T` checked for every method               | ✓      |
| `iface-inherent`    | Inherent methods         | `impl T { … }` inherent methods                           | ✓      |
| `iface-static`      | Static methods           | no-`self` methods called on the type                      | ✓      |
| `iface-display`     | Display and Debug        | `${}` uses `Display` if present, else `Debug` (total)     | ✓      |
| `iface-debug`       | Display and Debug        | structural `Debug` derive for structs                     | ◐      |
| `iface-eq`          | Display and Debug        | `==` structural by default; explicit `impl Eq` overrides   | ✓      |
| `iface-ord`         | Interfaces / Dispatch    | `Ord.compare` → `Ordering`; primitives + user `impl Ord`; `<T: Ord>` dispatches dynamically | ✓ |
| `iface-inherit`     | Interface inheritance    | `interface E: Display + Debug` obligations & widened set   | ✓      |
| `iface-dispatch`    | Dispatch                 | dynamic dispatch for interface-typed values & bounds       | ✓      |
| `generic-bounds`    | Interfaces / Dispatch    | `<T: Eq + Debug>` enforced at call sites                  | ✓      |
| `generic-type-bounds`| Interfaces / Dispatch    | a bound on a generic type's own parameter (`Box<T: Display>`) is enforced on its type arguments | ✓ |

## Imports, scoping & visibility

| ID                  | Spec (scoping.md)        | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `name-undefined`    | scoping.md               | a bare unknown name is a diagnostic                       | ✓      |
| `mod-import-ns`     | Imports                  | last path segment becomes the namespace                   | ✓      |
| `mod-import-as`     | Imports                  | `import … as alias` rebinds the prefix                    | ✓      |
| `mod-import-under`  | Imports                  | `import … as _` brings names in unqualified                | ✓      |
| `mod-prelude`       | Imports                  | `std.core` names available unqualified                    | ✓      |
| `mod-qualified-only`| scoping.md               | bare cross-library reference is rejected                  | ✓      |
| `mod-ns-file-local` | scoping.md               | a namespace is file-local; qualifying with one this file didn't import is rejected | ✓ |
| `mod-no-bare-fallback`| scoping.md             | a bare name owned by an un-imported (closure-only) library is `undefined` — no global last-wins fallback | ✓ |
| `mod-shared-value-name`| scoping.md              | two libraries may share a top-level value name; each qualified call dispatches to its own library (value-uniqueness lift) | ✓ |
| `vis-pub`           | Visibility               | non-`pub` top-level is file-private (enforced)            | ✓      |
| `vis-barrel`        | Visibility               | barrel re-exports a directory library's symbols (std.cli) | ◐      |
| `vis-whitebox-test` | Visibility / Testing     | `foo_test.hawk` sees `foo.hawk` privates (bare)           | ✓      |

## Entry point & misc

| ID                  | Spec (language.md)       | Pins                                                        | Status |
| ------------------- | ------------------------ | ---------------------------------------------------------- | ------ |
| `entry-main`        | Entry point              | `main` signatures; `Int` return is the exit code          | ✓      |
| `entry-main-err`    | Entry point              | an `Err` result exits non-zero, message to stderr         | ✓      |
| `decorators`        | Decorators / annotations | `@name(args)` parse & attach (e.g. `@test`)               | ✓      |

## Findings

Discrepancies surfaced by the reconciliation pass. The reconciliation drove a
sweep of enforcement fixes (now in [Resolved](#resolved-changelog)); what remains
open is below.

### Open

- **Resolution is correct for *values*, not yet for *types*** (scoping.md gaps
  1/2/5). Per-file namespaces (gap 3) and per-file bare *value* resolution (gap 1
  for values) are enforced with no global last-wins fallback — pinned by
  `mod-ns-file-local`, `mod-no-bare-fallback`, `vis-whitebox-test`. Still open: the
  same per-file gate for bare **type** references (`check_type_ref` consults the
  flat `type_defs`), surface-checked within-library qualified resolution (gap 2),
  and physical per-library ownership of the flat tables (gap 5; same-name
  cross-file collisions are guarded by the duplicate-name diagnostic, not yet by
  ownership). `qualify_lint`/`visibility_lint` still enforce the qualified-only +
  `pub` rules and own the "qualify as `ns.name`" message; they retire once the
  above lands. See [scoping.md](scoping.md).

- **`iface-debug` — structural `Debug` derive not accepted as a `Debug` value**
  (◐). A struct with no explicit `impl Debug` is rejected where a `Debug`-typed
  argument is expected, though language.md says `Debug` is auto-derived; the tests
  work around it with an explicit `impl Debug`. Likewise `.debug()`/`.eq()` aren't
  directly callable on a concrete type without an impl — reachable only via
  dispatch.

- **`check` leniency on an unknown callee.** A call to an undefined free function
  (e.g. the old capitalized `Error('x')`) type-checks silently — the checker is
  lenient on unknown callees (part of the Unknown-leniency feedback-loop work).
  Shrinking this is its own arc.

- **`vis-whitebox-test` — intentionally untested in this harness** (✗). A
  `foo_test.hawk` seeing `foo.hawk`'s privates is exercised by the project's real
  `_test.hawk` suites, but not pinnable in `tests/lang/`, since this harness drives
  `hawk run`/`check`, not `hawk test`.

### Resolved (changelog)

Each is now pinned by the cited conformance test(s); see git history for the
implementation detail.

- **`mod-qualified-only`, `vis-pub`** — a bare cross-library reference and a
  qualified access to a non-public member are both `check` errors (`qualify_lint`
  / `visibility_lint`). Corpus had 0 of each.
- **immutability, uniform** (`var-let-immutable`, `type-struct-immut`,
  `type-mut-field`) — reassigning a non-`mut` `let`/param *and* assigning a
  non-`mut` field are errors; `mut` opts in. 62 field sites migrated.
- **`type-field-nonstruct`** — a bare field access on a primitive receiver
  (`5.x`) is a `check` error.
- **`type-string-noindex`** — `s[i]` on a `String` is rejected at `check`.
- **`iface-display`** — total rendering: `${}` / `println` use a value's
  `Display` if it has one, else its auto-derived `Debug` (Debug-fallback), so
  interpolation works for any value and is never a `check` error.
- **trap messages** — faults abort with a human-readable `hawk: trap: <message>`
  (`impl Display for Trap`); `MissingKey` names the key. Pinned by `fault-*`.
- **`Double` Display for integral values** — `1.0` renders as `1.0`, not `1`
  (`value::format_double`). Pinned by `lex-float`.
- **`err-constructor` docs** — language.md now shows the lowercase `error('…')`
  (the capitalized `Error('…')` examples were corrected).
