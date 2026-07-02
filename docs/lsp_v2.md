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

Staged (fixpoint-idempotent until the final flip — the Phase 2e playbook). The
standalone codegen pull-out was **folded into T3**: on investigation it couldn't
be validated ahead of T4 (type-name uniqueness is still enforced, so no
two-same-named-types conformance test is constructible yet), and its interesting
sites resolve an *inferred* `Type` — which needs the owner on `Type` (T1) anyway.

- **T1 — representation. _Done._** Added `owner_file` to `TypeDefElement`;
  introduced `TypeId {owner, name}`; `Interface(String)`→`Interface(TypeId)`. Owner
  is stamped from the resolved element's `owner_file` (via a `named_type(type_defs,
  name, args)` helper for fresh names; a re-wrapped `Interface(id, _)` reuses its
  id) — correct under uniqueness; the scope-aware `FileScope` resolution that
  *picks among* same-named types is deferred to T4. Every `Interface` destructure
  now reads `id.name`. Owner is carried *and* part of structural `==`, which stays
  behavior-preserving because owner is captured consistently (all constructions of
  a name share one owner) — **the SDK fixpoint is byte-identical**, proving it.
  ~70 sites across the type core (types/element/resolver/inference/checker/codegen)
  + test updates (expected types built via `named_type`, so owners match).
- **T2 — element model. _Done._** `FileScope.resolve_type_def` now takes a
  `TypeId` and resolves via `file_type_defs[id.owner]` (no global fallback for a
  real owner; the `<builtin>` sentinel falls through to the hermetic floor). The
  6 `Type.Interface`-derived call sites pass the id; the 7 bare-name sites (struct
  literals, interface bounds, primitive elements — no owner in hand) use a new
  `resolve_type_def_by_name` (still global, an owner-correct *source* resolution is
  T4). Because a wrong owner would miss the per-file table → broken build, **the
  byte-identical SDK fixpoint validates T1's owner stamping here.** (The checker's
  raw `type_defs.get(name)` sites stay name-based — migrated in T4.)
- **T3 — codegen type table. _Done._** `ModuleScope.structs`/`enums` are keyed
  `owner → name → info` (no global by-name fallback); `add_struct`/`add_enum` take
  the declaring file. Lookups resolve the owner two ways: an **inferred-`Type`**
  site takes the owner straight off the type's `TypeId` (`type_id_of` /
  `type_id_of_type`, the owner-carrying analogue of `type_of`/`name_of_type`) — the
  enum-dispatch chain (`plan_dispatch`→`emit_dispatch`→`emit_bisect`→`emit_leaf`→
  `emit_pattern`→`variant_tag`) now threads `Option<TypeId>` instead of the bare
  name, and `struct_of`/`emit_field_call`/`emit_enum_name_call` use `type_id_of`;
  a **source-name** site (a `Foo {}` literal, a static `Enum.Variant`, an enum
  field's declared type, a dispatch row's impl type) owner-qualifies via the
  registry (`type_owner`/`type_id_for`), correct under uniqueness (scope-aware
  source resolution is T4). Because a wrong owner misses the per-owner table →
  broken build, **the byte-identical SDK fixpoint validates the codegen owner
  keying** (as T2 did for the element model).
- **T4 — the flip. _Done._** Type-name uniqueness is lifted: two libraries may
  each define `Point`. Staged in two fixpoint-idempotent halves plus the flip:
  - **T4a (scope-aware resolution).** New `FileScope.resolve_type_owner(name,
    namespace)` picks a source type name's owner from *this file's* scope (a
    `ns.T` qualifier → the namespace's owner; else own file → bare surface →
    `<builtin>` → flat-registry fallback). New `resolver.resolve_type_ref_in` /
    `resolve_opt_in` stamp that owner; the main annotation/expression paths
    (inference, `check_fn`, codegen — all of which have the current file) use
    them. The flat `resolve_type_ref` stays for `build_library`'s own passes
    (they run before a `FileScope` exists). Behaviour-preserving under
    uniqueness → the byte-identical fixpoint validated it.
  - **construction + registry owner-keying.** `infer_struct`, the checker's
    struct-literal field check, and codegen's `struct_expr` resolve the owner
    scope-aware (honoring `ns.Point`) and fetch the def via `resolve_type_def`.
    Crucially, `build_library`'s pass-2 field/variant/interface filling now
    mutates the **per-file** element (`file_type_def`) instead of the flat
    last-wins entry — the flat `type_defs[name]` clobbers on collision, so the
    two `Point`s' fields were landing on one element.
  - **the flip.** `collides` for types now mirrors values (only a same-file
    redefinition collides); type equality already included owner (T1). Conformance
    test `mod-shared-type-name` (two libraries, disjoint `Point` field sets,
    qualified construction + field access) proves distinct resolution end to end;
    the same-file duplicate is still flagged. Type visibility was already enforced
    (`vis-pub`/`vis-pub-type-reject`).

- **T4 follow-ups — mostly closed.** After T4, several flat-path sites stayed
  owner-blind (latent only under a collision the corpus lacks). Now addressed:
  - **`is_assignable` identity (a real soundness hole). _Done._** The same-element
    generics branch compared elements by *name*, so `a.Box<Int>` unified with
    `b.Box<Int>`; now it compares the full `TypeId` ([types.hawk] `sid != tid`).
    One-liner, byte-identical under uniqueness; unit test in `element_test`.
  - **`build_library` pass-2 resolution + `resolve_impl`. _Done._** The
    `LibraryElement` is now assembled right after pass 1, so pass 2 resolves every
    signature / field / variant / const type against `file_scope(library, file)`
    (`resolve_type_ref_in`) instead of the flat map — a function param or struct
    field whose type is a collided name now gets the owner its file sees.
    `resolve_impl` likewise attaches methods to the scope-resolved element. The
    conformance test now exercises a collided **field type** (`Point.label: Label`)
    and the signature path (`a.sum(_ p: Point)`); byte-identical fixpoint validates.
  - **Bare enum / static-method receivers. _Done._** `type_def_for_expr`'s bare
    `Ident` case (inference) and codegen's new `static_type_id` now resolve the
    receiver's owner through the file's scope (`resolve_type_owner`, honoring a
    `ns.Enum` qualifier) — the enum/static analogue of `infer_struct`, closing the
    inconsistency where a bare `Enum.Variant` still went through the flat by-name
    lookup. Conformance test `shared_enum_name` (two libraries, disjoint `Color`
    variants; bare construction, qualified payload construction, and `match`).
  - **Deferred — codegen method-owner keying.** Method *dispatch* is still
    name-keyed: `ModuleScope.method_table` and the method unit's `self`-type
    (`named_self_type`) resolve by bare type name, so a method impl'd on a collided
    type would dispatch to / type `self` as the last-wins type. This is a
    T3-for-methods (owner-key `method_table`, thread the impl's file into
    `named_self_type`, owner the dispatch rows) — its own increment; until then the
    conformance test avoids methods on collided types.
  - **Deferred — deep subtype helpers.** `is_assignable`/`satisfies_bound` still
    take the flat `type_defs` for their interface-conformance def-lookups
    (`map_get_def`/`type_defs.get(name)`), wrong only when a collided name
    participates in *cross-library* interface conformance. Fold into a future
    "retire the flat `type_defs` map" pass rather than pay a ~17-site ripple now.

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
