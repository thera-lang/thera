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

This builds directly on the self-hosting spike
([selfhosting.md](selfhosting.md)), which proved Hawk can already express a
complete small front-end and produced the ranked language-gap list this plan
depends on.

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

1. **`bytecode/` writer** — emit `.hawkbc` bytes; diff against the Dart writer.
   Pure, isolated, high-confidence start.
2. **`lexer/`** — already spike-validated at small scale; diff token streams.
3. **`ast/` + `parser/`** — the bulk; diff AST structurally against Dart. The
   recovery-loop translation lands here.
4. **`element/` (resolver + types + inference)** — symbol tables and typing.
5. **`checker/`** — diagnostics; diff diagnostic sets.
6. **`codegen/`** — AST → bytecode; the final diff is end-to-end `.hawkbc`.
7. **`driver.hawk`** — wire the phases, reuse the `std.cli` Command app (the
   `pkgs/cli` rewrite already prototyped this).

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
