# Parser error recovery

**What this is:** the design and staged plan for making Hawk's parser *resilient* —
producing a structurally useful AST from incomplete or malformed source, so the LSP
can offer completion/hover mid-keystroke and the compiler can report precise,
non-cascading errors.

## Goals & non-goals

- **Primary goal — code completion.** The LSP parses source that is *almost always*
  in a syntax-error state (the user is mid-type). Completion, hover, and signature
  help need an AST that (a) preserves the declarations and statements *around* the
  cursor and (b) carries a node **at the cursor** to anchor the query (`obj.` must
  yield a member access whose member is "the thing being typed").
- **Secondary goal — error-message quality.** Recovery should yield **one precise
  error per real hole** (today: one per declaration), and — crucially — must **not
  cascade**: a syntax hole must not spawn a flurry of downstream *semantic* errors
  ("undefined name `''`", "expected Int, found Void").
- **Hard constraint — valid input parses unchanged.** Recovery must be a **no-op on
  well-formed source**. The self-hosting **fixpoint** enforces this for free: the
  whole front-end + stdlib + corpus is well-formed, so any regression in happy-path
  parsing changes the emitted bytecode and breaks the build. Recovery's only
  behavioral surface is *broken* input, which the fixpoint doesn't cover but the new
  recovery tests do.
- **Non-goals.** Incremental/cached reparse (that's the LSP-v2 engine item);
  *semantic* recovery beyond "don't cascade"; and perfect trees for adversarial
  garbage (best-effort is fine — the test is real mid-typing, not fuzzing).

## Two consumers, one AST

The same parser feeds the **compiler** (`check`/`emit`) and the **LSP**. Their needs
differ and occasionally conflict:

| | wants |
|---|---|
| **LSP** | the *maximal* partial tree — keep going past every hole, preserve a node at the cursor |
| **compiler** | precise errors, **no semantic cascade** from synthesized nodes; for cross-file resolution, keep a broken decl's *signature* |

These reconcile through one rule: **recovery synthesizes nodes, and those nodes carry
a marker the resolver/checker treat as "incomplete — analyze leniently, report
nothing."** That marker is what lets the LSP keep the rich tree while the compiler
stays quiet on the holes.

## Where we are today

The parser uses a **panic flag** with a single recovery point (`parser.hawk`):

- `fail`/`fail_at` record **one** error and set `panicking`.
- While `panicking`, `advance`/`match_kind` freeze (consume nothing) and **every parse
  loop** is guarded `while … && !self.panicking && …`, so the whole declaration
  unwinds without consuming or recording further errors.
- `parse_decl_or_recover` is the *only* place the flag clears: it `sync_to_decl`s
  (skips to the next top-level keyword) and drops the failed declaration.
- Throwaway nodes (`err_expr → Unit`, `err_type → NamedType{name:""}`, …) are returned
  during the unwind and **discarded** at the boundary.

What's **good** and worth keeping: it never cascades, never spins, and is simple —
the freeze + single sync gives termination, anti-cascade, and forward progress in one
mechanism.

What it **can't** do for our goals:

1. **It destroys the leaf node the completion engine needs.** `obj.` deep in a
   function panics and unwinds to the *declaration* boundary — the `Field` node, and
   everything else in that function, is gone. Completion has nothing to anchor on.
2. **No intra-declaration recovery.** An error in one statement discards the rest of
   the function body (only sibling *declarations* survive — the motivation that "the
   rest of the file is discarded" is an overstatement; the rest of the *decl* is).
3. **No suppression marker.** The throwaway `Unit` even *mis*-types — it's `Void`, so
   in a typed slot (`let x: Int = <hole>`) it would cascade into a type-mismatch *if*
   it were kept. Any move to keep partial nodes needs an explicit "incomplete" signal.
4. **One error per declaration**, where we want one per hole.
5. **No signature-past-body recovery** (needed by whole-closure diagnostics).

## The core decision: recover *known holes* in place; unwind only when lost

The panic-freeze is right for one situation and wrong for another:

- **A known hole** — the parser knows exactly what token it wanted (`)`, a field name
  after `.`, an expression after `=`). Here it should **fill the hole and keep
  parsing**: record the error, synthesize the node, *do not* unwind. This preserves
  the surrounding tree and the cursor anchor — what completion needs.
- **Genuine confusion** — the parser is at a token that can start nothing sensible
  (garbage mid-statement). Here unwinding to a recovery point and re-syncing is right;
  there's no meaningful partial node to keep anyway.

So we **keep `panicking`** as the "I'm lost → unwind and resync" mechanism, but make
**`expect` non-fatal** so known holes no longer trigger it, and we **add finer
recovery points** (statement and block, not only declaration) so the rare unwind is
*contained*. This is incremental — most loops keep their `!panicking` guard, which
still does its job for the lost case — and it's provably safe on valid input (the
non-fatal and unwind paths are simply never taken there; the fixpoint confirms it).

## Design

### 1. Non-fatal expectation (the leaf)

`expect(kind)` on a mismatch **records the error and returns a synthetic token** of the
expected kind — empty text, **span anchored at the cursor offset** — *without*
consuming input and *without* setting `panicking`. Parsing continues.

- A missing delimiter (`)`, `}`, `;`, `>`, `,`) is recorded; the enclosing loop closes
  on its structural check. One error per actually-missing token.
- `obj.` → `expect(Identifier)` fails → `Field(obj, "")`. The empty field name *is* the
  completion anchor; the cursor span tells the LSP where.

The span fidelity is load-bearing: a synthetic token at the wrong offset silently
breaks completion. The cursor's current span is correct here (today's `err_*` helpers
already use `self.current().span`).

### 2. Placeholder nodes + the suppression contract

- **Add one AST node: `Expr.Error(SourceSpan)`** — "an expression was required but none
  could be parsed" (`let x =` ⏎, `a +` ⏎, an empty argument slot). It replaces the
  `err_expr → Unit` hack and, unlike `Unit`, **types as `Unknown`** (lenient,
  assignable everywhere) — so it never triggers a type-mismatch cascade.
- **Empty-name convention for member/type holes.** `obj.` → field `""`; a missing type
  → `NamedType{name: ""}`. The lexer never produces an empty identifier from valid
  source, so *empty name == recovery hole*. (Minimal AST churn — no new variant for
  these; revisit if the convention proves leaky.)
- **Downstream contract (the anti-cascade rule).** The resolver, checker, and inference
  treat `Expr.Error` and empty-name members/types as `Unknown` and emit **no semantic
  diagnostic**. This is precisely what preserves error-message quality: the user sees
  the *syntax* error, not ten spurious semantic ones. Codegen gets a defensive arm
  (`Expr.Error` → trap) that is **unreachable in practice** — `emit` runs only after a
  clean `check`.

This is the contract the original "synthetic tokens, no Error nodes" sketch was
missing: synthesizing nodes without a suppression signal *degrades* error quality.

### 3. The forward-progress invariant

This is the property `panicking`'s freeze gave implicitly, and the one most easily lost
once `expect` stops unwinding: **every recovery loop must consume ≥1 token per
iteration or terminate.** Concretely, a list loop (`while !check(close) && !at_end()`)
that calls a sub-parser which *can* return without consuming (a synthetic fill) must,
when it sees no progress *and* is at neither the close delimiter nor a valid
element-start, record an error and force one `advance()`. State it once, apply it to
every list/sequence loop; it is the anti-spin guarantee.

### 4. Statement/block resync for genuine confusion

When the parser is truly stuck — a statement that can't begin, an expression position
holding a token that starts nothing and isn't a known hole — it records an error and
unwinds (`panicking`) to the **nearest** recovery point. We add two below the existing
declaration point:

- `parse_stmt_or_recover` in the block loop: clears the flag, `sync_to_stmt` (advance
  to the next `;` / statement keyword / `}`), and contributes a `Stmt.Expr(Expr.Error)`
  (or nothing). Siblings before *and* after the bad statement survive.
- The declaration loop keeps its `parse_decl_or_recover` / `sync_to_decl`.

Each `*_or_recover` must honor the progress invariant (advance ≥1 token on the error
path) so the enclosing loop can't spin.

### 5. Signature-past-body recovery

A broken **body** must not drop the **signature**. `fn name(p: T) -> R { <broken> }`
recovers to a `FnDecl` with its real signature and a body of recovered/`Error`
statements; a malformed `{ … }` on a `type`/`enum` keeps the decl with the fields that
parsed. This is the highest-value case for the *compiler* path: it lets a dependent in
another file resolve against the signature even when the body is malformed — the
direct dependency named by the *whole-closure diagnostics* roadmap item (cascade
suppression / cause-naming). Mechanically it falls out of statement-level recovery (the
body's block recovers internally) plus *not* propagating a body failure up past the
signature.

### 6. Multiple, deduped errors

Recovery naturally yields one error per hole. Guard against pile-ups: suppress a second
error at the same offset (don't stack "expected expression" + "expected `;`" on one
spot), and optionally cap total errors per file. Tune the heuristics against real
broken files.

## Recovery cases (the catalog the test suite must cover)

For each, the test asserts the **recovered tree** (or the **completion result at the
cursor**) *and* that the well-formed counterpart is unchanged.

**Declarations**
- Incomplete function: `fn foo(a: Int` (missing `)`/body); `fn foo() {` (missing `}`).
- Incomplete struct/enum: `struct User { let name:` (missing type and `}`).
- Mid-`impl` edit: a half-typed `fn bar(` between two valid methods.
- **Signature-past-body:** `fn f() -> Int { <garbage> }` keeps `f`'s signature.

**Statements**
- Missing `;`: `let x = 5` then a statement on the next line.
- Mid-body edit: `let y =` between two valid statements (preserves both).
- Incomplete control flow: `if cond {`, `match v {` (missing arms).

**Expressions / completion triggers**
- **Dangling dot:** `user.`, `xs.map(x => x.)` → member access with empty member at
  the cursor.
- Incomplete call: `f(a,` (next argument); unterminated `f(`.
- Incomplete operator: `let x = a +` (missing RHS → `Binary(a, +, Error)`).
- Unclosed string: `let s = "hello` (lexer-side hole; recovery must still frame the
  statement).

**Position-sensitive completion (easy to forget)**
- Type position: `let x: ` / `fn f(a: ` — a type-name hole the LSP completes.
- Statement-keyword position: `{ l| }` (complete `let`).
- Import path: `import '|'`.

## Testing

- **Oracle.** Two complementary mechanisms: (a) a **structural AST dump** — extend
  `ast/describe.hawk` to a full indented/s-expr printer — with golden expectations;
  and (b) a **behavioral `complete_at(source, offset)`** that returns the completion
  items, asserted directly. Prefer (b) for the completion-trigger cases — it tests the
  actual customer, not a proxy.
- **Location.** These pin *implementation behavior*, not the language spec, so they
  live in the `@test` suite (`pkgs/cli/parser/recovery_test.hawk`), **not** `tests/lang`.
- **Every case asserts two directions:** the broken input yields the expected partial
  tree/completion, **and** the well-formed counterpart parses unchanged. The build's
  fixpoint already guards the no-op-on-valid invariant globally; these lock it locally
  and document intent.

## Staged plan

Each stage is independently useful and **fixpoint-clean** (valid input untouched).

- **Stage 0 — contract first (no recovery yet).** Add `Expr.Error`; route the existing
  `err_*` throwaways to it; give the resolver/checker/inference their lenient arm and
  codegen its defensive trap. Add the structural AST dump + the recovery test harness.
  This establishes the **suppression contract before any partial node is produced** —
  fixing the original plan's entanglement, where synthetic nodes would have cascaded.
  Pure scaffolding; byte-identical fixpoint.
- **Stage 1 — non-fatal `expect` + progress invariant.** `expect` records + returns a
  synthetic token instead of failing; add the forward-progress guard to the list loops.
  Now a missing delimiter / `obj.` / `a +` yields a *partial node* instead of a
  discarded declaration — the first real completion win. The lost case still unwinds to
  the declaration boundary (today's behavior), which is fine for now. (Load-bearing
  flip; the fixpoint proves valid input is unchanged because the non-fatal path is
  never taken there.)
- **Stage 2 — statement-level recovery + signature-past-body.** Add
  `parse_stmt_or_recover` / `sync_to_stmt`; the block loop recovers per statement, so
  siblings survive and a broken body keeps its signature. Retire `!panicking` guards as
  each loop is touched and confirmed handled by the structural + progress checks.
- **Stage 3 — graceful EOF, completion polish, full case suite.** Synthesize closing
  delimiters when EOF lands inside an open block/expression (unwind to the root rather
  than dropping outer decls); verify every dot/type/keyword/arg anchor carries the
  cursor span; build out the catalog and validate against `complete_at`.
- **Stage 4 — cleanup.** Once no site sets `panicking`, remove the field; finalize
  error dedup/cap.

The ordering rationale: **the contract (Stage 0) precedes the first partial node
(Stage 1)**, so recovery never ships a cascade; and the leaf win (Stage 1) precedes the
sibling/structural work (Stage 2–3), so the highest-value completion behavior lands
first.

## Risks & open questions

- **Empty-name convention vs. an explicit per-hole marker.** The convention is cheap
  and needs no new node for member/type holes; if it proves leaky (some real path wants
  an empty name), switch those to a marker. `Expr.Error` is the explicit marker for the
  expression case where mis-typing (`Unit`/`Void`) actively cascades.
- **Resync granularity.** Statement vs. expression-level resync changes how much
  survives around garbage; tune against the catalog, not in the abstract.
- **Completion's exact contract.** Does the engine want the `Field(obj, "")` node, or a
  dedicated cursor sentinel? Settle when wiring `textDocument/completion` (the dependent
  LSP item) — the parser just needs to guarantee *a node with the cursor span* exists.
- **How much to keep vs. drop on adversarial input.** Best-effort is the explicit
  stance; the suite encodes realistic mid-typing, and the cap/dedup heuristics bound the
  worst case.
