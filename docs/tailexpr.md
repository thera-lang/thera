# Tail expressions — spec & sizing

**What this is:** the design for making a block's final expression its value
(and, with it, `if`/`match` usable in value position), plus a component-by-
component estimate of how large the arc is. Motivated by the self-hosting spike,
where "no tail expressions" was the #1 friction ([selfhosting.md](selfhosting.md)).

## The feature

Today a block runs statements and yields `Unit`; a value-producing branch must
`return` or assign a `mut`. The change: **in expression position, the final
expression of a block — an expression with no trailing `;` — is the block's
value.** Since `if`/`match` arms are blocks, they then yield values too.

**Decided scope: expression position only; function returns stay explicit.**
A block yields a value where a value is expected — a `let` initializer, a `match`
arm, an `if`/`else` branch, an argument. A **function body still returns with an
explicit `return`** (a bare trailing expression there is not a return — it's the
existing require-`;` rule). See the rationale under Design decisions; we can
revisit if dogfooding says the explicit-return tax is too high.

```hawk
// today (works): single-expression arms
let sign = match ord { Less => -1, Equal => 0, Greater => 1 };

// today (does NOT compile): an arm that needs a statement + a value
let label = match tok {
    Number(n) => { let s = format(n); 'num: ' + s },   // block yields Unit, not 'num: …'
    _ => 'other',
};

// with tail expressions: the block's last expression is its value
let label = match tok {
    Number(n) => {
        let s = format(n);
        'num: ' + s          // ← tail
    },
    _ => 'other',
};

// and `if` becomes usable in value position
let max = if a > b { a } else { b };
```

**Semicolon rule (consistent with our existing require-`;` work):** in an
expression-position block, every statement ends in `;` *except* a final
expression with no `;`, which is the tail. `let x = { f(); g() }` → `x` is
`g()`'s value; `let x = { f(); g(); }` → `x` is `Unit` (g discarded). A bare
trailing expression with no `;` is **only** legal in expression position;
elsewhere (function bodies, `if`/`while`/`for` statement bodies) the current
require-`;` rule is unchanged, so `return` stays the way a function produces its
result. This also keeps the implementation boundary clean: tails live in the
`BlockExpr` / match-arm / `if`-expression parse paths, not the statement-level
block parser.

## Why it generalizes (not just a parser nicety)

Most languages an LLM has seen (Rust, Kotlin, Scala, ML, Ruby) make the last
expression the value, so a model *instinctively* writes `let x = if c { a } else
{ b }` or a value-yielding match block — which today is a compile error and a
wasted iteration. Closing the gap makes the obvious thing compile. The shape
(compute a value by cases) is pervasive in ordinary code, not just parsers.

## Current representation (what's already there)

The AST is already partway here:

- `MatchExpr` is an **expression**; `MatchArm.body` is an `Expr`; a `{…}` arm is
  a `BlockExpr` wrapping a `Block`. `ReturnExpr`/`ThrowExpr` exist so `=> return
  x` works in an arm.
- `Block` is a bare `List<Stmt>` with **no value slot** — the missing piece.
- `BlockExpr` codegen is literally `_block(block); emit(constUnit)`
  (`codegen.dart`) — the one line that throws the value away.
- `if` is **`IfStmt` only** (statement); there is no `IfExpr`.
- The runtime is **not involved**: "block yields Unit" is purely a codegen
  decision. Tail expressions lower to the same stack ops already used by
  `_matchExpr` (which merges per-arm values at a label). **No bytecode or
  interpreter change.**

## The arc, component by component

Front-end only. Roughly ordered by effort:

1. **AST (small).** Add a tail slot to the expression-position block — either
   `BlockExpr.tail: Expr?` or `Block.tail: Expr?` populated only when the block
   is parsed in expression context. Add an `IfExpr` node (condition + then/else
   blocks) for the value form. (The statement-level `Block` and `IfStmt` are
   unchanged.)
2. **Parser (medium — the fiddliest part).** Tails are parsed only on the
   expression paths — `BlockExpr`, `match` arms, and `IfExpr` branches: when an
   expression is the last item before `}` and isn't followed by `;`, attach it
   as the tail. The statement-level `_parseBlock` keeps the current require-`;`
   rule untouched, so function bodies are unaffected. Plus parse `if` in
   expression position.
3. **Inference (small–medium).** An expression-position block types as its tail
   (Unit when absent). `IfExpr` unifies then/else (and requires an `else`).
   `MatchExpr` already unifies arm types — block arms fall out once the block
   carries the tail.
4. **Checker (small).** A value-position `if`/block must actually produce a value
   (else-branch present; tail present). Match exhaustiveness is already handled.
5. **Codegen (small–medium).** Two spots: `BlockExpr` emits the tail value
   instead of `constUnit`; `IfExpr` leaves a value from each branch and merges
   (mirrors the existing `_matchExpr` merge-label pattern). Match block arms then
   "just work." The statement-level `_block` and `IfStmt` paths don't change.
6. **Runtime:** none.

**Estimate:** a **medium arc** — bigger than the slice spike, well short of the
generics or interface-dispatch arcs. Splittable (see Staging). Scoping tails to
expression position (below) keeps it on the smaller end: the statement-level
block parser and codegen are untouched.

## Design decisions

- **Tails are expression-position only; function returns stay explicit
  (decided).** A block yields a value where a value is expected (`let`
  initializer, `match` arm, `if`/`else` branch, argument). A **function body
  still returns with `return`** — a bare trailing expression there is not a
  return. The rule reads as *"expressions yield their last value; functions
  return explicitly,"* which is close to how the AST already splits `BlockExpr`
  from a statement-position `Block`.

  This deliberately **declines** implicit function return
  (`fn add(a, b) -> Int { a + b }` stays `{ return a + b; }`). The reasons,
  weighed against the Rust-style "a block is a block everywhere" alternative:
  - It preserves Hawk's explicit-return ethos — the value a function produces is
    always marked.
  - It removes the one real footgun: the `;` flip
    (`{ …; foo() }` vs `{ …; foo(); }`) silently changing a *return* value. With
    function bodies non-value-position, that case can't arise; in expression
    position the static expected type catches a wrong-typed tail at compile time.
  - The cost is small and familiar: `return x;` in functions (as today), and the
    occasional helper instead of a one-line implicit-return function.

  **Revisit if** dogfooding or other feedback shows the explicit-return tax
  outweighs the safety — the expression-position machinery would already be in
  place, so extending tails to function bodies later is additive.
- **`if` with no `else` in value position** → error (can't produce a value);
  fine as a statement.
- **`return`/`throw` as tails** already work via `ReturnExpr`/`ThrowExpr`; they
  diverge, so they unify with any sibling arm/branch.

## Staging

1. **Block + match-arm tails** (no `if`-expr). This alone retires the #1 spike
   friction (match-arm value blocks) and the awkward `mut`/helper workarounds.
   Smallest useful slice.
2. **`if`-as-expression** (`IfExpr` or always-expression `if`). The natural
   completion; gives `let x = if c { a } else { b }`.

Decide decision (A)/(B) first; it applies to both stages.
