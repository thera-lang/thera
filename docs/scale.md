# Thera at scale

**What this is:** the planning doc for keeping a large Thera codebase (100k,
500k lines) workable for LLMs and coding agents. It gives the scaling model —
what actually breaks for an agent at that size — an inventory of what the
language already does about it, and a set of work items, each with the problem,
the current state, a direction, and the open questions to dig into. Items
**graduate out of this doc**: a decided semantic lands in
[language.md](language.md), a scoped piece of work becomes a
[roadmap](roadmap.md) arc, and the item here shrinks to a pointer. Several items
below are already tracked in the roadmap; for those this doc adds the scaling
frame and defers the details to the roadmap entry.

## The scaling model — four failure modes

At 100k+ lines no agent reads the codebase; every task is done through a
keyhole. Progress then depends on four properties, each with a distinct failure
mode. Every work item below names which of these it attacks.

1. **Reading radius.** How much code must be read to make one correct change? If
   understanding a function requires understanding distant mutable state,
   implicit conventions, or a cyclic tangle of imports, the radius exceeds the
   context window and the agent starts guessing.
2. **Discoverability.** Can the agent find the thing that already exists? The
   signature failure is **convergent reimplementation** — large codebases
   accrete five private copies of `pad2` because finding the existing helper
   costs more than writing a new one, and each copy makes the next search worse.
3. **Feedback-loop latency.** Agents make progress by iterating against `check`
   and `test`. If whole-program checking takes minutes, agents either slow to a
   crawl or skip verification. Agent throughput is roughly proportional to
   verification speed — this is quietly the most important of the four.
4. **Trustworthiness of prose.** An LLM believes docs and conventions more
   readily than a human skimmer does. Stale docs, drifted conventions, and "we
   do it three ways depending on when the code was written" actively poison an
   agent — it pattern-matches on whichever style it saw last.

Plus one cross-cutting mode: **mechanical sweeps**. Renames, signature changes,
and idiom migrations touching hundreds of sites. Done by hand — even an agent's
hand — these are where large codebases rot: partial migrations leave two
conventions alive forever, feeding failure mode 4.

The governing loop is **convention → documented → linted → auto-fixed → swept**.
Every time a piece of engineering discipline completes that pipeline it moves
out of the prompt/guidelines column — where it decays and consumes context —
into the toolchain column, where it is free and permanent. A large Thera
codebase stays workable to the degree its conventions have made that trip; the
ones that haven't are exactly the ones agents will violate, one
plausible-looking PR at a time. (The `=> void` sweep and the `lint --fix` idiom
rules are this loop already running — see the roadmap's _Tools — refactorings_.)

## What already exists

Aimed at **reading radius**: file-as-privacy-unit with explicit `pub` and
per-file namespaces ([language.md § Visibility](language.md#visibility));
immutability by default and errors as values (local reasoning); single-threaded
fibers (no cross-thread interleavings to reason about).

Aimed at **discoverability**: qualified-by-default imports — `fs.read_text` is
findable by grep in a way bare imports never are
([language.md § Imports](language.md#imports)); the LSP's workspace-symbol and
hover surface.

Aimed at **trustworthy prose**: the doc model — `///`/`//!`/`//` separated
lexically, the standalone summary sentence, progressive disclosure as the stated
design principle ([language.md § Documentation](language.md#documentation)); the
strict formatter (one shape per construct); the _Choosing a form_ canonical
idiom table.

Aimed at **sweeps**: the landed `thera lint` / `lint --fix` / LSP code-action
machinery (roadmap _Tools — refactorings_), which is the seed every enforcement
item below builds on.

Already tracked in the roadmap and part of this story: **verify doc snippets**
(doctests), the **doc generator / doc-comment tooling**, the **idioms rules
file**, and the remaining **lint rules** — see _§ Work items_ for how each slots
in.

## Nomenclature

The units this doc's items hang off, smallest to largest. The first two are
already defined in [language.md § Visibility](language.md#visibility); only
**package** is new:

| Term            | Unit of                                                                                                                                                  | Status   |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| **source file** | privacy (`pub` vs. file-private)                                                                                                                         | exists   |
| **library**     | import/API surface — a single file, or a directory + its barrel; proposed here as the unit of **acyclicity** (item 1) and **separate checking** (item 2) | exists   |
| **package**     | manifest — a set of libraries with declared dependencies (item 4)                                                                                        | proposed |

With these terms the cycle rule states itself: _imports between libraries must
be acyclic; files within a directory library may import each other freely._ Test
files (`foo_test.thera`) are **consumers** of the library they sit beside, not
members of it — they get white-box visibility, but their imports do not count
toward the library's dependency graph (see item 1's survey for why this
matters).

## Work items

Each item: the problem, today's state, a direction, and the open questions a
digging session should settle. Status lines track graduation.

### 1. Acyclic library imports — **done, graduated**

_Attacked: reading radius; enables item 2._

The rule is now language: **imports between libraries must be acyclic** — spec'd
in [language.md § Import resolution](language.md#import-resolution) (the
normative statement), pinned by conformance IDs `mod-import-cycle` /
`mod-import-cycle-sibling`, enforced in the loader as an error-level `check`
diagnostic on every participating import (each carrying one full cycle path).
The unit is the library (directory libraries' sibling files may cycle freely);
test files are consumers, per _§ Nomenclature_.

How it got here, briefly: the 2026-07 survey (167 files, 541 edges) found one
real file-level cycle (`element ↔ types` — same-directory siblings, legal under
the library rule) and one directory-level artifact (`diagnostic ↔ lexer/`),
dissolved by hoisting `SourceSpan` + the comment side channel into
`pkgs/cli/source.thera` (the source-model leaf library). The survey also
produced the consumer rule (test files manufactured every false cycle) and
settled library granularity over file granularity. Enforcement skipped the
planned lint stage and landed directly as an error: the corpus was already clean
(nothing to migrate), and item 2's separate checking will _rely_ on the DAG — an
invariant the toolchain depends on can't be ignorable.

### 2. Per-library separate checking

_Attacks: feedback-loop latency. **One design with item 1** — separate checking
needs an acyclic order to check in._

**Problem.** At 500k lines a whole-program `check` is minutes, and agent
throughput collapses with it. The target: an edit inside one library re-checks
that library and (only when its public surface changed) its dependents — keeping
the loop at seconds regardless of codebase size.

**Scoping (2026-07, measured — `dev/bench_session.thera`).** The session re-arch
for the LSP already provides most of the in-process story: each layer (parse →
`FileSurface` → imports-only element base → check verdict → type records) is a
pure function of earlier layers with a cache, invalidated over the
reverse-import cone. Measured on the 53k-line corpus: a warm no-edit re-check is
**5 ms** against a ~400 ms cold closure; a cold CLI process pays 4.4 s for the
whole corpus. What the item's original sketch asked for was therefore not one
build but **three separable deltas**:

- **(a) The surface-digest gate — landed.** Invalidation was _any-edit_: a
  body-only edit (the overwhelming agent case) evicted the whole dependent cone
  — measured 123–199 ms per re-check where ~5 ms is achievable, a gap that grows
  linearly with the edited file's fan-in. Now `set_overlay` parses the new text
  (seeding the parse cache — no net extra parse) and compares the file's
  **printed public surface** (`surface_signature` in `session.thera`: pub
  fn/interface signatures, pub type/enum shapes, pub const/let annotations, impl
  headers + pub method signatures, pub imports — sorted, so decl order is not
  surface). Unchanged ⇒ only the edited file and its white-box test sibling
  re-check; dependents' verdicts and type records stay live. Measured after:
  **66 ms** (direct-dep edit) and **10 ms** (deep-leaf edit). Soundness rests on
  two language rules: return types are always written (omitted = `Void`, never
  inferred) and module-level bindings are annotated boundaries — so bodies
  cannot leak into importer-visible types; the unannotated-const/let case
  contributes its decl text (conservative), private decls are excluded but the
  white-box sibling is evicted unconditionally, and any unparseable side falls
  back to the full cone (mid-edit states stay conservative).
- **(b) Persistence — open, the next arc.** Every CLI process is cold: 4.4 s
  corpus, 416 ms single file, every `thera check`/CI run — and agents live in
  cold CLI runs. The caches being pure functions of (file text, dep surfaces) is
  exactly what makes them disk-keyable:
  `(content hash, dep-digest vector) → verdict + FileSurface` under `build/`,
  turning a warm re-run into a hash walk. The digest definition from (a) is the
  key ingredient and now exists in code.
- **(c) Per-library composition — open, deferred until it hurts.** The
  element-model cache is **closure-signature-monolithic**: keyed on the whole
  import set, any member edit evicts the whole base, and the base rebuild is
  most of the residual 66 ms above. With acyclicity (item 1) and sealed barrels
  (item 3) landed, the model could be built and cached _per library_ and
  composed in topo order — per-library eviction, structural sharing, a
  parallelism seam, and the agent-facing report "the surface of X changed; these
  N libraries depend on it". The genuinely large refactor; (a)+(b) capture most
  of the latency win before it.

**Status:** (a) landed (gate + tests in `session.thera` / `session_test.thera`);
(b) open — next; (c) open — deferred. The "decide early" warning is discharged:
the acyclic DAG is enforced and the digest definition is code, so (b) and (c)
extend rather than retrofit.

### 3. Barrel-enforced boundaries (no deep imports) — **done, graduated**

_Attacked: reading radius (a library's surface is real), trustworthiness (the
barrel doc describes everything reachable)._

The rule is now language: **a directory library's files are importable only from
inside it** — outsiders go through the barrel (by directory path or barrel-file
path, equivalently) — spec'd in
[language.md § Import resolution](language.md#import-resolution), pinned by
conformance IDs `mod-import-deep` / `mod-import-barrel-file`, enforced in the
loader as an error-level `check` diagnostic at the offending import. The sibling
rule is **same directory** (settled by the nesting survey: zero nested cases in
the corpus; tightenable-free — subtree can be liberalized later, item 4's
territory). Test files get no exemption — white-box access is the same-directory
`foo_test.thera` convention, already sibling-legal. A directory _without_ a
barrel is not sealed: its files are independent single-file libraries (so a
program root of loose files needs no barrel, and file → directory-library
promotion never changes importers).

How it got here: the precise survey found 33 violations (27 production + 6
test), all in `pkgs/cli`, targeting six internal files that were de-facto public
API; the migration extended three barrels (lexer re-exports the token model,
element its four phase files, ast its renderers) and moved every importer
through them — deduplicating one convergent reimplementation (checker's
`is_reserved_type_name` shim) and flushing out a checker hole (unknown namespace
in a type annotation resolves instead of erroring — see the roadmap diagnostics
punchlist). Deferred as a future normalization lint: the corpus's 93
barrel-reached-by-file-path imports (`import 'lexer/lexer'` for
`import 'lexer'`) — legal, just two spellings of one thing.

### 4. A package unit + manifest (declared dependencies, layering)

_Attacks: reading radius (enforced architecture), discoverability (an explicit
DAG to orient by). **Furthest out — dig after 1–3 settle the units.**_

**Problem.** Above ~one directory there is no unit that says what it may depend
on. Layering ("the parser must not import codegen") is a review comment, not a
check error — and review comments are exactly what erodes at 500k lines. An
explicit, machine-readable dependency DAG is also an orientation artifact for
agents ("what does this sit on top of?") and the natural invalidation unit for
item 2's caching.

**Today.** No package concept: `std.*` plus relative file imports. `pkgs/cli` is
a de-facto package with de-facto internal layering (lexer → parser → resolver →
checker → codegen) enforced by nobody.

**Direction.** A manifest per package declaring (at least) its importable
dependencies. `check` errors on an import the manifest doesn't allow.
`pkgs/cli`'s pipeline is the first customer. Deliberately under-specified until
items 1–3 land — the manifest should describe units that already have enforced
boundaries.

**Open questions.** (a) Manifest **location** — the format half is settled:
**TOML**, and `std.toml` is core, complete, and conformance-pinned
([stdlib.md](stdlib.md) § `std.toml`), with a strict `Cursor` built for exactly
this kind of reader (a typo'd key fails with the path that names it); (b) is a
package a directory-library or a coarser grouping of libraries? (c) does `std.*`
get manifests? (d) relationship to a future third-party package story (don't
design that here, but don't preclude it). (e) **a second manifest already wants
to exist** — [api-access.md](api-access.md) § The manifest is a
per-generated-API config file (spec URL, hash pin, selected operations, auth
technique, per-call overrides), which would sit in the same directory as this
one with a different lifecycle. Two files rather than one, since dependencies
change when you add a dependency and that one changes when an upstream spec
moves; both are TOML.

**Status:** open, deferred behind 1–3.

### 5. Generated API index

_Attacks: discoverability, trustworthiness. **Already tracked:** roadmap
*Developer tooling → Doc-comment tooling*, item (3) — the doc generator._

**The scaling frame.** The doc model defines the perfect atoms (barrel `//!`
package doc, standalone summary sentences); the aggregation is the missing
piece. A generated per-library index — one line per `pub` symbol: signature +
summary sentence — is _the_ orientation artifact at scale: an agent reads the
index (~a page) instead of the source (~unbounded), and because it is generated
it cannot go stale the way a hand-written ARCHITECTURE.md does. It also directly
attacks convergent reimplementation: "search the index before writing a helper"
is a cheap, enforceable habit — and the repo-root orientation that today lives
in CLAUDE.md becomes mostly derivable.

**Direction — transport settled (2026-07).** The candidate transports (a
`thera doc` CLI, committed artifacts + a CI freshness check, a custom LSP
command, an MCP server) are not competing designs — they are transports over one
function, so the core is built **once** (doc extraction + index formatting, in
`pkgs/cli`, riding the loader/element data) and exposed in order of agent reach:

- **Front door: `thera doc <lib>` to stdout** (plus `thera doc --index` for the
  workspace map). The shell is the one transport every coding agent has, and
  output consumed from a pipe **cannot be stale** — the exact trustworthy-prose
  property this item exists for. Output is terse, deterministic, stable-ordered
  text (the consumer is a context window): one line per `pub` symbol —
  signature + summary sentence. `--json` later if tooling needs it.
- **LSP shares the core** — hover and workspace-symbol serve the same data as
  the ambient editor surface (roadmap doc-comment tooling items 2–3). No custom
  LSP command: worst discovery of the four, and the thing agents drive least
  well.
- **MCP deferred** — a thin shim over the same core, addable the week a non-exec
  agent context needs it; until then it adds config burden without capability.
- **Committed artifacts rejected.** The staleness window is adversarial (an
  agent consults the index precisely while a change is in flight — exactly when
  a committed copy is wrong), and the regen/CI/merge-conflict tax is permanent.
  The bootstrap-snapshot precedent doesn't transfer: it is committed because it
  must be, and changes rarely; API docs change with every edit. The one unique
  benefit — API-surface changes visible in PR diffs — is item 2's job (interface
  digests), not checked-in docs.

**Discovery** is a prompting-surface problem with an existing reliable channel:
a best-practice line in each project's CLAUDE.md ("before reading a library's
source, run `thera doc <lib>`"), and/or the agent rules-file / skill from the
roadmap's _Idioms & best-practices guidance_ item — "navigate Thera this way"
lives beside "write Thera this way". Escape valve if that proves insufficient:
commit only the tiny, slow-changing root map, whose own header teaches the tool
— but wait for evidence before paying even that.

**Status:** transport settled; open — the index format itself, and
implementation sequencing (needs doc-comment tooling item 1, attach docs to AST,
first). Details in the roadmap entry.

### 6. Doctests — self-verifying examples

_Attacks: trustworthiness. **Also tracked:** roadmap *Developer tooling → Verify
the code snippets in docs* (the motivating bugs and harness notes)._

**The scaling frame.** Code examples are the highest-value doc content for an
LLM — they are the thing it imitates — and also the doc content that rots
fastest. Verifying them makes the docs self-verifying, which is precisely the
property that matters when the primary reader trusts documents uncritically. The
roadmap entry's motivating bugs (a doc teaching `loop { … }`, a sketch calling
an API that never compiled) were both **statically** wrong — so the static bar
alone catches the rot class that prompted this item.

**Direction — settled (2026-07).** Examples come in three sizes, and size
decides where they live. The principle: **minimize code that lives as strings**
— only the smallest examples sit in comments; anything bigger is real code that
participates in checking and refactors with no special tooling.

1. **One-liners in doc comments** — fenced blocks in `///`/`//!`, REPL style
   (~99 blocks across 33 `sdk/std` files today). Locality is the point: they
   surface in hover and `thera doc` at the API they illustrate. **The fence tag
   is the contract**: a `thera`-tagged fence claims to be real Thera and is
   verified; attributes make exceptions (`thera sketch` — rendered, never
   checked, self-labels aspirational API; `thera no_run` — compile only). An
   **untagged fence is ignored** — legitimately: design fiction is fine when
   lexically marked, and the corpus already conforms (language.md's 64 blocks
   are all tagged and should verify; stdlib.md's 52 sketch blocks are all
   untagged). Same rule for fences in `docs/*.md`.
2. **Workflow examples in test files** — an `@example`-decorated fn in the
   existing `foo_test.thera` (consistent with `@test`; compiled and run by the
   test runner). Ordinary code: renames, checking, and find-references work with
   zero special handling. A doc site pulls one in by an explicit reference on
   its own doc line — `/// @foo_test.thera#example_name` — the `file#fragment`
   shape agents already know, and a breadcrumb an agent can follow even with no
   tooling at all. Tooling (`thera doc`, hover) inlines the referenced body.
   **Explicit references, no name magic**: Go-style `example_<symbol>`
   name-matching detaches silently on rename, while a reference is validated
   resolve-or-error by the same machinery as item 7's `[Symbol]` references. An
   unreferenced `@example` fn is a natural lint.
3. **Whole programs in `examples/`** — already exists, already run by
   `bin/test.sh`. Done.

**Static vs. run.** Compile-check (parse, resolve, type-check) is the universal
bar for every tagged block — it is deterministic, needs no sandbox, and catches
the observed rot class (fictional syntax, fictional APIs, stale names after
renames). **Running is opt-in by shape**: a block runs iff it contains a
`// => value` oracle (the harness debug-formats the expression and compares —
the marker is both the assertion and the run-me signal; Go's `// Output:`
design) or `// error:` expectations (check mode, per the `tests/lang` harness).
The transform is also what makes REPL-style lines legal — bare expression
statements and discarded `Result`s are errors, so oracle lines compile _as
assertions_, not verbatim. Blocks with neither marker are compile-only. Wrapper
synthesis: implicit `fn main` + prelude + the documented library auto-imported
under its own namespace (existing examples already assume this —
`path.components(...)`).

**Phasing.** Spec the whole surface now (fence attributes, `// =>`, `@example`,
`@file#fragment` references) so examples get written in the final shape;
implement in stages: (1) extraction + **compile-check** of tagged fences — the
high-order bit; (2) `@example` + references + `thera doc`/hover inlining (lands
with item 5's doc generator — the reference convention is only as good as its
rendering); (3) `// =>` oracles and check-mode blocks; (4) the `lint --fix`
sweep converting the ~99 stdlib blocks' trailing comments to `// =>` where they
parse as values.

**Open questions.** (a) Do `// =>` runs get the `std.testing` deterministic
doubles (fixed clock/env) ambiently, so `no_run` stays rare? (b) Doctest
identity/reporting (`file:line` as the test name?). (c) Whether language.md's
error-demonstrating blocks adopt `// expect error:` verbatim from `tests/lang`
or keep the lighter `// error:` spelling.

**Status:** direction settled; graduates to language.md § Documentation (fence
tags, `// =>`, `@example`, references) as each phase lands. Sequencing:
`sdk/std` doc comments first, language.md second, stdlib.md sketches stay
untagged (or gain `thera sketch`) as their APIs land.

### 7. Doc-reference integrity, promoted to errors

_Attacks: trustworthiness. **Already tracked:** roadmap *Doc-comment tooling*,
item (4) — reference resolution + lint._

**The scaling frame.** The principle to settle here: **anything the toolchain
can verify about prose, it eventually should** — unverified prose is a liability
at 500k lines. Concretely, a `[Symbol]` doc reference that no longer resolves
should follow the standard promotion path: lint → warning → check error, same as
a broken import. The digging question is the promotion policy (when does a doc
lint get teeth?), not the mechanism.

**Status:** open; mechanism in the roadmap entry, promotion policy here.

### 8. Mechanical refactors as CLI operations

_Attacks: sweeps. **Builds on:** the landed `lint --fix` machinery (roadmap
*Tools — refactorings*)._

**Problem.** The existing machinery rewrites _shapes in place_ (`if let`, `?`,
combinators). Migrations also need the cross-file operations: **rename**
(symbol, field, library) and **change-signature** (add/remove/reorder
parameters, positional → labeled). With those as `thera` operations, an agent
decides _what_ and the tool edits the 300 sites — sweeps become transactional
instead of a hand-edited long tail, which is what lets conventions converge
instead of forking.

**Direction.** `thera rename` first — it is resolution-complete (the LSP's
find-references is most of it) and the highest-frequency migration.
Change-signature second; it pairs with the calling-convention lint already on
the roadmap.

**Open questions.** (a) CLI shape (`thera rename <lib>.<symbol> <new>`?); (b)
shared machinery with LSP rename (should be the same code); (c) how a rename
interacts with doc references (item 7 — a rename should rewrite `[Symbol]`
mentions too).

**Status:** open.

### 9. Duplicate-helper detection

_Attacks: discoverability. **Speculative — dig last; may not pay for itself.**_

**Problem.** Convergent reimplementation is silent: nothing flags a new private
`pad2` when `std.fmt` already exports one. Even a crude signal converts the
failure from silent to visible.

**Direction.** A lint that flags a new private helper whose name/signature
closely matches an existing `pub` symbol elsewhere (exact-name match first;
anything fuzzier is research). Honest uncertainty: the false-positive rate may
sink it — a survey of the current corpus (how many true duplicates exist? would
exact-name matching have caught them?) should precede any implementation.

**Status:** open, speculative.

## What stays process

Genuinely process-level, not fixable by the language: task decomposition
(keeping each change small and verifiable), deciding _what_ to build, review
judgment about design quality, and the orientation prose that explains _why_ the
architecture is shaped as it is — generated indexes (item 5) say _what_; intent
still needs a human-authored paragraph (CLAUDE.md, the `//!` barrel docs, this
docs/ tree). The boundary is not static: the governing loop above exists to keep
moving discipline from the process column into the toolchain column, and this
doc's items are that loop applied to scale.

## Suggested order

1. **Items 1 + 2 together** — acyclicity + separate checking are one design.
   **Item 1 is done**; item 2 is scoped into three arcs with **(a) the
   surface-digest gate landed** — (b) persistence is the next arc, (c)
   per-library composition deferred until base-rebuild cost or memory hurts.
2. **Item 5** (API index) — highest orientation payoff, machinery already
   half-planned.
3. **Item 3 is done** (migration + enforcement landed; the unit items 2 and 4
   depend on is now sealed).
4. **Item 6** (doctests), then **7** — the trustworthy-prose pair.
5. **Item 8** (rename, then change-signature) — as soon as a real sweep needs
   it.
6. **Item 4** (manifest/layering) when the units are settled; **item 9** only
   after its survey justifies it.
