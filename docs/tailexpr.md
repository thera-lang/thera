# Tail expressions — spec & sizing

**What this is:** the design for making a block's final expression its value
(and, with it, `if`/`match` usable in value position), plus a component-by-
component estimate of how large the arc is. Motivated by the self-hosting spike,
where "no tail expressions" was the #1 friction ([selfhosting.md](selfhosting.md)).

## The feature

Today a block runs statements and yields `Unit`; a value-producing branch must
`return` or assign a `mut`. The change: **the final expression of a block — an
expression with no trailing `;` — is the block's value.** Since `if`/`match`
arms are blocks, they then yield values too.

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

**Semicolon rule (Rust's, and consistent with our existing require-`;` work):**
within a block, every statement ends in `;` *except* a final expression with no
`;`, which is the tail. `{ f(); g() }` → `g()` is the value; `{ f(); g(); }` →
value is `Unit` (g discarded). This dovetails with the current rule that a
bare block-terminated `match` needs no `;`.

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

1. **AST (small).** Add `Block.tail: Expr?`. Add an `IfExpr` node (condition +
   then/else blocks) for the value form — or make `if` always an expression and
   let statement position wrap it in an `ExprStmt` (cleaner long-term, slightly
   more refactoring).
2. **Parser (medium — the fiddliest part).** In `_parseStmt`/`_parseBlock`: when
   an expression is the last item before `}` and is not followed by `;`, attach
   it as the block's `tail` rather than erroring (today line ~608 does
   `_expect(';')`). Plus parse `if` in expression position. If `if` becomes
   always-expression, the statement/expression split disappears and this is the
   bulk of the work.
3. **Inference (small–medium).** `_inferBlock` returns the tail's type (Unit when
   absent). `BlockExpr` types as its block's tail. `IfExpr` unifies then/else
   (and requires an `else`). `MatchExpr` already unifies arm types — block arms
   fall out once `BlockExpr` carries the tail.
4. **Checker (small).** A value-position `if`/block must actually produce a value
   (else-branch present; tail present). Match exhaustiveness is already handled.
5. **Codegen (small–medium).** Three spots: `BlockExpr` emits the tail value
   instead of `constUnit`; `_block` in **statement** position pops/discards a
   tail value (it's unused there); `IfExpr` leaves a value from each branch and
   merges (mirrors the existing `_matchExpr` merge-label pattern). Match block
   arms then "just work."
6. **Runtime:** none.

**Estimate:** a **medium arc** — bigger than the slice spike, well short of the
generics or interface-dispatch arcs. Splittable (see Staging).

## Design decisions (the "stays easy to read / internally consistent" part)

- **Does a function body's tail become an implicit return?**
  `fn add(a: Int, b: Int) -> Int { a + b }`. If a block yields its tail and a
  function body is a block, then *yes, naturally*. This is the one real tension
  with Hawk's explicit, errors-as-values, "boring" ethos (two ways to return).
  Two consistent options:
  - **(A) Allow it.** A block is a block everywhere; most-aligned with LLM
    priors; keep `return` idiomatic for early exits. Recommended, with a style
    note that multi-statement functions still tend to read better with `return`.
  - **(B) Restrict tails to expression position.** Tails yield values only in
    `let`/arg/`match`-arm/`if`-branch position; a function body still requires
    explicit `return` (a bare tail there is an error). Preserves "functions
    return explicitly," at the cost of "a block sometimes yields, sometimes
    doesn't," which is *less* internally consistent.

  The choice is really "is a function body a value-position block?" (A) is
  simpler to explain ("the last expression is the value, always"); (B) keeps a
  cherished invariant. Worth deciding before implementing — it shapes the parser
  and checker rules.
- **`if` with no `else` in value position** → error (can't produce a value);
  fine as a statement.
- **`return`/`throw` as tails** already work via `ReturnExpr`/`ThrowExpr`; they
  have type `Never`-ish (diverge), so they unify with any sibling arm/branch.

## Staging

1. **Block + match-arm tails** (no `if`-expr). This alone retires the #1 spike
   friction (match-arm value blocks) and the awkward `mut`/helper workarounds.
   Smallest useful slice.
2. **`if`-as-expression** (`IfExpr` or always-expression `if`). The natural
   completion; gives `let x = if c { a } else { b }`.

Decide decision (A)/(B) first; it applies to both stages.
