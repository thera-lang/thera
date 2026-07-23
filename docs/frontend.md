# Thera front-end design

**What this is:** how the self-hosted front-end (`pkgs/cli/`, written in Thera)
turns `.thera` source into a checked, lowered `Module`. It is one program with
two customers — the compiler (`check`/`emit`/`run`/`test`) and the LSP — so its
design choices are driven by both. For the runtime that _executes_ the emitted
bytecode see [architecture.md](architecture.md); for status and open work see
[roadmap.md](roadmap.md).

## The pipeline

A single stage sequence carries source to bytecode; each stage is a directory
under `pkgs/cli/`:

```
source ──► lexer ──► parser ──► resolver ──► checker ──► inference ──► codegen ──► encoder ──► Module / .thera-bc
           (tokens)  (AST)      (element    (diagnostics) (on-demand    (bytecode)  (.thera-bc)
                                 model)                    Type query)
```

- **Lexer** — source → tokens; also surfaces comments (incl. `///`/`//!`) on a
  parser-invisible trivia side-channel.
- **Parser** — tokens → AST, with **error recovery** (below) so the AST survives
  incomplete/malformed input.
- **Resolver** — builds the semantic `Type`/element model (`pkgs/cli/element/`):
  names, owners, surfaces, imports. Resolution is owner-correct for values _and_
  types.
- **Checker** — reports located diagnostics (type mismatches, bad
  calls/fields/methods, unpinnable generics), driving the inference query as it
  goes.
- **Inference** — a **pure, on-demand** query (`infer_expr`, no AST annotation)
  the checker and codegen call; sees through generics and does bidirectional +
  forward-flow inference.
- **Codegen + encoder** — lower the checked AST to bytecode and serialize it to
  the `.thera-bc` format (constant pool; natives bound by name).

The whole front-end self-hosts: `bin/build_sdk.sh` compiles it with the
checked-in bootstrap snapshot and ends with a **fixpoint check** that it
re-emits itself byte-for-byte.

## Parser error recovery

The parser must produce a structurally useful AST from incomplete or malformed
source: the LSP parses code that is _almost always_ mid-edit and needs
completion/hover to anchor on a node **at the cursor**, and the compiler wants
**one precise error per hole** with **no downstream semantic cascade**. The same
AST feeds both — the LSP wants the maximal partial tree; the compiler wants
precise, quiet errors and a broken decl's _signature_ kept for cross-file
resolution.

**Hard constraint — recovery is a no-op on well-formed source.** The recovery
and non-fatal paths are simply never taken on valid input, and the self-hosting
fixpoint enforces this for free (the whole front-end + stdlib is well-formed, so
any happy-path regression changes the emitted bytecode and breaks the build).

### The core decision: recover known holes in place; unwind only when lost

Two situations, two mechanisms:

- **A known hole** — the parser knows exactly which token it wanted (`)`, a
  field name after `.`, an expression after `=`). It **fills the hole and keeps
  parsing**: records one error, synthesizes a node, does _not_ unwind. This is
  what preserves the surrounding tree and the cursor anchor.
- **Genuine confusion** — the current token can start nothing sensible (garbage
  mid-statement). Here the parser **unwinds to the nearest recovery point and
  resyncs**; there is no meaningful partial node to keep.

`panicking` is retained as the "I'm lost → unwind and resync" flag, but
**`expect` is non-fatal**: on a mismatch it records the error and returns a
**zero-width synthetic token** of the expected kind, **anchored at the cursor
offset**, _without_ consuming input and _without_ setting `panicking`. The span
fidelity is load-bearing — a synthetic token at the wrong offset silently breaks
completion. Most parse loops keep their `!panicking` guard, which still handles
the lost case.

The genuinely-unstartable `fail` sites (`parse_param` on a `{`,
`parse_primary`'s fallback) still unwind — so a _missing expression_ (`a +`,
`let x =`) unwinds rather than leaving a half-node inside a full declaration,
but surfaces as `Expr.Error` when parsed in isolation and as an `Expr.Error`
placeholder statement at the statement level.

### The suppression contract (anti-cascade)

Recovery synthesizes nodes; those nodes carry a marker the resolver/checker/
inference treat as **"incomplete — analyze leniently, report nothing."** This is
what lets the LSP keep the rich tree while the compiler stays quiet on the
holes.

- **`Expr.Error(SourceSpan)`** — "an expression was required but none could be
  parsed." Unlike the old `err_expr → Unit` throwaway, it types as **`Unknown`**
  (assignable everywhere), so it never triggers a type-mismatch cascade. Codegen
  has a defensive trap for it, unreachable in practice (`emit` runs only after a
  clean `check`).
- **Empty-name convention** for member/type holes: `obj.` → `Field(obj, "")`; a
  missing type → `NamedType{name: ""}`. The lexer never produces an empty
  identifier from valid source, so _empty name == recovery hole_. The empty
  field name is itself the completion anchor.

### Recovery points and `brace_depth` resync

Recovery is contained at the **nearest** boundary. Two points exist below the
declaration level:

- **Declaration** — `parse_decl_or_recover` / `sync_to_decl` (skip to the next
  top-level keyword), the original single recovery point.
- **Statement** — `parse_stmt_or_recover` / `sync_to_stmt`: a broken statement's
  siblings (before _and_ after) survive, and a broken function body keeps its
  signature.

Statement resync is driven by a running **`brace_depth`** (maintained by
`advance`, snapshotted at each statement start), _not_ a local counter: a panic
raised deep in nested braces (a match arm) must resync to the _statement's_
nesting depth, not the first `}` it sees — a naive local counter cascades (a
broken match arm spills the rest of the body to top level as spurious "expected
a declaration" errors). Relatedly, a stray top-level decl keyword inside a block
is treated as a block boundary, so an inner hole that ate the block's `}` can't
swallow the next declaration.

`parse_block` keeps its `!panicking` guard by design: it is what distinguishes
an _external_ signature panic that must propagate from an _internal_ statement
panic that recovery clears in place — which is what gives **signature-past-body
recovery** (a broken body recovers internally without dropping its `FnDecl`
signature, so a dependent in another file still resolves against it).

### The forward-progress invariant

Every recovery loop must **consume ≥1 token per iteration or terminate** — the
anti-spin property `panicking`'s freeze used to give implicitly. A list loop
whose sub-parser can return without consuming (a synthetic fill) must, on no
progress at neither the close delimiter nor a valid element-start, record an
error and force one `advance()`. In practice most loops terminate for free (a
comma-exit, a required starter keyword, `parse_primary`'s `fail`); only the
`impl`-method loop needed an explicit guard.

### Testing

Recovery cases pin _implementation behavior_, not the language spec, so they
live in the `@test` suite (`pkgs/cli/parser/recovery_test.thera`), not
`tests/lang`. The oracle is a **structural AST dump**
(`pkgs/cli/ast/dump.thera`) plus span assertions; a **behavioral
`complete_at(source, offset)`** oracle lands with the LSP
`textDocument/completion` item. Every case asserts two directions: the broken
input yields the expected partial tree, **and** the well-formed counterpart
parses unchanged (the fixpoint guards the no-op-on-valid invariant globally;
these lock it locally).
