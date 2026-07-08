# Formatter v2 — intra-line spacing

The design for the next `hawk fmt` step: normalizing horizontal spacing _within_
a line (`fn  foo( a:Int )` → `fn foo(a: Int)`), the remaining piece of the
"eliminate ~99% of format discussion" goal. v1 (indentation) is described in
[roadmap.md](roadmap.md#developer-tooling); this doc covers only the intra-line
work. Unbuilt — this is the plan.

## The problem, precisely

v1 ([`pkgs/cli/fmt.hawk`](../pkgs/cli/fmt.hawk)) is a **whole-line** pass: it
re-indents lines and collapses blank runs but never touches within-line content,
which is exactly why "it moves only whole lines, so tokens are preserved and it
can never break a compile." v2 must edit _inside_ lines while keeping that
guarantee.

The AST is the wrong tool to drive it. By design the tree keeps only **node
spans**, not the spans of the connective tokens between them — keywords (`fn`,
`let`, `mut`, `else`) and delimiters (`<`, `>`, `(`, `:`, `->`, `,`). This is
why the refactoring machinery
([`pkgs/cli/fix/fix.hawk`](../pkgs/cli/fix/fix.hawk)) hand-writes scaffolding —
`'let ${ctor}(${name}) = ${subj} else ${els};'` — rather than slicing it from
source: the keywords and punctuation are simply not recoverable from the AST. An
AST pretty-printer for the formatter would hit the same wall, needing every one
of those omitted tokens.

The correct reading of that limitation: **don't reconstruct text from the AST.**
Drive from the **token stream** — which retains everything, keywords included —
and use the AST (or a parser side-channel) only as a sparse _role oracle_ for
the few tokens whose spacing is genuinely ambiguous.

## Core model: gap-edits, not rebuild

Treat the source as tokens `T₀…Tₙ` with whitespace **gaps** between them. For
each adjacent pair on the _same line_, compute the canonical gap (0 or 1 space)
and emit a `TextEdit` ([`pkgs/cli/edit/edit.hawk`](../pkgs/cli/edit/edit.hawk))
only where the actual gap differs. Lines are never rebuilt from tokens;
whitespace is spliced into the original string. Four properties follow for free:

- **Comment-safe with zero attachment logic.** Hawk has only line comments (`//`
  → end of line), so a comment always ends its line and the next token is always
  on a later line → its gap is a line-break gap → skipped. **No two same-line
  tokens can have a comment between them.** This fully decouples intra-line
  spacing from the deferred _comment-attachment_ problem that gates doc-comment
  tooling; v2 does **not** depend on it.
- **Token-preserving.** Only inter-token whitespace is rewritten; every lexeme
  stays byte-identical. v1's "can't break a compile" guarantee carries over.
- **Minimal diffs.** Like `fix`, only changed gaps move.
- **Composes with what exists.** Reuses `TextEdit` / `apply_edits` and the
  code-point offset model already shared with the AST's `SourceSpan`s.

### Pipeline

```
source ─▶ [Stage A: intra-line spacing] ─▶ spaced source ─▶ [Stage B: v1 indent] ─▶ output
```

Stage A is new; Stage B is today's `format_source`, unchanged. A emits a new
string; B re-lexes it — no offset threading between them. Both are idempotent,
so the composition is idempotent. If the file **does not parse**, Stage A is
skipped and behavior falls back to today's indentation-only pass (fmt is already
scoped to syntactically-valid files, so requiring a parse for _spacing_ is
acceptable).

### Safety net: round-trip check

The one obvious hazard is collapsing a gap to 0 and **fusing** two tokens (`let x`
→ `letx`, `-` `>` → `->`, `=` `=` → `==`). Guard it structurally (never 0 between
two word-ish tokens) **and** verify: after Stage A, re-tokenize the result and
assert the token kind+lexeme sequence is identical to the input.

But — discovered in implementation — a **lexer-level** round-trip is *not
sufficient*. Hawk's shift operators `<<` / `>>` / `>>>` are **not** lexer tokens;
the *parser* recognizes them by combining **adjacent** single `<`/`>` tokens
(`shift_op_ahead`, gated on `adjacent()` = touching offsets). Spacing `v >>> 8`
into `v > > > 8` leaves the token kinds/lexemes **identical** (three `Gt`) — the
lexer round-trip passes — yet the parse breaks, because the `>`s are no longer
adjacent. Two-part fix:

1. **Adjacent angle brackets stay tight.** In valid source, two touching `<`/`>`
   tokens are always either a shift operator or a nested-generic close
   (`List<List<Int>>`); both want 0. So `is_angle(a) && is_angle(b) ⇒ 0` — the
   rewrite never separates them.
2. **Re-parse guard.** The round-trip also re-parses the result and requires no
   new errors, catching any *offset-only* parser-level change the lexer can't see.
   On any failure (token mismatch or parse error) Stage A returns the source
   untouched. This makes "never breaks a compile" a genuinely _checked_ invariant.

(A subtlety worth stating: an empty gap — two already-adjacent tokens — is still a
candidate, since a *missing* space may need inserting, e.g. `Point{` → `Point {`.)

## Where the AST is actually needed

Walking the local token pair resolves almost everything. Working the cases:

- **Unary vs binary `-` does _not_ need the AST.** A local rule suffices: `-` is
  binary iff the previous token is a value-ender (identifier, literal, `)`, `]`,
  `?`, or a generic-closing `>`); otherwise it is prefix-unary. No Hawk
  counterexample exists — `return -1`, `= -1`, `[a, -1]`, `(-1)` all have
  non-value-ender predecessors. `!` and `~` are _always_ prefix in Hawk (no
  postfix `!`), needing nothing.
- **`<` / `>` are the sole irreducibly-ambiguous case.** `Foo<T>` and `a < b`
  are both `ident < ident` locally, and the lexer/parser _combine_ adjacent `>`
  (the shift-operator note in [`token.hawk`](../pkgs/cli/lexer/token.hawk)), so
  no token-pair rule and no glyph-counting can separate them.

The entire AST dependency thus collapses to one question: **is this `<`/`>` an
angle bracket?**

## The generic-delimiter side-channel

Rather than fatten the AST to retain delimiter tokens (it churns every node, and
the tree is deliberately a pure structural tree), add a **parser side-channel**
— the same architectural move already used for `LexResult.comments`. The parser
is the only component that _knows_ a `<` opens type arguments, because it chose
to parse type args there.

```hawk
// produced alongside the AST; consumed only by tooling (fmt), never by compile.
struct GenericDelims {
    let opens:  Set<Int>;   // code-point offsets of `<` used as a generic open
    let closes: Set<Int>;   // offsets of `>` used as a generic close (incl. split `>>`)
}
```

Every parser site that consumes generic angle brackets — `NamedType.args`,
type-param lists (`<T: Eq + Debug>`), `CallExpr.type_args` / `recv_type_args`,
and enum/impl/interface generics — records the opener/closer offsets. A split
`>>` is handled naturally: the parser already knows it is closing two generics,
so it records both. Stage A tests each `Lt`/`Gt` token's offset for membership —
inside a generic ⇒ tight, otherwise ⇒ spaced comparison.

This is the precise, minimal answer to "the parser throws away keyword tokens":
we do not reclaim all of them, only the one role the formatter cannot otherwise
derive, and via a side table rather than the AST.

_Fallback (no parser change):_ derive the same set by re-scanning `<`/`>` tokens
within the spans of type-arg-bearing AST nodes. It works, but must reconstruct
where `<` begins inside a `NamedType` span and has no single node for a
type-param list — more code, more edge cases. The side-channel is authoritative
and cheaper; it is the recommended path.

## Spacing rule table

Default **1 space** between same-line tokens, with 0-space exceptions. Grounded
against the corpus (already hand-formatted) so v2 is a near-fixpoint on the
tree, mirroring how v1 was validated ("a no-op except legit blank/whitespace
cleanups").

| Context                                         | Rule                                                                              | Example                               |
| ----------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------- |
| Two word-ish tokens (id / keyword / literal)    | **1** (never 0 — fusion guard)                                                    | `let mut x`, `else if`, `for x in xs` |
| Just inside `( )` / `[ ]`                       | **0**                                                                             | `foo(a)`, `xs[i]`                     |
| Before `,` `;` `:`                              | **0**                                                                             | `a, b`                                |
| After `,` `;`                                   | **1**                                                                             | `f(a, b)`                             |
| After `:` (annotation / entry)                  | **1**                                                                             | `name: String`, `key: value`, `T: Eq` |
| Around `.` and `..`                             | **0**                                                                             | `a.b`, `0..n`                         |
| Around `->` `=>`                                | **1**                                                                             | `) -> T`, `Pat => body`               |
| Before postfix `?`                              | **0**                                                                             | `x?`                                  |
| After `@` `#`                                   | **0**                                                                             | `@test`, `#loc`                       |
| Binary ops `+ * / % == != && \|\| & \| ^ <= >=` | **1** both sides                                                                  | `a + b`                               |
| Prefix `-` `!` `~` (local rule above)           | **0** after                                                                       | `-x`, `!ok`                           |
| Generic `<` `>` (side-channel)                  | **0** inside                                                                      | `List<Int>`, `Map<String, Int>`       |
| Adjacent `<`/`>` (shift / nested close)         | **0** (never separate — see safety net)                                           | `v >>> 8`, `List<List<Int>>`          |
| `(` / `[` leading                               | **0** before iff prev ∈ {id, `)`, `]`, `?`, generic-`>`} (call/index), else **1** | `foo(x)` vs `= [1, 2]`                |
| Just inside a *non-empty* struct / map literal `{ }` | **1**                                                                        | `Foo { field: v }`, `{ 'a': 1 }`      |
| Empty braces `{}` (block / literal / arm body)  | **0**                                                                              | `{}`, `Foo {}`, `Some(_) => {}`       |

**Style calls, ratified against the corpus** (dogfooded as a whole-tree sweep —
the changes reduced to hand-alignment collapse plus these two, no broken code,
suite green): struct **and** map literals both space a non-empty interior
(`{ 'a': 1 }`, matching `Foo { x }` — Stage A can't tell a map `{` from a struct
`{` by token alone, and the shared rule reads consistently); empty `{}` is tight;
`[ ]` / `( )` interiors are never spaced.

## Sequencing

1. **Parser side-channel** for `GenericDelims` (+ tests) — the only non-formatter
   change; small, additive, and compile-path-invisible (like comments). _Done._
2. **Stage A** in `fmt.hawk`: token-pair rule table + role oracle + gap-edits +
   round-trip guard (token equality **and** re-parse — see safety net). _Done._
3. **Wire A before B** in `format_source`; parse-failure ⇒ skip A (so a fix
   fragment that doesn't parse standalone still gets indented). _Done._
4. **Ratify the style calls** against the corpus, then land the whole-tree `fmt`
   sweep + a CI `fmt --check` (the roadmap's "format the corpus" follow-up
   becomes actionable once spacing is canonical). _Style calls ratified + sweep
   landed; CI check remaining._

## Relationship to doc-comment tooling

Both consume parser-produced side tables and both work around the AST omitting
sub-node lexical detail (comments for docs; delimiter roles for spacing) — the
same pattern. But they are **independent**: because Hawk has only line comments,
intra-line spacing needs none of the comment-_attachment_ machinery that
doc-comment tooling requires, and can ship ahead of it.
