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

The companion docs are [language.md](language.md) (semantics & name resolution)
and [grammar.md](grammar.md) (syntax).

## Status legend

| Mark | Meaning                                                                |
| ---- | ---------------------------------------------------------------------- |
| ✓    | covered — a passing conformance test pins this                         |
| ◐    | partial — some cases covered, more to write                            |
| ✗    | none — no test yet                                                     |
| ⓧ    | xfail — spec is ahead of the implementation (a test exists, `xfail`)   |
| ⚠    | mismatch — spec and implementation disagree; see [Findings](#findings) |

## Lexical & literals

| ID                    | Spec (grammar.md)       | Pins                                                                                                                     | Status |
| --------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------ |
| `lex-comments`        | Comments & whitespace   | `//` line comments only; no block comments                                                                               | ✓      |
| `lex-interp-errors`   | Strings / Interpolation | a syntax error inside `${...}` is a located parse error with a real file span (empty `${}` and trailing tokens included) | ✓      |
| `parse-recovery-sync` | Parsing / Recovery      | error recovery resyncs at a top-level declaration boundary, brace-aware — no phantom declarations or cascades            | ✓      |
| `lex-int`             | Literals                | decimal + `0x` hex; hex wraps into signed `Int`                                                                          | ✓      |
| `lex-float`           | Literals                | digits both sides of `.`; no `1.` / `.5` / exponent                                                                      | ✓      |
| `lex-string-escape`   | Literals                | the 7 escapes + `\xNN` + `\u{…}`; unknown escape = error                                                                 | ✓      |
| `lex-string-interp`   | Literals                | `${expr}` interpolation                                                                                                  | ✓      |
| `lex-bool-unit`       | Literals                | `true` / `false` / `void` keywords in expression position                                                                | ✓      |

## Expressions & operators

| ID                     | Spec (grammar.md)      | Pins                                                                                                                                                  | Status |
| ---------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `expr-precedence`      | Operator precedence    | arithmetic/comparison precedence & left-assoc                                                                                                         | ✓      |
| `expr-unary`           | Operator precedence    | prefix `!` `-` `~`, right-assoc                                                                                                                       | ✓      |
| `expr-logical`         | Operator precedence    | `&&` `\|\|` and short-circuit evaluation                                                                                                              | ✓      |
| `expr-bitwise`         | Operator precedence    | `&` `\|` `^` `~` (Int)                                                                                                                                | ✓      |
| `expr-shift`           | Operator precedence    | `<<` `>>` (arith) `>>>` (logical), mask 0..63, Int-only                                                                                               | ✓      |
| `expr-comparison`      | Operator precedence    | `== != < > <= >=`                                                                                                                                     | ✓      |
| `expr-range`           | Operator precedence    | `a..b`, non-associative                                                                                                                               | ◐      |
| `expr-concat`          | language.md Types      | `+` concatenates strings                                                                                                                              | ✓      |
| `expr-operator-types`  | Operator precedence    | operands type-checked: same-typed Int/Double (+String for `+`), Bool for logical/`!`, Int for `%`/bitwise, agreeing `==`/`!=`; no Int↔Double coercion | ✓      |
| `expr-lt-ambiguity`    | Expressions / Generics | `name<...>` commits to type args only before `(`/`.`; `a < b > (c)` is a checked error, chains parse as comparisons                                   | ✓      |
| `expr-tail`            | language.md Tail exprs | `if`/`match` as values (tail expression)                                                                                                              | ✓      |
| `expr-if-branch-types` | language.md Tail exprs | an expression-position `if`'s branches must agree in type (value-less/exiting branches exempt)                                                        | ✓      |
| `expr-semicolon`       | language.md Tail exprs | `;` discards a tail; bare tail only in expr position                                                                                                  | ◐      |
| `expr-if-needs-else`   | language.md Tail exprs | `let x = if c { 1 }` (no else) is an error                                                                                                            | ✓      |
| `expr-loc`             | Metaconstants          | `#loc` → `SourceLoc`; as a default param, captures caller                                                                                             | ✓      |

## Types & values

| ID                            | Spec (language.md)     | Pins                                                                                                                                   | Status |
| ----------------------------- | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `type-primitives`             | Types → Primitives     | Int/Double/Bool/String/Void behavior                                                                                                   | ✓      |
| `type-string-noindex`         | Types → Primitives     | `s[i]` on a String is disallowed                                                                                                       | ✓      |
| `type-list`                   | Collections            | `List<T>` literal, `len`, indexing                                                                                                     | ✓      |
| `type-map`                    | Collections            | `Map<K,V>` literal, keyed access                                                                                                       | ✓      |
| `type-map-bracket`            | Collections            | bracket map literals `[k: v, …]` / empty `[:]`: unrestricted keys, valid in any expression position (incl. match arms)                 | ✓      |
| `type-set`                    | Collections            | `Set<T>` uniqueness via `Set.from`                                                                                                     | ✓      |
| `gen-static-context`          | Collections / Generics | a generic static method (`Set.new()`) infers its owner `T` from call context                                                           | ✓      |
| `gen-static-recv-args`        | Collections / Generics | receiver type args on a static call (`Set<String>.new()`) bind the owner parameter                                                     | ✓      |
| `gen-call-nested-args`        | Collections / Generics | nested generics in call-position type args (`make<List<Int>>()`, `Set<List<Int>>.new()`); comparison chains unaffected                 | ✓      |
| `type-bytes`                  | Types → Bytes          | `Bytes` len / `to_string` / `from_list` / `empty`                                                                                      | ◐      |
| `type-native`                 | Types → Built-ins      | `native type` decl: opaque, impl-extensible, no field layout                                                                           | ✓      |
| `type-struct`                 | Structs                | `struct` decl, struct literal, field access                                                                                            | ✓      |
| `type-struct-keyword`         | Structs                | the removed `type Name = { … }` form is a parse error                                                                                  | ✓      |
| `type-struct-field-let`       | Structs                | a struct field must be declared with `let` (`let x: T;`) — parse error otherwise                                                       | ✓      |
| `type-struct-field-semicolon` | Structs                | struct fields are terminated with `;`, not separated by `,` — parse error otherwise                                                    | ✓      |
| `type-struct-immut`           | Structs                | struct fields immutable by default (non-`mut` assign = error)                                                                          | ✓      |
| `type-mut-field`              | Structs                | a `mut field: T` may be reassigned after construction                                                                                  | ✓      |
| `type-struct-fields-required` | Structs                | a struct literal must provide every declared field — a `check` diagnostic                                                              | ✓      |
| `type-enum-nonempty`          | Enums                  | an enum must declare at least one variant — a zero-variant enum is a parse error                                                       | ✓      |
| `type-reserved-names`         | language.md            | the language's own type names (Result, Option, List, Void, …) may not be declared in user code; core utility names (Args, …) stay free | ✓      |
| `type-fn-variance`            | Types                  | function-type assignability: contravariant parameters, covariant result                                                                | ✓      |
| `type-field-nonstruct`        | Structs                | a bare field access on a non-struct value is rejected                                                                                  | ✓      |
| `type-impl-param-bare`        | Impl blocks            | an inherent `impl Type<…>` element must be a bare parameter name (a type expression is an error, not silently flattened)               | ✓      |

## Variables & semantics

| ID                            | Spec (language.md) | Pins                                                                                           | Status |
| ----------------------------- | ------------------ | ---------------------------------------------------------------------------------------------- | ------ |
| `var-let-mut`                 | Variables          | immutable by default; `mut` allows reassign                                                    | ✓      |
| `var-let-immutable`           | Variables          | reassigning a `let` (or a parameter) is an error                                               | ✓      |
| `var-assign-type`             | Variables          | an assignment's value must match the target's type (binding, element, field)                   | ✓      |
| `var-expr-position-immutable` | Variables          | immutability enforced inside expression-position blocks/`if`s/match arms                       | ✓      |
| `var-references`              | Variables          | heap values are shared references                                                              | ✓      |
| `var-block-scope`             | Variables          | block/arm/loop bindings shadow lexically; the outer binding (value and type) restores after    | ✓      |
| `module-let-immutable`        | language.md        | no top-level `let mut`; module globals are immutable                                           | ✓      |
| `module-let`                  | language.md        | top-level `let` computed once into a stored global slot                                        | ✓      |
| `module-let-order`            | language.md        | initializers run in dependency order; a cycle is an error                                      | ◐      |
| `module-let-cross-module`     | language.md        | imported globals initialize before an importer's that use them                                 | ✓      |
| `const-manifest`              | language.md        | `const` must be compile-time evaluable; computed -> use `let`                                  | ✓      |
| `const-inline-scope`          | language.md        | a const's inlined initializer evaluates in the const's own top-level scope, not the consumer's | ✓      |

## Functions

| ID                    | Spec (language.md)      | Pins                                                                                                           | Status |
| --------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------- | ------ |
| `fn-decl`             | Functions               | params, return type, default `Void` return                                                                     | ✓      |
| `fn-named-params`     | Named parameters        | label-by-name, `_` suppression, `external internal`                                                            | ✓      |
| `fn-labeled-reorder`  | Named parameters        | labeled args in any order; an un-annotated lambda types (and compiles) against the parameter its label targets | ✓      |
| `fn-call-args`        | Functions → Calls       | argument diagnostics (type mismatch, unknown label, bound violation) anchor to the offending argument          | ✓      |
| `gen-arg-consistency` | Functions → Generics    | a type parameter must bind consistently across a call's arguments; undetermined bindings stay lenient          | ✓      |
| `fn-default-params`   | Named parameters        | default parameter values                                                                                       | ✓      |
| `fn-lambda`           | Functions               | `n => …` and `(a, b) => …` forms                                                                               | ✓      |
| `fn-lambda-infer`     | Functions → Param types | lambda param type from context (incl. if/block tails, static-method args); error when undetermined             | ✓      |
| `fn-closures`         | Functions               | capture by value; captured `mut` is shared                                                                     | ✓      |
| `fn-types`            | Functions               | `(T) -> R` function-typed values                                                                               | ✓      |

## Control flow

| ID                       | Spec                   | Pins                                                                                                                                          | Status |
| ------------------------ | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `cf-if`                  | Control flow           | `if`/`else` statement form                                                                                                                    | ✓      |
| `cf-if-let`              | Control flow           | `if let PAT = e { … }` conditional binding (statement/value/`else if let`/nested)                                                             | ✓      |
| `cf-if-let-needs-else`   | Control flow           | value `if let` with no `else` is an error                                                                                                     | ✓      |
| `cf-let-else`            | Control flow           | `let PAT = e else { … }` bind-or-diverge guard (single/assertion/`throw`)                                                                     | ✓      |
| `cf-let-else-diverge`    | Control flow           | `let … else` whose `else` doesn't diverge is an error                                                                                         | ✓      |
| `cf-for`                 | Control flow           | `for x in` over lists and ranges                                                                                                              | ✓      |
| `cf-while`               | grammar.md Statements  | `while` loop                                                                                                                                  | ✓      |
| `cf-match`               | grammar.md Patterns    | match dispatch; exhaustiveness assumption                                                                                                     | ✓      |
| `cf-match-nested`        | grammar.md Patterns    | nested constructor patterns bind at leaves                                                                                                    | ✓      |
| `cf-match-exhaustive`    | grammar.md Patterns    | a match must be exhaustive: enum = all variants or catch-all; Bool = both literals; other subjects = catch-all                                | ✓      |
| `cf-match-variant-check` | grammar.md Patterns    | a constructor pattern (incl. nested payloads; capitalized bare = zero-arg constructor) must name a real variant — a `check` diagnostic        | ✓      |
| `cf-match-arm-comma`     | grammar.md Expressions | the `,` after an expression-bodied match arm is required (trailing comma optional; block arms need none) — a parse error                      | ✓      |
| `cf-match-literal`       | grammar.md Patterns    | int/string/bool literal patterns (not float)                                                                                                  | ✓      |
| `cf-match-literal-type`  | grammar.md Patterns    | a literal pattern whose type can never equal the subject's is a `check` error                                                                 | ✓      |
| `cf-break-continue`      | grammar.md Statements  | `break` exits / `continue` advances the innermost loop (while/range/list); statement-only, a `check` error outside a loop or across a closure | ✓      |

## Error handling

| ID                     | Spec (language.md)      | Pins                                                       | Status |
| ---------------------- | ----------------------- | ---------------------------------------------------------- | ------ |
| `err-result-option`    | Error handling / Option | `Result`/`Option` as qualified-constructed prelude enums   | ✓      |
| `err-propagate`        | Error handling          | `?` propagates `Err` to the caller                         | ✓      |
| `err-propagate-option` | Error handling / Option | `?` on an `Option` propagates `None` (Option-returning fn) | ✓      |
| `err-propagate-cross`  | Error handling          | cross-family `?` (Option `?` in a Result fn) is rejected   | ✓      |
| `err-throw`            | Error handling → throw  | `throw e` ≡ `return Result.Err(e)`                         | ✓      |
| `err-constructor`      | Error handling          | `error('…') -> Error` (lowercase) builds the simple error  | ✓      |
| `err-implicit-ok`      | Error handling → throw  | `return n` implicitly `Result.Ok(n)`                       | ✓      |
| `fault-index`          | Runtime faults          | out-of-range list index / missing map key trap             | ✓      |
| `fault-div-zero`       | Runtime faults          | integer divide-by-zero traps                               | ✓      |
| `fault-get-checked`    | Collections → get       | `.get(i)` returns `Option` instead of trapping             | ✓      |
| `int-wraps`            | Runtime faults          | `Int` arithmetic wraps (no overflow trap)                  | ✓      |

## Interfaces

| ID                     | Spec (language.md)    | Pins                                                                                                                                                                                   | Status |
| ---------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `iface-impl`           | Interfaces            | `impl Iface for T` checked for every method                                                                                                                                            | ✓      |
| `iface-inherent`       | Inherent methods      | `impl T { … }` inherent methods                                                                                                                                                        | ✓      |
| `iface-static`         | Static methods        | no-`self` methods called on the type                                                                                                                                                   | ✓      |
| `iface-display`        | Display and Debug     | `${}` uses `Display` if present, else `Debug` (total)                                                                                                                                  | ✓      |
| `iface-debug`          | Display and Debug     | structural `Debug` derive for structs                                                                                                                                                  | ◐      |
| `iface-eq`             | Display and Debug     | `==` structural by default; explicit `impl Eq` overrides                                                                                                                               | ✓      |
| `iface-ord`            | Interfaces / Dispatch | `Ord.compare` → `Ordering`; primitives + user `impl Ord`; `<T: Ord>` dispatches dynamically                                                                                            | ✓      |
| `iface-inherit`        | Interface inheritance | `interface E: Display + Debug` obligations & widened set                                                                                                                               | ✓      |
| `iface-dispatch`       | Dispatch              | dynamic dispatch for interface-typed values & bounds                                                                                                                                   | ✓      |
| `iface-default`        | Interfaces            | default methods (interface method bodies); optional in an `impl`, overridable, dispatched dynamically                                                                                  | ✓      |
| `iface-identity`       | Interfaces            | interface identity is owner+name: conformance obligations, default-method units, and interface-typed params bind per-owner; `impl ns.Iface for T` names an interface through an import | ✓      |
| `iface-bound-identity` | Interfaces / Dispatch | a type-parameter bound binds the interface its declaring file resolves — a conformer to a same-named interface elsewhere does not satisfy it                                           | ✓      |
| `generic-bounds`       | Interfaces / Dispatch | `<T: Eq + Debug>` enforced at call sites                                                                                                                                               | ✓      |
| `generic-type-bounds`  | Interfaces / Dispatch | a bound on a generic type's own parameter (`Box<T: Display>`) is enforced on its type arguments                                                                                        | ✓      |

## Imports, scoping & visibility

| ID                          | Spec (language.md)   | Pins                                                                                                                                              | Status |
| --------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `name-undefined`            | language.md          | a bare unknown name is a diagnostic                                                                                                               | ✓      |
| `mod-import-ns`             | Imports              | last path segment becomes the namespace                                                                                                           | ✓      |
| `mod-import-as`             | Imports              | `import … as alias` rebinds the prefix                                                                                                            | ✓      |
| `mod-import-under`          | Imports              | `import … as _` brings names in unqualified                                                                                                       | ✓      |
| `mod-prelude`               | Imports              | `std.core` names available unqualified                                                                                                            | ✓      |
| `mod-qualified-only`        | language.md          | bare cross-library reference is rejected                                                                                                          | ✓      |
| `mod-ns-file-local`         | language.md          | a namespace is file-local; qualifying with one this file didn't import is rejected                                                                | ✓      |
| `mod-no-bare-fallback`      | language.md          | a bare name owned by an un-imported (closure-only) library is `undefined` — no global last-wins fallback                                          | ✓      |
| `mod-shared-value-name`     | language.md          | two libraries may share a top-level value name; each qualified call dispatches to its own library (value-uniqueness lift)                         | ✓      |
| `mod-shared-type-name`      | language.md          | two libraries may share a top-level _type_ name; each qualified `ns.T` constructs/resolves its own library's type (type-uniqueness lift)          | ✓      |
| `mod-whitebox-same-dir`     | Modules / Testing    | `<base>_test.hawk` gets `<base>.hawk`'s private surface bare — same directory only                                                                | ✓      |
| `mod-shared-const-name`     | language.md          | two libraries may share a const name: `ns.NAME` inlines its own library's initializer, resolved against the const's file; owner-keyed cycle guard | ✓      |
| `mod-shared-global-name`    | language.md          | two libraries may share a module-global name: distinct slots, both initializers run, owner-keyed init order and dependency edges                  | ✓      |
| `mod-native-name-isolation` | language.md          | a `native fn` binds within its own library: `ns.fn(...)` resolves on `ns`'s surface, never a flat native table (no cross-import hijack)           | ✓      |
| `mod-import-resolve-error`  | Imports              | an import that doesn't resolve is a located diagnostic at the import decl (not a silent no-op / downstream `undefined name`)                      | ✓      |
| `mod-import-literal-path`   | Imports              | an import path is a literal: an interpolated path is a parse error                                                                                | ✓      |
| `mod-one-name-space`        | language.md          | one name space per scope: a file introduces a top-level name once, across all kinds (fn/type/const/let/import namespace)                          | ✓      |
| `mod-bare-collision`        | language.md          | two `import … as _` exposing one public name is an error at the second import (barrel collisions likewise, at the barrel — unit-tested)           | ✓      |
| `mod-no-surface-shadow`     | language.md          | a top-level declaration may not re-introduce a bare-surface name (prelude or `as _`); the eponymous-barrel namespace is exempt                    | ✓      |
| `vis-pub`                   | Visibility           | non-`pub` top-level is file-private (enforced)                                                                                                    | ✓      |
| `vis-barrel`                | Visibility           | barrel re-exports a directory library's symbols (std.cli)                                                                                         | ◐      |
| `vis-whitebox-test`         | Visibility / Testing | `foo_test.hawk` sees `foo.hawk` privates (bare)                                                                                                   | ✓      |

## Entry point & misc

| ID               | Spec (language.md)       | Pins                                              | Status |
| ---------------- | ------------------------ | ------------------------------------------------- | ------ |
| `entry-main`     | Entry point              | `main` signatures; `Int` return is the exit code  | ✓      |
| `entry-main-err` | Entry point              | an `Err` result exits non-zero, message to stderr | ✓      |
| `decorators`     | Decorators / annotations | `@name(args)` parse & attach (e.g. `@test`)       | ✓      |

## Findings

Discrepancies surfaced by the reconciliation pass. The reconciliation drove a
sweep of enforcement fixes (now in [Resolved](#resolved-changelog)); what
remains open is below.

### Open

- **`iface-debug` — structural `Debug` derive not accepted as a `Debug` value**
  (◐). A struct with no explicit `impl Debug` is rejected where a `Debug`-typed
  argument is expected, though language.md says `Debug` is auto-derived; the
  tests work around it with an explicit `impl Debug`. Likewise
  `.debug()`/`.eq()` aren't directly callable on a concrete type without an impl
  — reachable only via dispatch.

- **`check` leniency on an unknown callee.** A call to an undefined free
  function (e.g. the old capitalized `Error('x')`) type-checks silently — the
  checker is lenient on unknown callees (part of the Unknown-leniency
  feedback-loop work). Shrinking this is its own arc.

- **`vis-whitebox-test` — intentionally untested in this harness** (✗). A
  `foo_test.hawk` seeing `foo.hawk`'s privates is exercised by the project's
  real `_test.hawk` suites, but not pinnable in `tests/lang/`, since this
  harness drives `hawk run`/`check`, not `hawk test`.

### Resolved (changelog)

Each is now pinned by the cited conformance test(s); see git history for the
implementation detail.

- **`mod-qualified-only`, `vis-pub`** — a bare cross-library reference and a
  qualified access to a non-public member are both `check` errors
  (`qualify_lint` / `visibility_lint`). Corpus had 0 of each.
- **immutability, uniform** (`var-let-immutable`, `type-struct-immut`,
  `type-mut-field`) — reassigning a non-`mut` `let`/param _and_ assigning a
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
