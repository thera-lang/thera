# Thera roadmap

**What this is:** where Thera is today and what's next. Design details for
_completed_ work live in [architecture.md](architecture.md) and
[language.md](language.md); this doc focuses on what's open. As an arc lands,
its open-work entry is removed and condensed into a one-line note in the
[Changelog](#changelog) at the end.

## Current state

**Checkpoint (2026-06).** Thera **self-hosts**. The front-end (`pkgs/cli/`,
written in Thera) lexes, parses, resolves, type-checks, infers, and lowers Thera
to `.thera-bc`, and runs the `check`/`emit`/`run`/`test`/`lsp` CLI (see
[architecture.md](architecture.md) for the commands and their output streams).
It compiles its own sources and the whole stdlib; `bin/build_sdk.sh` embeds it
into the `thera` binary with a **fixpoint check** that the front-end reproduces
itself byte-for-byte. The Dart toolchain that bootstrapped it has been removed —
the build bootstraps from a checked-in `bootstrap/frontend.thera-bc` snapshot
(see `bootstrap/README.md`), and `bin/test.sh` (cargo + the `pkgs/cli`/`sdk/std`
`@test` suites + examples) is the suite.

**Runtime (`runtime/`, Rust).** A Tier-0 bytecode interpreter with an explicit
call-frame stack (`Vm::run_loop` over `Vec<Frame>`, each frame a
`{func, pc, base}` into one **unified value stack** per fiber — locals +
operands laid end to end, so a call passes its arguments in place with no
per-call allocation) and a **precise non-moving mark-sweep GC** (`heap.rs`). It
runs the full language core: `Int`/`Double`/ `Bool`/`Unit`, control flow,
functions + recursion, **closures**, enums (`Result`/`Option` as ordinary
`std.core` enums, with `?`/`match`/implicit-`Ok`), structs + a type table,
`List`/`Map`/`Set`, and **interface dispatch** — static on concrete types,
dynamic (`call.virtual` + a type-id-keyed table) for interface-typed values and
bounded generics, with bounds enforced at call sites and **default methods** on
interfaces. Natives are bound by name at load (the native ABI). Bytecode
serializes to `.thera-bc` (header + sections, LEB128, string constant pool). A
first cut of **cooperative fibers** (`std.fiber`) is in:
`spawn`/`join`/`yield` + buffered channels.

**Inference.** The front-end carries a semantic `Type`/element model
(`pkgs/cli/element/`) built by a resolution stage; inference is a **pure,
on-demand** query (`infer_expr` — no AST annotation) the checker and codegen
call. It sees through generics (`Option<T>`/`List<T>` elements, method returns,
match bindings, `?`/`unwrap`), does bidirectional and forward-flow inference,
and the checker reports located diagnostics (type mismatches, bad
calls/fields/methods, unpinnable generics). The inference-completeness arc is
**closed** — see _Changelog_ at the end.

**Not yet:** a broader stdlib; generic operators (`<T: Add>`); index (`[]`)
operator overloading; the Cranelift JIT tier. (Name resolution is now fully
owner-correct for values _and_ types — the `TypeId` arc — with qualified-only
resolution and `pub`/privacy enforced; see _Changelog_.)

## Open work

(The coding-at-scale arc — acyclic imports, per-library incremental checking,
barrel-enforced boundaries, manifests, and the rest — is planned in
[scale.md](scale.md); items graduate from there into the sections below.)

### Stdlib

The staples arc has landed — the collection/string/bytes staples,
`std.encoding`/`std.hash`/`std.regex`/`std.log`/`std.term`/`std.http` with TLS
(over the provisional `std.net`), and the lazy iteration arc — see _Changelog_.
The open items have moved to the tracker: sorted/`Ord`-keyed `Set`/`Map`
variants ([#89](https://github.com/thera-lang/thera/issues/89)) and the
`zip`/`flat_map`/`chain` iterator adapters, gated on the `Pair`-vs-`Tuple`
decision ([#90](https://github.com/thera-lang/thera/issues/90)). The `std.fiber`
combinator layer is [#94](https://github.com/thera-lang/thera/issues/94).

### Runtime (Rust)

Fibers phases 0–4 are done (scheduler-drivable `run_loop`; `spawn`/`join`/
`yield` with GC roots across every fiber; buffered `Channel<T>`; park on real
I/O via timers + the worker pool; the readiness poller; `select` — see
_Changelog_; design in [architecture.md](architecture.md) §Concurrency). The
interpreter was profiled 2026-06 and the easy wins are in (the unified value
stack, the `ListLen` opcode); the findings — the cost is the heap-access path
and allocation, not dispatch — are preserved in the issues below. The in-VM
profiler v1 (`THERA_PROFILE=1`) is done.

The open items have moved to the tracker:

- fiber refinements: per-resource waiter lists
  ([#91](https://github.com/thera-lang/thera/issues/91)), zero-capacity
  rendezvous channels ([#92](https://github.com/thera-lang/thera/issues/92)),
  exit semantics for surviving spawned fibers
  ([#93](https://github.com/thera-lang/thera/issues/93))
- the `std.fiber` combinator layer — cancellation, structured concurrency,
  bounded concurrency ([#94](https://github.com/thera-lang/thera/issues/94))
- interpreter perf, structural: per-object allocation
  ([#95](https://github.com/thera-lang/thera/issues/95))
- the Cranelift JIT tier, with the untagged-value and heap-access rework
  ([#96](https://github.com/thera-lang/thera/issues/96))
- profiler stages 2 and 3: line-attribution debug info
  ([#97](https://github.com/thera-lang/thera/issues/97)) and perf-map/jitdump
  for JITed frames ([#98](https://github.com/thera-lang/thera/issues/98))
- native resource finalization via GC-owned `Obj::Foreign`
  ([#99](https://github.com/thera-lang/thera/issues/99))

(Profiling the _runtime itself_ — the Rust interpreter/natives — is separate and
already covered by `cargo` + samply/Instruments and the `[profile.profiling]` /
`native-stats` setup.)

### Compiler & front-end

The big arcs here have landed — qualified-only + `pub` visibility enforcement,
the owner-correct `TypeId` resolution arc, parser recovery (Stages 0–3 + 2b),
instruction-level codegen tests for the trickier lowerings, and the codegen
audit's match-compilation / closure-walker extraction seams — see _Changelog_.
The hermetic checker/resolver test harness stays the default by design (speed,
isolation, bootstrapping safety).

The open items have moved to the tracker:

- faithful `if let` / `let … else` syntax nodes, retiring `MatchOrigin`
  ([#105](https://github.com/thera-lang/thera/issues/105))
- resolution follow-ups: `impl` coherence / orphan rules ([#107](https://github.com/thera-lang/thera/issues/107)),
  selective import `show`/`hide` ([#108](https://github.com/thera-lang/thera/issues/108)), the "module"→"library"
  terminology sweep ([#109](https://github.com/thera-lang/thera/issues/109)), prelude value-name shadowing — the
  `std.log` `error` unblock ([#114](https://github.com/thera-lang/thera/issues/114))
- whole-closure diagnostics: cascade suppression / cause-naming
  ([#110](https://github.com/thera-lang/thera/issues/110)), check-path closure scope ([#111](https://github.com/thera-lang/thera/issues/111))
- native-decl follow-ups ([#112](https://github.com/thera-lang/thera/issues/112)) and the `@extern` name-check test
  ([#115](https://github.com/thera-lang/thera/issues/115))
- generics residual follow-ons ([#113](https://github.com/thera-lang/thera/issues/113))
- codegen: `module_scope` unit coverage ([#116](https://github.com/thera-lang/thera/issues/116)), owner-qualified
  `FuncDef` names ([#117](https://github.com/thera-lang/thera/issues/117)), the owner-blind keying tail + CH12
  arg-resolution cleanup ([#118](https://github.com/thera-lang/thera/issues/118)), remaining extraction seams
  ([#119](https://github.com/thera-lang/thera/issues/119))
- the linked-real-`std.core` harness, deferred until a test needs it
  ([#106](https://github.com/thera-lang/thera/issues/106))

### LSP

The query layer + incremental engine landed in full: one analysis session
shared by `thera check` and the LSP, owner-correct value+type resolution, the
resolved-library cache with dependency-graph invalidation, `type_at`, semantic
references/rename, backgrounded workspace diagnostics with `resultId` caching,
completion, and signature help — see _Changelog_. (When touching the parser,
keep in mind the precedence-table refactor preserved the `panicking`/recovery
structure.)

The remaining follow-ups have moved to the tracker: the agent-facing renderer
queue — implementation/type hierarchy, call hierarchy, inlay hints,
`willRenameFiles` ([#122](https://github.com/thera-lang/thera/issues/122)); streaming partial workspace-diagnostic
results ([#120](https://github.com/thera-lang/thera/issues/120)); and the `files.watcherExclude` reconciliation
([#121](https://github.com/thera-lang/thera/issues/121)).

### Developer tooling

- **Verify the code snippets in docs.** Nothing checks that a fenced `thera`
  block in `docs/*.md` or a `///`/`//!` doc comment compiles, and they rot
  silently — which is the worst way for them to fail, because a snippet's whole
  audience is someone (or something) learning the language from it. An LLM
  reading a doc that teaches syntax the compiler rejects is precisely the
  failure this language exists to avoid.

  Not hypothetical: the `std.net`/`std.http` arc (2026-07) shipped a module
  header using `loop { … }`, which is not Thera (there is `while`/`for` and no
  `loop`), and `docs/stdlib.md` plus a `server.thera` example both showed
  `serve(addr, handler)` with a named function — the form that motivated the
  first-class-functions fix, and that did not compile when it was written. Both
  were caught by hand, which is exactly the thing that doesn't scale.

  **Design settled (2026-07) — see [scale.md](scale.md) § item 6** for the full
  treatment. The shape: three example tiers by size (fenced one-liners in doc
  comments; `@example` fns in `foo_test.thera`, pulled into doc sites by
  explicit `/// @file#fragment` references; whole programs in `examples/`);
  **the fence tag is the contract** — `thera`-tagged blocks are verified
  (attributes `sketch`/`no_run` for exceptions), untagged blocks are ignored,
  which the existing corpus already conforms to (language.md's blocks all
  tagged, stdlib.md's sketches all untagged); **compile-check is the universal
  bar**, running is opt-in by shape (a `// => value` oracle or `// error:`
  expectations — the `tests/lang` harness has the machinery). Implementation
  phased: extraction + compile-check first (catches the rot class above),
  `@example`/references with the doc generator, oracles and the `// =>`
  migration sweep after.

- **Reflowing doc comments — the prose half of the formatter.** `thera fmt`
  normalizes code layout but never touches comment text, so `///` prose is
  hand-wrapped and drifts. A follow-on to the canonical-formatter arc (see
  _Reflowing formatter_): rewrap `///` / `//!` runs to the same margin the code
  uses.

  **It needs its own guard, and the existing one does not cover it.** The
  formatter's safety check is token equality, and **comments are not in the
  token stream** — the lexer records them on a side channel
  ([lexer.thera](../pkgs/cli/lexer/lexer.thera)), so `same_tokens` says nothing
  about them. That is benign today (no pass touches comment text) but it means
  reflowing prose would be unguarded. The invariant to add is **normalized prose
  equality**: strip the `///` prefixes and collapse whitespace on both sides,
  and require the text to match. Note this also means doc-comment reflow was
  never blocked by the whitespace-only contract — the two are independent.

  **What must not be rewrapped**, and the reason this is a real pass rather than
  a word-wrap loop:
  - **Fenced code blocks.** A ` ```thera ` block is source, not prose. This
    interlocks with _Verify the code snippets in docs_ below, which wants those
    same fences extracted and compiled — both features need one fence-detector,
    so build it once.
  - **Lists, tables, and indented examples**, where the line structure is the
    content.
  - **Ordinary `//` comments — scope call.** Doc comments have a defined shape;
    plain comments are often deliberately laid out (aligned trailing notes, the
    ASCII diagrams in module headers). Leaning toward `///` / `//!` only, with
    plain comments left alone.

  Sequencing: after the formatter arc settles, and after (or with) the
  fence-detector from the doctest item. Not urgent — measured over the corpus,
  comment prose already sits at ≤84 chars in 99.3% of lines, so this buys
  consistency rather than relief.

- **Doc-comment tooling — machinery pending.** The conventions
  ([language.md](language.md#documentation)), the `sdk/std/` migration to
  `///`/`//!`, and the lexer's comment side-channel are done (see _Changelog_) —
  but every downstream consumer remains **pending** (the side channel is
  collected, then dropped: each `parse_tokens` call site passes only
  `lex.tokens`). The remaining tooling: (1) **attach docs to AST nodes** — a
  pass re-associating each `///`/`//!` comment to the decl it precedes by span,
  threaded onto the AST (or a side table) — the one piece the side channel
  directly unblocks; (2) **LSP hover** surfaces the item/file doc (today
  `hover.thera` shows the signature only); (3) a **doc generator** extracts a
  package's `pub` surface + barrel `//!` into an index for agent navigation (no
  `doc` subcommand yet); (4) **reference resolution + lint** — resolve
  `[Symbol]` references (link them in hover/doc-gen, flag ones that no longer
  resolve), plus a lint for `pub` symbols whose doc only restates the signature,
  and normalization of doc layout. (Not yet migrated: `pkgs/cli/` and
  `examples/`, deliberately deferred — the public API surface was the priority.)

- **Tools — refactorings (suggestion diagnostics + code actions).** The
  machinery landed end to end (see _Changelog_): `thera lint` reports
  convertible sites per rule, `thera lint --fix` applies the rewrites (`if let`,
  `?`, `unwrap_or`/`unwrap_or_else`, `map`, `let … else`) via AST-guided
  source-slice reassembly, and the LSP code action offers the same sites as
  `refactor.rewrite` actions. Each future idiom adds a structured `lint` site +
  a `fix` edit and rides the same pipeline. Remaining:
  - **`while i < xs.len()` → `for` / `enumerate` auto-rewriter.** The lint flags
    the shape and the corpus was hand-migrated with `List.enumerate()` (47 of 65
    sites; the remaining 18 genuinely don't fit — a non-zero start, a
    stepped/conditional increment, a compound or sub-range bound, a plain count,
    a `Bytes` receiver, or a list mutated mid-loop). Unlike the `match` rules
    the rewriter needs a genuine loop-body rewrite — substitute `xs[i]` → the
    binding and delete the pre-loop `let mut i = 0` + the `i = i + 1`, both
    outside the loop span. Deferred with it: a `zip` adapter for the
    parallel-two-list sub-case (needs the `Pair`/`Tuple` decision — see
    _Stdlib_).
  - **Calling-convention lint** (positional argument → labeled parameter) — the
    next rule; needs resolution, not just AST shape. Pairs with the enforcement
    sweep under _Language → Calling convention_.
  - **Ecosystem payoff.** These aren't one-off cleanups: the same
    shape-matching + located-suggestion + auto-fix machinery is what a Thera
    `lint` / `thera fix` is built from, and what the LSP surfaces as code
    actions. Investing here (diagnostics that flag non-idiomatic code, with a
    mechanical fix) pays off for every future idiom, not just this batch — so
    lean into it rather than hand-editing files. Migration of existing code is
    **opportunistic until then** (touch a file, modernize it); the standing
    guard is the lint.

- **Idioms & best-practices guidance (agent-facing).** The language now has a
  canonical form for each common shape (the _Choosing a form_ table in
  [language.md](language.md), and the per-combinator "reach for it when…" docs),
  but that is reference material. The open piece is **prescriptive guidance an
  agent loads** — "write Thera this way": prefer `if let`/`let … else`/`?`/
  combinators over `match`-as-guard, `for`/`enumerate` over `while i <`, the
  doc-comment conventions, etc. Surfaced by the ergonomics sprint, which found
  that a lot of **existing** code predates these features and doesn't use them —
  so idiomatic Thera has to be written down somewhere consulted, not just
  implied. **The content now exists: [idioms.md](../sdk/doc/idioms.md)** — a
  self-contained agent-facing primer, seeded from the canonical-form-per-shape
  table, the `match`-as-guard anti-pattern, and the errors agents actually made
  on first contact (mined from real sessions: unqualified `Result.Ok`, guessed
  stdlib methods, `Json` field access, missing `[:]`, …). It lives in `sdk/doc/`
  and **ships with the built SDK** (`build/sdk/doc/`), so the guidance an agent
  reads is version-locked to the toolchain it invokes — never a stale
  project-local copy. Remaining is **distribution into user projects**, as two
  commands:
  - **A command that prints the primer** — so any agent harness can reach it
    without knowing the install path. Naming is open: `thera doc idioms` (and a
    natural future home for `thera doc std.fs`-style API lookups), vs. hanging
    it off init/config. Leaning `thera doc`.
  - **`thera init`** (with `thera create` delegating to it) — writes a thin,
    stable **pointer stanza** into the project's `AGENTS.md`/`CLAUDE.md`
    ("before writing Thera, read the output of `thera doc idioms`; run
    `thera check` early and often"), never the content itself: a five-line
    pointer can't rot, while a copied primer diverges from the SDK the project
    actually builds with. Optional per-harness emitters (a Claude Code skill,
    `.cursor/rules`, …) can layer on later; the harness-neutral pointer is the
    base. The strongest channel remains the diagnostics themselves —
    prescriptive errors teach at the moment of the mistake (see _Tools —
    refactorings_).

  Pairs with _Tools — refactorings_: the doc says what's idiomatic, the lint
  enforces it mechanically. The **language changes** the session mining pointed
  at are tracked separately in the _Idioms punchlist_ below.

- **Width: keeping 100, and the reason is not that the data chose it.** The
  study ran — the corpus reformatted at 80 / 88 / 90 / 92 / 94 / 96 / 98 / 100 /
  110, via `format_source_at` in [fmt.thera](../pkgs/cli/fmt.thera). Comments
  are excluded from the code columns (the formatter does not rewrap them yet);
  the irreducible column is lines dominated by one long string literal, and
  unbroken is the rest of what stayed over the margin.

  | width |  lines | vs 100 | irreducible | unbroken | split groups | crowding margin | code p90 |
  | ----: | -----: | -----: | ----------: | -------: | -----------: | --------------: | -------: |
  |    80 | 64,689 | +10.4% |         357 |       90 |       11,705 |           1,375 |       64 |
  |    88 | 61,613 |  +5.2% |         226 |       31 |       10,775 |             836 |       68 |
  |    90 | 60,967 |  +4.1% |         202 |       26 |       10,576 |             741 |       68 |
  |    92 | 60,458 |  +3.2% |         187 |       24 |       10,408 |             639 |       69 |
  |    94 | 59,891 |  +2.2% |         164 |       23 |       10,240 |             628 |       70 |
  |    96 | 59,423 |  +1.4% |         144 |       22 |       10,098 |             560 |       71 |
  |    98 | 59,060 |  +0.8% |         130 |       19 |        9,988 |             516 |       71 |
  |   100 | 58,576 |      — |         116 |       19 |        9,840 |             518 |       72 |
  |   110 | 57,637 |  −1.6% |          64 |       15 |        9,568 |             145 |       73 |
  - **There is no knee between 88 and 110.** Every column decays smoothly; the
    per-column line cost drifts from ~380 at the narrow end to ~100 at the wide
    end with no step anywhere. So the corpus does not pick a number, and any
    choice in that range is a judgment call rather than a measurement.
  - **80 is the one width the data does rule out.** Lines the formatter cannot
    break rise to 90 (3–4× every other width), crowding nearly doubles against
    88, and separately **2,009 comment lines already exceed 80** — the corpus's
    prose is hand-wrapped at p75 = 80, p99 = 84. Until doc-comment reflow lands
    those would simply sit over the margin.
  - **The margin governs only the top decile.** Code p90 moves 64 → 73 across
    the whole 80–110 range: nine columns for thirty. Half the corpus's code
    lines are under 30 columns wide. Whatever this choice is worth, it is not
    worth much.
  - **Two false signals, both worth recording.** An apparent cliff at 98 → 100
    (962 lines/column against ~180 either side) was a formatter bug, not a
    property of the corpus — a scalar list already packed into rows was
    misclassified and exploded to one element per line (fixed; see _Changelog_).
    And the residual "unbroken" rise below 100 is 37–58 packed scalar rows that
    keep the width they were packed to, an artifact of measuring from a
    100-formatted corpus rather than from scratch.

  So the tiebreak is not empirical. **Keep 100**: it is what the corpus is
  already formatted to (any change is another ~5,000-line sweep), it is what
  [language.md](language.md#style) already tells authors, and it is where the
  statically-typed cluster sits — rustfmt, google-java-format, swift-format and
  ktfmt all default to 100, and the Linux kernel moved 80 → 100 in 2020. Thera's
  shape is that cluster's: qualified paths and generic types like
  `Map<String, Map<String, LibraryNamespace>>` are what consume the columns.

  - Context, unchanged by the study: enforced formatters split into a **~80
    cluster** (ocamlformat 77, Prettier 80, `dart format` 80, PEP 8's 79) and a
    **~100 cluster** (rustfmt, google-java-format, swift-format, ktfmt), with
    Black's 88 deliberately between — "80 plus 10%". Tellingly, **Go and Zig,
    the two strongest one-true-format traditions, decline to take a position on
    line length at all**, on the grounds that where to break is a semantic
    judgment about what groups with what. From the LLM side the concern is
    **pathological** lines, since agents navigate through line-addressed
    interfaces (grep output, `file:line:col`, patch hunks) — an argument for a
    ceiling against outliers, not for tight wrapping. The outliers here are the
    116 irreducible string literals, and no width in the range touches them.
  - **Prose should get its own, narrower width** when _Reflowing doc comments_
    lands, rather than inheriting 100. The corpus already votes for it —
    comments sit at p75 = 80, p90 = 82, p99 = 84, with six over 88, written that
    way by hand against a 100-column guideline. PEP 8 codifies the same split
    (79 for code, 72 for prose), and it is the one place these measurements
    point somewhere definite.

### Language

- **Only an identifier or a field may be a call target.** `maker()(5)` and
  `fns[0](10)` are rejected with `unsupported call target`
  ([codegen.thera](../pkgs/cli/codegen/codegen.thera) → `call_expr`) — an
  arbitrary expression in callee position doesn't compile, so a function value
  has to be bound to a name before it can be called. Equally true of a lambda,
  so it is not about function _references_; it surfaced next to them (2026-07)
  because a reference makes function values easy to produce.

  This is the same spec/implementation shape the first-class-functions gap had:
  [language.md](language.md) §Functions shows `adder(by: 2)` returning
  `(Int) -> Int` as a headline, and the obvious next keystroke — calling it —
  needs a bound name. Decide whether the spec means to allow an expression
  callee (and if so, compile it: the callee is just another operand to evaluate
  before `call.indirect`) or to require the binding, and say which. A
  conformance test under `tests/lang/functions/` should pin whichever.

- Instance level mutability would be easier for agents to reason about. We
  should consider the impact, pros, and cons of switching from field level
  mutability to instance level mutability.

- **Calling convention — one canonical call form (tighten + enforce).** The
  decided model (see [language.md](language.md) → Named parameters): the author
  chooses each parameter's call form and the call site has exactly **one** —
  **labeled by default**, **positional via `_`** (label forbidden). This
  eliminates caller choice, so every call to a function reads the same (the
  consistency the LLM-native goal wants), while the author still gets terse,
  self-documenting call sites where each is warranted. The checker is currently
  **permissive** (a labeled parameter also accepts a positional argument, and
  labeled arguments may be reordered), so the model ships with an
  enforcement-status caveat in the docs. Sequencing:
  1. **Clarify the docs** — _done_ (language.md Named parameters + style rule).
  2. **Fix existing code** — migrate call sites that pass a labeled parameter
     positionally (or rely on reordering) to the canonical form, and add `_` to
     the parameters that should be positional (the obvious "subject" args). This
     is a corpus-wide sweep; it pairs with the _Tools — refactorings_ machinery
     (a located diagnostic for "positional argument to a labeled parameter" is
     the natural lint, with a mechanical fix).
  3. **Enforce** — the checker requires a labeled parameter's label and forbids
     a positional argument for it. Flip after the sweep so the corpus stays
     green.
  - **Open sub-decision:** whether to also require **source order** for labeled
    arguments (forbid `f(b: 2, a: 1)`). The same one-form principle argues yes;
    it's a separable call from the positional-vs-labeled tightening. Decide
    during step 3.
  - The style rule (`_` for the single obvious "subject" arg; labels for
    booleans / multiple same-typed / non-obvious roles) belongs in the
    agent-facing idioms guidance (see _Idioms & best-practices guidance_).
  - **Longer-term — first-arg-positional default (investigate, not scheduled).**
    If `_`-on-every-first-parameter proves a frequent irritant once the
    convention tightens, reconsider making the **first ("subject") parameter
    positional by default and the rest labeled**, with explicit overrides both
    ways. It makes the common case need no marker, at the cost of
    position-dependence and a two-way override (less "simple, one rule"). **Not
    an immediate goal.** Measure first — count how often `_` would land on the
    first parameter **under the tightened convention** (not today's permissive
    usage); that frequency is the input to the flat-`_` vs first-arg-positional
    call. (Keyword markers like `pos`/`positional` were considered and declined:
    too verbose at this frequency, and `pos` collides with the ubiquitous `pos`
    variable; `_` reads as "external label = none", consistent with the
    `external internal` slot.)

- **Generic operators** (`<T: Add>`, operators-as-traits) — the remaining piece
  of the generics arc (bound enforcement + `call.virtual` dispatch on `T` are
  done). This is also where the language's **implicit operator/literal
  lowerings** would gain a Thera-level surface: `==`, `+`/interpolation,
  `[]`/`[]=`, and the `[k: v]` map literal are emitted by codegen straight to
  runtime natives (`eq`, `str_concat`, `stringify`,
  `list_index`/`list_set`/`map_index`, `map_new`/`map_set`) with no named Thera
  method behind them — the one category of addressable behaviour not represented
  in `sdk/std`. Operators-as-interfaces (`Eq`, `Add`, and `Indexable` below) is
  what turns those into ordinary Thera methods; revisit the exact shape then
  (the `[]` half is the _Index operator_ item).
- **Primitive vtables — enabling work, deferred to the generics arc.** A
  primitive reached through _virtual_ dispatch — `call.virtual` from a
  bounded-generic context where the runtime value is an
  `Int`/`Double`/`Bool`/`String` — has no vtable row; it resolves through a
  **hardcoded fallback** in the interpreter (`virtual_fallback` in
  `interp/mod.rs`: `display`/`debug`/`eq`/`compare`). The 2026-07 scoping pass
  closed the user-reachable soundness gap at the checker (primitive bounds are
  limited to the four interfaces the fallback can dispatch) and indexed the
  dispatch table per receiver type — see _Changelog_. What remains is the
  enabling work, deliberately deferred:
  - **Letting user interfaces on primitives dispatch** (so the checker guard can
    lift): reserve a dispatch-id range for the built-in value shapes (`Value`
    variant → fixed id, partitioned alongside struct type-table indexes and
    `ENUM_DISPATCH_BASE`), have `dispatch_type_id` return them, and teach
    `build_dispatch` to resolve impl-on-native-type rows. Do this **with the
    operators-as-interfaces / conditional-impl generics work** — it's the same
    "dispatch a built-in interface on a concrete type" machinery, and `<T: Add>`
    will force the same id scheme.
  - **Perf constraint (measured context):** keep the fallback as the fast path
    for the four built-in selectors — direct Rust with _no_ lookup at all, and
    `eq` is the highest-volume operation in the interpreter profile — while a
    vtable hit pays the lookup plus an interpreter frame. Vtable rows should add
    dispatch for _user_ selectors; the built-in four stay hardcoded as an
    optimization rather than a correctness crutch.
  - **`virtual_fallback` never fully retires regardless:** its structural
    `debug`/`eq` for impl-less structs/enums _is_ the auto-derive mechanism, and
    the `display` → `debug` arm is what keeps rendering total.
- **Index operator (`[]`) overloading.** `a[i]` / `a[i] = v` are hardcoded in
  codegen to the built-in `List`/`Map` natives by static type; any other
  receiver is a compile error (`pkgs/cli/codegen/codegen.thera`). Small–medium,
  self-contained: desugar to a method call reusing static/`call.virtual`
  dispatch (inference resolves `a[i]` from the receiver's index method;
  codegen's two `throw` branches become method-call lowerings; List/Map keep
  their native fast path). Design leaning: a single `Indexable<K, V>` interface
  (one `get`- and one `set`-style method) rather than separate
  `Index`/`IndexSet`. Also a prerequisite for a Thera `Map` (which additionally
  needs map-literal lowering and a native↔Thera-map bridge).

### Idioms punchlist

Language changes pointed at by the idioms work: writing
[sdk/doc/idioms.md](../sdk/doc/idioms.md) meant mining recent agent-session
transcripts (2026-08, ~240 diagnostics) for what first-time writers actually get
wrong, and some of those errors implicate the language rather than the doc. The
**razor** for deciding which: does the rule impose a **recurring per-line tax**
(ceremony that stays expensive after the agent has learned it) or a **one-time
surprise** (learned in one check-cycle, cheap forever)? Change the language for
the former; teach the latter via the primer and diagnostics. Corollary from the
same data: breaking an LLM prior is fine when the break is **unmissable** (no
`async` produced zero errors — there is nothing to almost-get-right), and costly
when prior-shaped code **almost works** (bare `Ok(x)` fails only at the
constructor). Re-mine transcripts after each change lands; that is the
measurement instrument for this list.

**Strong candidates:**

- **Keywords as member names (contextual `type`).** `type` cannot be a field,
  parameter, label, or member name — yet every real JSON API has `type` fields
  (most Anthropic content blocks, GitHub payloads), so mirroring an API forces
  rename-and-map at every decode boundary, and the
  [api-access.md](api-access.md) generator will hit it constantly. Field/label/
  member positions are grammatically unambiguous, so making keywords contextual
  there (the TypeScript move) costs nothing in local reasoning. Do this before
  the OpenAPI generator, not after.
- **Bare variant construction where the expected type is known.** The most
  frequent first-contact error is `Ok(x)` / `Some(v)` for `Result.Ok(x)` /
  `Option.Some(v)` — and it is a recurring tax (every function's exit paths,
  forever), against an enormous Rust prior. The asymmetry is the tell: patterns
  are bare _because the scrutinee's type is known_, and bidirectional inference
  already flows expected types into expressions — so allow bare `Variant(args)`
  exactly where an expected enum type pins it (`return Ok(x)`, an argument, an
  annotated binding), keeping the qualified form as the general case. The
  reserved-names rule means `Ok`/`Some`/`None`/`Err` can never mean anything
  else, so "one name, one meaning" survives. A smaller extension on the same
  principle, to evaluate with it: accept `[]` as the empty map where the
  expected type is a `Map` (today it infers `List<?>` and mismatches).
- **`let … else` completion.** The v1 limits — the `else` must end in a
  _literal_ `return`/`throw` (divergence through nested branches isn't
  recognized), and the pattern binds at most one variable — are checker
  maturity, not design; the Rust prior (any diverging block, multiple bindings)
  is also the correct semantics. Finish it.

**Worth investigating (not yet decided):**

- **Implicit `T → Option<T>` promotion** at assignability boundaries. Would kill
  a real mined error class (`expected Option<Double>, found Double`), and
  Swift's precedent says it's an ergonomic win — but it would be Thera's first
  implicit conversion, and bare-variant construction doesn't absorb it (agents
  write `f(x)`, not `f(Some(x))`). Hold the line for now: make the diagnostic
  prescriptive ("wrap it: `Option.Some(x)`"), re-measure after the strong
  candidates land.
- **First-arg-positional default** — already an investigate item under _Calling
  convention_; the mining adds moderate supporting evidence (label friction is a
  per-call-site recurring tax). Today's permissive checker understates the
  friction tightening will cause, so re-run the transcript mining after
  one-canonical-call-form lands and let that decide.
- **Typed JSON priority.** The single biggest mined error class (23×
  `field access on non-struct value`) is agents reaching for TS/Python
  duck-typing on `Json`. The accessor chain is the workaround; the fix is making
  the typed path cheap enough that agents reach for it first — derived decoders
  / the generator (see [api-access.md](api-access.md),
  [typed-json.md](typed-json.md)). The data says raise that arc's priority.

**Cross-cutting:**

- **Stdlib naming audit against LLM priors.** Agents guess `n.to_string()`,
  `s.parse<Int>()` — where a Thera name fights an overwhelming cross-language
  prior _without a compensating principle_, take the prior. The flagship case:
  `display()` vs `to_string()` — Thera's own named-for-its-result convention
  (`to_list`, `to_int`, `to_double`) argues for `to_string`, which is also the
  name agents guess.
- **Diagnostics as the primary channel — policy.** The transcripts show agents
  fix nearly every idioms-list error on the first diagnostic, so every
  prescriptive message pays out at the exact moment of the mistake,
  version-locked, in every harness. Standing policy: when a first-contact error
  class shows up in mining, the first response is a did-you-mean /
  here-is-the-fix diagnostic
  ([#85](https://github.com/thera-lang/thera/issues/85)); a language change
  needs the recurring-tax bar above.

### Language spec punchlist

The standing worklist for keeping the language spec — [language.md](language.md)
and its companion docs — consistent with the implementation. Populated by
periodic self-consistency reviews (the grammar pass, the 2026-07 spec pass, the
2026-07 diagnostics audit) and worked through iteratively: doc-only corrections
are applied directly and recorded below; findings that imply design or
implementation work stay open here until decided.

**Open — design/behavior follow-ups from the 2026-07 review:** none currently —
the review's follow-ups all landed, summarized in the [Changelog](#changelog):
the doc sweep, the eager-`List` + `List.iter()` bridge decision,
`thera test`/`check` LLM-output UX, `collect()`→`to_list()`, named structural
`Debug`, and the OOM/stack-overflow traps.

### Type system punchlist

Findings from the 2026-07 type-system review (a design-completeness pass over
the implemented system; every hole it found was verified empirically — each
checked clean but went wrong at runtime). Most are now closed (see _Changelog_);
what remains below is deferred with findings, or an open design call. The review
also settled the "formal treatment?" question: no lambda-calculus formalization
— the system is simple enough to specify in prose, and `Unknown`'s deliberate
leniency makes the classical soundness theorem false by construction; the spec
(language.md §Generics / §Assignability) plus the `tests/lang/` conformance
suite are the vehicle.

**Open — targeted checker fixes.** The three local, low-risk fixes from this set
are landed (see _Changelog_ → _Type-checker holes closed_); the one below is the
outlier — the spike showed it is _not_ local, so it is deferred with its
findings recorded.

- **`TypeParameter` → concrete assignability** — _deferred; spiked 2026-07._
  `fn f<T>(_ x: T) -> Int { return x; }` checks clean and traps at the call: a
  `T`-typed value flows into a concrete-typed position. The leniency is only
  needed concrete-→-`T` (instantiation, validated at call sites); a bare `T`
  source against a concrete target should be an error.

  **Spike (naive narrowing = remove the source-side `TypeParameter → true` in
  `is_assignable`): not viable.** Over the whole corpus it produced 13 new
  errors — **1 genuine hole** (the planted `fault-type-mismatch` test) and **12
  false positives** in legitimate code, in three patterns:
  - **A. Bounded `T` → its bound** (5) — `sorted<T: Ord>` passing a `T` where
    `Ord` is expected. `T: Ord` _is_ an `Ord`, but `is_assignable` has no bounds
    context.
  - **B. Type param under function contravariance** (7) —
    `xs.fold(0, (acc,x) => …)`: the lambda `(Int,T)->Int` vs `fold<A>`'s
    `(A,T)->A`. Param contravariance flips the _target_ param `A` into _source_
    position in the recursive call.
  - **C. Unbound inference param in generic args** (1) —
    `some.and_then((_n) => Option.None)` bound to `Option<Int>` → `Option<U>` vs
    `Option<Int>`; `U` should unify to `Int` but `None` pins nothing.

  **Why it can't live in `is_assignable`:** source-side `TypeParameter` leniency
  is load-bearing _inside the recursion_ — B and C arise only deep in it
  (function contravariance, generic-arg pairing), not from "using a `T` value as
  concrete." The real hole is a value whose type is _exactly_ `TypeParameter(T)`
  in a value-flow position (return / assign / arg) at the **top level**.

  **Recommended approach when revisited:** a dedicated check at the value-flow
  sites (`check_return`, `expect_type` for let/assign/args), **not** in
  `is_assignable`, that fires only when the source type is a _bare_
  `TypeParameter` (excludes B/C — their sources are `(…)->…` and `Option<U>`,
  never bare) and is **bounds-aware** — a `T: Ord` source satisfies `Ord` and
  its supers (excludes A). Bounds live in the checker's `type_param_bounds` (the
  table the unbounded-`T` method fix reads), which is why the check must be at
  the site, not in `is_assignable`. Residual false-positive risk: ~zero.

  **Why deferred:** the corpus has **zero** real instances of the hole (only the
  planted test), it can't cause memory unsafety (it traps cleanly with the
  honest `runtime type error: expected Int, found String` message — see the
  _Honest tag-mismatch traps_ changelog), and the fix needs bounds threaded to
  the value-flow checks — a materially larger, lower-payoff change than the
  other three targeted fixes (all landed). Revisit if a forcing case appears.

**Open — design decisions:**

- **Honest wording for native-argument type mismatches.** _(Runtime, follow-up
  to the tag-mismatch trap split — see \_Changelog_.)\_ The interpreter's own
  tag-checked pops now raise `Trap::TypeError` ("runtime type error: expected
  Int, found String"), but the native arg-checks (`str_contents`,
  `as_int`/`as_double`, `with_bytes`) still raise `Trap::Bug` ("internal
  error"). Converting them is blocked only on unthreading their `who` context
  param from ~100 call sites — do that, then route them through `TypeError` too
  (module-free type names, since natives have no `Module` handle).

**Deferred type-shape items:**

- **A first-class `Range` type** (deferred — no forcing function). The internal
  range cleanup landed (see _Changelog_); making `Range` a _nameable value type_
  (store, pass, return, `.contains`/`.to_list`) has no corpus demand — all range
  use is `for i in a..b`. Revisit when a feature wants ranges as values, the
  obvious one being range-based slicing (`list[2..5]`), which needs slice
  support anyway.
- **Type aliases** — **deferred indefinitely, by design.** An alias is a
  _transparent_ name (`type Fallible = Result<Void, Error>`), which adds exactly
  the indirection Thera's local-reasoning thesis is built to avoid: an LLM
  seeing `Fallible` must resolve it elsewhere. The verbosity win (the top
  candidate, `Result<Void, Error>`, is frequent but not _complex_) doesn't
  outweigh giving a reader more work; genuinely meaningful nested types are
  better served by a nominal `struct`. Recorded as a language non-goal in
  [language.md](language.md). Would need a very compelling use case to reopen.

**Qualified generic bounds and supers — done** (2026-08, found wiring TLS into
`std.http`): `fn f<S: io.Reader>(…)` and `interface A: ns.B` now parse and
resolve through the namespace like every other interface position — see
_Changelog_. The follow-up is done too: the http client's duplicated read/write
paths are now one `fn exchange<S: io.Reader + io.Writer + io.Closer>`, which
also let `send` shrink to a scheme branch over two connect calls. (Since renamed
to `open` and given a `Stream` to return — see the streaming Changelog entry.)

The review's holes are all closed or deferred-with-findings above; the landed
fixes are summarized in the [Changelog](#changelog) (variance, `Never` + tail
`throw`, and the four type-checker holes).

### Diagnostics punchlist

The still-open tail of the 2026-07 diagnostics review; everything else landed —
see the Changelog's **Diagnostics review** entry for the arc summary. The
warning machinery is live: add rules one at a time, corpus-sweeping each.

The open items have **moved to the issue tracker** (labeled per
[tracker.md](tracker.md); this section was the migration pilot): the effect-free
expression-statement warning
([#83](https://github.com/thera-lang/thera/issues/83)), the
referencing-a-`_`-prefixed-local warning
([#84](https://github.com/thera-lang/thera/issues/84)), did-you-mean suggestions
([#85](https://github.com/thera-lang/thera/issues/85)), owner-qualified
same-name type mismatches
([#86](https://github.com/thera-lang/thera/issues/86)), and the `as _`
qualified-access semantic to decide
([#87](https://github.com/thera-lang/thera/issues/87)).

Already tracked elsewhere, not repeated here: imported-body check scope, cascade
suppression, calling-convention enforcement, native-arg trap wording, and the
deferred bare-`TypeParameter` narrowing.

### Networking punchlist

The arc is done: the phase-4 poller's gaps (per-fd wakeup routing,
`select`-based socket timeouts), all five TLS stages of
[http-tls.md](http-tls.md) (so `std.http` speaks `https`, chain- and
host-verified, tested end to end with no network), streaming response bodies +
`std.http.sse`, and a reachable `std.http.server` — see the Changelog entries
for each arc; the design docs keep the reasoning and the decisions settled along
the way (ALPN unoffered; the trust seam not reaching `std.http`).

What `std.http` still lacks is deferred with reasons in [stdlib.md](stdlib.md):
redirect following and a public server-TLS surface (file when someone cares),
plus two items tracked as deferred issues because the streaming design left
notes that size the work — connection pooling / keep-alive
([#102](https://github.com/thera-lang/thera/issues/102)) and streaming request
bodies ([#103](https://github.com/thera-lang/thera/issues/103)). None of them
gates [api-access.md](api-access.md), the larger arc all of this feeds — calling
third-party HTTP APIs (GenAI, MCP, GitHub) from Thera tools.

### Scheduler punchlist

Findings from a 2026-07 design review of fiber waiting/waking (the park
taxonomy, the readiness poller, `select`). The review's verdict was that the
design is sound — the two `Multi`-park invariants (idempotent waking,
sweep-on-schedule) are enforced at single choke points and mutation-tested — so
the findings are gaps _around_ it, not problems _in_ it; none is a correctness
bug, and all grow teeth with a long-running server.

The three findings have moved to the tracker: per-resource waiter lists, which
also covers the Progress-free-select re-probe herd and the `IoFinish` comment
insurance ([#91](https://github.com/thera-lang/thera/issues/91)); the
wall-vs-monotonic select-deadline clock
([#100](https://github.com/thera-lang/thera/issues/100)); and scheduler
reclamation of `Done` fibers and closed channels — the biggest, the one that
gates calling the `std.http` server production-shaped
([#101](https://github.com/thera-lang/thera/issues/101)).

## Runtime staging (longer view)

See [architecture.md](architecture.md) for the design behind each tier.

1. ~~Tree-walker POC (settle semantics); define the bytecode IR.~~ _Done._
2. ~~Tier-0 interpreter + precise non-moving mark-sweep GC.~~ _Done_ — runs real
   Thera apps with fast startup.
3. **Cranelift JIT tier** for hot functions (or trial copy-and-patch); decide
   the JIT GC-root strategy here. This is what forces the tagged→untagged
   value-representation move (interpreted and compiled frames must share a
   representation).
4. **AOT via `cranelift-object`** later — single-binary distribution; optional,
   not on the startup-critical path.

## Changelog

Brief summaries of finished arcs; design details live in
[architecture.md](architecture.md) / [language.md](language.md) and the linked
conformance specs. Newest first.

- **Credential redaction, and a live smoke that checks the contract** (2026-08).
  The first client to hold a real secret found the leak api-access.md item 6 had
  predicted: `'${client}'` printed the bearer token in full, and so did
  `'${request}'`, because `Debug` derives structurally and is the total fallback
  every unprepared print goes through. `github.Client` and `std.http`'s
  `Request`/`Response` now override it, with `http.SENSITIVE_HEADERS` and
  `http.redact_headers` public so a caller logging its own headers reuses the
  list. Display-only — `Eq` stays structural, so redaction cannot change a
  comparison. The general answer (a `Secret` type with an explicit `.expose()`)
  is still open.
  - **And a third test layer.** The hermetic suite runs against a loopback fake,
    which agrees with whatever misreading it was written from — so it cannot
    check whether the types match what the server really sends, which for types
    derived from a description known to be wrong is the question that matters.
    Four `THERA_NET_TESTS`-gated live tests (structure only, never content, no
    credential) validated GitHub's whole response shape, following the precedent
    `std.net` and `std.http` set for their own live TLS smokes.
  - `pkgs/github/example.thera` is the runnable demonstration — a real call
    against a public repository — and the first data point for what a package
    layout needs beyond its library ([scale.md](scale.md) item 4, open question
    f).
- **`pkgs/github` — the call surface, settled by a complete small client**
  (2026-08). Three operations out of GitHub's 1220 (list PRs, create PR, create
  issue), written to answer the questions [api-access.md](api-access.md) Arc 2 §
  When the shape is ready to evaluate lists before a generator emits 1220 of
  them. Six of the seven checklist rows are now decided: a `Client` value with
  an overridable `base_url` (which is what makes an end-to-end test possible at
  all, since `std.http` has no server-side TLS); an error enum with one variant
  per _kind_ of failure rather than per status; a total error decoder, because a
  strict one trades the server's explanation for a complaint about it;
  `client.pulls().list(…)` over a flat surface, on the completion-list argument;
  and a `Page<T>` that carries its own decoder so `page.next()` needs no
  arguments, with `all()` bounded by default. 48 tests, every request over a
  real socket to a loopback fake GitHub.
  - **Written against the real description, which changed the answer four
    times.** OpenAPI 3.0 cannot express a nullable `$ref`, so GitHub ships a
    duplicate `nullable-simple-user` and a required field is still `Option`;
    untagged `oneOf` decodes by dispatching on `Json.kind()` — the discriminator
    the spec failed to declare — which closes the last alarming row of the
    schema-to-type table; request-side and response-side unions are different
    problems, because you control what you send; and `pulls/list` and
    `pulls/create` return _different_ schemas. Four more manifest-only facts
    joined Anthropic's three, which is what settles that the pattern was not
    vendor-specific.
  - **Two front-end bugs, both check-clean-and-wrong.** A declared enum `name()`
    lost to the built-in tag reader (two of three resolution sites had the
    precedence backwards; the builtin is now documented in
    [language.md](language.md) § Inherent methods and pinned by
    `iface-enum-name`), and `unused-import` fired on an import whose file adds
    methods to a foreign type — a false positive on a load-bearing import, with
    `--fatal-warnings` gating the corpus and no correct fix available. Keeping
    that seam working matters: it is how a generator adds a resource by writing
    one new file and editing none.
- **`std.toml` — a durable config format, conformance-pinned** (2026-08). A
  complete TOML 1.0.0 reader in core, pure Thera, driven by the two manifests
  that needed it (api-access.md's generator manifest, scale.md item 4's package
  manifest) — the stdlib's "promote TOML when demand is demonstrated" clause
  firing as designed. A `Json`-parallel value model with two format-forced
  deltas (no null; a text-carrying `Datetime` with a `parse_rfc3339` bridge); a
  path-shaped lenient surface (`get_int('server.port')`) plus a
  `json.Cursor`-mirrored strict `Cursor` whose errors name TOML-spelled paths;
  parse-only until a tool writes a manifest. Conformance is measured, not
  claimed: the official toml-test suite (v2.2.0, all 679 TOML 1.0.0 cases)
  passes, vendored under the `third_party/` convention this arc introduced.
  Surface in [stdlib.md](stdlib.md) § `std.toml`; the design doc (docs/toml.md)
  retired with the arc, per its own plan.
- **The OpenAPI spec survey — "which API next" is a table now** (2026-08).
  `dev/spec_survey.py` fetches the seven-API hand-list (following Anthropic's
  `.stats.yml` indirection), caches under `build/spec-cache/`, and reports a
  ranking table, a construct histogram, and the transitive schema closure of a
  named operation set. `--guru N` adds an APIs.guru sample for the
  population-wide view. Results in [api-access.md](api-access.md) § Choosing
  targets; it is a `dev/` analysis helper, not part of the build.
  - **It corrected three things the plan had wrong.** api-access.md's "527
    `anyOf` occurrences, the row that will hurt" — 480 of those are
    `anyOf: [T, {type: null}]`, which is 3.1's spelling of `Option<T>` and not a
    union at all, leaving **47** genuinely untagged. Anthropic's `?beta=true`
    path variants are **80 of 89 paths and 120 of 131 operations**, so they are
    a gating Arc 3 decision rather than a footnote. And **no spec on the slate
    models streaming**: Anthropic has a `stream: boolean` request property, an
    `application/json`-only 200 response, and zero occurrences of `event-stream`
    — so layer (c) cannot be generated, which retroactively justifies leaving it
    to Arc 2.
  - **Filtering is a number, not an assertion.** A realistic three-operation
    client reaches 165 of Anthropic's 928 schemas (18%), 28 of GitHub's 969
    (3%), 73 of OpenAI's 1394 (5%). Generating GitHub whole would emit 34× what
    a pull-request tool needs.
  - **Construct priority, by measured frequency**, with the slate and the
    population disagreeing sharply:
    `$ref`/`enum`/`format`/`additionalProperties` are universal, `oneOf` +
    `discriminator` are dominant in the slate but appear in **2 of 177** sampled
    3.x specs, `allOf` is the reverse, and untagged
    `anyOf`/`not`/`patternProperties` are rare enough for a `Json` fallback.
  - **`operationId` coverage was dropped as a ranking criterion** — 100% on all
    seven, so it discriminates nothing. Four of seven declare no
    `securitySchemes` at all, so auth is not derivable from the spec for most of
    the slate, Anthropic included.
  - **`std.json` can ingest these specs** — 1.4 s for 12.9 MB, 2.5 s for 23.3 MB
    on the Tier-0 interpreter, counts matching a Python reference. Arc 3's
    ingestion is not gated on performance; **it is gated on YAML**, since
    Anthropic publishes only `.yml` and Thera has no YAML reader.
- **Typed JSON — `json.Cursor`, and a client to prove it on** (2026-08).
  [api-access.md](api-access.md) Arc 1 item 3, pulled ahead of item 5 because a
  codec convention gets copied into every file a generator emits while a retry
  policy slides in under an unchanged `http.send` at any time. The method was
  the one Arc 2 prescribes: hand-write the client first, against the library
  unchanged, and let it name the gaps. Full record in
  [typed-json.md](typed-json.md).
  - **The gap was not "no derive", it was "no location".** `std.json`'s
    accessors suit a _lenient_ reader — navigation never fails, absent is
    `None`, nothing is an error, which is how the LSP reads requests it must not
    crash on. A client needs the opposite, and needs a failure to name a
    **path**. A bare `Json` cannot: it has no idea where it came from, so the
    path gets threaded alongside it by hand at every level with nothing checking
    the two agree. Stage 1 measured that at **101 lines of generic plumbing to
    support 62 lines of decoders**, and 10 hand-written path literals.
  - **`json.Cursor` is a value paired with its location.** `field`/`index` never
    fail (a missing key gives an absent cursor at the extended path); the
    readers do — `string`/`int`/`double`/`bool`/`object`/`list`/`raw`, each with
    an `opt_` twin. `list()` indexes each element's path, so `$.content[2].text`
    costs the caller nothing. New `json.DecodeError` (`Missing`/`Shape`), kept
    distinct from `JsonError`: a syntax error and a shape mismatch are different
    problems.
  - **An optional field of the wrong kind is still an error.** "May be absent"
    is the schema speaking; "a number where a string belongs" is a bug or a
    breaking change, and reporting it as `None` would turn a loud failure into a
    silently missing value. Separately, `present` tells absent from
    explicitly-null for the rarer API that means different things by them.
  - **The plumbing file went to zero**, decoders 62 → 51 lines, threaded paths
    10 → 0 — and two messages got _more accurate_, not just cheaper: a
    fractional number read as an integer used to say "expected number … got
    number", and a required field that was present but `null` used to say
    "missing required field", which was simply wrong.
  - **Encoding needed two small functions**, not a layer:
    `json.opt(value, encode)` lifts an `Option` (`None` → `Null`), and
    `obj(fields, omit_nulls: true)` drops the nulls — so a request body is one
    line per field with no conditional insert and no `mut` map.
  - **Default arguments beat the alternatives, at one specific cost.** A struct
    literal has no per-field defaults so it would force all nine fields every
    time, and a wither chain reimplements what the language has; the direct call
    names three arguments for a minimal request. But an `Option<T>` parameter
    does not accept a bare `T`, so every optional argument a caller passes is
    `Option.Some(0.5)`. No implicit `Some`-wrap is proposed: the implicit `Ok`
    is a return-position rule, this would be an argument-position coercion, and
    language.md says there are no implicit conversions of any kind. The cost is
    recorded instead.
  - **One front-end bug, fixed rather than worked around.** A
    namespace-qualified function used as a value (`xs.map(json.str)`)
    type-checked and then failed to compile — codegen's namespace branch knew
    `ns.CONST` and `ns.global` but not `ns.fn`, so it fell through to struct
    field access and reported "field access on non-struct value" on a
    check-clean program. One branch in `codegen.thera` emitting `ClosureNew`,
    the qualified counterpart of `load_function_value`; ordinary and `native`
    fns both resolve. Pinned by
    `tests/lang/functions/qualified_fn_reference.thera`. Same shape as the TLS
    arc's dividend: composing two documented features across a library boundary,
    and finding the combination had never been exercised.
  - **`pkgs/` is now where non-`std` libraries are authored** — `pkgs/anthropic`
    is the first, `bin/test.sh` gained a `packages` group that picks up any
    `pkgs/*` other than the front-end, and its `check`/`fmt` corpus widened from
    `pkgs/cli` to `pkgs`. Where third-party packages ultimately live is still
    [scale.md](scale.md) item 4's question.
- **`std.http` regains a reachable server** (2026-08). `import std.http.server`
  was a check error — `server.thera` was a plain file inside the `std/http`
  directory library, so from outside it the only importable surface was the
  barrel, and the server was reachable solely from its sibling tests. Documented
  in [stdlib.md](stdlib.md) in five places, used by nothing, unnoticed for that
  reason.
  - **The fix was not the obvious one.** Moving the file into `std/http/server/`
    makes it a separate library, and a separate library cannot import a private
    sibling of another — `import '../wire'` is the same error one level down. So
    the codec they share became its own library too: `wire.thera` →
    `std/http/common/common.thera`, re-exported by the barrel and imported
    directly by the server. The alternatives were worse: having the server
    import the `std.http` barrel would drag in the client and its TLS dial,
    which is the coupling the split exists to prevent, and re-exporting the
    server through the barrel would do the same while changing every documented
    spelling.
  - **The cost is one redundant name.** `import std.http.common` resolves, and
    nobody needs it: the barrel re-exports all of it, so the types stay
    `http.Request` / `http.Response` / `http.HttpError`. A second spelling for
    the same declarations, not a second concept — and `http.get(url)` is
    untouched.
  - **The rename is not cosmetic.** `wire` was a good private name for a codec;
    as a name a reader can encounter it says nothing, and `common` says what the
    library is for.
  - **A sweep found no others**, and it is repeatable — `dev/import_surface.py`.
    Every directory under `sdk/std` is fronted by its own barrel, there are no
    loose files, and every other `import std.…` spelling in the tree resolves.
    `pkgs/cli` has two non-re-exported siblings, both imported by their barrel
    with a plain `import` — the intended internal shape.
  - **And something outside the SDK now imports the server:**
    `examples/http_server.thera`, whose output `bin/test.sh` pins. The absence
    of exactly that is why the gap survived.
  - **Namespace derivation was reconsidered and left alone.** A nested library
    binds its _trailing_ segment, so `std.http.server` is `server.serve(…)` —
    context-free at the call site. Concatenating segments (`http_server`) was
    considered and rejected: `../ast` and `../ast/ast` are both in use for the
    same library and language.md promises they are interchangeable, so joining
    written segments would bind two different names for one library; and
    `bytecode/` and `lsp/` have no barrels, so it would rename dozens of
    front-end call sites. The import list at the top of a file is the context,
    each library's `//! Import as:` header is the canonical spelling, and `as`
    handles a genuine clash. Revisit when a package ecosystem makes cross-vendor
    collisions real ([scale.md](scale.md) item 4).

- **Streaming response bodies and SSE** (2026-08) — a `text/event-stream` now
  reaches a caller event by event over `http` or `https`. The item
  [api-access.md](api-access.md) called the gate on every GenAI client, and the
  work went in three stages: the codec, the framing library, the client surface.
  - **The codec streams.** `framing_of` derives a `Framing` from the headers
    once, and a `BodyReader` walks it a read at a time (`io.Reader`, plus
    `read_some` as the honest primitive that keeps the `Protocol`-vs-`Body`
    distinction the interface's `Error` would lose). `Wire.stream_response`
    returns the head with the body still on the wire, and `read_response` is
    **defined as** that plus a capped drain — which is what keeps the two paths
    from drifting. `MAX_BODY_BYTES` moved with the drain, since it is a property
    of assembling a body rather than reading one, so streaming is deliberately
    uncapped; an oversized frame is still refused before it is read, because the
    drain consults the reader's declared remainder each time round.
  - **`std.http.sse`** decodes the framing over any `io.Reader`. Three places
    the obvious implementation is wrong, each pinned by a test: `retry` is state
    on the `Decoder` rather than a field of `Event`, because a `retry:`-only
    record dispatches no event and the value would have nowhere to go; `id`
    carries forward across events (the spec's buffer is not cleared between
    records) while the event _name_ does not; and an `id` containing NUL is
    dropped, a header-injection guard for any caller that later implements
    resumption. Framing only — `[DONE]` is an OpenAI convention and
    `event: message_stop` an Anthropic one, so neither appears in it.
  - **The client's entry point owns the connection.** `http.stream` returns an
    `http.Stream` the caller must close; `http.with_stream(request, handle: …)`
    closes on every path out, including an early `?` inside the callback, and is
    the blessed spelling — Thera has no destructors, so nothing else will.
    Ownership transfers on success and only on success: the failure path closes
    the connection itself, since nothing owns it yet. `send` is now `stream`
    plus the drain plus the close, which deleted `exchange` outright.
  - **The incrementality test is a handshake, not a timing measurement.** The
    server writes the first event, waits to be told it arrived before writing
    the second, and reports back whether the go-ahead came; the wait is bounded
    by `fiber.select` against a timer, so a client that read the body whole
    **fails the assertion** instead of deadlocking the suite. Mutation-checked.
  - **Found on the way:** `import std.http.server` does not resolve — see the
    _Networking punchlist_. And a placement correction worth keeping: SSE landed
    as `std.http.sse` (its own nested directory library) rather than the
    top-level `std.sse` the plan first settled on, because a format depending
    only on `std.io` is not a reason for the top-level namespace to grow a name
    per format that rides on an HTTP body.

- **Qualified generic bounds and super-interfaces** (2026-08). A generic bound
  could only name a bare type — `fn f<S: io.Reader>` was a syntax error at the
  `.`, so no generic could be bounded by an interface from another library
  (found wiring TLS into `std.http`; the client passed its stream twice, once
  per role). Interface `extends` had the identical hole. Both positions now
  accept a qualified `ns.Name`, resolving through the namespace exactly like an
  `impl ns.I for T` — the third sibling position, which always accepted one. The
  mechanical core: the AST's two parallel string/span bound lists became one
  `List<BoundRef>` (`{namespace, name, span}`), and `element.bound_id` resolves
  it via the already-namespace-aware `resolve_type_owner`; everything downstream
  (element model, inference, bound enforcement, dispatch) operates on resolved
  `TypeId`s and needed no change. Also along the way: per-super error spans
  (previously the whole-interface name span), self-extension detected by
  resolved identity rather than spelling, qualified bounds/supers counted by the
  unused-import walker, and LSP member resolution on parameters bounded by
  qualified interfaces. Bootstrap snapshot refreshed (new syntax — the
  self-hosting ratchet). **Consumed:** the http client is now one
  `fn exchange<S: io.Reader + io.Writer + io.Closer>` instead of a function
  taking its stream twice, once per role — and folding the close into that bound
  shrank `send` to a scheme branch over two connect calls.

- **The hermetic TLS loop** (2026-08) — [http-tls.md](http-tls.md) stage 5,
  completing the TLS arc. The runtime gained `TlsSession::server`,
  `server_config(cert_pem, key_pem)`, and the **`tls_accept`** native — the
  server mirror of `tls_connect`, wrapping an accepted socket in place. rustls's
  `Connection` covers both roles, so the pump, the park/retry discipline, and
  every other `tls_*` native were reused unchanged; the server session is new
  code only at the config boundary.
  - **A real client↔server handshake in one process**, over loopback, in
    `net_test.thera`: two fibers, a plaintext round trip, a clean
    `close_notify`. Plus the hermetic form of the security assertion — the same
    server refused by a client on the production root store, which is what pins
    verification being on without reaching for the network.
  - **The certificate is checked in, not minted.** `rcgen` is a dev-dependency,
    so it is available to the Rust tests but absent from `thera-rt`; minting
    from Thera would mean shipping a cert-generation native to serve tests
    alone. `net_test.thera` embeds a throwaway CA, a `localhost` leaf, and its
    key, with regeneration commands in the doc comments. The trade is an expiry
    (2052-08-06) instead of a runtime dependency.
  - **The trust seam deliberately stops at `std.net`.** It is file-private, so
    only `net_test.thera` can build a TLS stream trusting a test certificate —
    an `https` round trip in `client_test.thera` would mean making trust
    injection or server-TLS termination _public API_. Declined: that is a
    permanent widening of a security boundary for a small amount of coverage.
    `std.http` instead gets a hermetic test that points an `https` URL at the
    **plaintext** loopback server, which pins scheme routing and the
    `HttpError.Tls` mapping together — a plaintext peer cannot complete a
    handshake, so any other outcome means the scheme was ignored.

- **`std.http` speaks `https`** (2026-08) — [http-tls.md](http-tls.md) stage 4,
  the last thing between `std.http` and complete. `send` branches on the scheme
  to `net.connect_tls` (resolve → connect → wrap → verify), so a request to an
  `https` URL is chain- and host-verified against the bundled Mozilla roots.
  - **`HttpError.Tls(String)`, not a `Connect`.** A rejected certificate is not
    a network failure and **retrying will not fix it**, so it gets its own
    variant — the same reasoning that gave `NetError` its `Tls`, and the
    distinction any retry policy has to be able to make. Only that cause
    survives the `NetError` → `HttpError` mapping as itself; everything else is
    the `Connect` it already was.
  - **Verified against live failure modes**, not just the happy path: an unknown
    issuer, an expired certificate, and a host-name mismatch each come back as
    `Tls` with the specific reason in the message.
  - **ALPN stays unoffered** — settled rather than deferred: `net.connect_tls`
    is a general TLS dial, so an HTTP protocol list can't be a constant there,
    and a server offered no ALPN defaults to HTTP/1.1 anyway. If it ever matters
    it becomes a per-connection parameter.
  - **Test coverage is honestly partial.** The hermetic loop needs a TLS
    listener and a test-time certificate (stage 5), so the `https` path is
    covered today by two live smokes gated on `THERA_NET_TESTS` — one success,
    one untrusted certificate refused as `Tls`. The plaintext loopback suite is
    unchanged and still hermetic.
  - **Noted in passing:** `exchange` takes its stream twice, once per role,
    because a generic bound parses only a bare name — so no bound can name
    `io.Reader`. _(Since fixed — see **Qualified generic bounds and
    super-interfaces** above; `exchange` is now generic over one stream.)_

- **A default parameter value resolves where it is written** (2026-07). A call
  that omitted an argument materialized the default expression where the _call_
  was, and resolved its names there — so a default naming anything the caller
  could not see (a declaring-file `const`, a member of an import only that file
  has) failed to compile, while `thera check` accepted the same program. Codegen
  now compiles a default in the **declaring file's** top-level context
  (`emit_default_arg`, the same `enter_file_context` seam an inlined `const`
  initializer already used), tagging each resolved argument with where it came
  from (`ArgSite.Caller` / `Default`).
  - **`#loc` still stamps the call site.** A default needs two contexts at once:
    the declaration's for names, the call's for `#loc` — which is what gives
    `std.testing` assertions the failing test's location. Hoisting the default
    into a thunk compiled in its own file would have fixed the first half and
    silently broken the second, so the default is still expanded per call site,
    with the call's span carried alongside as the `loc_span` that `#loc` reads —
    one `Option<SourceSpan>` field, since a span already carries its file. It
    now reaches a _nested_ `#loc` (`at: Int = tag(#loc)`), which the old
    top-level-only span swap missed.
  - **Check/emit divergence closed.** Defaults are now checked at the
    declaration — once, in the file that wrote them, including on signature-only
    declarations (`native fn`, interface methods) — against the parameter's
    type, so both an unresolvable default and a mismatched one
    (`text: String = 7`) are `check` errors instead of an emit failure or no
    error at all. Zero corpus hits.
  - Specs: `fn-default-params` — `default_arg_scope.thera` and
    `default_arg_loc.thera` (both were `xfail`, now passing) plus a new
    `default_arg_reject.thera` for the check-time diagnostics.

- **Formatter width settled at 100** (2026-07). The empirical study ran (see
  _Developer tooling_ for the table); it found **no knee between 88 and 110**,
  so 100 stays on the non-empirical grounds — the corpus is already there, it is
  what the authoring guideline says, and it is where the statically-typed
  cluster (rustfmt, google-java-format, swift-format, ktfmt) sits. 80 is the one
  width the data rules out. Two findings did come out of it: **prose wants its
  own narrower width** (~80, which is where the corpus's comments already sit)
  when doc-comment reflow lands, and a **scalar list packed into rows was
  misclassified** — `is_scalar_list` was asked about the break points still
  untaken, which skip every row boundary, so an already-filled list read as non-
  scalar and exploded to one element per line. Unreachable at width 100, where
  the corpus is a fixpoint; it cost a byte fixture 1,358 lines at every other
  margin and faked a cliff in the first run of the study. A packed list is now
  left as packed — re-packing means _deleting_ row breaks, which a pass that
  only inserts cannot do.

- **`thera fmt` owns line breaks** (2026-07). The reflowing pass below is now
  what `thera fmt` does — the `--reflow` flag is gone, the LSP's
  `textDocument/formatting` returns the same layout, and the corpus was swept in
  one commit alongside `bin/test.sh`'s `fmt --check` gate. Layout is a function
  of the token stream: the same code comes out the same however it was typed.
  - **Stage A and Stage B were not retired**, as the plan assumed they would be.
    They were written against a full `Doc`-renderer design that was declined;
    the pass that shipped computes break _offsets_ and re-runs the existing
    layout passes after each round, so they are the engine, not dead weight.
    What the split needed was honest names — `format_lines` for the line-layout
    half, `format_source` for the whole formatter.
  - **`format_source` takes no width.** The formatter is not configurable by
    design, and a `width` parameter on the public entry point said otherwise;
    `format_source_at` carries the margin for tests and the width study. Forced
    by a front-end bug found here — a defaulted
    `width: Int = reflow.DEFAULT_WIDTH` could not be called from the LSP, since
    a default was resolved in the _caller's_ scope (fixed since; see the entry
    above). Dropping the parameter was the better API regardless.
  - Sweep: **103 files, +5156/−2106**. Over-width lines **545 → 139**, of which
    all but a handful are single long string literals and multi-line help text —
    nothing a break can shorten.

- **Reflowing formatter — the pass** (2026-07). `thera fmt` was line-preserving
  by design; this is the work that taught it to break and join lines, developed
  behind a `--reflow` flag until the corpus migration above.
  - **A token backbone, not an AST pretty-printer.** A bracket pair is a group;
    its break points are after the opener, after each top-level separator, and
    before the closer, taken **all-or-nothing** (packing would make one added
    element rewrap its neighbours, which is the churn this exists to remove).
    For an over-width line the **outermost** group with a break left to give is
    split, widest first. The AST is consulted for exactly one thing — whether a
    `{` opens a struct literal, which tokens cannot tell (`impl Foo {` and
    `Point {` read alike) — and only to classify an offset, never to render. So
    the parser's `if let` / `let … else` / `else if` desugaring never has to be
    reversed, and a break can never land inside a string literal or between the
    adjacent `>` `>` of a shift operator.
  - **Joining** removes author line breaks inside a group that fits, so layout
    follows the token stream rather than how the code was typed. `{` never joins
    — a statement block, `match` body, or declaration body stays expanded
    however short — unless it opens a struct literal. A group holding a line
    comment (joining would comment out the code after it) or a multi-line string
    is held back.
  - **`Fill`** packs a scalar `[…]` literal to the margin rather than one
    element per line; without it the byte fixtures in `codegen_test.thera`
    expanded to ~90 lines each.
  - **Trailing commas are added on split and removed on join** — the one place
    the formatter edits tokens rather than whitespace. The grammar makes the
    comma optional in every comma list, so the guard drops inert trailing commas
    from both streams and still compares exactly; only a group with an existing
    top-level comma qualifies, since `(a + b,)` is a parse error. This replaced
    an _accidental_ magic trailing comma — under the original whitespace-only
    rule a trailing comma silently pinned a group open, because the formatter
    could not delete it.
  - **Guarded, and no longer silently.** Unless the result is the same code and
    still parses, the plain format is returned. That fallback is
    indistinguishable from "nothing to do" and hid two real bugs during
    development (a double comma, and generic-argument commas counted as a
    block's own), so `thera fmt` now reports each skipped file.
  - **A split has to pay for itself** — the second pass, and what makes a call
    hug a multi-line argument. Outermost-first was handing each over-width line
    to the widest group covering it, which for a builder chain is the whole
    chain, whose only break there is the one before its closer: splitting sheds
    a `)` and nothing else, while the line stays over-width and gains an indent
    level. So a group is now a candidate only if the head it would leave — the
    line up to its first break on that line — is itself within the margin, which
    picks the `.flag(…)` that can genuinely break over the `.subcommand(…)` that
    cannot. A line no break can shorten is skipped outright: every line a
    multi-line string touches is emitted verbatim, so a `.details('…')` argument
    used to pry apart the chain around it a group per round without ever
    shortening the line it was chasing. Corpus effect: **+2790/−1089 →
    +2335/−927**, lone-closer lines **385 → 278**, over-width unchanged at 137.
  - **A closer line aligns with its own opener**, not the outermost one it
    closes (`fmt.thera`'s `scan_lines`). Pre-existing and reachable without
    `--reflow`, but hugging makes staggered closers common:
    `a.foo(b.new('x')⏎ .bar(⏎ …⏎ ));` had its `));` dedented past the `.bar(` it
    closes.
  - **A comma inside `Map<String, …>` is no longer a break point.** `<`/`>` are
    ordinary operator tokens, so the comma read as a separator of the enclosing
    block — enough to produce `let names: Map<String,⏎List<NameSite>> = [:];`.
    It was already excluded from making a group a comma list; now it is excluded
    from the break list too.
  - **All-or-nothing is an invariant, not just how a split is taken.** A comma
    list broken at _some_ of its break points is now broken at all of them,
    independently of width. Without that, a hand-wrapped
    `add_error(errors,⏎ '…',⏎ span);` whose message is too long to ever fit kept
    that shape forever while the same call with a shorter message came out one
    argument per line — layout deciding itself on how long an argument happens
    to be, which is the author-dependent layout the pass exists to remove. The
    condition is "some of its **own** breaks taken", not "spans several lines":
    a group is also multi-line when an _element_ is, and that is exactly the
    hugging shape, which has to survive. Exempt: a group holding a line comment
    (a break before it would swallow the code after) and a scalar `[…]` (packed
    to the margin by design).
    - Cost, and the reason it landed on its own: the sweep goes from +2335/−927
      across 89 files to **+5156/−2106 across 103**. Reading the extra churn, it
      is almost entirely hand-wrapped parameter lists
      (`fn check(_ program: Program, _ imports: …,⏎ …)` → one per line), which
      is what the formatter already produces when the margin triggers the split
      — so the sweep is what makes the corpus agree with the pass's own rule.
      Two long string literals end up over the margin that were not before,
      having gained an indent level from the call around them.
  - **A join deletes every trailing comma it collapses**, not just the one last
    in the joined span. A span is the _outermost_ group that fits ([join_spans]
    drops the ones it contains), so its own closer is only the last of several,
    and a nested group's comma is just as much a trailing comma once the join
    puts it on one line: `push(Comment {⏎ …,⏎ span: span,⏎ });` came out as
    `…, span: span, });`. The rule is now "a comma directly before any closer".
    Reachable today but not triggered by the corpus at width 100 — the sweep is
    byte-identical either way; it blocks the all-or-nothing item under
    _Developer tooling_, which creates the trailing commas that hit it.
  - **Verified** by reflowing the whole corpus: `bin/test.sh` green and
    `bin/build_sdk.sh` still byte-for-byte — the front-end compiled from
    reflowed sources compiles itself to the same bytes.
  - _Declined:_ a **token-tree** reflow with no AST at all (saves ~200 lines but
    can only be canonical per bracket structure, not per token stream), and a
    full `Doc`/event renderer (the break-offset form reuses the existing
    indentation pass instead, which is most of why the implementation came in
    small).
  - _Declined_ for hugging specifically: **preferring the inner group of the
    last element**, the shape the plan originally called for. Measured on the
    sweep, it would improve the 10 sites where that inner group is itself split
    (saving two lines and an indent level each) and worsen the 60 where it fits
    on one line, since hugging explodes its arguments one per line. It also
    contradicts outermost-first, which is pinned as deliberate. The head-fits
    rule above gets the builder chains without the trade.

- **Unknown namespace in type position is its own error** (2026-07). A type
  annotation or construction qualified with a namespace the file doesn't import
  (`bogus.Thing`) used to resolve its bare segment to a _different_ nominal
  identity and surface downstream as `expected Thing, found Thing`. Now
  `check_named_type` rejects the unbound qualifier at the annotation
  (`unknown namespace: bogus`, with a qualify-as hint when an import exposes the
  type), and `resolve_named_in` resolves such a reference as `Unknown`, so the
  root cause is the _only_ diagnostic (no mismatch cascade). Pinned by
  `mod-ns-file-local`'s type-position test. Found during the barrel migration,
  where a leftover `inference.TypeRecord` annotation checked "successfully"
  against the wrong identity.

- **Barrel-enforced boundaries — no deep imports** (2026-07). The second
  scale.md item landed end to end (language.md § Import resolution; conformance
  `mod-import-deep` / `mod-import-barrel-file`): a directory library's
  non-barrel files are importable only from that directory — outsiders import
  the barrel (directory path ≡ barrel-file path), which re-exports whatever
  internals they need. Enforced in the loader (`detect_deep_imports`, beside the
  cycle pass) as an error at the offending import; same-directory sibling rule
  (nesting survey: zero cases); no test-file exemption (white-box is already
  sibling-legal). The migration extended three barrels (lexer → token model,
  element → its four phase files, ast → describe/dump), moved all 33 deep-import
  sites through them, and deduplicated checker's `is_reserved_type_name`
  forwarding shim. Deferred: a normalization lint for the two barrel spellings.

- **Acyclic library imports** (2026-07). Imports between libraries are now
  required to be acyclic — the first scale.md item landed end to end
  (language.md § Import resolution; conformance `mod-import-cycle` /
  `mod-import-cycle-sibling`). The unit is the **library**: a directory
  library's files (barrel + siblings) may cycle freely; every other file is its
  own unit; a test file's imports don't participate (a consumer, not a member).
  Detection lives in the loader (`detect_import_cycles`, a Kosaraju pass over
  `file_imports` contracted to units) and reports an error-level diagnostic on
  **every** participating import, each carrying one full cycle path
  (`import cycle between libraries: a.thera → b/ → a.thera`) — the flagged set
  is exactly the edits that can break the cycle. Landed directly as an error (no
  lint stage): the corpus was already clean after the `SourceSpan` hoist into
  `pkgs/cli/source.thera`, and per-library incremental checking (scale.md
  item 2) will rely on the DAG. Loading still links a cyclic closure
  best-effort, so downstream diagnostics stay real; `thera check`'s printed-line
  dedupe collapses the per-closure repeats.

- **LSP go-to-type-definition** (2026-07). `textDocument/typeDefinition`
  (`pkgs/cli/lsp/type_definition.thera`) — jump from a _value_ to the
  declaration of its _type_ — as a thin renderer over the shared cursor resolver
  and the committed-type record, the first of the agent-facing renderers. The
  ladder: `self` → the enclosing impl/interface's type; a value ident → its
  committed (inferred) type at the cursor's own span, navigated owner-correct by
  `TypeId` (a primitive looks through to its core declaration via
  `member_target`); a local without a use-site record → its binding site's
  record, else the written annotation's named head; a _type_ name → itself (like
  plain definition). Known v1 gaps: a member-access / enum-variant token carries
  no committed record of its own, and a bare `T`-typed value names no nominal
  declaration.

- **Primitive-bound soundness gap closed; dispatch-table index** (2026-07). The
  scoping pass on _Primitive vtables_ (still open under _Language_).
  `impl Doubler for Int` + `apply_bound<T: Doubler>(21)` type-checked and then
  trapped at the `call.virtual`; `satisfies_bound` now limits primitive bounds
  to the four core interfaces the runtime fallback can dispatch — `Eq`/`Debug`
  (intrinsic) and `Display`/`Ord` (declared core impls) — with a diagnostic
  naming the limitation. Static calls of a user impl on a primitive
  (`n.doubled()`) stay fine; only the bound-reachable (virtual) path is
  interdicted. Separately, `dispatch_target`'s flat scan over every impl-method
  row — O(program size) per virtual call, measured at +50% on an iterator loop
  from 150 unrelated impls — is now a per-receiver-type index
  (`Module::set_dispatch`): one fast u32 hash, then the receiver's own handful
  of selectors.

- **LSP completion + signature help** (2026-07). `textDocument/completion`
  (`pkgs/cli/lsp/completion.thera`): `complete_at` — the behavioral oracle the
  recovery stages promised — classifies the cursor over the token stream and
  enumerates from the same owner-correct surfaces hover resolves against: member
  completion after `.` (the receiver's committed type, working mid-edit because
  the session checks recovered trees; namespace and static surfaces; `self`) and
  bare-name completion (locals, the file's decls, its bare surface, its
  namespaces); `.` is the trigger character. Along the way, non-fatal `expect`'s
  synthetic token was re-anchored **just past the previous token** (the hole the
  cursor sits in). `textDocument/signatureHelp` (`lsp/signature_help.thera`):
  the parser frames an unterminated call (a token that closes an enclosing
  construct can't start an argument, so the synthesized `)` completes the call
  node with the arguments already written); `signature_help_at` locates the
  innermost enclosing call, resolves the callee through hover's
  `callee_fn_site`, and reports the active parameter by counting completed
  arguments; `(`/`,` trigger. Known completion gaps: cursors inside comments and
  non-interpolated strings (tokens carry no trivia), and `${…}` interpolation
  contexts.

- **Parser error recovery — Stage 2b (expression blocks + match arms)**
  (2026-07). `parse_expr_block` recovers a broken element in place
  (`sync_to_stmt` at the block's own depth, an `Expr.Error` placeholder — or an
  `Expr.Error` _tail_ when the hole is the block's value, so it types Unknown
  rather than a cascading Void), and the match-arm loop recovers a broken
  pattern/`=>`/body to the next arm via `sync_to_arm`. A broken statement inside
  an arm keeps the enclosing `let`, the match tree, and the sibling arms —
  pinned structurally in `recovery_test.thera` and behaviorally by the
  completion oracle. With Stages 0–3 (entry below) this closes the
  parser-recovery arc.

- **Primitive-receiver member resolution (LSP)** (2026-07). Hover / definition /
  completion / signature help on a primitive receiver (`'s'.split()`) resolve
  through `resolve.member_target`: a `Primitive` committed type looks through to
  its core declaration by name via the file's bare surface — the same bridge
  inference's `type_def_for` has always used to let primitives host methods.
  Front-end only; independent of the _Primitive vtables_ runtime item.

- **`select` + `with_timeout`** (2026-07). `fiber.select(sources) -> Int` over a
  `Selectable` interface — `is_ready` (non-destructive, since it's asked
  speculatively about sources the caller may never act on) + `source` (how to
  wait) — implemented by `Fiber`, `Channel`, `Timer`, and `net.TcpStream`
  (readability probed with mio's `peek`, so the `read` that follows still sees
  the bytes; `TcpListener` is deliberately not selectable — probing it means
  `accept`, which consumes). Not Go's fused `select { case … }` syntax:
  cooperative scheduling means nothing runs between "ready" and "act", so
  ask-then-act is equivalent with no new grammar; lowest ready index wins,
  deterministically. `fiber.with_timeout(work, dur)` and socket timeouts fell
  out of it. The runtime piece is `ParkRequest::Multi` (one fiber listed in
  `blocked` + `timers` + `poll_blocked` at once), held up by two mutation-tested
  safety properties: **idempotent waking** (a `queued` flag behind the one
  `make_ready` choke point) and **sweep-on-schedule** (`unlist`, so a select's
  losing deadline can't fire at whatever the fiber parks on next). The honest
  limit: the timed-out work is **not cancelled** — a fiber can't be killed — so
  it bounds the wait, not the work; releasing the resource is the caller's job
  (for a socket, close it).

- **Per-fd wakeup routing (poller)** (2026-07). Readiness events route by socket
  handle (which already _is_ the `mio::Token`), waking only the fibers parked on
  that socket instead of every socket-parked fiber — spurious retries down ~27%
  on the 20-connection suite, a win that scales with connection count
  (`wake_all_poll` was O(parked) per event, exactly the shape a server holding
  many idle connections hits). The catch: the coarse wake was an accidental
  safety net — a fiber parked on a socket _another fiber closes_ used to be
  rescued by unrelated events, and with routing it would park forever. So
  `socket_close` now wakes its waiters explicitly (`wake_poll_waiters`; pinned
  by `closing_a_socket_wakes_a_fiber_parked_on_it`), making
  close-from-another-fiber the supported cancellation pattern. Left coarser on
  purpose: fibers sharing a handle (a reader and a writer) wake together;
  splitting by direction waits on a profile.

- **Fibers phase 3 — park on real I/O** (2026-07). Two park kinds, both on the
  deliver-on-resume model: a `Timer(deadline)` request for `time.sleep` (other
  fibers run during a sleep), and an `Await{job, finish}` request offloading a
  blocking syscall to a lazily-created 4-thread **worker pool** — the worker
  returns owned Rust data and the `Value` is built back on the Thera thread (the
  heap is thread-local), keeping the runtime single-threaded. Parked: `fs` path
  ops, `stdin`, `File` read/write/seek, and `std.process` `run`/`exec`/`wait` +
  pipe I/O. Handle resources use a **take-out/return** discipline — no lock held
  across the blocking call — so one fiber can feed a child's stdin while another
  drains its stdout. Fast, non-blocking syscalls (`fs.exists`,
  `process.start`/`kill`) stay thread-blocking on purpose.

- **Refactoring machinery — `thera lint`, `lint --fix`, LSP code action**
  (2026-07). The shape-match → located-suggestion → mechanical-fix pipeline, end
  to end. `thera lint` walks the AST (purely syntactic) and reports convertible
  sites; the rules partition, so a `match` fires at most once: empty arm →
  `if let`; error-propagating arm → `?`; diverging arm in a `let` initializer →
  `let … else`; value fallback → `unwrap_or` (a computed fallback becomes
  `unwrap_or_else`); both arms re-wrap → `map`. `--fix` applies via **AST-guided
  source-slice reassembly** (`pkgs/cli/edit/`, `fix/`): kept sub-expressions are
  sliced verbatim from source, only connective scaffolding is generated, and
  each replacement is formatted as a fragment at the site's own indentation
  (`fmt.format_fragment`) so the edit is localized; batches of non-overlapping
  edits loop to a fixpoint so nested matches converge. The LSP
  `textDocument/codeAction` offers the same sites as `refactor.rewrite` actions,
  honoring `context.only`. Rewrites are conservative — precision over recall; a
  block-bodied arm is left to a human. Corpus survey: `match → if let` 258 sites
  (the dominant cleanup), `unwrap_or` 49, `while i <` 64, `let … else`/`map`
  modest, `?` **zero** (already idiomatic). Dogfooded across ~45 front-end
  sites, fixpoint byte-identical, suite green. The open tail (the `while → for`
  rewriter, the calling-convention lint) stays in _Developer tooling_.

- **Doc comments — convention, `sdk/std` migration, lexer trivia side-channel**
  (2026-07). The conventions are spec'd
  ([language.md](language.md#documentation)): `///` item docs, `//!`
  file/package docs, plain `//` never extracted, a summary-first sentence, a
  small Markdown subset. All 61 `sdk/std/` files migrated (behavior-neutral —
  the lexer skips doc comments on the compile path, so it stayed
  fixpoint-clean). And the lexer now surfaces comments, classified, on
  `LexResult.comments` as a source-ordered, parser-invisible side channel (the
  gofmt positioned-comment model; compile path byte-identical). Every consumer
  (doc-to-AST attachment, hover docs, a doc generator, `[Symbol]` resolution) is
  still pending — see _Developer tooling_.

- **Collection/string/bytes staples; `std.term` + `std.http`** (2026-07). The
  staples landed pure-Thera over the existing primitives (except the two
  `trim_*` natives): `List.first`/`last`/`is_empty`/`contains`/`index_of`/
  `reverse`/`sort` (comparator-based), `String.replace`/`repeat`/`reverse`/
  `find`/`pad_start`/`pad_end`/`trim_start`/`trim_end`, `Map.get_or`,
  `Bytes.is_empty`, and `BytesReader` (round-trips `BytesBuilder`). `std.term`
  and `std.http` (client + simple server + wire codec, over the provisional
  `std.net`) landed too.

- **`List.enumerate()` — indexed iteration** (2026-07). A lazy
  `Iterator<Indexed<T>>` right on `List`
  (`for p in xs.enumerate() { … p.index … p.value … }`) — the idiomatic
  replacement for a `while i < xs.len()` index loop, reusing the blessed
  `Indexed<T>` struct (sidestepping the `Pair`/`Tuple` decision). 47 of the
  corpus's 65 index loops migrated with it; now implemented as
  `self.iter().enumerate()` (see the eager-`List` entry).

- **codegen instruction-level unit tests** (2026-07). The trickier lowerings —
  the call-resolution branches (enum ctor / enum `name()` / user static+instance
  / native instance+static / free native / field call / virtual dispatch),
  match-dispatch bisection-vs-linear, and closure mut-capture boxing — are now
  pinned by decoding the emitted `Module` and asserting which opcode each lowers
  to, so a regression is a readable, located failure instead of a
  fixpoint/example break. `module_scope` internals remain end-to-end-covered
  (see _Compiler & front-end_).

- **Test health: shared parse `testkit` + a floor-vs-core drift guard**
  (2026-07). The front-end's hermetic unit harnesses resolve built-ins against
  the `<builtin>` floor (`builtin_type_defs`) rather than real `std.core` — kept
  as the default for speed/isolation/bootstrapping, but shored up. A new
  `pkgs/cli/testkit.thera` gives the `*_test` suites one home for the
  tokenize+parse boilerplate (`parse`/`parse_at`), replacing the
  `program_at`/`prog_of`/`program_of` helpers (defined 4×) and ~30 inline
  `parse_tokens(tokenize(..))` sites across checker/resolver/loader/codegen/lsp
  tests, and retiring their now-unused lexer/parser imports; it is imported only
  by test files, so it stays outside the front-end runtime closure and doesn't
  touch the bootstrap. A new `pkgs/cli/element/floor_test.thera` links the real
  `std.core` closure once and asserts each floor name's generic arity matches
  core's (and that the linked def shadows the floor) — one test pays the
  real-SDK cost so the ~180 hermetic tests don't have to. This is the accurate
  form of the mooted "canonical stub": the inline `enum Result {..}` stubs
  proved to be identity fixtures (bodies deliberately arbitrary), so the real
  drift risk is the floor-vs-core pair, guarded directly. The floor's contract
  is now documented on `builtin_type_defs`.

- **LSP: intentional-error conformance fixtures analyze themselves** (2026-07).
  The `tests/lang/` fixtures are _deliberately_ broken — they pin how the
  compiler rejects bad code — and were hidden from the editor wholesale by a
  `thera.exclude: tests/lang/**` glob, which also dropped the ~130 _clean_
  fixtures from analysis and left the errors that _are_ the point unanalyzed.
  Now the server drops each fixture's **declared** diagnostics per-file
  (`lsp/fixtures.thera`): a diagnostic is withheld only when the source line it
  sits on carries a matching `// expect error:` / `// expect warning:` marker —
  the same match the harness (`tests/lang_runner.thera`) makes, keyed on LSP
  severity rather than a rendered `warning:` prefix — or when the file is
  `//! xfail:` (expected to fail wholesale). A **surprise** error — one on an
  unmarked line, or whose message drifted from its marker — still surfaces, so a
  fixture that breaks unintentionally stays visible. Scoped to `tests/lang/`
  paths (`is_fixture_rel`), so the marker convention can't silence diagnostics
  in an ordinary project; the `tests/lang/**` glob is retired from
  `.vscode/settings.json` (the `runtime/target/**` scan prune stays). Wired in
  at the two report paths — `document_items` and the workspace scan's
  `scan_by_file` — and unit-tested in `lsp/fixtures_test.thera`.

- **Parser error recovery — the resilient-parsing core (Stages 0–3)** (2026-07).
  The parser now produces a structurally useful AST from broken, mid-edit source
  — the groundwork the LSP's completion/hover needs and the anti-cascade the
  compiler wants — without perturbing the happy path (fixpoint-clean; the
  recovery paths are never taken on valid input). Design in
  [frontend.md](frontend.md) §Parser error recovery. What landed: a **non-fatal
  `expect`** that fills a _known hole_ (missing `)`, a field after `.`) with a
  zero-width synthetic token at the cursor and keeps parsing, so the leaf
  survives as a completion anchor; an **`Expr.Error` placeholder** (types as
  `Unknown`) plus the **empty-name convention** for member/type holes, both
  given a lenient, no-diagnostic arm in the resolver/checker/inference (the
  suppression contract) and a defensive codegen trap; **statement-level
  recovery** driven by a running `brace_depth`
  (`parse_stmt_or_recover`/`sync_to_stmt`), so a broken statement's siblings
  survive and a broken body keeps its **signature** (signature-past-body);
  graceful EOF (open constructs recover with synthesized delimiters); and the
  structural AST dump (`ast/dump.thera`) + `parser/recovery_test.thera` as the
  oracle. The remaining tails — Stage 2b expression-block recovery and the
  behavioral `complete_at` oracle — have since landed (see the entries above).

- **LSP: the workspace pull is held open — an idle server does nothing at all**
  (2026-07). The tail of the idle-CPU arc (next entry): even with an unchanged
  pull at ~18ms, the client re-issued it every 2s forever, because
  `vscode-languageclient` re-arms its workspace-pull timer after every
  _settlement_ — the only lever is not settling. The spec plans for exactly
  this: clients implement partial-result progress for the workspace pull "to
  allow servers to keep the request open for a long time", and re-trigger if it
  closes. So a pull carrying a `partialResultToken` now gets its report as
  `$/progress` and **no response** (`Server.open_pull`); the request settles
  only on supersession or cancel (empty final result / `RequestCancelled`) — and
  `shutdown` supersedes an in-flight scan then settles, so the client is never
  owed a response. Idle is now genuinely zero: no timers on either side, the
  dispatch loop parked on stdin.

  Held open, the stream becomes closed files' **only** channel — verified in the
  client source: `workspace/diagnostic/refresh` re-pulls open _documents_ only,
  never the workspace. So workspace-affecting changes (surface edits, closes,
  watcher events, exclude changes) now stream **delta batches**: only files
  whose diagnostics changed (partial results merge per-uri, so omission means
  unchanged — an idle workspace streams nothing), plus **retractions** (an empty
  `full`, no `resultId`) for files that left the scan — deleted, newly excluded,
  or a closed loose file — which nothing else would ever clear. Deltas diff
  against `ws_emitted` (what the workspace channel last delivered), deliberately
  not `diag_reports` (which document pulls also update): the client discards a
  closed buffer's diagnostics, so `close_document` invalidates the file's
  `ws_emitted` entry — not removes it; the entry is what marks a departed file
  as needing retraction — forcing a full re-send. A change racing the initial
  scan is covered by a `delta_pending` flag the worker drains before finishing.
  Clients that send no token (and the in-process tests) keep the
  respond-and-re-pull path unchanged.

  The follow-up (phase 2) made the pulls that _do_ still happen — the initial
  one, and every re-pull for a polling client — skip even the per-file
  byte-compare when nothing changed: `input_generation` counts every input
  mutation (edit, close, watcher event, roots/exclude change — exactly the five
  entry points), the `ScanCache` is stamped with the generation its texts were
  captured under, and a matching stamp reuses in O(1). The compare stays as the
  fallback tier — it catches an edit that _reverted_, and a match there
  re-stamps. Measured on this repo: an unchanged re-pull 43ms → 13ms (the
  remainder is emit + serialize). Pinned by poisoning the cache so the two tiers
  disagree — only the generation tier can serve the marker. The clock also
  closed a latent race: `disk_files` parks across its reads, so a watcher
  eviction landing mid-build was silently overwritten by the finishing build —
  reinstating the stale text until the file's next event; the build now stores
  its cache only if the generation didn't move.

  Phase 3 closed the arc with the settle-code conformance polish: a superseded
  scan now answers with the code the diagnostic-pull spec assigns its cause —
  `RequestCancelled` (-32800) when the client cancelled that very request,
  `ServerCancelled` (-32802) with
  `DiagnosticServerCancellationData { retriggerRequest: false }` when a newer
  pull replaced it or the session is shutting down (the pre-3.17
  `ContentModified` is gone). Distinguishing the causes required tracking the
  scan's request id (`Server.scan_id`), which also fixed a latent sloppiness:
  `$/cancelRequest` used to bump the generation _blindly_, so a cancel for any
  already-completed request killed an innocent scan — cancels now match by id,
  and an unrelated one is ignored per the protocol. Behavior-neutral for
  vscode-languageclient (it re-arms its workspace timer on any settlement and
  only reads `retriggerRequest` on document pulls), so this is truthfulness for
  other clients, not observable behavior for VS Code.

- **LSP: an idle server costs ~nothing (and stops going stale)** (2026-07). An
  idle `thera lsp` sat at 40–80% CPU with the editor untouched. Not a scheduler
  spin: the server measures 0% idle and never wakes itself. The cause is that
  `vscode-languageclient`'s `pullWorkspace` re-arms `setTimeout(…, 2000)`
  unconditionally after every reply — idle or not, forever — so a pull's cost is
  paid continuously. `resultId` caching (already correct here) only saves
  re-_sending_ items, never re-_computing_ them; and our supersession reply
  (`ContentModified`, -32801) is swallowed by the client as a resolved default,
  so neither of the classic runaway-pull traps applied. The client's design
  simply assumes an unchanged pull is cheap. Three fixes, warm pull 2.19s → 60ms
  (~52% CPU → ~3%): (1) `fs.read_dir` — the walk stat-ed every entry to ask
  "file or directory?", which `readdir` already answers (1593ms → 255ms); (2)
  `thera.exclude` prunes subtrees during the walk rather than filtering files
  after it, and this repo excludes `runtime/target/**`; (3) a content-keyed scan
  cache — identical texts in, identical diagnostics out, so an unchanged pull
  skips checking entirely. Along the way this turned up a **pre-existing
  staleness bug**, reproduced on the prior commit: `parsed_primary` keys the
  parse cache by path and evicts only on overlay events, so a file changed on
  disk with no buffer open (a branch switch, a rebase) kept serving its
  first-ever parse for the life of the session. Fixed by registering
  `workspace/didChangeWatchedFiles` (dynamic registration only — there is no
  static capability) and invalidating on each event. With the watcher in place
  the scan itself is cached too (it was re-walking and re-reading every file
  each pull to rediscover what the watcher had already reported), leaving a warm
  pull at **~18ms — ~0.9% of a core**. Every cache invalidation was verified
  load-bearing by removing it and watching a test fail. Measurement note: the
  first probe polled for replies on a 50ms `sleep`, quantizing every timing to
  the next tick — it reported a flat "55ms" that hid both the cost and the
  improvement. Wait on an event, not a poll.
- **Function references** (2026-07). A named `fn` is now usable as a value —
  `apply(double, 21)`, `let f = double`, `return stringify_it` — closing a
  **spec/implementation divergence** rather than adding a feature:
  [language.md](language.md) §Functions already opened "Functions are
  first-class values" and its type table already called `(Int, String) -> Bool`
  "the type of lambdas **and function references**". Only lambdas worked; a bare
  `fn` name in value position failed in codegen with
  `not a local variable: double`.

  Found while building `std.http.server`, where a handler is exactly the case
  for naming a function and handing it over — `serve(addr, my_handler)` is the
  form docs/stdlib.md's own sketch showed, and it did not compile.

  Two halves, and the second mattered more than the symptom suggested:
  - **codegen** — a reference is a closure over the function's own unit with no
    captures, i.e. the same `closure.new` a lambda emits, appended to the
    local→const→global resolution chain (a name is a function reference only if
    it is nothing else, and one name space per scope means it cannot be two).
  - **inference** — `infer_ident` fell through to `Unknown`, which is lenient on
    both sides, so the reference was not merely uncompilable but **untyped**:
    `apply(takes_string, 21)` against `(Int) -> Int` type-checked and only died
    in codegen. A reference now carries its function's signature, so the
    mismatch is a proper argument-anchored error
    (`expected (Int) -> Int, found (String) -> Int`). Generic functions stay
    `Unknown`: `show<T: Display>` is a family, not a type, and choosing a member
    needs an instantiation the position doesn't supply.

  Pinned by `tests/lang/functions/fn_reference.thera` (the xfail written when
  the gap was found, now a passing test) and `fn_reference_reject.thera` (the
  typing). Uncovered next door, still open: only an identifier or a field may be
  a **call target** (`fns[0](10)` doesn't compile) — see _Open work → Language_.

- **Readiness poller + `std.net`** (2026-07). Fibers phase 4, and the socket
  layer under the coming `std.http`. `mio` joins as the 4th runtime dependency —
  the call was never "dep vs. no dep", since hand-rolling `kqueue`/`epoll` needs
  `libc` for the syscalls anyway: the real cost was one extra crate (`log`)
  against two unsafe backends and no windows. Sockets are **non-blocking** and
  so never touch the phase-3 worker pool — a blocking `accept` would pin one of
  its four threads indefinitely, and four would stall every other fiber's I/O.
  `EWOULDBLOCK` parks the fiber (`ParkRequest::Ready`) and the `call.native`
  re-runs on readiness: `BlockRetry`'s discipline, woken by the poller. The
  driver keeps **one** wait point (`poll()`, timer-bounded, with worker
  completions interrupting via a `Waker`), so there is no poller thread and the
  runtime stays single-threaded.

  Two findings made it smaller than budgeted. Sockets need **no readiness
  state** despite mio being edge-triggered — the usual lost-edge hazard can't
  occur when a fiber parks only _after_ its syscall returned `EWOULDBLOCK`,
  since any earlier edge was stale by construction; the syscall is the ground
  truth, which promotes "attempt before parking" to a correctness rule. And
  because the ops never leave the Thera thread, sockets skip phase 3's
  take-out/return discipline entirely, so concurrent read + write on one socket
  from two fibers works (unlike a `File`). The retry does make **idempotency** a
  rule: `write` returns a _count_ rather than writing all (a write-all native
  would re-send on retry), and `connect` splits into `socket_connect` +
  `socket_connect_finish` because re-issuing `connect(2)` on a pending fd
  reports `EALREADY`. DNS stays on the worker pool — blocking, but bounded.

  `std.net` is deliberately **provisional** (docs/stdlib.md § "not in core"): a
  Go-shaped `listen`/`connect`/`accept` with `TcpStream` as an ordinary
  `Reader`+`Writer`+`Closer`, carrying only what `std.http` needs — no UDP,
  deadlines, half-close, socket options, or TLS. Its first client already paid
  off: the accept loop drove the retry-on-wake shape, and exposed that
  **`io.copy` assumed writes never go short** — true of files, false of sockets,
  and a silent byte-dropping bug for any short-writing `Writer` (fixed;
  `io.write_all` added and `copy` routed through it). Open tail: _Open work →
  Networking punchlist_.

- **Diagnostics review — arc complete** (2026-07). The final rung of the staged
  language review (grammar → spec → type system → diagnostics), asking: do the
  diagnostics cover the language surface and prevent invalid code from being
  written? Method: inventory every diagnostic each phase can produce (~80
  parser, ~50 checker, ~25 codegen emit-time), then verify suspected holes with
  41 invalid-program probes; every new diagnostic was corpus-swept against all
  159 production files with a zero-false-positive bar. What landed (each with
  its own entry below): the **checker holes closed** — definite-return analysis
  (+ implicit `Ok(void)`), pattern arity, member uniqueness, interface
  default-method body-checking, and the emit→check promotion (for-iterables,
  index receivers, range position, non-function callees, impl targets); **unused
  `Result` as a hard error** with `let _ =` as the discard idiom (the review's
  one design call, decided by corpus survey); **same-block rebinding and
  self-imports rejected**; the **warning tier** — severity plumbing, exit-0
  policy, kebab-case rule names, `// ignore: <rule>` suppression — with four
  rules (`unused-import` incl. `as _` attribution, `unreachable-code`,
  `unreachable-arm`, `unused-variable`) and the `_`-prefix intentionally-unused
  convention spec'd; and **`thera fix` folded into `thera lint --fix`**. Decided
  along the way: hard errors stay ID-less (message + span — a `CAxxxx` code is
  context noise for LLMs); kebab-case slugs only where selection is meaningful
  (warning rules, lint rules). The sweeps themselves paid for the arc: two
  dropped-`Result` bugs, seven dead imports, and a handful of dead locals found
  and fixed in the corpus. The open tail lives in _Open work → Diagnostics
  punchlist_.

- **`unused-import` covers `as _` imports; `_`-prefix spec'd** (2026-07). The
  arc's final warning extension. An `as _` import is now attributed **by
  surface**: it is used when any name it provides occurs in the file, or when
  its derived namespace is used qualified (which works today — see the open
  wrinkle), and flagged (``unused import: nothing from `x` is referenced``)
  otherwise. No new plumbing: the loader already records every import's public
  surface — barrels flattened — in `file_namespaces` under the derived
  namespace; with no surface recorded (hermetic check, unresolved import) the
  rule stays silent. The use-walker also collects bare type-ish names now
  (`NamedType.name`, struct-literal type names, impl targets and interface
  names, super-interfaces, generic bounds), which the namespace-only attribution
  never needed. The sweep found **five genuinely dead `as _` imports** (removed)
  and one spelling fix (`lsp/workspace.thera` imported `std.path as _` but used
  it qualified — now a plain import). And language.md §Variables now specs the
  `_`-prefix convention: a leading underscore declares a local intentionally
  unused; referencing one contradicts the marker (a future warning candidate,
  tracked above). Spec `warn-unused-import` (new `as _` fixture); language.md
  §Variables, §Errors and warnings.

- **`unused-variable` warning** (2026-07). The fourth warning rule — flagged in
  the review as the false-positive-prone one, so the exemptions carry the
  design. Scope: **statement `let`s only** — parameters and pattern bindings
  (their names are often fixed by a signature or an arity) and module globals
  (cross-file consumers) are out. **`_`-prefixed names are exempt**
  (`let _hint = …`), the Rust/Dart/TS intentional-discard convention LLMs
  already know, alongside `let _ =`. The use-scan reuses the unused-import
  identifier walk — _any_ later occurrence of the name counts, including an
  assignment target and a use that actually resolves to an inner shadow — so the
  rule under-reports but never flags a referenced binding. One reverse pass per
  block keeps it O(n) and scope-correct: uses before a `let` can only refer to
  an outer binding, so an unused inner shadow is still caught. Zero hits on
  production code; the `let x = <expr under test>;` scaffolding idiom in 10
  conformance fixtures and 22 hermetic checker tests was renamed to `_`-prefixed
  form — the exemption's first dogfood. Spec `warn-unused-variable`; language.md
  §Variables, §Errors and warnings.

- **`unreachable-code` + `unreachable-arm` warnings** (2026-07). The second and
  third warning rules, both dead-code signals on the existing exit-analysis
  machinery. **`unreachable-code`**: a statement (or block tail) after one that
  always transfers control — `return`/`throw`, `break`/`continue`, an `if` whose
  branches all exit, a break-less `while true` (reusing `stmt_always_exits`, so
  it inherits its lenient direction) — reported once per block, on the first
  dead statement. **`unreachable-arm`**: a match arm no value can reach — any
  arm after a catch-all (`_` or a binding; full coverage counts the same: all
  variants matched, or both `Bool` literals), a variant already fully matched by
  an earlier arm (bare name, or a constructor whose sub-patterns all bind —
  sub-position identifiers always bind, codegen's rule), or a repeated literal
  (kind-prefixed keys; interpolated strings are never keyed). A _refutable_
  constructor arm (`Some(1)`) claims nothing, so later arms for its variant stay
  reachable — under-reports, never flags a live arm. Source matches only
  (`if let`/`let … else` fabricate their own wildcard arm). Zero corpus hits on
  production code; the two deliberately-broken fixtures the rules also caught
  now carry ignore comments. `stmt_span` moved from the parser to `ast.thera` as
  the third span accessor. Specs `warn-unreachable-code`,
  `warn-unreachable-arm`; language.md §Errors and warnings.

- **Warning-severity diagnostics + `unused-import` + `// ignore:` suppression**
  (2026-07). The diagnostic model's dormant `Severity.Warning` gained its first
  producer and full plumbing. Semantics: an error is invalid code (blocks
  `run`/`emit`/`test`, exits 1); a **warning** is legal-but-probably-a-bug —
  `thera check` and the LSP report it (`path:line:col: warning: … (<rule>)`),
  nothing gates, exit stays 0, and the summary appends `; N warnings`. Every
  gate now filters by severity (`diagnostic.error_count`), so warnings ride the
  same diagnostics list end to end. Warnings carry **kebab-case rule names** and
  are suppressable per site with `// ignore: <rule>` on the line or the line
  above — implemented as a source-reading post-filter (spans carry the file
  text), the comment side-channel's first compile-path consumer in spirit with
  no threading. First rule: **`unused-import`** — a namespace import never
  referenced (any identifier occurrence counts: qualified calls, qualified
  types; exempt: `pub import`, `as _`, and a test file's module-under-test,
  whose surface arrives bare). The corpus sweep found two genuinely dead imports
  (removed) and one design-relevant false positive (the test-file exemption,
  added); seven `tests/lang` fixtures whose imports are the _subject_ now carry
  ignore comments — the suppression mechanism's first dogfood. The conformance
  runner learned `// expect warning:`. Specs `warn-unused-import`; language.md
  §Errors and warnings.

- **Same-block rebinding + self-imports rejected** (2026-07). Two wrinkles from
  the diagnostics review. A second `let x` in the **same block** is now a check
  error
  (`` `x` is already bound in this block; rename it (an inner block may shadow) ``)
  — shadowing remains legal from any nested scope (a block, an arm, a loop
  body), a body `let` may shadow a parameter, and `_` never collides. And a
  direct **self-import** (an import path resolving back to the importing file)
  is rejected at the import decl (`a file cannot import itself`); longer cycles
  through other files stay legal. Zero corpus hits for either. Specs
  `var-same-block-rebind`, `mod-import-self`; language.md §Lexical scope,
  §Import resolution.

- **Unused `Result` is a check error; `let _ =` discard** (2026-07).
  Diagnostics-punchlist item 4, the review's one design call. A `Result` in
  statement position — `might_fail();` — silently dropped its failure (the
  errors-as-values analogue of an unchecked exception vanishing; a bare
  `testing.assert_eq(a, b);` without `?` "passed"). It is now a **hard error**
  (`unused \`Result\`: handle it (\`?\`, \`match\`, \`if let\`) or discard it
  explicitly with \`let _ = …\``), paired with the new discard idiom: `let _ =
  expr;` evaluates and discards — no binding, side effects run, an annotation still checks. Scope is deliberately **`Result`-only**: the corpus survey found dropped `Result`s were 2-for-2 genuine bugs (both in `fiber_test`, now fixed — the pipe-writer fiber asserts its write count) while dropped `Option`s were 8-for-8 idiomatic `pop()`/`remove()`effect-calls, matching Rust's must-use line. Hard-error over warning because agents chase exit codes, and pre-1.0 there is no ecosystem to break. Specs`err-unused-result`, `var-wildcard-let`; language.md §Error handling + §Variables; grammar.md `letStmt`.

- **Check/emit parity + interface default-method bodies** (2026-07).
  Diagnostics-punchlist item 3, closing the punchlist's checker holes. Interface
  **default-method bodies are now body-checked** — previously
  `check_interface_decl` validated signatures only, so a default body could
  reference undefined names, drop paths, or misuse types and still check clean
  (surfacing only at emit or runtime). Methods now route through `check_fn` with
  an interface-typed `self` (only the interface's own surface visible;
  definite-return applies), spec'd in language.md §Default methods. And the
  statically-decidable **emit-only errors moved into `check`**: a `for` iterable
  must be a range/`List`/`Iterator`-conformer (`for x in 5`), only `List`/`Map`
  are indexable (`p[0]` and `p[0] = v` on a struct; `String` keeps its tailored
  hint), a range outside a for-loop head is positional error not a value, a
  bare-name callee must be a function (`let x = 5; x(3);` — previously caught by
  _neither_ phase), and an `impl` block's target type must exist
  (`impl Display for Ghost` previously checked clean and ran). Zero corpus false
  positives; the stdlib's Iterator default methods all check clean under the new
  body pass. Specs `cf-for-iterable`, `expr-range-value`, `expr-index-receiver`,
  `expr-call-non-fn`, `iface-impl-target`, `iface-default-body`.

- **Pattern arity + member uniqueness** (2026-07). Diagnostics-punchlist item 2.
  A constructor pattern now binds exactly its variant's field count —
  `Some(a, b)` (trapped `enum.get: field 1 out of range`), `Two(a)` (silently
  bound a prefix), and a bare payload variant `Some =>` (silently ignored the
  payload) are all located check errors with a
  `match it as \`Some(_)\`` hint — and a pattern binds each name at most once (`Two(a,
  a)`). The member tier gained the one-name-space rule's analogue: duplicate struct fields, enum variants, type parameters, parameters (internal names \_and_ external labels), impl/interface method names, and struct-literal fields are all `duplicate
  …
  \`x\``errors at the second site (previously silently first- or last-wins). Corpus sweep found exactly one genuine hit — a parser test's`Assign(sp,
  _,
  _)`under-binding the 4-field`Stmt.Assign`— and zero false positives. Specs`cf-match-pattern-arity`, `type-member-unique`;
  language.md §One name space per scope (member tier), §Choosing a form (pattern
  arity).

- **Definite-return analysis + `Result<Void, _>` implicit `Ok(void)`**
  (2026-07). The top hole from the diagnostics review: a value-returning
  function with a non-returning path checked clean — falling off the end after
  `if b { return 1; }` trapped as
  `internal error (malformed bytecode): pc ran off the end` (blaming the
  compiler), a body with no `return` **silently** returned `()` into typed
  positions, and `fn step() -> Result<Void, Error>` ending in a bare `inner()?;`
  returned a raw unit that trapped at the _caller's_ match. Now: the checker
  requires every path through a value-returning function to exit
  (`return`/`throw`; a break-less `while true` counts — the scan is
  lenient-direction only), a bare `return;` in such a function is an error, and
  — the semantic half — a `Result<Void, _>` function completing normally is the
  implicit `Ok(void)` (fall-through and bare `return;` both wrap, mirroring
  implicit-`Ok` on `return <value>`), so the ceremony-free propagate-and-succeed
  shape is _correct_ rather than rejected. Codegen's epilogue also handles a
  forward jump landing past the last instruction (the `pc ran off the end`
  shape, which also bit `Void` functions ending in `if b { return; }`). Zero
  corpus false positives. Specs `fn-missing-return`, `err-implicit-ok-void`;
  language.md §Functions → Definite return, §Error handling.

- **Generic-argument variance — invariant containers, covariant read-only
  builtins** (2026-07). Type arguments were covariant everywhere, so a
  `List<Cat>` was accepted where `List<Animal>` was expected and a `Dog` written
  through the widened alias could be read back as a `Cat` (a real, if narrow,
  soundness hole — the poisoned read runs a statically-dispatched `Cat` method
  on a `Dog`). An invariance spike found the fault line exactly: the only corpus
  reliance on covariance was `Result<T, ConcreteError>` → `Result<T, Error>`
  (the error idiom), never a mutable container. So `is_assignable`'s
  same-constructor branch now partitions by variance —
  `Result`/`Option`/`Iterator` (read-only) stay **covariant**,
  `List`/`Map`/`Set` and every user generic are **invariant** — with no
  `out`/`in` annotations. The one thing that relied on container covariance, a
  polymorphic list literal, now types against context
  (`let pets: List<Animal> = [Cat…, Dog…]` checks each element against
  `Animal`). Spec `gen-variance`; language.md § Variance.

- **Divergence typing — `Never` bottom type + tail `throw`** (2026-07). `throw`/
  `return` inferred `Unknown`, so a diverging branch composed only by leaning on
  `Unknown`'s leniency (conflating "this path exits" with "type hole"). They now
  infer a real bottom type `Never` — assignable to every type, from none;
  inference-only, no surface syntax — absorbed by the arm/branch merge so
  `if c { 5 } else { throw }` is `Int`, which also shrinks the `Unknown`
  population. On the back of that, `throw` is now valid in branch-tail (value)
  position (`x = if c { a } else { throw … }`), a one-keyword parser change
  since the type machinery already absorbs it. Specs `type-never-divergence`,
  `err-throw-tail`.

- **Type-checker holes closed** (2026-07). Four check-clean-but-wrong-at-runtime
  holes from the type-system review, each fixed with zero corpus false
  positives: list/map literal tails are checked for homogeneity (`[1, 'two']` is
  now a `check` error — `type-list-homogeneous`); interface conformance compares
  the target's type arguments (`impl Box<Int>` no longer satisfies `Box<String>`
  — `iface-conformance-args`); an unbounded-`T` method call is rejected at
  `check` rather than only at emit, with `display`/`debug` staying universal
  (`gen-param-methods`); and a for-loop's range element types from the
  iterable's _syntax_ instead of an `Unknown => Int` fallback that also fired on
  genuine holes, with `Int` range bounds now enforced (`expr-range-bound`). The
  fifth hole — bare-`TypeParameter`-source assignability — was spiked and
  deferred (a 12:1 false-positive ratio for the naive narrowing; findings kept
  in _Type system punchlist_).

- **Honest tag-mismatch traps — `Trap::TypeError` split** (2026-07). A type hole
  reaching the runtime (a value whose static type the checker got wrong) now
  traps as `runtime type error: expected Int, found String` instead of
  `internal error (malformed bytecode): expected Int, found Ref(0)` — which had
  wrongly blamed the compiler. The interpreter's type-checked pops
  (`pop_int`/`field.get`/`enum.get`/`call.indirect`/`list.*`) raise a new
  `Trap::TypeError`; genuine structural malformations (stack underflow, bad
  slot) keep `Trap::Bug`/"internal error". The `found` type is named via the v3
  type/enum tables (`found Point`, not `Ref(0)`). Native arg-checks are a
  tracked follow-up (Type system punchlist). Faults in language.md.

- **Named structural `Debug` — field + variant names (bytecode v3)** (2026-07).
  The auto-derived `Debug` now renders structs by field name
  (`Point { x: 1, y: 2 }`) and user enums by variant name (`Circle(3)`,
  `Square`) instead of the old positional `Point { 1, 2 }` / `variant1`.
  Bytecode v3 threads the names into the runtime type table
  (`TypeDef.field_names`) and a new Enums section (`EnumDef`: ty + name +
  variant names); the loader still accepts v2 (names absent ⇒ positional).
  `Ordering` now names its variants too; the runtime keeps a built-in
  `Ok`/`Some` fallback for `Result`/`Option`. This is the enabling primitive for
  runtime reflection/introspection. Format in bytecode.md.

- **`thera test`/`check`/`lint` UX for LLM output** (2026-07). The analyzers
  stop emitting lines just for doing work: quiet-by-default reports (failure
  blocks only), a one-line proof-of-work summary
  (`Ran N tests for M test files; K failures.` /
  `Checked N source files; M issues found.`), `--verbose` for the classic
  per-test report, and no-argument invocations defaulting to the current
  directory. The test runner now captures the child's output and reads the
  per-test failure count from a stdout trailer (the exit code stays pass/fail
  only). Spec in language.md §The `thera` tool / §`thera test`.

- **`Iterator.collect()` renamed `to_list()`** (2026-07). The drain consumer now
  follows the `to_X` conversion convention (`Set.to_list()`, `Bytes.to_list()`,
  `to_int`/`to_double`) instead of borrowing Rust's `collect` without its
  type-directed semantics. Interface default method + all call sites renamed;
  language.md §Pipelines and stdlib.md updated, with the rationale recorded in
  the spec.

- **Eager `List` transforms + a `List.iter()` bridge** (2026-07). Settled that
  `List.map`/`filter` stay **eager** (returning a `List` — the result still
  indexes, has `len`, re-iterates, and chains), matching the dominant array
  convention (JS/Ruby/Swift/Kotlin) and avoiding a one-shot-consumption footgun;
  the lazy, fused, short-circuiting path is reached explicitly via `xs.iter()`,
  whose doc is the discoverable "when/why" home. `List.iter()` is the single
  list→`Iterator` bridge — `List.enumerate` composes as
  `self.iter().enumerate()` (the bespoke `ListEnumerateIter` is gone) and
  `iter.from_list` is a thin alias.

- **OOM + stack-overflow traps; string-indexing hint** (2026-07). Memory and
  frame-stack exhaustion are real traps now, not process aborts: the heap has a
  live-bytes ceiling (`THERA_MAX_HEAP_MB`, default 1 GiB) enforced at the
  safepoint right after a collection (`Trap::OutOfMemory` — only genuinely-live
  bytes count), an allocation past the ceiling arms a collection even below the
  adaptive threshold, and a call past the 1M-frame depth backstop raises
  `Trap::StackOverflow` (the 250k-deep recursion test still passes — the
  explicit frame stack is the point). Both messages follow the trap table in
  language.md §Runtime faults. Also: the string-indexing hint now suggests
  `.chars()` / `.slice(start, end)` instead of the retired `.graphemes()`.

- **Type-system review + spec sections** (2026-07). A design-completeness pass
  over the implemented type system (the five-shape lattice, assignability,
  generics/bounds, local bidirectional inference). Verified solid: branch/arm
  join checking, cross-type `==` rejection, function-type variance, bound
  enforcement, annotated-binding mismatches. Four holes found empirically (all
  check-clean today, trap or misbehave at runtime): unchecked list/map literal
  tails, conformance assignability ignoring the target's interface args,
  `TypeParameter`-source leniency, and covariant generic args under mutation.
  Decided against a formal (lambda-calculus) treatment — prose spec +
  conformance tests instead; language.md gained "The type system at a glance",
  **Generics**, and **Assignability** sections. The fixes have since landed (see
  the type-system entries above); the remaining design calls — the deferred
  bare-`TypeParameter` narrowing and the native-arg trap wording — stay open in
  _Type system punchlist_.

- **Language-spec self-consistency review + doc sweep** (2026-07). language.md
  and the supporting docs were cross-checked against the implementation — stdlib
  surfaces, the CLI, the runtime — with every suspect behavioral claim verified
  empirically before reporting. The confirmed-stale sections were rewritten
  (Pipelines, interpolation/`Debug`, `std.process`, `thera test` + command
  tables, Concurrency/fibers, `Map`/`Set` ordering, Style/formatter, SDK layout,
  runtime-fault conditions, `.graphemes()`, `let mut` field spelling; plus
  architecture.md's fiber banner, conformance.md's stale white-box finding, and
  overview.md's JIT tense/`call.virtual`). Verified accurate with no change
  needed: the trap-message table, the reserved-name list, the `Option`/`Result`
  combinator sets, the `std.testing` assertion table, `Args`, `Bytes`, and the
  entry-point forms. The design follow-ups it spawned (iterator consumer naming,
  lazy `List` transforms, `thera test` UX, `Trap::OutOfMemory`) have all since
  landed — see the entries above.

- **Front-end O(n²) source-slicing removed** (2026-07). `String.slice` /
  `SourceSpan.text()` rematerialized the whole string via `chars()` on every
  call, so slicing per token was quadratic in file size. Fixed in two layers:
  the hot call sites (lexer `scan_ident`, and the formatter's `space_intra_line`
  / `same_tokens` / `scan_lines` / `apply_edits`) now materialize the source's
  code points once and index that list; and `String.slice` itself is now a
  native (`str_slice`) that walks to the range's end in one O(end) pass instead
  of building a whole-string code-point list. `thera fmt` on a 110 KB file
  dropped from ~4 s to ~0.2 s (~20×) and now scales linearly. Residual: `slice`
  still walks from the front (a byte offset can't be found in O(1) over UTF-8),
  so slicing at ever-increasing offsets over one large string stays superlinear
  in aggregate — hot per-token loops should keep materializing `chars` once.
- **Map-literal migration follow-ups (checker diagnostic, rendering, legacy
  sites)** (2026-07). Three tails of the migration closed. (1) **`Void`-arm
  diagnostic**: `check_void_arms` splits the `unify_arm` value-less-arm
  exemption — a _diverging_ arm (`return`/`throw`, or a block/`if`/`match` all
  of whose paths exit, per the new syntactic `expr_always_exits` view; a
  tail-less block infers `Unit` whether or not it exits) stays exempt, but a
  plain `Void` arm (`=> void` / `=> {}`) in a value-producing match is now a
  check error — it flows its unit value out and previously trapped only at the
  use site (`map.len: expected map`). Source-origin matches only (a statement
  `if let` fabricates a Unit wildcard arm by design), and a bare unbound
  `TypeParameter` reference stays lenient like `Unknown` (a match as a lambda
  body passed to a generic `fiber.spawn(() -> T)` can still bind `T = Unit`).
  Conformance: `cf-match-void-arm`. (2) **Map/Set `Display`** now follows the
  source syntax: `['x': 1]` / `[:]` (round-trips as code); `Set` renders
  `(1, 2, 3)`. (3) **Legacy `match` sites converted to `if let`** — the 28
  pre-`if let` two-arm matches, via `thera fix --only match-to-if-let --write` +
  one hand rewrite. Doing so surfaced and fixed a **position bug in the fix
  machinery**: the `if let` rewrite (an else-less `if`) was offered from _any_
  expression position but only parses as a statement or a block tail — rewriting
  a match arm body produced unparseable code. `fs_if_let` now gates it to those
  positions (also covering the LSP code action, which drives the same
  `fix_sites`); the value-preserving rules (`?`/`unwrap_or`/`map`) still apply
  anywhere.
- **Bracket map literals — `[k: v]` / `[:]`; braces are always blocks
  (language)** (2026-07). The map-literal migration completed: map literals are
  written `['a': 1]` (empty `[:]`), and a `{` in expression position is always a
  block (`{}` = empty block, value `Void`). **Decision** (2026-07-10
  grammar-review research): the brace-map form carried three pinches — any `{`
  in a match arm was a block (so `pat => {}` silently made a `Void` arm and a
  non-empty map arm couldn't be written), a map whose first key wasn't a literal
  was unwritable, and the commit heuristic itself was a rule with no
  training-corpus analogue. Bracket maps kill all three, state as one rule
  ("collections are brackets; braces are blocks" — struct instantiation keeps
  braces, disambiguated by the type name), and made the parser simpler: after
  `[`, one expression is parsed and a following `:` commits to a map — no
  heuristic, keys are unrestricted expressions. Rejected: smart-brace probing,
  empty-token-only, type-directed arm parse. **Migration**: corpus swept by a
  one-shot AST-driven rewriter (edit only the MapLit delimiter characters,
  verify by reparse) — ~330 sites, with `bootstrap/frontend.thera-bc` coming out
  byte-identical (no spans in `.thera-bc`), proving zero bytecode change; docs
  examples flipped. **Removal**: the brace form is now a targeted parse error —
  the old commit heuristic survives as the shape detector
  (`at_legacy_brace_map`), and a non-literal key is caught at the `:` after an
  expression statement; both hint "map literals are written `[k: v]`".
  Conformance: `type-map-bracket`, `type-map-brace-reject`; AST `describe`
  renders maps in bracket form. Follow-up: Map/Set runtime rendering still uses
  brace notation (see Open work).
- **`=> void` for no-result arms (idiom + lint + sweep)** (2026-07). Step 1 of
  the map-literal migration (the decided bracket-maps item above): a no-result
  match arm is written `=> void` — the explicit unit value — not `=> {}` (an
  empty block, semantically identical but ambiguous-looking, and one keystroke
  from an empty map). The corpus's ~230 `=> {}` sites were swept to `=> void`
  (string fixtures that deliberately pin the `{}` shape kept); a new per-arm
  lint rule `void-arm` flags the old spelling (source matches only; defers to
  `match-to-if-let`, whose rewrite removes the arm); language.md's _Choosing a
  form_ documents the idiom. Corpus-wide `void-arm` tally after the sweep: 0.
  (The ~28 remaining `match-to-if-let` sites — small matches predating `if let`
  / the Option combinators — are an independent follow-up.)
- **Grammar-review syntax tightenings (parser)** (2026-07). Three items from the
  2026-07 grammar review landed. (1) **Nested generics in call-position type
  args**: `looks_like_type_arg_list` is now a balanced `<`/`>` scan (over
  identifiers / `.` / `,`) keeping the same `(`/`.` follow-token commit rule, so
  `f<Result<T, E>>(…)` and `Map<String, List<Int>>.new()` parse. Function types
  in call-position type args stay unrecognized — admitting `(` would swallow
  parenthesized comparisons; annotated positions handle them fine. (2) **`,`
  required after expression-bodied `match` arms** (optional after a `{…}` arm
  and before the closing `}`) — the Rust rule, pre-empting the ambiguity
  or-/parenthesized patterns would create; the error marks the arm's end, where
  the comma belongs. Corpus impact was zero. (3) **Zero-variant enums rejected**
  (`enum Never {}` parsed and checked clean; uninhabited, and there is no
  never-type story). Conformance: `gen-call-nested-args`, `cf-match-arm-comma`,
  `type-enum-nonempty`; grammar.md updated alongside. The map-literal-vs-block
  ambiguity — the review's big design item — stays open above.
- **Workspace diagnostics — `resultId` caching + surface-gated nudge (LSP)**
  (2026-07). Two refinements on the pull-diagnostics path. (1) **Per-file
  `resultId` caching** (LSP 3.17): the server stamps each file's report with an
  opaque resultId and caches the exact rendered items it stands for; a re-pull
  that echoes the resultId (via `previousResultId` / `previousResultIds`) gets a
  light `unchanged` report for any file whose items are byte-identical, instead
  of re-sending them. Exact content comparison, not a hash — a collision would
  wrongly report `unchanged` (a stale squiggle). The cache is self-correcting
  (every decision compares current content), so no explicit invalidation is
  needed, and it is shared across the document and workspace channels (same
  content → same id). (2) **Surface-gated refresh nudge**: an edit now nudges a
  workspace re-pull only when it could alter _another_ file's diagnostics — a
  change to the file's public-surface _signature_ (`pkgs/cli/lsp/surface.thera`:
  the source with fn/method body interiors elided, since importers type-check
  against declarations, never bodies). A body-only edit — typing inside a
  function — no longer triggers a project-wide re-check; the file's own
  diagnostics still reach the editor via the client's per-document pull.
  Conservative by construction (elides less than the true surface), so it can
  only over-nudge, never miss a cross-file change. A close still nudges
  unconditionally (a loose file drops out of the report).
- **Workspace diagnostics — backgrounded on a fiber (LSP)** (2026-07). The
  `workspace/diagnostic` scan no longer runs synchronously on the request loop:
  it runs on a background fiber (`server.start_workspace_scan`) that `yield`s
  between files, so a large project's first pass no longer blocks
  hover/edits/completion. The scheduler runs the worker during the loop's stdin
  parks; the worker delivers its report through a new **outbox**
  (`pkgs/cli/lsp/outbox.thera`) — a single serialized outbound sink so the
  dispatch loop and the worker never interleave bytes of one framed message.
  `serve` installs an _async_ outbox (a writer fiber draining a channel, joined
  on exit so buffered replies flush); `handle` (the one-shot/test path) installs
  a _direct_ one and joins the worker inline, so the in-process tests stay
  synchronous. Supersession is a generation counter: a newer pull or a
  `$/cancelRequest` bumps it, and the stale worker bails with `ContentModified`
  (-32801) — the client keeps the latest (eventual consistency). Still deferred:
  per-file `resultId` caching and a smarter refresh nudge.
- **Per-file SDK resolution — cross-path core identity (loader)** (2026-07). A
  file that lives _inside_ an SDK's `std` tree now resolves its `std.*` imports
  (and the auto-imported `std.core` prelude) from **that same tree** rather than
  the configured SDK root (`loader.own_std_dir`). This fixes the
  LSP-editing-the-repo case: with the prelude resolved from an installed SDK but
  the file from the repo copy, the core types (`List<T>`, …) existed twice with
  distinct identities, so a core file's own generic methods stopped
  type-checking against their own `List<T>` and every top-level decl looked like
  it shadowed the prelude copy of itself. `thera check sdk/std` via a foreign
  SDK is now clean (was ~8 false diagnostics). Ordinary project files (not under
  a `std` tree) are unaffected — they keep resolving against the configured SDK
  — and the normal build resolves identically (fixpoint holds). Also: an
  unresolved for-loop iterable now types its element as `Unknown`, not `Int`
  (the `Int` fallback is scoped to ranges), so a genuinely unknown element no
  longer cascades into "no method X on Int".
- **Pull-only diagnostics + server-side `exclude` (LSP)** (2026-07). The server
  no longer pushes `publishDiagnostics` at all — it went **pull-only**, so open
  files and the workspace flow through the one channel
  (`textDocument/diagnostic` / `workspace/diagnostic`), and an edit's only
  proactive signal is the `workspace/diagnostic/refresh` nudge. This removes the
  push/pull duplication (a file no longer got diagnostics on two channels).
  Diagnostic filtering also moved from the VS Code extension to the server: the
  client sends its `thera.exclude` globs via `initializationOptions` (live
  changes via `workspace/didChangeConfiguration`), and the server withholds
  matching files from both reports — uniform across channels and
  client-agnostic, replacing the extension's per-channel glob middleware. A
  small workspace-relative glob matcher (`pkgs/cli/lsp/glob.thera`, `*` / `**` /
  `?`) does the matching. Closing a file now marks a change (a re-pull nudge)
  rather than clearing via push.
- **Workspace-wide diagnostics — pull model (LSP)** (2026-07). Diagnostics are
  no longer limited to open files. The server advertises a 3.17
  `diagnosticProvider` (`interFileDependencies` + `workspaceDiagnostics`) and
  answers `textDocument/diagnostic` (one document) and `workspace/diagnostic`
  (every workspace file, opened or not — a full report per file, empty items =
  clean). The workspace pull reuses the session's shared check and checked-clean
  dedup — the same `thera check <dir>` loop — so a shared import is checked once
  per pass, not once per importer, and `diagnostics.group_by_file` folds each
  file's own errors out of the closure result (the push path filtered them to
  one URI). The proactive signal is the pull model's
  `workspace/diagnostic/refresh` nudge, sent once per edit-flush to a
  refresh-capable client, which then re-pulls (the edited cone recomputes, the
  rest are checked-set hits) — so push stays for open files and pull carries the
  project. The `library_cache` is now **LRU** with a high cap (1024) instead of
  clear-all-at-32, so workspace analysis doesn't thrash it. (Backgrounding the
  workspace check on a fiber landed later — see the top of this changelog;
  `resultId` caching is still deferred.)
- **References/rename — dependency-cone pruning (LSP)** (2026-07). The
  project-wide scan no longer builds every workspace file's closure. Both
  requests now scope the expensive resolution to the target's **dependency
  cone** — its declaring file plus its transitive importers
  (`session.dependents_of`), intersected with the scan — so a file that can't
  see the declaration (a same-named identifier there is a distinct `SymbolId`)
  is skipped without a closure load. Completeness is preserved by first indexing
  the workspace's forward import edges with a cheap edges-only probe
  (`loader.import_edges` — resolves specifiers, no child
  sources/surfaces/element model; `session.index_edges` fills only files never
  loaded, so a warm request does no extra work), then reversing that graph: a
  closed, never-opened importer is still found. An edit drops the file's forward
  edges (`invalidate`) so a changed import list re-probes. Cost now scales with
  the target's reachability, not project size, with the same results as the old
  whole-project scan.
- **Session tokenization dedup — cached tokens (LSP, audit LS-D1 tail)**
  (2026-07). Tokens are now the materialized bottom rung of the analysis ladder:
  `parse_source` retains its lex on `ParsedFile.tokens` (paired with the AST by
  construction), the session carries the primary's tokens on `Closure`, and
  `ResolveCtx` hands them to the resolver. `resolve.primary_tokens` reads that
  cached tokenization instead of re-lexing — so hover/definition lex the buffer
  once per request (was twice: parse + resolve), and references/rename lex each
  scanned file once instead of once per candidate occurrence (the loop and every
  `resolve_at` inside it now share `ctx.tokens`). A cache hit is consistent with
  the request's text by construction (both flow from one `parsed_primary`);
  callers without cached tokens (hermetic tests) pass an empty list and the
  resolver lexes on demand — correct, just un-cached. Eviction is free: tokens
  ride the parse cache's existing invalidation cone.
- **Pre-rename collision check (LSP)** (2026-07). `textDocument/rename` now
  pre-flights the new name: renaming a top-level symbol onto a name already
  bound in its file's one name space — a same-file declaration, a prelude /
  `as _` bare-surface name, or a bound import namespace — is declined with an
  error response naming the clash, instead of writing an edit the checker would
  reject on the next publish. `rename.collision` reuses `find_decl_site` for the
  predicate (the same bare resolution the checker's duplicate/shadow checks
  agree with); `rename_at` returns a three-way `RenameOutcome`
  (`Edit`/`Decline`/`Collision`) the server maps to a WorkspaceEdit, a null
  result, or a `RequestFailed` error. Scoped to file-scope targets — a local
  shadows legally, so it isn't pre-checked.
- **Formatter (`thera fmt`)** (2026-07). A line-preserving formatter
  (`pkgs/cli/fmt.thera`): re-indents each line (token-only anchor stack),
  normalizes intra-line spacing (a token-driven **gap-edit** pass — rewrites
  only the whitespace between adjacent same-line tokens, so comments and lexemes
  are untouched), collapses blank runs, trims trailing whitespace. Keeps every
  author-chosen line break — no line joining/splitting. The one spacing role the
  token stream can't classify (`List<Int>` vs `a < b`) comes from a
  **generic-delimiter parser side-channel** (`ParseResult.generic_delims`, the
  `LexResult.comments` model); a round-trip guard (token equality + re-parse)
  makes "never breaks a compile" a checked invariant. No config knobs, by
  design. The corpus is a fmt fixpoint, gated by `bin/test.sh`. Philosophy (no
  config, bounded scope) in
  [architecture.md](architecture.md#the-formatter-thera-fmt).
- **Struct fields are `let`-declarations terminated by `;` — DONE.** A field is
  `let name: T;` (`let mut name: T;` for a reassignable one):
  `struct Point { let x: Int; let y: Int; }`. The `let`/`;` form reads as a
  declaration and differentiates a struct _declaration_ from a struct
  _instantiation_ — the two bodies (`{ x: … }`) were otherwise identical, told
  apart only by resolving each RHS as a type vs. a value.
- **Unified diagnostic model (audit LD15 tail)** (2026-07). Every phase — lex,
  parse, check, codegen, load — now produces one
  `Diagnostic {message, span, file, severity}` directly (new
  `pkgs/cli/diagnostic.thera`), retiring the five per-phase error structs
  (`LexError`/`ParseError`/`CheckError`/`CodegenError`/ `LoadDiagnostic`) and
  the session-level converters that mapped them. `file` is still derived from
  the span (the loader stamps an explicit file); `severity` is a three-level
  enum (`Error`/`Warning`/`Info`) so lint-style suggestions can ride the same
  model later — every compile-phase diagnostic is `Error` today, and the LSP
  severity map is its first consumer. No `phase` field (no consumer). check/
  emit/LSP are now pure renderers over a `List<Diagnostic>`.
- **Complete field identity (LSP)** (2026-07). A struct field now has full
  symbol identity, so references and rename treat it like any other declaration.
  Hover/definition on a field's declaration name, its `S { field: … }` literal
  uses, and its member accesses had already been unified onto the field's
  `FieldDef` name span (one owner-correct `SymbolId`); the remaining step was to
  stop declining field rename. `matching_spans` already resolves each occurrence
  at its own offset and keeps only those whose `SymbolId` matches, so all three
  positions collect and rewrite together — a same-named field on a different
  struct stays untouched. Removed the `is_field()` rename guard (and the
  now-dead method); check-only, no `.thera-bc` change.
- **Boundary type-annotation diagnostics** (2026-07). The "hard at the
  boundaries, soft in the center" rule (language.md, _Type annotations &
  inference_) is now enforced at all four boundaries. Struct fields were already
  required by the grammar; the checker now also flags an un-annotated **function
  parameter** (other than `self`), an omitted **return type** on a function that
  returns a value (a bare `return;`/`return void;` stays `Void`; reported once
  per function via a shared `CheckCtx` box; the check-site placement excludes
  returns inside nested lambdas for free), and an un-annotated **module-level
  `let`/`const`**. The module-level check keeps the pass-4 initializer inference
  under the hood (codegen never sees an `Unknown` global) but requires the
  annotation at the source. Corpus impact was a single migration — `std.log`'s
  `config` singleton, now `let config: Config = …`. No `.thera-bc` changes (a
  check-only error path), so the fixpoint held without a snapshot churn.
- **Un-annotated module-global type inference — resolver pass 4** (2026-07). A
  top-level `let`/`const` with no type annotation now has its type **inferred
  from its initializer** (mirroring a local `let`). Previously the resolver
  recorded a global's type from its annotation only, leaving an un-annotated
  global `Unknown`: the checker tolerated it (lenient member access on
  `Unknown`) but codegen hard-failed (`field access on non-struct value`), so
  `let config = Config { … }` type-checked yet wouldn't run. Implemented as the
  resolver's **pass 4** (`inference.infer_program_globals`, run per-program
  after the interface closure in
  `build_library`/`build_import_library`/`layer_primary`), so building a library
  yields a fully-typed one — no external caller has to run a second step, and
  the incremental cache stays correct (the base's imports are typed once at
  base-build; `layer_primary` types only the primary, honoring the frozen-base
  invariant). Making the resolver able to call inference required breaking the
  `inference → resolver` import cycle: `resolve_type_ref_in` / `resolve_opt_in`
  moved down to `scope.thera` (a layer both import), so `inference` no longer
  imports `resolver` and `resolver` now imports `inference`.
  Annotation-preserving and safe (inference degrades to `Unknown`), so no
  existing global — all annotated — changes. Unblocks the "final global struct
  with `mut` fields" mutable-singleton pattern (`std.log`'s config).
  _Fast-follow (Gap 2, open):_ a generic method on a struct's field
  (`config.filters.keys()`) still doesn't recover the field's type arguments —
  infers `List<Int>` — so it needs an annotated-local pin
  (`let m: Map<K,V> = config.filters;`); see Compiler & front-end open items.

- **`std.log` — named, per-source logging** (2026-07). Levels
  (`Debug`/`Info`/`Warn`/`Error`), named loggers with hierarchical per-source
  filtering (longest dotted-prefix wins), and Text/JSON rendering on stderr.
  Configuration (`set_level`/`set_level_for`/`set_format`/`configure_from_env`,
  the last reading a `RUST_LOG`-style `THERA_LOG` spec) is application-only
  behind a facade; libraries only ever emit. Ambient logging is the free
  functions `info`/`warn`/`debug` (plus `named(...)` for source-tagged loggers);
  its config is the one **sanctioned exception** to "no global state" —
  write-only diagnostics set once by the app — while the capability `to_writer`
  logger (own sink/level, testable) is the escape hatch. Implemented **pure
  Thera, no natives**: the config is a `let config = Config { … }` module global
  (an immutable binding whose `mut` fields mutate in place), rendering is pure
  Thera (JSON via `std.json`), and output writes through `io.stderr()`. An
  ambient `error` free function is a TODO — a top-level `error` collides with
  the prelude `error()` constructor; pending the prelude-value-shadow relaxation
  below (until then `error` is available as a `Logger` method). See
  [stdlib.md](stdlib.md) § `std.log`.

- **Semantic LSP resolution — references, rename, inferred-type navigation**
  (2026-07). `textDocument/references` and `rename` are now **semantic** — every
  candidate resolved by `SymbolId` identity across the open documents + a
  workspace scan (not by text match), so unrelated same-named symbols are never
  touched; both are registered in the server. The same resolver drives
  hover/definition on **inferred** receivers: local `let`/loop-variable types (a
  committed type-record, `session.type_at`), members on computed receivers
  (`f().x`, `xs[i].y`), struct fields, generic type parameters, and names inside
  `${…}`. Retires the parked lexical-only `references.thera`/`rename.thera`.

- **Owner-correct type resolution — `TypeId`** (2026-07). Completes the
  type-origin arc the roadmap flagged as foundational: nominal type identity is
  now `(owning library, name)` via a `TypeId {owner, name}` carried on every
  `Type` through inference, unification, and codegen's type tables (staged
  T1–T4, fixpoint-idempotent), lifting type-name uniqueness so two libraries may
  each define `Point` (conformance `mod-shared-type-name`). The preceding
  architecture-review checkpoint chose the `TypeId` struct over an interned int
  (keeps inference pure) and over a bare positional owner.

- **LSP incremental analysis engine + `type_at`** (2026-07). `thera check` and
  the LSP now share one long-lived analysis session (`session.Session` /
  `Analysis`) with a resolved-library cache + dependency-graph invalidation, so
  a keystroke re-parses only the edited file and re-checks only the affected
  libraries instead of the whole closure (batch corpus check 22.6s → 12.5s; warm
  keystroke ~5ms). The checker records each node's committed type
  (`Session.type_at`), which serves inference-at-offset and halved the checker's
  inference work.

- **Front-end audit — six-subsystem correctness sweep** (2026-07). An
  adversarial audit of `pkgs/cli/` closed whole classes of "checks clean, wrong
  at runtime" gaps: match exhaustiveness and assignment / operator / `if`-branch
  typing; value (const/global/native) owner-keying and codegen block/const
  scoping; builtin identity by `TypeId` rather than name string; canonical file
  identity + surfaced loader error paths + a unified per-file diagnostic model;
  owner-correct LSP resolution; and parser soundness (interpolation errors,
  `<`-ambiguity, brace-aware recovery).

- **Map/Set scaling — hashed, insertion-ordered** (2026-07). `Obj::Map` was a
  linear-scan, clone-on-mutate `Vec<(Value, Value)>`, so building an N-entry map
  was O(n²) (it bit an inference refactor building tens-of-thousands-entry
  maps). Now a dedicated `MapObj` (`runtime/src/map.rs`): a Vec for insertion
  order + a parallel key-hash Vec + an open-addressing index above 16 entries,
  with content-based hashing consistent with `values_eq` and mutation via
  `heap::take_obj` — O(1) get/has/insert. `Set` inherits it; insertion order is
  preserved so the fixpoint is unaffected.

- **Streaming files — `fs.open`/`fs.create` + `Seek`** (2026-06). `std.io`
  gained a `Seek` interface; `std.fs` gained `File` — a
  `Reader`/`Writer`/`Seek`/`Closer` over an OS file — so `io.lines(fs.open(p)?)`
  streams a file line by line without `read_all`. No GC finalizer yet, so
  `close()` is the caller's job. Deferred: `temp_file`, append/read-write
  `open_options`.

- **Interface default methods + Iterator adapters** (2026-06). Interface methods
  may carry a body — a _default_ an `impl` inherits (and may override), compiled
  once as a shared unit with `self` typed as the interface (no runtime change).
  First use: `Iterator<T>` gained lazy `map`/`filter`/`take` + `collect`/`count`
  as defaults, so every iterator is fluent with no `Iter<T>` wrapper; also fixed
  a lambda-arg-to-virtual-call inference bug. Spec `iface-default`; unblocks
  `io.lines`/`fs.walk`/`BufReader`.

- **Nested generic args in `impl` headers → `enumerate`** (2026-06). An `impl`
  header's `<…>` parsed type-param names only, so
  `impl Iterator<Indexed<T>> for …` didn't parse; `parse_impl_generics` now
  keeps both a TypeRef and a TypeParam view, chosen by whether `for` follows.
  Unblocked the `enumerate` adapter (`-> Iterator<Indexed<T>>`) and future
  wrapped adapters (`zip`/`flat_map`/ `chain`).

- **Iterator-backed stdlib — `io.lines`/`BufReader`, `fs.walk`, `List.pop`**
  (2026-06). First consumers of the new adapters: `io.lines(src)` yields one
  line per `next` (an `Iterator<String>`), `fs.walk(root)` is a lazy recursive
  `Iterator<String>` of descendant paths, and `List.pop() -> Option<T>` is the
  mutating companion of `last()`.

- **Module initializers — computed-once immutable globals** (2026-06). Top-level
  `let NAME[: T] = expr;` is computed once at load into a stored global slot
  (runtime `global.get`/`set`, a globals GC root, an `<init>` thunk before the
  entry; front-end does topological init with cycle detection + an
  effectful-native denylist). Immutable only; `const` tightened to manifest
  constants. First use: `std.math` `INFINITY`/`NAN`. See
  [language.md](language.md) → Module-level bindings; conformance `module-let*`,
  `const-manifest`.
- **`std.regex` — RE2 regexes over the `regex` crate** (2026-06). The runtime's
  2nd deliberate dependency (after `std.hash`): the linear-time RE2-derived
  `regex` crate — `compile`/`is_match`/`find`/`find_all`/`captures`/`replace`
  (`_all`), byte-offset `Match`, `RegexError.Syntax`. A compiled pattern lives
  in a runtime registry behind an `Int` handle, not yet freed (the benign leak
  the _Native resource finalization_ item addresses). Design:
  [stdlib.md](stdlib.md) §std.regex.
- **`std.hash` — native digests + the runtime's first external deps** (2026-06).
  `sha256`/`sha1`/`md5` (as `Bytes`) and `crc32` (as `Int`), thin wrappers over
  audited RustCrypto crates rather than reimplemented in Thera — hashing is
  crypto-adjacent. This deliberately added the runtime's first external
  dependencies (each named in its function's doc); checked against published
  vectors.

- **`std.encoding` — base64 / hex / url** (2026-06). `base64`/`hex`/`url`
  encode+decode, **pure Thera** over `Bytes`/`String` + bitwise ops (no natives,
  no lookup tables); decoding is fallible (`Result`), never a trap. RFC
  4648/3986 vectors + binary round-trip + malformed-input cases covered.
  `std.path` `normalize`/`relative` also landed.

- **Struct-definition keyword: `type Foo = { … }` → `struct Foo { … }`**
  (2026-06). Thera is nominal, but `type Foo = { … }` read as a structural alias
  (the wrong prior); structs now use the nominal keyword-name-braces form,
  rhyming with `enum`/`interface`. Purely surface — same `TypeDecl` AST,
  byte-identical re-emit — landed as a three-cycle ratchet (additive parser +
  snapshot, migrate 145 sites, remove the legacy form). Frees `type X = Y` for a
  future transparent alias.

- **LSP keystroke latency — parse cache + edit coalescing** (2026-06). A
  server-lived parse cache (keyed by path, evicted on edit) reuses the parsed
  import closure across keystrokes: **186 → 8.3 ms/edit (~22×)**. Edit
  coalescing drains a whole buffered burst before one diagnostics flush, so 100
  bunched edits ≈ the cost of 1. Next lever: caching the resolved/element-model
  closure (the incremental engine).

- **In-VM profiler + `thera check` ~7.7× faster** (2026-06). A deterministic
  instruction-budget profiler (`THERA_PROFILE`) drove a measure-then-fix pass on
  `thera check pkgs/cli` (80s): a cross-file parse cache (the `std.core` prelude
  was parsed 46× → once) plus string-constant interning took it to **~10.4s**,
  byte-identical fixpoint. Surfaced that a top-level `const` keyword map can't
  replace a `match` without load-time init — the motivation for _Module
  initializers_.

- **Unified checker/codegen inference context + a differential oracle**
  (2026-06). The checker and codegen built `infer_expr`'s context independently
  — a bug class where the two stages inferred an expression to different types
  (a runtime-trapping miscompile). A differential oracle (`THERA_INFER_ORACLE`)
  mapped every divergence to one pattern (codegen dropping the receiver's type
  args), now fixed and a permanent assert-zero guard in `bin/test.sh`;
  byte-identical fixpoint. _Open: extend the oracle to lambda units — a
  full-context attempt hung `check` (a compile-time blowup) and was reverted, to
  be redone perf-aware._

- **`Ord` interface + `std.sort`** (2026-06). Total ordering modeled on
  `Eq`/`Display`: `interface Ord { fn compare(self, other: Self) -> Ordering }`
  - `enum Ordering`, with explicit primitive impls and a `compare` arm in the
    runtime `virtual_fallback` for virtual dispatch. `std.sort` ships
    `sorted`/`sorted_desc`/`min`/`max` over `<T: Ord>` (free fns); comparison
    operators stay Int/Double-only (wiring them through `Ord` is the _Generic
    operators_ arc). Also fixed a latent gap: lifted lambdas now inherit their
    enclosing function's `type_param_bounds`. Spec `iface-ord`.

- **Bitwise operators** (2026-06). `& | ^ << >> >>> ~` on `Int` (wrapping i64),
  lexer → parser precedence → checker (Int-only) → opcodes. Let `std.random`'s
  SplitMix64 and the LEB128 / little-endian `Bytes` codecs move into pure Thera
  (the `random_mix` native is gone). Specs `expr-bitwise`/`expr-shift`.

- **Generics: static-method type args, struct/enum bounds, inference cleanup**
  (2026-06). Three solidifications: static-method owner type params recovered
  from call context (`Set.new()`) or named via receiver type args
  (`Set<String>.new()`); generic struct/enum bounds (`type Box<T: Display>`)
  enforced where a concrete arg is supplied; and the static-receiver
  classification unified in `resolve_static_receiver`. All byte-identical
  fixpoint except the added checks; generics are invariant by design. Specs
  `gen-static-*`, `generic-type-bounds`. _Open follow-ons above._

- **Resolution: `FileScope` + owner-correct value resolution (Phase 2)**
  (2026-06). Resolution moved off flat global name tables onto a per-file
  `FileScope` with `name → defining-file` origin, so value (function/const)
  resolution is owner-correct (bare to its own file, qualified within its
  library) and two libraries may share a top-level value name. Landed in eight
  fixpoint-preserving steps; also fixed a duplicate-file-loading bug that cut
  the self-compile ~11.5s → 4.3s and the bootstrap 282KB → 124KB. Spec
  `mod-shared-value-name`. (Type-name owner-correctness followed — the `TypeId`
  entry above.)

- **`#loc` caller-location + assertion source locations** (2026-06). `#loc` is a
  compiler metaconstant evaluating to a `SourceLoc`; as a default parameter
  value it captures the call site. `std.testing` assertions take
  `at: SourceLoc = #loc` and prefix failures `file:line:column:` — the same
  format `thera check` prints. Spec `expr-loc`. _Open tail above (single-hop
  limit; runtime backtraces)._
- **Total rendering — `Display`-preferred, `Debug`-fallback** (2026-06). `${x}`
  / `println(x)` are total: a value renders via its `Display` impl if present,
  else its auto-derived `Debug`, never a check error or trap.
  `List`/`Map`/`Set`/`Option`/`Result` carry `Display` impls (elements via
  `Debug`, so nested strings quote). Specs `iface-display`/`iface-debug`. _Open:
  richer structural `Debug`, primitive vtables (both above)._
- **Primitive `Display` explicit** (2026-06). `Int`/`Double`/`Bool`/`String`
  carry real `impl Display`s bound to per-type natives; the catch-all
  `stringify` native and both front-end hardcodes are gone. `display_string`
  still backs the per-type natives + `list.join` + the virtual fallback — full
  retirement waits on primitive vtables.
- **`native type` declarations for the built-ins** (2026-06).
  `Int`/`Double`/`Bool`/`String`/`List`/`Map`/`Bytes`/`BytesBuilder` have
  bodyless `native type` decls in `sdk/std/core/` — a definition + doc site, no
  codegen/runtime entry (shadows the built-in floor byte-identically). Spec
  `type-native`. _Open follow-ups above._
- **Whole-closure diagnostics — per-file origin + import parse errors**
  (2026-06). `Diagnostic` carries a `file` origin resolved from the span's
  source text, so an imported-file error prints against its own file; the loader
  parses every closure file best-effort and surfaces each file's diagnostics
  (`LoadDiagnostic`), the LSP filtering per-URI. _Open tail above (cascade
  suppression / check-path scope)._
- **Unify call/member resolution** (2026-06). Codegen's `method_call` dispatches
  on the element model's `infer_callee_kind` (the single source of callee kind),
  choosing only the backend lowering per kind; the old codegen `ModuleScope`
  cascade was deleted, byte-identity held by the fixpoint.
- **Inference completeness** (2026-06). An un-inferable type is a clear, located
  check-time error, never a silent `Unknown`: lambda params (annotation/context
  or error), block-body lambda return, forward-flow for empty-literal/`None`
  locals (typed from first pinning use), call-argument checking for every call
  form, generic inference from context (incl. the assignment target), and
  match-arm unification. A broad "reject `Unknown`" flip was ruled out — ~330
  `Result.Ok(x)` → `Result<T, Unknown>` make leniency load-bearing.
- **`thera test` per-test stdout capture** (2026-06). Each test's output is
  buffered via the `test_capture_*` runtime natives and shown only on failure
  (or always with `--show-output`). _Open: per-test source locations,
  machine-readable output (above)._
- **Runtime tiers 0–baseline.** Tree-walker POC + bytecode IR; Tier-0 bytecode
  interpreter + precise non-moving mark-sweep GC (see Runtime staging 1–2). Plus
  the interpreter perf wins (unified value stack, `ListLen` opcode) noted under
  _Interpreter performance_.
