# Self-hosting spike: a Hawk front-end slice

**What this is:** a scoped, time-boxed experiment that ports a small but
structurally representative front-end slice to Hawk, to learn what the language
still lacks **before** committing to the full Hawk-in-Hawk front-end
([roadmap.md](roadmap.md) arc 3). It is not the front-end — it is a probe, and
its real output is a *prioritized list of language gaps*.

## Why a slice, not a feature

The dominant risk on the self-hosting arc is not a feature we have already named
(interface inheritance, say) — it is **what we haven't discovered Hawk can't
express yet**. A speculative feature is a guess at the top blocker; a real port
*confirms* the blocker list and its priority. The same principle just played out
at library scale: writing real `std.cli` clients surfaced the actual ergonomic
gaps (see [stdlib.md](stdlib.md) § std.cli v2) far better than guessing would
have. We want that feedback at language scale before the big arc.

So the spike's job is to **let the port drive the feature list**, cheaply.

## Goal & non-goals

- **Goal:** port a tiny calculator front-end (lex → parse → eval) to Hawk,
  compiled by the Dart toolchain and run on the Rust runtime, and record where
  the language fights back.
- **Deliverables:** (1) a runnable slice with `@test`s — or a *documented wall*
  (the exact construct that blocked it); (2) a ranked language-gap list that
  feeds [roadmap.md](roadmap.md) / [interfaces.md](interfaces.md).
- **Non-goals:** the real Hawk grammar, completeness, performance, or replacing
  any Dart code. Throwaway by design; keep it under `examples/` or a scratch
  `pkgs/` dir.

## The slice: a calculator (lex → parse → eval)

A tiny language that is *structurally* a real front-end — recursive-descent with
precedence, a recursive AST, errors threaded through recursion — without grammar
sprawl.

```
program = expr EOF
expr    = term (('+' | '-') term)*          // left-assoc, lower precedence
term    = factor (('*' | '/') factor)*      // left-assoc, higher precedence
factor  = NUMBER | '(' expr ')' | '-' factor
NUMBER  = DIGIT+ ('.' DIGIT+)?
```

**Stretch (only if the core lands cleanly):** `let NAME = expr;` statements with
a `Map<String, Double>` environment — adds statements, scope lookup, and a
second AST node, exercising a bit more without much new risk.

Why this grammar: it forces the exact shapes a real parser has — operator
precedence, a self-referential AST enum, a token cursor, and `Result`-threaded
errors — while being finishable in a sitting.

## What we'd port (three stages, easy → hard)

1. **Lexer** — `String -> Result<List<Token>, LexError>`.
   `enum Token { Number(Double), Plus, Minus, Star, Slash, LParen, RParen, Eof }`.
   A cursor over `s.chars()` using `std.char` predicates. **Lowest risk; likely
   succeeds** — a confidence baseline (and a check that the just-landed
   `std.char` / string-escape work carries a real tokenizer).

2. **Parser** — `List<Token> -> Result<Expr, ParseError>`, recursive descent
   over a small mutable cursor struct `{ tokens: List<Token>, pos: Int }`.
   `enum Expr { Num(Double), Neg(Expr), Bin(Op, Expr, Expr) }` (a **recursive
   enum**). **The highest-information stage:** dense `match` on tokens, recursion
   returning `Result`, and precedence climbing will stress exactly the language
   edges we suspect (below).

3. **Evaluator** — `Expr -> Result<Double, EvalError>` (divide-by-zero is the
   one error). A recursive `match` over the AST — the `match`-as-only-branching
   idiom over a self-referential type.

Each stage ships behind `@test`s with golden inputs (`'1 + 2 * 3'` → tokens → AST
shape → `7.0`), so the spike is self-checking and the slice is runnable
(`examples/calc.hawk`).

## Language gaps we expect to hit (hypotheses to confirm)

These are predictions the spike will confirm, refute, or — most usefully — rank
by how *pervasive* each is in real front-end code:

- **No tail expressions.** Every helper ends in an explicit `return`; a
  block-bodied `match` arm yields `Unit`, not a value (felt already in
  `pkgs/cli`). A parser is match-dense, so this is likely the most pervasive
  friction. Candidate fix: block/`match`-arm tail expressions.
- **No nested patterns.** `match tok { Plus => … }` is fine, but a single arm
  can't destructure `Some(Number(n))` (worked around in `fs`/`process` tests).
  Recursive AST walks want this often.
- **No string slicing / substring.** Tokenizers reach for `s[i..j]`; today it's
  `chars()` + index loops (as `std.json` / `std.time` already do). Confirm how
  much it bites at parser scale.
- **No `if`-as-expression / ternary.** Computing a value from a condition needs
  a temp + statements; parser code has many small conditionals.
- **Recursive enums + `Map` ergonomics.** `std.json`'s `Json` already proves
  recursive enums work; confirm the parser's `Expr` and (stretch) a
  `Map<String, Double>` env are comfortable.
- **Mutual recursion / forward references** among a module's functions (the
  parser's `expr`/`term`/`factor` call each other). Confirm it just works.
- **Interface inheritance** (`interface Error: Display + Debug`). Does the slice
  *actually* want it — for its error types, and to use `assert_ok` on a
  `Result<_, Error>` — or is it a sideshow here? This spike is the cheapest way
  to find out whether it is on the critical path.

## Output & success criteria

- The slice compiles, runs, and passes its tests — **or** a documented wall
  naming the exact construct that blocked it (a wall *is* a result).
- A **ranked gap list**: each gap tagged pervasive / occasional, with a
  suggested language fix, appended to [roadmap.md](roadmap.md) (and
  [interfaces.md](interfaces.md) for dispatch-related ones). This is the real
  deliverable — it decides whether interface inheritance, tail expressions,
  nested patterns, or string slicing is the next language task.
- A short note on which Dart front-end structures should change to mirror the
  *validated* Hawk shape — input to the eventual restructure (don't restructure
  speculatively first; let the spike teach the target shape).

## Sizing

Small and time-boxed: the lexer is a sitting, the parser is the bulk, the
evaluator is short. If the parser hits a hard wall, **stop** — that wall is the
finding; prioritize the fix and resume.

## Spike results (2026-06)

The full slice landed: `pkgs/calc/` is a working `lexer` → `parser` → `eval`
pipeline with 13 tests and an end-to-end `main` (`hawk run pkgs/calc/main.hawk
-- '1 + 2 * 3'` → `7`; `'5 / (3 - 3)'` → `error: division by zero`). **The
headline result: Hawk can already express a complete small front-end** — no hard
walls.

### What worked, with no friction (the encouraging core)

- **Directly-recursive enums.** `enum Expr { Num(Double), Neg(Expr), Bin(Op,
  Expr, Expr) }` — an enum holding itself directly (two recursive fields in
  `Bin`), no boxing or indirection needed. This is the shape every AST has, and
  it was the biggest open risk; it just works.
- **Mutually recursive functions** (`parse_expr` ↔ `parse_term` ↔ `parse_factor`
  ↔ `parse_expr`) — no forward declarations needed.
- **`match` on variants with payload binding** (`Number(n)`, `Bin(op, l, r)`),
  and **`?` propagation inside match-arm blocks** and through recursion.
- **Structural `Eq`/`Debug` on recursive enums** → `assert_eq` compares whole
  ASTs out of the box (`assert_eq(actual: ast('1+2*3'), expected: Expr.Bin(...))`).
  This is a large win for testing a compiler.
- **Per-domain error enums** (`LexError`/`ParseError`/`EvalError`), each `impl
  Error`, unified as `Result<_, Error>` across stages via `?` subsumption.
- A **mutable cursor struct** (`Parser { pos }`) with in-place `self.pos = …`.
- `std.char`, `chars()`, `String.from_chars`, `to_double`, list push/index, and
  cross-module sibling imports (`import 'lexer'`) — all comfortable.

### Gaps & friction, ranked

1. **No tail expressions — pervasive; the clear #1.** A block-bodied `match`
   arm (or `if`/block) yields `Unit`, never its last expression, so any arm that
   *computes* a value must `return` it or assign a `mut`. I hit this instinctively
   in the lexer (`Some(n) => { tokens.push(…); Result.Ok(i) }` doesn't typecheck).
   The forced idiom is "statement-position `match` where every arm `return`s,"
   and `let x = match … { … }` is unavailable whenever an arm needs more than one
   statement to produce its value. For match-dense compiler code this is the
   dominant ergonomic tax. **Recommended next language task:** allow a block's
   final expression to be its value (at minimum in `match` arms / `if` / block
   expressions). (The statement-match-all-arms-`return` form *is* accepted as a
   function's terminator, with no trailing `return` — that much is fine.)

2. **No `if`-as-expression — occasional; same family as #1.** Computing a value
   from a condition needs a temp + statements. Subsumed by a tail-expression fix.

3. **No `match` on named constants — minor, lexer-only.** Patterns must be
   literals, so dispatching on character *classes* (`char.PLUS`, …) is an
   if-else ladder rather than a `match` (int-literal patterns work but mean magic
   numbers). A real lexer tolerates the ladder; `match` guards or const patterns
   would be nicer.

4. **No list/string slicing — minor, recurring.** Wrote a `slice(List<Int>)`
   helper yet again (as `std.json`/`std.time` each did). A `List.slice` (and
   string substring) would retire boilerplate every scanner reinvents — worth a
   stdlib add even before any language change.

### A notable *negative* result

**Interface inheritance was never wanted by the spike.** Each stage used a
concrete error enum with an explicit `impl Display`, `assert_err` (no `Debug`
bound) covered the error tests, and only the top-level `main` called
`e.message()`. So `interface Error: Display + Debug` is **not** on the critical
path for front-end code — it stays a general ergonomics cleanup, not a
self-hosting blocker. (Nested patterns also went unused: the grammar's matches
are single-level.)

### Verdict

The next language task that most improves front-end ergonomics is **tail
expressions (#1)** — it shapes every function and is felt on nearly every match.
That ranks ahead of interface inheritance for the self-hosting arc. The slice
itself can grow (the `let`-binding stretch, better error positions) but has
already served its purpose: it turned "what might Hawk lack?" into a ranked list.

The validated shapes here (recursive AST enums, a mutable cursor struct,
`match` + `?`, structural `Eq`/`Debug` for AST diffing) are the foundation the
full-port architecture builds on — see [frontend_in_hawk.md](frontend_in_hawk.md),
which turns these findings into the batch-port plan, the Dart→Hawk mapping, and
the gating language work.
