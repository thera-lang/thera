# The Hawk front-end, in Hawk — architecture

**What this is:** the architecture for porting Hawk's front-end (today the Dart
toolchain in `tool/`) to Hawk itself — [roadmap.md](roadmap.md) arc 3. It
answers three questions, in the order they actually constrain each other:

1. **Where are we going?** The _ultimate_ shape is an incremental, demand-driven
   analysis engine that can back an LSP. We don't build that first, but it sets
   guardrails for everything earlier.
2. **What is the first port?** A batch compiler — a near-mechanical translation
   of today's pipeline — emitting `.hawkbc` for the existing Rust runtime.
3. **What do we change in the Dart front-end first?** Targeted, low-regret
   refactors that make the Dart code already shaped like its Hawk image, so the
   port is transcription rather than redesign.

This builds directly on the self-hosting spike (folded into "The grounding
spike" below), which proved Hawk can already express a complete small front-end
and produced the ranked language-gap list this plan depends on.

## The grounding spike

Before committing to the full port, a scoped, time-boxed spike ported a small
but structurally representative front-end slice to Hawk — a probe whose real
output was a _prioritized list of language gaps_. The dominant risk on this arc
was never a feature we had already named (interface inheritance, say); it was
**what we hadn't discovered Hawk couldn't express yet**. A real port _confirms_
the blocker list and its priority far better than guessing — the same lesson
that writing real `std.cli` clients taught at library scale.

**The slice:** a tiny calculator front-end (lex → parse → eval), structurally a
real front-end — recursive-descent with precedence, a recursive AST, errors
threaded through recursion — without grammar sprawl:

```
program = expr EOF
expr    = term (('+' | '-') term)*          // left-assoc, lower precedence
term    = factor (('*' | '/') factor)*      // left-assoc, higher precedence
factor  = NUMBER | '(' expr ')' | '-' factor
NUMBER  = DIGIT+ ('.' DIGIT+)?
```

**The result:** the full slice landed — `pkgs/calc/` is a working `lexer` →
`parser` → `eval` pipeline with tests and an end-to-end `main`
(`hawk run pkgs/calc/main.hawk -- '1 + 2 * 3'` → `7`; `'5 / (3 - 3)'` →
`error: division by zero`). **Hawk can already express a complete small
front-end — no hard walls.**

### What worked with no friction (the encouraging core)

- **Directly-recursive enums.** `enum Expr { Num(Double), Neg(Expr), Bin(Op,
  Expr, Expr) }` — an enum holding itself directly, no boxing. The shape every
  AST has, and the biggest open risk; it just works.
- **Mutually recursive functions** (`parse_expr` ↔ `parse_term` ↔
  `parse_factor`) — no forward declarations.
- **`match` on variants with payload binding** (`Number(n)`, `Bin(op, l, r)`),
  and **`?` propagation inside match-arm blocks** and through recursion.
- **Structural `Eq`/`Debug` on recursive enums** → `assert_eq` compares whole
  ASTs out of the box. A large win for testing a compiler.
- **Per-domain error enums** (`LexError`/`ParseError`/`EvalError`), each
  `impl Error`, unified as `Result<_, Error>` across stages via `?` subsumption.
- A **mutable cursor struct** (`Parser { pos }`) with in-place `self.pos = …`,
  `std.char`, `chars()`, `String.from_chars`, list push/index, and cross-module
  sibling imports (`import 'lexer'`) — all comfortable.

### Gaps the spike ranked — now all addressed

1. **Tail expressions (the clear #1, pervasive).** A block-bodied `match` arm
   yielded `Unit`, never its last expression, so any arm that _computes_ a value
   had to `return` or assign a `mut`. The dominant ergonomic tax in match-dense
   compiler code. **Done** — see [tailexpr.md](tailexpr.md).
2. **`if`-as-expression (occasional, same family as #1).** **Done** (subsumed by
   the tail-expression work).
3. **Nested patterns / `match` on named constants.** Single arms couldn't
   destructure `Some(Number(n))`, and dispatching on character _classes_ was an
   if-else ladder. Nested patterns **done**; const-pattern `match` guards remain
   a minor nice-to-have.
4. **List/string slicing.** Every scanner reinvented a `slice` helper.
   `List.slice`/`String.slice` **done**.

### A notable _negative_ result

**Interface inheritance was never wanted by the spike.** Each stage used a
concrete error enum with an explicit `impl Display`; `assert_err` covered the
error tests, and only `main` called `e.message()`. So `interface Error: Display
+ Debug` is **not** on the critical path for front-end code — it stays a general
ergonomics cleanup, not a self-hosting blocker. (It has since landed anyway, and
removes friction now that it exists.)

### Verdict

The spike turned "what might Hawk lack?" into a ranked list and confirmed the
foundation the full port builds on: recursive AST enums, a mutable cursor
struct, `match` + `?`, and structural `Eq`/`Debug` for AST diffing. Every gating
gap it found is now closed (see "Language work this depends on" below), so the
port is transcription, not a wait on language features.

## What we are _not_ porting

The runtime stays. The Rust Tier-0 interpreter, the `.hawkbc` format, the GC,
and the native ABI are the stable substrate; the Hawk front-end targets
`.hawkbc` exactly as the Dart emitter does today. So "self-hosting the
front-end" means the **lexer → parser → resolver → checker → codegen** pipeline
runs in Hawk and emits bytecode the existing runtime loads. The LSP server and
the legacy tree-walking paths are out of the initial scope.

This keeps the bootstrap honest and small: one artifact to reproduce (a
`.hawkbc` module), one oracle to diff against (the Dart emitter's output).

## Today's pipeline (the thing being ported)

A straight, mostly-pure pipeline already (line counts are a rough size guide):

```
source ──Lexer──▶ tokens ──Parser──▶ AST ─┬─ buildLibrary (resolver) ─▶ elements
                                          ├─ Inferrer ─▶ types
                                          ├─ TypeChecker ─▶ diagnostics
                                          └─ codegen ─▶ Module ─▶ .hawkbc
```

| Dart (`tool/lib/src/`)                        | LOC  | Role                                  |
| --------------------------------------------- | ---- | ------------------------------------- |
| `lexer.dart`                                  | 460  | `String → tokens`                     |
| `token.dart`                                  | 184  | token kinds + spans                   |
| `parser.dart`                                 | 1303 | recursive descent → AST               |
| `ast.dart`                                    | 1045 | ~40 node types (sealed hierarchy)     |
| `element/resolver.dart`                       | 307  | AST → element model (symbol tables)   |
| `element/{element,types}.dart`                | 459  | elements + the type lattice           |
| `element/inference.dart`                      | 665  | expression typing                     |
| `checker/type_checker.dart`                   | 680  | conformance, arity, assignability     |
| `codegen/codegen.dart`                        | 1887 | AST → bytecode (`call.virtual`, etc.) |
| `bytecode/{instr,encoder,writer,module}.dart` | 516  | `.hawkbc` serialization               |
| `lsp/*`                                       | ~870 | diagnostics/hover/defn/symbols        |

~8.5k lines total; the front-end-proper (excluding LSP, bytecode I/O, loader) is
~6k. Each phase is already close to a pure function of its input — the property
the incremental target needs and the port should preserve.

## (1) Where we're going: the incremental target

The end state is a **query-based, demand-driven** engine in the lineage of
rust-analyzer (Salsa), the Dart analysis server, and Roslyn. The defining ideas:

- **Inputs and derived queries.** The only _inputs_ are file contents.
  Everything else — tokens, the parse tree, a file's symbols, a name's type, a
  file's diagnostics — is a **query**: a pure function of inputs (and other
  queries), _memoized_. Editing one file invalidates only the queries that
  transitively depended on it; unrelated results are reused.
- **Demand-driven.** An IDE request (hover at a position) computes only the
  queries that answer reaches — not a whole-program recompile. The current LSP
  does the opposite: every keystroke re-lexes, re-parses, re-loads the import
  closure, and re-checks everything
  ([lsp/server.dart](../tool/lib/src/lsp/server.dart)).
- **Per-file granularity.** Parsing is per file and cached; cross-file work
  (resolution, type-of-name) is expressed as queries over those per-file
  results, so a one-file edit re-resolves only dependents.
- **A lossless syntax layer, eventually.** IDE features that rewrite source
  (format, rename, quick-fixes) want a concrete syntax tree that preserves every
  token and trivia (whitespace/comments) — a red/green tree. Today's AST is
  lossy (no trivia, spans only). This is a _later_ layer; the batch port keeps
  the lossy AST.
- **Cancellation.** A newer keystroke supersedes an in-flight analysis. Needs
  cooperative cancellation threaded through long queries.

**We do not build this first.** But naming it now buys three cheap guardrails
the batch port should honor so the incremental engine is additive, not a
rewrite:

- **Keep every phase a pure function of its inputs.** No hidden global mutable
  state; pass context explicitly. (Largely true today — preserve it.)
- **Keep inputs addressable.** A file is identified by a stable id/path; a phase
  takes ids and a content map, never reaches out to the filesystem itself. (The
  Dart loader already centralizes I/O — keep that boundary.)
- **Keep spans on every node.** The incremental layer and the IDE both key off
  them; the AST already carries `SourceSpan` everywhere — don't drop it in the
  port.

Concretely: the batch compiler is the **memoize-nothing special case** of the
query engine (every query recomputed, every edit a full rebuild). Adding memo
tables and an invalidation pass later turns it incremental without reshaping the
phases. So the order is _correct batch first, incremental second_, and the batch
design must not foreclose the second step.

## (2) The first port: a batch compiler in Hawk

A single-shot `compile(files) → Result<Module, List<Diagnostic>>`, structurally
a transcription of today's pipeline. The interesting content is the
representational mapping from Dart idioms to Hawk ones — most of which the spike
already exercised.

### Representational mapping (Dart → Hawk)

| Dart idiom                                    | Hawk form                                                         | Spike status                                  |
| --------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------------- |
| Sealed class hierarchy + `switch` (AST nodes) | **`enum` per category** + `match` (`enum Expr { … }`)             | ✅ validated (recursive `Expr`)               |
| OO methods (`node.describe()`, `childNodes`)  | free `fn`s taking the enum (`fn describe(e: Expr)`)               | ✅ (impls + free fns both work)               |
| Nullable `T?`                                 | `Option<T>`                                                       | ✅                                            |
| Exceptions for parser recovery (`_ParseFail`) | `Result<Decl, ParseError>` + a recovery loop at the decl boundary | ◑ (Result threading ✅; recovery loop is new) |
| Mutable cursor (`_pos++`)                     | mutable struct field (`self.pos = self.pos + 1`)                  | ✅ validated (calc `Parser`)                  |
| `Map`/`List`/`Set`, string ops                | same, via stdlib                                                  | ✅                                            |
| Errors as collected diagnostics               | `List<Diagnostic>` accumulator (struct field, `push`)             | ✅ (mutable fields)                           |

The two non-trivial shifts:

- **AST: a hierarchy becomes a sum of enums.** Dart's ~40 node classes across a
  few sealed bases (`Decl`/`Stmt`/`Expr`/`TypeRef`/`Pattern`) become one Hawk
  `enum` per base, each variant a node kind carrying its fields (positionally,
  or via a small payload struct when a node has many fields). The spike's
  `enum Expr { Num(Double), Neg(Expr), Bin(Op, Expr, Expr) }` is this exact
  shape at small scale — the biggest representational risk, already retired.
  Node "methods" (`describe`, `childNodes`, span access) become free functions
  that `match`.
- **Error recovery without exceptions.** The Dart parser throws `_ParseFail` and
  catches it at the declaration boundary to resync
  ([parser.dart](../tool/lib/src/parser.dart)). Hawk has no try/catch, so a decl
  parse returns `Result<Decl, ParseError>`; the top-level loop matches it, and
  on `Err` records the diagnostic, skips to the next declaration keyword
  (`_syncToDecl`'s logic), and continues. This is a clean, local translation of
  the existing pattern — the only genuinely _new_ control-flow shape in the
  port.

### Module layout (mirrors `tool/lib/src/`)

```
pkgs/cli/   (the future Hawk front-end + CLI, today a placeholder)
  lexer/        token.hawk, lexer.hawk
  ast/          ast.hawk            (the node enums + free fns over them)
  parser/       parser.hawk
  element/      element.hawk, types.hawk, resolver.hawk, inference.hawk
  checker/      checker.hawk
  codegen/      codegen.hawk
  bytecode/     instr.hawk, encoder.hawk, writer.hawk   (emit .hawkbc bytes)
  driver.hawk   compile(files) + the CLI (already on std.cli Command)
```

The `bytecode/` chunk is the most self-contained and a good early win: it's pure
data-to-bytes with a fixed spec ([bytecode.md](bytecode.md)), no type theory,
and its oracle is byte-for-byte equality with the Dart writer's `.hawkbc`.

### Bootstrap & the self-hosting test

Two-stage, with a fixpoint check:

- **Stage 0.** The Dart toolchain compiles the Hawk-written front-end
  (`pkgs/cli/**`) to `frontend.hawkbc`. (Dart remains the bootstrap compiler.)
- **Stage 1.** Run `frontend.hawkbc` on the Rust runtime and have it compile
  some target — first small programs, ultimately _its own sources_ — to
  `.hawkbc`.
- **Fixpoint.** When stage 1 compiles the front-end's own sources, diff that
  output against stage 0's `frontend.hawkbc`. **Byte-identical output is the
  self-hosting milestone** — the Hawk compiler reproduces what the Dart compiler
  produced from the same sources.

Per-phase, the port is validated _against the Dart oracle the whole way_: for a
corpus of `.hawk` files, the Hawk lexer's tokens, the parser's AST (compared
structurally — `Eq`/`Debug` on the AST enums make this a one-line `assert_eq`,
exactly as the spike found), and finally the emitted bytecode must match Dart's.
This makes the port incremental and continuously checkable, not a big-bang.

### Suggested sequence (each independently shippable & diffable)

1. **`bytecode/` writer — done.** `pkgs/cli/bytecode/` ({instr,module,encoder}.hawk)
   emits `.hawkbc`; its test rebuilds the runtime's `demo_module()` and asserts
   byte-identical output against `emit-demo` (plus hand-derived goldens for the
   type/dispatch sections and the numeric opcodes).
2. **`lexer/` — done.** `pkgs/cli/lexer/` (token.hawk + lexer.hawk) is a faithful
   transcription of `lexer.dart`/`token.dart`; the Hawk tests pin token kinds /
   lexemes / spans / error messages, and a Dart `lexer_parity_test.dart` asserts
   the oracle produces the same `kind:lexeme` streams for the same corpus.
3. **`ast/` + `parser/` — done.** `pkgs/cli/ast/` (ast.hawk + describe.hawk) and
   `pkgs/cli/parser/parser.hawk`; structural `Eq`/`Debug` diff a whole `Program`,
   and the recovery-loop translation (panic flag) landed here.
4. **`element/` (resolver + types + inference) — done.** `pkgs/cli/element/`
   (element.hawk, types.hawk, resolver.hawk, inference.hawk): the name-based
   element model, the type lattice, the two-pass resolver, and the pure-function
   typing engine. Tests build a `LibraryElement` and assert resolved member types
   and inferred expression types.
5. **`checker/` — done.** `pkgs/cli/checker/checker.hawk`: the first consumer of
   the inference engine. Walks decls/blocks/stmts/exprs and emits diagnostics
   (undefined name, unknown type/field, type mismatch on let/return/condition/
   argument, call arity & labels, generic bounds, lambda-param inferability,
   interface conformance). Tests assert diagnostic counts + messages.
6. **`codegen/` — done.** `pkgs/cli/codegen/` (module_scope.hawk + codegen.hawk):
   the module scope (unit table, struct/enum layout, native + dispatch tables) and
   the per-function emitter, covering the whole language — control flow,
   primitives, strings, lists/maps, indexing, fields, propagation, struct/enum
   construction, the full call ladder (free/native/static/instance-native/user
   methods + `call.virtual` dynamic dispatch + function-valued fields), `match`
   (linear chain + balanced binary-search dispatch), and lambdas/closures
   (free-variable capture, `mut`-capture boxing, lambda lifting). Validated
   **byte-identical** against the Dart oracle (`compileProgram(…, imports: [])` +
   `encodeModule`) by a 9-program golden suite. Two adaptations carried the pure
   model: the compiler is modeled as mutable structs with `impl` (Hawk structs are
   references), and `type_of` calls `infer_expr` on demand against a `type_scope`
   maintained beside `slots` — with lifted-lambda parameter types stashed at lift
   time (from the bidirectional `expected`) and seeded into the lifted unit's
   `type_scope`, since a lifted lambda compiles as its own unit with no annotated
   tree to read.
7. **`driver.hawk` + `loader.hawk` — done.** `pkgs/cli/driver.hawk` wires the
   phases into the source→bytecode pipeline (`check_source`/`check_source_at` →
   diagnostics; `compile_source`/`compile_source_at` → `.hawkbc` bytes, each phase
   short-circuiting on errors); `pkgs/cli/loader.hawk` ports the import-closure
   loader (`std.core` auto-load, `std.x` / relative resolution, directory barrels,
   namespace surfaces, SDK-root discovery via `HAWK_SDK` or a cwd walk-up) over
   `std.fs`/`std.env`; `main.hawk` drives `check`/`emit` on the `std.cli` app. The
   Hawk-written CLI, run via the Dart bootstrap
   (`hawk run pkgs/cli/main.hawk emit <file> <out>`), now compiles a **std-using**
   program — its `.hawkbc` is **byte-identical** to the Dart oracle (2141 bytes for
   a `println`/list/`for`/interpolation program), and the runtime executes it.
   This is the self-hosting validation: the Hawk front-end resolving the prelude
   and emitting oracle-matching bytecode the runtime runs.
8. **`run` / `test` (runtime invocation) — done.** `pkgs/cli/runner.hawk` wires
   the two subcommands that drive the Rust runtime: `run` compiles to a temporary
   `.hawkbc` and spawns `<sdk_root>/runtime/target/debug/hawk` (forwarding program
   args, propagating the exit code); `test` discovers `@test` functions,
   synthesizes the `__hawk_test_main` driver, runs it under `--entry`, and prints
   the per-test/per-file report + summary (with recursive `*_test.hawk` collection,
   sorted + de-duplicated). Both mirror the Dart `RunCommand`/`TestCommand`. **The
   front-end now self-hosts the test pipeline:** it compiles and runs its own
   104-test `pkgs/cli` suite, the full **200-test** stdlib suite (output
   byte-identical to the Dart oracle), and all 12 examples. Two design departures
   from the Dart CLI, both because `std.process` *captures* the child's
   stdout/stderr rather than inheriting the terminal: output is buffered and
   replayed (no interactive stdin), and `hawk run prog --flag` doesn't forward
   dash-flags to the program (std.cli intercepts them; positional args do forward).
   See [completeness.md](completeness.md) for the punchlist.

#### Findings from the ported chunks

- **No `break` / `continue`.** Hawk exits loops on a condition only (a `mut`
  flag), so the lexer's `break`-driven loops were rewritten: a
  `while going && !at_end` flag for whitespace/comment skipping, and letting the
  loop guard fall through where the Dart code `break`s after consuming a trailing
  backslash. `return` was kept where Dart used it (Hawk has `return`). Minor,
  local, mechanical — but pervasive enough in scanner/parser code that a
  `break`/`continue` (already on the roadmap's deferred list) would shave real
  friction off the parser port. Not a blocker.
- **A few letters lack `std.char` constants** (`x`, escape letters `n`/`t`/`r`/…).
  A `char.hex_digit_value` was added to std.char (it parallels `digit_value` and
  the `\xNN`/`\u{}` escapes wanted it). No language gap.

The `ast/` + `parser/` chunk added:

- **`ast/` is data + free functions.** The Dart sealed hierarchies map to one
  `enum` per base; multi-field nodes carry a named payload struct, Dart records
  (`List<(String, TypeRef)>`) become small structs (`FieldDef`/`MapEntry`/…), and
  `.span`/`describe()` become free `fn`s that `match`. Deep mutual recursion
  (Decl → FnDecl → Block → Stmt → Expr → TypeRef) and struct-mediated recursion
  compile fine; structural `Eq`/`Debug` diff a whole `Program`.
- **`hawkbc` hex parsing → `String.to_int_radix`.** Closed the audit's hex gap in
  pure Hawk (wrapping `*`/`+`), no native — see the stdlib commit.
- **Panic-flag recovery works.** The `_ParseFail` throw → a `panicking` flag the
  token primitives and parse loops short-circuit on, cleared at the decl
  boundary; verified by a recovery test. The one real translation cost of the
  port, and it's local.

Bugs/gaps surfaced (not blocking; worth tracking):

- **`\$` does not escape interpolation — fixed (both front-ends).** The lexer
  used to collapse `\$`→`$` in the captured value, so the parser's splitter
  re-read `${` as an interpolation (and a malformed one crashed the Dart parser
  with a `RangeError`). Fix: the lexer now re-escapes a literal `\`/`$` in the
  value (`\\`/`\$`); the splitter decodes those and treats only a *bare* `$`+`{`
  as interpolation. `\${x}` is now literal `${x}`; the round-trip is identical
  for every valid existing string. Applied identically to the Dart toolchain
  (`lexer.dart`/`parser.dart`) and the Hawk port (`lexer/`/`parser/`), with the
  unterminated-`${` overrun hardened into a clean parse. Lexeme of a string now
  carries the escaped value (decoding is the splitter's job).
- **`check` doesn't validate built-in `List`/generic method names — fixed (both
  front-ends).** A call to a non-existent `xs.remove_last()` used to pass
  `hawk check` (surfacing only at codegen); the checker now resolves field
  accesses and method calls against the receiver's type and reports `no such
  field`/`no method` when a concrete receiver doesn't provide the member. See
  [completeness.md](completeness.md) (static-analysis robustness).
- **`Option.None` locals need a type annotation when only a later assignment
  pins the element type** (`let mut x: Option<SourceSpan> = Option.None;`).
  Inference doesn't flow backward from a later `x = Some(span)` through a
  `match`/method call. Minor, but recurring in stateful parser code.

The `element/` chunk (model + resolver) added:

- **Identity-bearing elements → name-based references.** Dart's
  `InterfaceType.element` is an object pointer (type equality is element
  identity); the port's `Type.Interface(name, args)` holds the element *name* and
  looks the element up in the registry, so type equality stays structural and
  matches identity (names are unique). The `TypeDefElement` subclass hierarchy
  becomes one tagged struct so the resolver fills `methods`/`fields`/`variants`
  in place across passes — verified that a struct stored in a `Map`/`List`
  mutates by reference (the property the two-pass resolver needs).
- **Mutual imports work** (`types` ↔ `element`), so the cyclic Dart split ports
  directly.
- **`fn` is reserved**, so a parameter named `fn` is a syntax error (renamed to
  `decl`). And **an else-less `if` as the last statement of a match-arm block**
  is parsed as a value-position tail (the checker then demands an `else`); a
  trailing `;` demotes it to a discarded statement. Both minor, both recurring in
  match-dense compiler code.
- **`resolvedType` mutation was the open fork for inference — now resolved.** The
  Dart inferrer annotates every `Expr` with its type in place; Hawk `Expr`s are
  immutable values. Resolution (now implemented in `inference.hawk`): the
  annotation pass is gone and typing is a *pure function*
  (`infer_expr(expr, scope, ctx, expected) -> Type`) the checker calls on demand —
  simpler than the Dart two-pass, and better aligned with horizon-1's per-node
  *queries* (type-of is a memoizable query, not a stored field). The codegen
  already recomputes types independently, so nothing depended on the annotation.

The `element/` chunk (inference) added:

- **Pure typing, no AST mutation.** `infer_expr` returns a `Type` and never
  touches the node; `expected: Option<Type>` threads the bidirectional
  expectation (un-annotated lambda params take their types from the surrounding
  signature). A per-function `InferCtx` bundles the constants the Dart class held
  as fields (`library`, in-scope generics + their bounds, `self`'s type, the
  return type). Constructed against the existing element model — name-based
  `Type.Interface` lookups, structural `substitute`/`unify` — with no new
  language features needed.
- **Dropping the annotation drops the cosmetic walks.** The Dart version recursed
  into every sub-expression *only* to fill `resolvedType` (a range's bounds, the
  rest of a list's items, an `if` statement's branches). Without annotation only
  the recursion that determines the returned type remains, and `infer_stmt`
  collapses to **just `let`** — the sole statement kind that grows the scope a
  block's tail expression sees; the checker types every other statement's
  sub-expressions when it visits them. A noticeably smaller, flatter port than
  the Dart original.
- **Scopes are copied explicitly.** Hawk `Map` is a reference, so each block/arm
  that shadows the outer scope copies it (`copy_scope`) where Dart wrote
  `Map.from` — the one mechanical cost, fully local.

The `checker/` chunk added:

- **`infer_expr` on demand replaces `resolvedType`.** The Dart checker reads the
  inferrer's in-place annotation at every type-mismatch site; the Hawk checker
  calls `infer_expr(expr, scope, ctx, expected)` there instead, and **threads the
  contextual `expected`** into call arguments, `let` values, `return` values, and
  lambda bodies — so bidirectional lambda-parameter typing (`xs.map(n => …)`)
  still works without a pre-pass. This is what made the pure engine worth it: the
  checker is its first real consumer and needs no annotated tree. (Cost: subtrees
  are re-inferred where the walk and a mismatch check overlap — fine for now;
  memoization is the horizon-1 plan.)
- **One unified `Map<String, Type>` scope.** Dart kept two parallel scopes — a
  `TypeRef?` map for name-definedness and the inferred annotations for types. The
  port collapses them: presence in the map is "defined", the value is the
  binding's type (`Unknown` when undetermined). Pattern/loop bindings reuse
  inference's `bind_match_pattern` / `bind_for_pattern`, so they bind *real*
  payload/element types rather than Dart's placeholder `null` — strictly more
  precise.
- **`InferCtx` carries the per-function constants** the Dart `TypeChecker` held as
  mutable fields (in-scope generics + bounds, `self`'s type, the return type), so
  the same context object drives both the checks and the inference calls.
- **No new language gaps.** The whole ~700-line checker ported on the existing
  surface; the only friction was the (already-tracked) statement-vs-value-tail
  `if` rule — a trailing `;` on a value-position `if`, none on a
  statement-position one. A 17-test suite (incl. a rich-generics false-positive
  guard) pins counts + messages.

The `driver/` + `loader/` chunk surfaced one structural finding:

- **Free functions resolved global-by-bare-name → now same-file-first
  (collision fixed).** Codegen's function table and the element model's
  `functions` map were flat-by-bare-name, so two co-loaded files that each define
  a private `fn last_segment(…)` of different arity linked to one unit and a call
  resolved to the wrong one — surfacing at codegen as a "missing argument" that
  slipped past `check` (hit twice porting the loader: `last_segment` vs the
  resolver's, `dirname` vs `std.path`'s). **Fixed in both front-ends:** each
  file's functions also register in a per-file table and a bare reference resolves
  *same-file-first*, with the flat table as the cross-file fallback (threaded
  through codegen `_fileFunctions`/`_globalFunctions` + `unitFiles`, the element
  model's `LibraryElement.fileFunctions`/`functionFor`, inference's
  `_currentFile`, and the checker's primary file). Byte-identical for
  collision-free programs; the loader's rename workarounds were reverted. **Still
  open:** this fixes the *collision*, not *visibility* — a private remains
  reachable cross-file via the fallback, and a `pub` name still collides across
  libraries through a namespace-qualified call (the qualifier is cosmetic). Real
  per-namespace resolution + private enforcement is the next visibility step.

The `run`/`test` chunk surfaced two latent codegen bugs (both now fixed), caught
by running real code (the stdlib suite) through the Hawk front-end for the first
time — the kind of coverage `check`/`emit` goldens miss:

- **`Bool ==`/`!=` lowered to the `eqI64` opcode → runtime trap.** The runtime
  keeps `Value::Bool` distinct from `Value::Int`, so `eqI64` (which pops two
  Ints) trapped `Bug("expected Int, found Bool")` on any Bool comparison. A
  **latent bug in both toolchains** — a one-line `true != false` trapped the Dart
  oracle too; it had simply never been exercised, since Bool-to-Bool `==`/`!=` is
  rare in the tested corpus (it first bit interface conformance, which compares
  two `is_static` Bools). Fix: route Bool equality through the structural `eq`
  native (the non-primitive path) in both `codegen.dart` and `codegen.hawk`.
  Guarded by a Hawk byte golden, a Dart structural test, and Dart e2e tests
  (Bool-eq + a user `impl Iface for T`).
- **`let x: T = init` typed `x` from the initializer, not the annotation**
  (Hawk codegen only — the Dart oracle was already correct via the inference
  pass's `annotated ?? inferred`). So `let prefix: List<String> = []` made
  `prefix` `List<unknown>`, and `prefix[0].is_empty()` failed to resolve at
  codegen. The Hawk codegen's own statement walker had diverged from the shared
  inference engine; fixed to use the annotation when present. (The checker missed
  it because imported-library *bodies* aren't body-checked — the still-open wrinkle
  below — but codegen must compile them.)

Language wrinkles (one resolved, one tracked):

- **A trailing else-less `if` in a match arm was treated as a value tail —
  resolved.** A side-effecting `if cond { … }` as the last statement of a `{…}`
  match arm (or block expression) was parsed as the block's tail value, so the
  checker demanded an `else` even when the arm's value is discarded; the
  workaround was a trailing `;`. **Fixed (both front-ends)** by the Rust rule: an
  else-less `if` has type `Unit`, and the tail-position `else` requirement fires
  only when the then-branch actually produces a non-`Unit` value (see
  docs/tailexpr.md). A pure relaxation — every phase below the checker already
  treated an else-less `if` as `Unit` (the parser parses it as a tail, inference
  types it `Unit`, codegen emits `constUnit` for the absent `else`), so the change
  was a ~5-line checker tweak each side. The now-redundant `;` workarounds in
  `element/{types,resolver}.hawk` were stripped. **(Earlier "compounding gap" now
  resolved by design:** importing a module contributes only its *signatures*, not
  a check of its bodies — the right scoping for single-file check. Whole-project
  coverage comes from `hawk check <dir>`, which checks every file's body
  directly, so no transitive body-checking of imports is needed. See
  [completeness.md](completeness.md).)
- **`{}` and `void` are interchangeable unit values.** An empty block `{}` and
  the unit literal `void` both denote the unit value in expression position (e.g.
  a no-op match arm `_ => {}` vs `_ => void`), verified compiling mixed. Benign
  redundancy; a later call on whether to canonicalize one form or accept both.

### Language work this depends on (gating the port)

The spike's ranked gaps are now _prerequisites_, not curiosities — a 6k-line,
match-dense port magnifies each:

- **Tail expressions (spike #1) — done.** Expression-position blocks and `{…}`
  match arms yield their tail, and `if` is usable in value position (`else if`
  chains, `if`-tails) — both stages landed ([tailexpr.md](tailexpr.md)). This
  retires the dominant match-dense friction (spike gaps #1 and #2's
  `if`-as-expression cousin) before the parser/checker port.
- **Nested patterns (spike #2) — done.** A `match` arm can now destructure
  several levels deep and bind at the leaves
  (`match e { Bin(Add, Num(a), Num(b)) => … }`), with literal patterns supported
  too. Codegen-only change (the front-end already bound nested patterns); a real
  constant-folder/checker — and the calc evaluator, which dropped its `apply`
  helper — uses it directly.
- **Interface inheritance — done.** `interface Error: Display + Debug` landed
  (see [interfaces.md](interfaces.md)); the port's per-phase error enums get
  `'${e}'` and `assert_*` for free. (The spike correctly flagged this as _not_
  on the critical path, but it removes friction now that it exists.)
- **`List.slice`/`String.slice` — done.** Scanners use them already.
- Nice-to-haves that don't gate: `match` guards / patterns on named constants
  (lexer ergonomics), richer structural `debug` (diagnostics).

The gating language work is now **done** — tail expressions and nested patterns
both landed, alongside interface inheritance and slicing. The parser/checker port
no longer waits on a language feature; the lexer and `bytecode/` writer remain the
lightest places to start.

## (3) De-risking refactors in the Dart front-end

The spike's guidance was _don't restructure speculatively — let the validated
shape teach the target_. The shape is now known, so a few **targeted,
low-regret** refactors make the Dart code already resemble its Hawk image,
shrinking the port to transcription. Each stands on its own (keeps the Dart
suite green) and is worth doing even if the port slipped:

- **Lift AST node behavior into free functions — assessed, deferred.** The idea
  was to move `describe()` / `childNodes` off the node classes into top-level
  functions that switch on the node (the Hawk form: enums are dumb data, behavior
  is free `fn`s that `match`). On inspection the payoff is low *now*: `childNodes`
  is declared on `AstNode` and overridden in ~40 node classes but has a **single**
  consumer (`lsp/ast_utils.dart`), and `describe()` serves only `lsp/hover.dart`
  + tests — all LSP/debug code, none in the first port. The core ported pipeline
  (parser/checker/inference/codegen) already treats nodes as dumb data and
  `switch`es on them, so the AST is already in port shape. Lifting `childNodes`
  also presupposes a unifying `Node` type (the generic heterogeneous walk),
  which is the deferred tagged-union rewrite below. Do this lazily, when the LSP
  and debug tooling are themselves ported — not as speculative churn now.
- **Make parser error recovery Result-shaped (or clearly quarantined).** Either
  convert `_parseDecl` to return a result the top loop recovers on, or at
  minimum confine the `_ParseFail` exception to a single boundary function whose
  body becomes the Hawk recovery loop. Removes the one control-flow idiom Hawk
  lacks.
- **Audit the stdlib surface the front-end uses — done; see "Stdlib-surface
  audit" below.** The core phases turned out remarkably self-contained; the audit
  produced a short, prioritized list of real stdlib gaps (the bytecode-writer
  ones most urgent) to feed the stdlib roadmap.
- **Tighten phase boundaries to pure `(input) → output`.** Where a phase reads
  ambient state or the filesystem directly, thread it through a parameter
  instead. This both eases the port and is the exact discipline the incremental
  target (1) needs — the one refactor that serves both horizons.
- **Keep the AST node set and the Hawk enum variants in lockstep.** As nodes
  change, prefer shapes expressible as a flat enum variant (positional fields or
  a small payload struct) over deep class hierarchies or behavior-bearing nodes.

**Deliberately not yet:** rewriting the Dart AST as actual tagged unions (Dart
sealed classes + `switch` already map cleanly to Hawk `enum` + `match`, so the
payoff is small), introducing a lossless syntax tree (that belongs to horizon 1,
after the batch port), or porting the LSP. Over-refactoring Dart to _be_ Hawk
buys little and risks the working toolchain.

### Stdlib-surface audit — findings

A sweep of the external/notable Dart APIs the **core phases** use (lexer, parser,
ast, element, checker, codegen, bytecode — excluding the LSP and `loader`, which
aren't in the first port). The headline: the core is almost free of external
dependencies — no `package:` imports outside the LSP, and only the bytecode layer
reaches for `dart:typed_data`/`dart:convert`.

| Dart API (core phases)                         | Where                       | Hawk today                          | Status |
| ---------------------------------------------- | --------------------------- | ----------------------------------- | ------ |
| `String.codeUnitAt` / `writeCharCode`          | lexer, parser string-split  | `String.chars()` / `String.from_chars` (code points) | ✅ (spike-validated) |
| `int.parse` / `double.parse` (decimal)         | parser literals             | `String.to_int()` / `to_double()`   | ✅ |
| `List.map` / `filter` / `fold` / `slice`       | throughout                  | same (std.core)                     | ✅ |
| `Map` get/has/remove/keys/values, `m[k]=v`     | throughout                  | same (std.core)                     | ✅ |
| `BytesBuilder.write_u8/bytes/str`, `String.bytes()` | bytecode writer        | same (std.core `BytesBuilder`)      | ✅ |
| `RegExp` (`path.split(RegExp('[./]'))`)        | `element/namespace.dart` ×1 | no regex                            | ⚠️ trivial — de-RegExp (split on `/` then `.`) |
| `BigInt.parse(radix: 16)` + `toSigned(64)`     | parser hex literals         | `to_int()` is base-10 only          | ❌ **gap:** hex/radix int parse |
| `ByteData.setUint32/setFloat64` (little-endian)| bytecode writer            | `BytesBuilder` writes `u8`/bytes only | ❌ **gap:** LE multi-byte writes |
| `double` → raw 8 bytes (IEEE-754 bits)         | bytecode writer (`setFloat64`) | no `Double.to_bits()`/`to_le_bytes()` | ❌ **gap:** needs a native |
| `List.firstWhere` / `indexWhere` / `any`       | codegen, element, checker   | List has map/filter/fold, **no** find/index/any | ❌ **gap:** List search |
| `Map.putIfAbsent` / `.entries`                 | resolver, codegen           | `if !m.has(k) { m[k]=v }` works     | ⚠️ ergonomic add |
| `List.asMap().entries` (index+value)           | a few enumerations          | index loop; `iter.enumerate` deferred | ⚠️ ergonomic |

**Prioritized stdlib gaps to feed the roadmap** (ordered by when the port hits
them — the bytecode writer is the planned first chunk, so its gaps come first):

1. **Bytecode-writer primitives (most urgent).** `BytesBuilder` needs
   little-endian multi-byte writes (`write_u32_le`, `write_u64_le`,
   `write_f64_le`), and `Double` needs an IEEE-754 **bit reinterpret**
   (`to_bits() -> Int` or `to_le_bytes() -> Bytes`) — a new runtime native, the
   single deepest gap (the runtime already does the reverse in `std.random`'s
   `to_unit`). Without these the `.hawkbc` writer can't emit `constDouble` or the
   u32 length/offset fields.
2. **Hex / radix integer parsing.** The lexer/parser parse `0x…` literals via
   `BigInt.parse(radix: 16)` with signed-64 wrapping. Hawk's `String.to_int()` is
   base-10; add `Int.parse(s, radix)` (or a `String.to_int_radix`) with two's-
   complement wrapping. Bitwise ops (now in the language) make a pure-Hawk version
   feasible if a native isn't wanted.
3. **List search.** `find` / `index_of` / `any` / `all` (and `contains`) — used by
   the enum registry (`indexWhere`), checker, and codegen. Pure-Hawk additions to
   `std.core/list`.
4. **Ergonomic Map/iter adds** (non-blocking): `Map.put_if_absent` / an entries
   view, and an `enumerate` iterator adapter (already on the iter backlog).

Everything else maps directly, and the lexer/parser string handling is already
spike-validated (`chars()`/`from_chars`). Net: the port's stdlib dependencies are
small and known, and the bytecode-writer gaps are the gating ones to close first
(fittingly, since `bytecode/` is the first port chunk).

## Summary

- **Target (horizon 1):** a query-based incremental engine for the LSP. Not
  built first; it imposes three cheap guardrails — pure phases, addressable
  inputs, spans everywhere — that the batch port must respect.
- **First port (horizon 0):** a batch `.hawkbc` compiler, a near-mechanical
  transcription. AST hierarchy → `enum`s (spike-validated), nullable → `Option`,
  exception recovery → `Result` loop (the one new shape), mutable cursor →
  mutable struct field (spike-validated). Bootstrapped via Dart, validated
  per-phase against the Dart oracle, with byte-identical self-compilation as the
  milestone.
- **Dart prep (done):** the stdlib-surface audit (gap list for the roadmap), the
  parser's exception idioms quarantined/removed, the loader made pure behind an
  injected `FileSystem`, and the lone `RegExp` dropped. Lifting AST node behavior
  to free functions was assessed and deferred (low payoff now — it serves
  not-yet-ported LSP/debug code and presupposes the deferred tagged-union AST).
- **Gating language work — done:** tail expressions (block/match-arm tails and
  `if`-as-expression), nested patterns, interface inheritance, and slicing all
  landed, so the parser/checker port is unblocked.
