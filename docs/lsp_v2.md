# LSP v2 — analysis engine, resolution correctness, query layer

**What this is:** the target architecture for Hawk's analysis/LSP layer and a
low-risk, incremental plan to reach it. It supersedes the scattered "LSP v2"
notes in [roadmap.md](roadmap.md) and builds on the resolution model in
[scoping.md](scoping.md).

**Goals** (in priority order for this effort):
1. **Correctness** — finish owner-correct name resolution for *values and types*;
   no flat program-wide name tables; `pub`/private enforced uniformly.
2. **Architecture** — one resolution authority, one analysis engine shared by
   `hawk check` and the LSP; clean seams (hygiene → correctness → performance).
3. **Performance at scale** — incremental recompute for **medium projects
   (~1–2k files)**: per-library caches + a real dependency graph, no
   whole-closure rebuild per keystroke.
4. **Feature support** — the existing LSP commands and the planned ones, with
   **semantic references + rename** as the first new target.

## Current state (as-is) and the correctness gaps

Every request — a `hawk check` run *and* every LSP keystroke — runs the same
stateless pipeline: `tokenize → parse → loader.load_imports (transitive) →
resolver.build_library (element model) → checker.check` (and, for compile,
`codegen.compile_program`). The LSP caches only **parsing** (server-lived
`parse_cache`, evicted on edit); the **element model and the check are rebuilt
per request**.

Resolution is *partly* owner-correct:

- **Values in the checker: owner-correct.** `FileScope.resolve_function` →
  `bare_owner` (same-file → prelude/`as _` origin), no global fallback
  (scoping.md Phase 2e). Value-name uniqueness is lifted.
- **Values in codegen: still global-by-name.** `ModuleScope.resolve_function`
  falls back to a flat `global_functions` map after the same-file check. This is
  a **latent miscompile**: two libraries with a same-named free function would
  miscompile bare calls — masked today only because the corpus keeps function
  names globally unique. (Found via a real collision: a *private* `find_method`
  added in `lsp/hover.hawk` was picked by codegen for `inference.hawk`'s bare
  `find_method` call — proving both the global path and that **visibility isn't
  enforced** on it.)
- **Types: global-by-name everywhere.** `resolve_type_def` →
  `library.type_defs.get(name)` in both checker and codegen, and a `Type` carries
  only a **name**, no origin — so cross-library same-named types can't even be
  represented distinctly. Type-name uniqueness is still forced. (scoping.md
  Phase 2e S5; roadmap "Owner-correct type resolution".)

Other gaps: no inference-at-offset (locals/members don't resolve — hover has a
syntactic approximation, see [scoping.md] / hover.hawk); references/rename are
lexical-only and unregistered; parser recovery is coarse (a syntax error drops
following decls).

## Target architecture (five layers)

1. **Analysis session.** One long-lived object owns: the document store (open
   buffers as overlays over disk), a layered cache (parse cache → resolved-library
   cache → element models), and a **dependency graph** (importer ↔ imported) for
   invalidation. **`hawk check` and the LSP drive the same engine** — batch warms
   it and queries every file; the LSP mutates it on edit. No second stateless
   path to keep in sync.

2. **One resolution authority, owner-correct for values *and* types.** Checker and
   codegen resolve through the same `FileScope`-shaped API. **No global-by-name
   table** for values or types. `Type` carries its **owning-library origin** so
   `A.Foo` and `B.Foo` stay distinct through inference, unification, and the
   codegen type table. `pub`/private enforced uniformly — a private helper can
   never leak into another library's resolution.

3. **Symbol identity.** Every declaration has a stable identity
   (owning file + kind + name + defining span). This is what makes
   definition/references/rename **semantic** rather than lexical, and it is the
   currency the query layer trades in.

4. **Query layer** — the LSP's front door, a module (`analysis`/`query`) exposing
   offset/symbol queries built on resolution + **inference-at-offset**:
   `resolve_at(file, offset) -> Symbol`, `type_at`, `definition_of(sym)`,
   `references_of(sym)`, later `completions_at`, `signature_at`. Every LSP feature
   is a thin renderer over these — unifying today's four handlers
   (hover/definition/references/rename) and giving new commands one plug-in point.

5. **Recovering parser.** A half-typed buffer still yields a usable AST (decls
   past an error, a signature past a bad body), so features degrade gracefully and
   the diagnostic-cascade problem shrinks.

## Plan (correctness-first; each step suite-green + fixpoint-idempotent)

The project's discipline holds throughout: a wrong resolution changes emitted
bytecode and breaks the SDK fixpoint, so the fixpoint is the oracle for
behavior-preserving refactors.

### Phase 0 — pull-outs (independent, start now, de-risk the rest)

- **A. Codegen bare-call owner-correctness. _Done._** `ModuleScope.resolve_function`
  now resolves the bare path via the file's bare surface (prelude / `as _`) to the
  owning file's table, like the checker's `FileScope`; `global_functions` deleted.
  Removed a latent miscompile (two libraries' same-named free functions);
  fixpoint-proved; regression test added.
- **B. Shared `resolve.hawk` query seam. _Done._** Hover's context-aware resolution
  is extracted into `resolve.hawk` (`resolve_at` → a `Resolved` carrying both the
  hover render *and* the definition location: file + name span). `hover.hawk` and
  `definition.hawk` are thin renderers over it; `references`/`rename`/
  `workspace_symbols`/`code_action`/`server` consume the shared primitives.
  Go-to-definition now navigates to `self`'s type, `self.method`s, parameters, and
  `Enum.Variant`s (not just top-level names); `self.field` renders but isn't
  navigable (a field carries no name span). Unit + end-to-end (`hawk lsp`) tested.
- **C. Analysis-session struct. _Done._** The server's open docs, SDK root, and
  parse cache (plus `analyze_at` / diagnostics) are folded into an `Analysis`
  object (`analysis.hawk`); `Server` keeps only protocol state (dispatch, the
  dirty set, shutdown). Pure refactor — this is the seam the Phase-2 incremental
  engine (resolved-library cache + dependency graph) grows on, without touching
  the protocol layer.
- **D. `module`→`library` terminology sweep** (optional, cheap hygiene) — _not
  started_; deferred (broad, cosmetic).

### Phase 1 — resolution correctness (the foundation)

**1a. Architecture-review checkpoint — done; decision recorded below.** Nominal
type identity is **(owning library, name)**, but three representations track it by
name alone and carry no origin: the semantic type `Type.Interface(String, args)`;
the element model's flat `type_defs: Map<String, TypeDefElement>` (~16 helpers take
the raw map); and codegen's name-keyed `structs`/`enums` maps (last-wins on
collision — a latent type miscompile, the same class as the `global_functions` bug
fixed in pull-out A). The crux: a resolved `Type.Interface(name)` flows through
inference/unification/codegen with **no file context**, so a def lookup is
unambiguous only while names are globally unique — full correctness therefore
*requires the `Type` to carry origin*.

**Decision: `TypeId {owner, name}`** (a struct, not a positional field or an
interned int). `Type.Interface(TypeId, args)`; origin is captured in the one site
that turns a source name into a type — `resolver.resolve_named`, which gains a
`FileScope` to resolve the name to its owner (own → `as _` → prelude → builtin;
builtins get owner = the core file / a `'<builtin>'` sentinel). `resolve_type_def`
becomes `file_type_defs[id.owner][id.name]` (reusing the per-file tables Phase 2e
already built). Chosen over an interned `Int` id (keeps inference **pure** — no
stateful interner — and keeps the name for diagnostics/codegen) and over a bare
positional owner (bundling encapsulates the identity). Cost: ~80–100 edit sites in
the type core (~7 files) + codegen; practical urgency is low (nominal types
discourage clashes) but it is foundational and the chosen correctness-first path.

Staged (fixpoint-idempotent until the final flip — the Phase 2e playbook):

- **Pull-out (early, ahead of T1): codegen type-name owner-correctness.** Make
  codegen resolve a type name *at a construction/annotation site* (`Foo {…}`,
  `Foo.Bar`) owner-correctly from the current file — like the `global_functions`
  fix, and *without* the `Type` change (the site has the file in hand). Closes the
  latent struct/enum miscompile; fixpoint-provable alone.
- **T1 — representation.** Introduce `TypeId`; `Interface(String)`→`Interface(TypeId)`;
  capture owner in `resolve_named` (thread `FileScope` through `resolve_type_ref`);
  `.name`→`.id.name` everywhere. Equality still ignores owner (names unique →
  behavior-preserving). The big mechanical step.
- **T2 — element model.** `resolve_type_def` owner-keyed via `file_type_defs`;
  migrate the raw-map helper sites. Same elements → fixpoint holds.
- **T3 — codegen type table.** Resolve a *resolved* `Type` to its runtime id via
  owner (the part the early pull-out couldn't cover). Fixpoint holds.
- **T4 — the flip (one behavior change).** Interface equality includes owner;
  relax `check_duplicates` for types; conformance test (two libraries, same-named
  type). Type-name uniqueness lifted; enforce type visibility.

### Phase 2 — incremental engine (medium scale)

Resolved-library cache + dependency-graph invalidation on top of the Phase-0
session struct: re-parse only the edited file; re-resolve only affected libraries;
keep element models for unchanged libraries. Back-port the batch parse-cache
learnings rather than bolting on more caches. Target: no whole-closure rebuild per
edit for ~1–2k-file projects.

### Phase 3 — query layer + inference-at-offset

Symbol identity → lexical-scope reconstruction at a cursor → `type_at` (run the
existing pure inference). Then **semantic references + rename** (resolve to a
declaration; collect only true binding references; verify rename doesn't collide)
— the priority feature. Hover upgrades (locals, loop vars, non-`self` members)
fall out of the same machinery. Completion / signature help / semantic tokens
follow as further renderers.

### Phase 4 — parser recovery

Parallelizable; benefits both the LSP (mid-keystroke robustness) and the
diagnostic-cascade tail (fewer dropped decls → fewer secondary errors).

## Open questions / decisions taken

- **Correctness before features** — the type-origin arc (Phase 1) lands before the
  incremental engine and new features. *(decided)*
- **Medium scale (~1–2k files)** — per-library caching + a real dependency graph;
  not designing for 10k+ lazy-loading yet. *(decided)*
- **Semantic references + rename** is the first query-layer feature. *(decided)*
- **One engine for `hawk check` + LSP.** *(recommended; assumed)*
- Still to settle within Phase 1a: the concrete `Type`-origin representation.
