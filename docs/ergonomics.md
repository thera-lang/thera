# Hawk ergonomics & syntax-elegance review

**What this is:** a focused review of Hawk's syntactic ergonomics — where common
code shapes are more verbose than they should be, whether that matters for the
LLM-native goal, and a prioritized list of changes to address it. Born from the
`pkgs/` self-hosting code review; supersedes the thin "Syntax-elegance pass"
stub in [roadmap.md](roadmap.md). Execute from the **Prioritized improvements**
list; keep the **Secondary observations** as a tracked backlog even where we
don't act right away.

## Verdict

There is a real ergonomics issue, but it is **narrow and fixable**, not a
pervasive design flaw. Hawk's core is clean —
[sdk/std/json/json.hawk](../sdk/std/json/json.hawk) reads well and uses `match`
and `?` idiomatically. The "cumbersome" feeling in files like
[pkgs/cli/checker/checker.hawk](../pkgs/cli/checker/checker.hawk) traces almost
entirely to **one missing capability**: there is no way to conditionally bind a
value out of an `Option` (or any enum), so `match` is conscripted to do a
conditional's or a guard's job. That single gap produces the bulk of the noise.

The fix is **not** "use less `match`."
`match`-as-an-expression-that-returns-a-value is a strength (see the json
accessors). The problem is `match`-as-a-statement standing in for
conditional-binding and early-return guards that the language doesn't yet offer.

## Evidence

### Match density (matches per 100 lines)

| dir                | match / 100 lines |
| ------------------ | ----------------- |
| `sdk/std/json`     | **1.6**           |
| `pkgs/cli/parser`  | 1.6               |
| `pkgs/cli/checker` | **5.6**           |
| `pkgs/cli/codegen` | 5.3               |
| `pkgs/cli/element` | 6.0               |

json reads well partly _because_ its match density is ~3.5× lower than the
checker's — and where it uses `match`, it uses it as a value-returning
expression ([`as_int`](../sdk/std/json/json.hawk),
[`as_bool`](../sdk/std/json/json.hawk)).

### The dominant anti-pattern

Across `pkgs/` + `sdk/`:

- **~323** "resolution cascade" sites —
  `match X { Some(v) => { …; return …; }, None => {} }` ("look up,
  act-and-return, else fall through"), ~280 of them in `pkgs/cli/`.
- **279** arms that are pure noise (`None => {}` / `_ => {}`), present only
  because `match` is exhaustive.
- **88** arms of the shape `=> { … return … }` — control flow buried inside an
  arm.
- Nesting reaches **3 levels** of pure `Option`-threading
  ([loader.hawk](../pkgs/cli/loader.hawk),
  [codegen/module_scope.hawk](../pkgs/cli/codegen/module_scope.hawk)).
- **214** functions whose entire body is `return match … { … };`.

Two representative shapes, both of which are conditionals/guards wearing a
`match` costume:

```hawk
// side-effecting "do X if present" (≈279 noise arms come from this)
match x.type_ann {
    Some(ref) => { check_type_ref(errors, ref, library, file, Set.new()); },
    None => {},
}

// sequential "bind-or-bail" guard (checker.hawk check_conformance)
let iface_name = match decl.interface_name {
    Some(n) => n,
    None => { return; },
};
let iface_def = match library.type_defs.get(iface_name) {
    Some(d) => d,
    None => {
        add_error(errors, 'unknown interface: ${iface_name}', decl.name_span);
        return;
    },
};
```

### Current Option/Result surface

- `Option<T>` has only `ok_or` / `unwrap_or` / `is_some` / `is_none`
  ([option.hawk](../sdk/std/core/option.hawk)).
- `Result<T, E>` has **no** methods at all — just a `Display` impl
  ([result.hawk](../sdk/std/core/result.hawk)).
- `?` (the `Propagate` operator) works on **`Result` only** by spec, and carries
  most `Result` handling already (which is why `Result` is matched on far less
  than `Option` — ~24 vs ~323 sites). Notably, inference
  ([`infer_propagate`](../pkgs/cli/element/inference.hawk)) and the tag-based
  runtime lowering ([`propagate_expr`](../pkgs/cli/codegen/codegen.hawk))
  already accept `Option` structurally; only checker policy restricts it. The
  documented `Option` workaround is the verbose `.ok_or(error('…'))?`.

## Does it matter for LLMs?

Yes — but the reasoning is specific, and it cuts both ways.

**Verbosity of this kind hurts.** The exhaustive `None => {}` arm is
_load-bearing boilerplate_: a model that writes the natural
`match opt { Some(v) => {…} }` and forgets the `None` arm produces
**non-compiling** code. Each of the ~279 noise arms is a token the model must
emit for no semantic reason, and a place it can fail. The
buried-`return`-in-an-arm shape additionally forces nonlocal reasoning ("the
`return` exits the _function_, not the arm"), which is where subtle bugs come
from.

**But regularity is itself an LLM-native virtue.** The hazard in "fixing" this
is shipping `if let` _and_ `let-else` _and_ `?`-on-`Option` _and_ a pile of
combinators, so that there are now six interchangeable ways to handle an
`Option` and the model must choose. That is a regression even if each option is
individually nicer.

So the design target is: **add the smallest set of constructs that makes the
common path simultaneously shorter, flatter, and more regular — then make each
the canonical way for its shape.** One obvious choice per situation.

## Prioritized improvements

### P0 — `if let` (conditional binding)

The single highest-leverage change. Collapses the ~279 noise arms and the
dominant act-and-return cascade, and removes the exhaustiveness obligation for
the conditional case (no more compile-breaking missing arm).

```hawk
// before                                   // after
match x.type_ann {                          if let Some(ref) = x.type_ann {
    Some(ref) => { check_type_ref(...); },      check_type_ref(...);
    None => {},                             }
}
```

Generalizes to any enum, not just `Option`, so it stays _one mechanism_.
Patterns stay bare (`Some(ref)`), consistent with `match`. An `else` clause
makes it a full conditional (`if let … { } else { }`).

### P1 — `let … else` (guard / bind-or-diverge)

Flattens the sequential-guard cascade and — important for LLMs — _linearizes_
it: the happy path stays un-indented, no nesting to track.

```hawk
let Some(iface_name) = decl.interface_name else { return; };
let Some(iface_def) = library.type_defs.get(iface_name) else {
    add_error(errors, 'unknown interface: ${iface_name}', decl.name_span);
    return;
};
```

Pairs with `if let` rather than overlapping it: `if let` is "do something in the
present case," `let … else` is "bind for the rest of the function, or bail." The
`else` block must diverge (`return` / `throw` / `continue` / `break`) — same
rule as Rust/Swift, easy to check and easy for a model to get right.

### P2 — `?` on `Option`

Lower-effort than it looks (inference and the runtime already accept `Option`;
the gap is checker policy), and it would drain a large share of the remaining
cascades. **Needs design effort before implementing** — specifically the
interaction with `Result`-returning functions:

- In an `Option`-returning function, `opt?` → propagate `None`. Clear.
- In a `Result`-returning function, what does `opt?` mean? Options:
  1. **Disallow** — require the explicit `.ok_or(err)?` so a `None`→`Err`
     conversion always names its error. (Conservative; keeps `?` meaning
     "propagate the same enum.")
  2. **Allow with a required error** somehow — less obvious, risks a second way
     to spell the same thing.
- Symmetric question: `result?` inside an `Option`-returning function.

Lean toward option 1 (one obvious way; `?` propagates the _same_ type, and
cross-type conversions stay explicit), but settle it during design.

### P2 — round out the Option/Result combinators

Handles the value-transforming cases that neither `if let` nor `let … else`
address, and chains well (json navigation already wants this). Keep the set
**small and deliberate** — do _not_ port all of Rust's surface. Candidate set:

- `Option`: `map`, `and_then`, `unwrap_or_else` (have
  `ok_or`/`unwrap_or`/`is_some`/`is_none`).
- `Result`: `is_ok`, `is_err`, `map`, `map_err`, `and_then`, `unwrap_or`,
  `unwrap_or_else`, `ok` (→ `Option`). Result has zero methods today.

Note: even existing combinators are underused (e.g.
[json `write_object`](../sdk/std/json/json.hawk) hand-writes a `match` that
`unwrap_or` already covers), which argues for a `fmt`/lint nudge alongside the
new methods.

### The one-obvious-way guardrail

Once the paths above exist, **reinforce the canonical choice in the language
docs**, and later capture concrete, prescriptive guidance for LLMs in a skill or
rules file. The canonical choice per shape:

| situation                            | canonical form                       |
| ------------------------------------ | ------------------------------------ |
| present-case side effect             | `if let`                             |
| bind-or-bail (early return)          | `let … else`                         |
| propagate up the call stack          | `?`                                  |
| transform / default a value inline   | combinator (`map` / `unwrap_or` / …) |
| genuinely choosing among ≥2 variants | `match`                              |

This guardrail is the point of the whole exercise: each addition only helps the
LLM-native goal if it comes with a clear rule for _when_ to reach for it.

## Secondary observations (tracked, not yet scheduled)

Lower-priority contributors to verbosity. Worth recording; address
opportunistically.

- **C-style `while i < xs.len()` loops** — ~83 of them. Some are genuine
  parallel-index iteration (`i_params[i]` vs `o_params[i]` in
  [`signatures_match`](../pkgs/cli/checker/checker.hawk)) that wants a `zip`
  adapter; others just need an index and `enumerate()` (already exists) would
  do. A `zip` iterator adapter would retire a chunk of these.
- **`return match … { … };` as a whole function body** (~214×). The
  most-repeated boilerplate after the Option arms. This follows from the
  deliberate decision that function bodies are _not_ expression position (so a
  function's value is always marked by `return`). The safety rationale is sound
  and LLM-friendly — recommend **keeping** it — but it is the next-largest
  contributor and worth a conscious revisit if the cost ever outweighs the
  safety.
- **Construct-qualified / match-bare asymmetry** — build with `Option.None` /
  `Result.Ok`, but match with bare `None` / `Ok`. Minor; `if let` / `let … else`
  inherit the bare-pattern side, so they stay consistent with `match`.

## Suggested sequencing

1. **P0 `if let`** end-to-end (lexer → parser → checker → codegen → conformance
   tests), then mechanically migrate the cascade sites. Biggest single win.
2. **P1 `let … else`**, then migrate the guard cascades.
3. **P2 combinators** (library-only, cheap; can land in parallel with the
   above).
4. **P2 `?` on `Option`** after the `Result`-interaction design is settled.
5. **Guardrail**: update [language.md](language.md) with the canonical-choice
   table; later, a dedicated LLM rules/skill file.
6. Revisit **secondary observations** opportunistically.
