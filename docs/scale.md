# Thera at scale

**What this is:** the planning doc for keeping a large Thera codebase (100k,
500k lines) workable for LLMs and coding agents. It gives the scaling model —
what actually breaks for an agent at that size — an inventory of what the
language already does about it, and a set of work items, each with the problem,
the current state, a direction, and the open questions to dig into. Items
**graduate out of this doc**: a decided semantic lands in
[language.md](language.md), a scoped piece of work becomes a
[roadmap](roadmap.md) arc, and the item here shrinks to a pointer. Several
items below are already tracked in the roadmap; for those this doc adds the
scaling frame and defers the details to the roadmap entry.

## The scaling model — four failure modes

At 100k+ lines no agent reads the codebase; every task is done through a
keyhole. Progress then depends on four properties, each with a distinct failure
mode. Every work item below names which of these it attacks.

1. **Reading radius.** How much code must be read to make one correct change?
   If understanding a function requires understanding distant mutable state,
   implicit conventions, or a cyclic tangle of imports, the radius exceeds the
   context window and the agent starts guessing.
2. **Discoverability.** Can the agent find the thing that already exists? The
   signature failure is **convergent reimplementation** — large codebases
   accrete five private copies of `pad2` because finding the existing helper
   costs more than writing a new one, and each copy makes the next search
   worse.
3. **Feedback-loop latency.** Agents make progress by iterating against
   `check` and `test`. If whole-program checking takes minutes, agents either
   slow to a crawl or skip verification. Agent throughput is roughly
   proportional to verification speed — this is quietly the most important of
   the four.
4. **Trustworthiness of prose.** An LLM believes docs and conventions more
   readily than a human skimmer does. Stale docs, drifted conventions, and
   "we do it three ways depending on when the code was written" actively
   poison an agent — it pattern-matches on whichever style it saw last.

Plus one cross-cutting mode: **mechanical sweeps**. Renames, signature
changes, and idiom migrations touching hundreds of sites. Done by hand — even
an agent's hand — these are where large codebases rot: partial migrations
leave two conventions alive forever, feeding failure mode 4.

The governing loop is **convention → documented → linted → auto-fixed →
swept**. Every time a piece of engineering discipline completes that pipeline
it moves out of the prompt/guidelines column — where it decays and consumes
context — into the toolchain column, where it is free and permanent. A large
Thera codebase stays workable to the degree its conventions have made that
trip; the ones that haven't are exactly the ones agents will violate, one
plausible-looking PR at a time. (The `=> void` sweep and the `lint --fix`
idiom rules are this loop already running — see the roadmap's _Tools —
refactorings_.)

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
lexically, the standalone summary sentence, progressive disclosure as the
stated design principle ([language.md § Documentation](language.md#documentation));
the strict formatter (one shape per construct); the _Choosing a form_ canonical
idiom table.

Aimed at **sweeps**: the landed `thera lint` / `lint --fix` / LSP code-action
machinery (roadmap _Tools — refactorings_), which is the seed every
enforcement item below builds on.

Already tracked in the roadmap and part of this story: **verify doc snippets**
(doctests), the **doc generator / doc-comment tooling**, the **idioms rules
file**, and the remaining **lint rules** — see _§ Work items_ for how each
slots in.

## Nomenclature

The units this doc's items hang off, smallest to largest. The first two are
already defined in [language.md § Visibility](language.md#visibility); only
**package** is new:

| Term            | Unit of                                                          | Status                |
| --------------- | ---------------------------------------------------------------- | --------------------- |
| **source file** | privacy (`pub` vs. file-private)                                 | exists                |
| **library**     | import/API surface — a single file, or a directory + its barrel; proposed here as the unit of **acyclicity** (item 1) and **separate checking** (item 2) | exists                |
| **package**     | manifest — a set of libraries with declared dependencies (item 4) | proposed              |

With these terms the cycle rule states itself: _imports between libraries must
be acyclic; files within a directory library may import each other freely._
Test files (`foo_test.thera`) are **consumers** of the library they sit
beside, not members of it — they get white-box visibility, but their imports
do not count toward the library's dependency graph (see item 1's survey for
why this matters).

## Work items

Each item: the problem, today's state, a direction, and the open questions a
digging session should settle. Status lines track graduation.

### 1. Acyclic library imports

_Attacks: reading radius, and enables item 2. **The enabling decision — dig
first, together with item 2.**_

**Problem.** A cycle means no file in it can be understood in isolation — the
reading radius of every member is the whole cycle. Cycles also block
per-library incremental checking (no topological order to check in) and
per-library caching. Every ecosystem that scaled made its units acyclic (Rust
crates, Go packages).

**Today.** [language.md § Import resolution](language.md#import-resolution):
direct self-import is a check error; **longer cycles remain legal**.

**The survey (2026-07).** The full import graph of `pkgs/cli` + `sdk/std`:
167 files, 541 edges. Production code (excluding `*_test.thera`) contains
**exactly one file-level cycle** — `element/element.thera ↔
element/types.thera`, the mutually recursive symbol-model/type-model pair,
and they are **siblings in the same directory**. At directory granularity
there is one SCC — `diagnostic.thera ↔ lexer/` — and it is an artifact of
contraction, not a real tangle: at file level it is a clean DAG
(`lexer.thera → diagnostic.thera → lexer/token.thera`); the directory only
cycles because `SourceSpan` lives inside `lexer/`. The fix is hoisting
`SourceSpan` into a leaf library — which the deep-import stats independently
demand (`lexer/token.thera` is imported from outside its directory 27×; see
item 3). Two more findings: **test files manufacture false cycles** (with
tests included there are three additional directory SCCs, every back-edge a
`*_test.thera` — hence the consumer rule in _§ Nomenclature_), and the
**prelude is safe** (`std.core` imports only its own siblings, so the
implicit edge into every file cannot cycle).

**Direction — settled by the survey.** Granularity is **library-level**:
cycles forbidden between libraries, free among sibling files within a
directory library (the Go model — packages acyclic, files within free).
File-level would tax the natural mutually-recursive-siblings case
(`element ↔ types`) for no architectural gain; library-level makes the
entire current corpus conform once `SourceSpan` is hoisted. A small program
pays nothing: one directory is one library, where all cycles are legal — the
constraint comes into existence exactly when a second directory (a declared
boundary) does. Staging per the governing loop: lint first, then `check`
error.

**Diagnostics.** A cycle is a property of a set of edges — there is no
principled single culprit — so the deterministic choice is to flag **every
import statement participating in a cycle**, each carrying the full path
(`import cycle: diagnostic → lexer/token → … → diagnostic`). A local edit
can therefore surface diagnostics in the cycle's other files; this is
acceptable because the blast radius is exactly the fix radius (the flagged
files are precisely those where an edit could break the cycle), the author
of the closing edge sees the error at the import they just wrote, and the
full path in the message makes it actionable from any end. The check is an
imports-only graph pass — no resolution, no types — so it runs first,
instantly, and never flickers with checker state.

**Open questions.** ~~(a) how many cycles / what shape~~ and ~~(b) file- or
library-level~~ — settled by the survey, above. Remaining: (c) does the
front-end's resolver already hold the import DAG in a form that makes the
lint cheap? (The loader builds the import closure — see
`pkgs/cli/loader.thera` — so likely yes.)

**Status:** direction settled; remaining work — hoist `SourceSpan` to a leaf
library, land the cycle lint, then promote to a `check` error. Graduates to
language.md § Import resolution + a roadmap _Language_ item.

### 2. Per-library separate checking

_Attacks: feedback-loop latency. **One design with item 1** — separate
checking needs an acyclic order to check in._

**Problem.** At 500k lines a whole-program `check` is minutes, and agent
throughput collapses with it. The target: an edit inside one library re-checks
that library and (only when its public surface changed) its dependents —
keeping the loop at seconds regardless of codebase size.

**Today.** `check` is whole-program. The visibility model already provides
the crucial ingredient: a library's `pub` surface **is** its interface, and
visibility is erased in bytecode — nothing downstream depends on private
internals.

**Direction.** Compute a per-library **interface digest** (a hash of the
`pub` surface: names, signatures, types). On an edit, re-check the edited
library; if its digest is unchanged, stop — dependents cannot be affected. If
it changed, re-check dependents (transitively, same rule). This also yields a
free, precise agent-facing signal: "your change altered the public surface of
X; these N libraries depend on it."

**Open questions.** (a) How far is the current checker from being callable
per-library (what global state does it thread)? (b) Where does the digest
cache live (`build/`, keyed how)? (c) Does `thera test` ride the same DAG
(only re-run tests of affected libraries)? (d) Interaction with the LSP's
incremental story.

**Status:** open. This is the item to decide **early** — it is an
architecture constraint on the checker that is cheap to honor now and brutal
to retrofit.

### 3. Barrel-enforced boundaries (no deep imports)

_Attacks: reading radius (a library's surface is real), trustworthiness (the
barrel doc describes everything reachable)._

**Problem.** Import resolution lets `import 'util/strings'` reach an
individual file inside a directory library, bypassing its barrel. That is how
"internal" surfaces become load-bearing at scale — once anything outside
imports an internal file, the library has two APIs, one undocumented. (The JS
ecosystem learned this the hard way; package.json grew an `"exports"` field
to ban deep imports.)

**Today.** Nothing distinguishes an outsider importing `util/strings` from a
sibling doing so. Barrels re-export via `pub import`, but consumers are not
required to come through them. The 2026-07 survey (item 1) counted **80 deep
imports** in `pkgs/cli` + `sdk/std`, heavily concentrated: 27 alone target
`lexer/token.thera` — a de-facto shared vocabulary library (`SourceSpan`,
`Token`) trapped inside `lexer/`, whose hoisting item 1 already requires.
(The survey also found 139 imports using `..` traversal — legal, and now
documented as such in language.md § Import resolution, which previously said
otherwise.)

**Direction.** Files inside a directory library are importable only by
siblings (same directory); outsiders go through the barrel. Then the barrel
really is the API, and its `pub import` list is the one place the surface is
defined. Staged: lint (survey violations in the corpus), then check error.

**Open questions.** ~~(a) does the corpus deep-import today~~ — yes, 80
sites (above); migration is real but concentrated, and the biggest offender
is fixed by item 1's `SourceSpan` hoist. Remaining: (b) is "same directory"
the right sibling rule, or "same library subtree" (nested dirs)? (c)
Interaction with test white-box access (`foo_test.thera` convention —
presumably unaffected, tests are siblings).

**Status:** open. Graduates to language.md § Visibility / § Import
resolution.

### 4. A package unit + manifest (declared dependencies, layering)

_Attacks: reading radius (enforced architecture), discoverability (an explicit
DAG to orient by). **Furthest out — dig after 1–3 settle the units.**_

**Problem.** Above ~one directory there is no unit that says what it may
depend on. Layering ("the parser must not import codegen") is a review
comment, not a check error — and review comments are exactly what erodes at
500k lines. An explicit, machine-readable dependency DAG is also an
orientation artifact for agents ("what does this sit on top of?") and the
natural invalidation unit for item 2's caching.

**Today.** No package concept: `std.*` plus relative file imports. `pkgs/cli`
is a de-facto package with de-facto internal layering (lexer → parser →
resolver → checker → codegen) enforced by nobody.

**Direction.** A manifest per package declaring (at least) its importable
dependencies. `check` errors on an import the manifest doesn't allow.
`pkgs/cli`'s pipeline is the first customer. Deliberately under-specified
until items 1–3 land — the manifest should describe units that already have
enforced boundaries.

**Open questions.** (a) Manifest format and location; (b) is a package a
directory-library or a coarser grouping of libraries? (c) does `std.*` get
manifests? (d) relationship to a future third-party package story (don't
design that here, but don't preclude it).

**Status:** open, deferred behind 1–3.

### 5. Generated API index

_Attacks: discoverability, trustworthiness. **Already tracked:** roadmap
_Developer tooling → Doc-comment tooling_, item (3) — the doc generator._

**The scaling frame.** The doc model defines the perfect atoms (barrel `//!`
package doc, standalone summary sentences); the aggregation is the missing
piece. A generated per-library index — one line per `pub` symbol: signature +
summary sentence — is *the* orientation artifact at scale: an agent reads the
index (~a page) instead of the source (~unbounded), and because it is
generated it cannot go stale the way a hand-written ARCHITECTURE.md does.
It also directly attacks convergent reimplementation: "search the index
before writing a helper" is a cheap, enforceable habit — and the repo-root
orientation that today lives in CLAUDE.md becomes mostly derivable.

**Direction — transport settled (2026-07).** The candidate transports (a
`thera doc` CLI, committed artifacts + a CI freshness check, a custom LSP
command, an MCP server) are not competing designs — they are transports over
one function, so the core is built **once** (doc extraction + index
formatting, in `pkgs/cli`, riding the loader/element data) and exposed in
order of agent reach:

- **Front door: `thera doc <lib>` to stdout** (plus `thera doc --index` for
  the workspace map). The shell is the one transport every coding agent has,
  and output consumed from a pipe **cannot be stale** — the exact
  trustworthy-prose property this item exists for. Output is terse,
  deterministic, stable-ordered text (the consumer is a context window):
  one line per `pub` symbol — signature + summary sentence. `--json` later
  if tooling needs it.
- **LSP shares the core** — hover and workspace-symbol serve the same data
  as the ambient editor surface (roadmap doc-comment tooling items 2–3). No
  custom LSP command: worst discovery of the four, and the thing agents
  drive least well.
- **MCP deferred** — a thin shim over the same core, addable the week a
  non-exec agent context needs it; until then it adds config burden without
  capability.
- **Committed artifacts rejected.** The staleness window is adversarial (an
  agent consults the index precisely while a change is in flight — exactly
  when a committed copy is wrong), and the regen/CI/merge-conflict tax is
  permanent. The bootstrap-snapshot precedent doesn't transfer: it is
  committed because it must be, and changes rarely; API docs change with
  every edit. The one unique benefit — API-surface changes visible in PR
  diffs — is item 2's job (interface digests), not checked-in docs.

**Discovery** is a prompting-surface problem with an existing reliable
channel: a best-practice line in each project's CLAUDE.md ("before reading a
library's source, run `thera doc <lib>`"), and/or the agent rules-file /
skill from the roadmap's _Idioms & best-practices guidance_ item — "navigate
Thera this way" lives beside "write Thera this way". Escape valve if that
proves insufficient: commit only the tiny, slow-changing root map, whose own
header teaches the tool — but wait for evidence before paying even that.

**Status:** transport settled; open — the index format itself, and
implementation sequencing (needs doc-comment tooling item 1, attach docs to
AST, first). Details in the roadmap entry.

### 6. Doctests — self-verifying examples

_Attacks: trustworthiness. **Already tracked:** roadmap _Developer tooling →
Verify the code snippets in docs_ (with design notes: fragment wrappers,
opt-in/out markers, rustdoc/Go prior art, the `tests/lang/` harness shape)._

**The scaling frame.** Code examples are the highest-value doc content for an
LLM — they are the thing it imitates — and also the doc content that rots
fastest. Compiling (and where possible running) fenced examples makes the
docs self-verifying, which is precisely the property that matters when the
primary reader trusts documents uncritically. The roadmap entry's own
motivating bugs (a doc teaching `loop { … }`, which is not Thera) are this
failure mode live.

**Status:** open; design and sequencing live in the roadmap entry.

### 7. Doc-reference integrity, promoted to errors

_Attacks: trustworthiness. **Already tracked:** roadmap _Doc-comment
tooling_, item (4) — reference resolution + lint._

**The scaling frame.** The principle to settle here: **anything the toolchain
can verify about prose, it eventually should** — unverified prose is a
liability at 500k lines. Concretely, a `[Symbol]` doc reference that no
longer resolves should follow the standard promotion path: lint → warning →
check error, same as a broken import. The digging question is the promotion
policy (when does a doc lint get teeth?), not the mechanism.

**Status:** open; mechanism in the roadmap entry, promotion policy here.

### 8. Mechanical refactors as CLI operations

_Attacks: sweeps. **Builds on:** the landed `lint --fix` machinery (roadmap
_Tools — refactorings_)._

**Problem.** The existing machinery rewrites *shapes in place* (`if let`,
`?`, combinators). Migrations also need the cross-file operations: **rename**
(symbol, field, library) and **change-signature** (add/remove/reorder
parameters, positional → labeled). With those as `thera` operations, an agent
decides *what* and the tool edits the 300 sites — sweeps become transactional
instead of a hand-edited long tail, which is what lets conventions converge
instead of forking.

**Direction.** `thera rename` first — it is resolution-complete (the LSP's
find-references is most of it) and the highest-frequency migration.
Change-signature second; it pairs with the calling-convention lint already on
the roadmap.

**Open questions.** (a) CLI shape (`thera rename <lib>.<symbol> <new>`?);
(b) shared machinery with LSP rename (should be the same code); (c) how a
rename interacts with doc references (item 7 — a rename should rewrite
`[Symbol]` mentions too).

**Status:** open.

### 9. Duplicate-helper detection

_Attacks: discoverability. **Speculative — dig last; may not pay for
itself.**_

**Problem.** Convergent reimplementation is silent: nothing flags a new
private `pad2` when `std.fmt` already exports one. Even a crude signal
converts the failure from silent to visible.

**Direction.** A lint that flags a new private helper whose name/signature
closely matches an existing `pub` symbol elsewhere (exact-name match first;
anything fuzzier is research). Honest uncertainty: the false-positive rate
may sink it — a survey of the current corpus (how many true duplicates exist?
would exact-name matching have caught them?) should precede any
implementation.

**Status:** open, speculative.

## What stays process

Genuinely process-level, not fixable by the language: task decomposition
(keeping each change small and verifiable), deciding *what* to build, review
judgment about design quality, and the orientation prose that explains *why*
the architecture is shaped as it is — generated indexes (item 5) say *what*;
intent still needs a human-authored paragraph (CLAUDE.md, the `//!` barrel
docs, this docs/ tree). The boundary is not static: the governing loop above
exists to keep moving discipline from the process column into the toolchain
column, and this doc's items are that loop applied to scale.

## Suggested order

1. **Items 1 + 2 together** — acyclicity + separate checking are one design,
   and the architecture decision that is cheap now and brutal to retrofit.
   The cycle survey is done (see item 1) and settled item 1's direction;
   next up: the `SourceSpan` hoist and the cycle lint.
2. **Item 5** (API index) — highest orientation payoff, machinery already
   half-planned.
3. **Item 3** (deep-import ban) — small, survey-first, sharpens the unit
   items 2 and 4 depend on.
4. **Item 6** (doctests), then **7** — the trustworthy-prose pair.
5. **Item 8** (rename, then change-signature) — as soon as a real sweep
   needs it.
6. **Item 4** (manifest/layering) when the units are settled; **item 9** only
   after its survey justifies it.
