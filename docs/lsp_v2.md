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
  - **Codegen method-owner keying. _Done._** Concrete-type method dispatch is now
    owner-keyed. A `type_key(owner, name)` composite keys `method_table`,
    `interface_impls` (now an `ImplInfo` carrying the split owner/name), and the
    `PendingDispatch` rows; interface *names* stay unqualified (their key space is
    disjoint — a type key always contains `#`), so the transitive-closure machinery
    (`interface_methods`/`interface_supers`/`flatten_interfaces`) is untouched.
    Registration resolves the receiver's owner scope-aware from the `impl`'s file
    (`owner_of`); reads (`resolve_method`, `interface_method`, `is_iterator`) key by
    the receiver's owner-correct identity (`static_type_id`/`type_id_of`, falling
    back to the registry owner for primitives, which carry no `Interface` TypeId);
    `named_self_type` types `self` owner-correct from the unit's file. Conformance
    test now covers an inherent method (`scaled`) and an interface method
    (`Display`) on the collided `Point`. Byte-identical fixpoint. **Remaining:**
    interface *name* collisions (two libraries, same interface name) are still
    name-keyed, and `native` instance/static methods (`native_*_methods`) stay
    name-keyed — both narrow, deferred.
  - **Deep subtype helpers. _Done_** (was deferred): the raw-`type_defs` sweep
    happened as a side effect of the interface-identity and `is_assignable`
    migrations (audit EL17) — `def_by_id` resolves through the per-file tables;
    the only raw takers left are `named_type` (reserved-name-sound, documented)
    and the flat-table builder itself. Interface *identity* is owner-correct
    end-to-end too. The one remaining crumb: the `native` instance/static
    method tables stay name-keyed (narrow by design — natives only come from
    SDK core).

**Phase 1 is complete.**

### Phase 2 — incremental engine (medium scale) — **complete (LD14)**

Resolved-library cache + dependency-graph invalidation on top of the Phase-0
session struct: re-parse only the edited file; re-resolve only affected libraries;
keep element models for unchanged libraries. Target: no whole-closure rebuild per
edit for ~1–2k-file projects.

**Groundwork (2026-07-03/04):** the CLI-level `Session` (LD16) with canonical
String file identity (LD17), file-carrying spans (LD7), distinct anon
identities (LD8), and unified invalidation state on `Analysis` (LS-D1).

**The engine (2026-07-04, four batches — LD14):**
- The primary parses through the session's `parse_cache` (R1).
- The session merges each load's `file_imports` into a persistent import
  graph; `invalidate(p)` cascades over `dependents_of(p)` (conservative over
  unlabeled edges; an SDK key invalidates everything — the implicit prelude
  dependency). This also fixed a live staleness bug: importers' checked-clean
  status survived a dependency edit. Open importers are marked dirty in the
  LSP, so a dep edit re-publishes them.
- Surfaces: `public_surface_of` is memoized per load (the per-edge quadratic
  is gone) and each file's derived `FileSurface` (namespaces, bare surface,
  edges, collision diagnostics) lives in a cross-call `surface_cache`.
- Libraries: `resolver.build_import_library` builds the imports-only element
  model, cached by closure signature; `resolver.layer_primary` stacks the
  primary on a shallow-copied view without mutating the base (**frozen-base
  invariant**: elements reachable from a cached base are frozen; a primary
  `impl` on a type it doesn't declare falls back to a full build). The
  checker takes the layered library via `check_files(prebuilt:)`; codegen
  keeps its full build (emit path, the fixpoint substrate).

Measured: batch corpus check 22.6s → 12.5s; a warm LSP keystroke costs the
primary only (small file 9ms → 5ms; warm closure load ~3ms; `build_library`
and `collect_surface` both dropped off the deterministic profile). The
remaining keystroke cost is the primary's own inference — CH19's memo
(Phase 3) is the next lever.

### Phase 3 — query layer + inference-at-offset

Symbol identity → lexical-scope reconstruction at a cursor → `type_at` (run the
existing pure inference). Then **semantic references + rename** (resolve to a
declaration; collect only true binding references; verify rename doesn't collide)
— the priority feature. Hover upgrades (locals, loop vars, non-`self` members)
fall out of the same machinery. Completion / signature help / semantic tokens
follow as further renderers.

**`type_at` is done (2026-07-04, CH19)** — and it did not need lexical-scope
reconstruction at a cursor: the checker's walk *records* each node's committed
type (write-once, span-keyed, skipping synthesized zero-length spans), the
pure inference engine consults the record instead of re-walking subtrees, and
the session stores each file's record under the same invalidation cone as
`checked`. `Session.type_at(file, offset)` answers with the smallest recorded
span containing the offset; `records_for` feeds `ResolveCtx.primary_types`,
which upgrades hover on unannotated locals (declaration and use sites) to the
inferred type. The memoization also halved the checker's inference work (warm
keystroke on main.hawk 719ms → 130ms).

**`SymbolId` is done (2026-07-05, LS-D2)** — `Resolved` carries a
`SymbolId {file, kind, name, name_span}`; `def_file`/`def_span` render from it.

**Member resolution on inferred receivers is done (2026-07-05)** — a member on a
value receiver whose type isn't written (`xs.map()`, `p.scaled()`) resolves on
the receiver's committed type (CH19's record at the receiver's span): a
`Receiver.Named` carries its span, and `inferred_member` reads the recorded
`Type`, takes its `TypeId` owner/name, and resolves the method or field
owner-correct via the shared `member_on_owner`. Both are **navigable**: a
`FieldDef` carries a real `name_span`, so `x.field`/`self.field` go-to-definition
lands on the field declaration (`find_field` returns the owning file too). Covers
user structs/enums and built-in collections; primitive receivers stay deferred (a
`Primitive` carries no `TypeId`).

**Computed-receiver member resolution is done (2026-07-05)** — `f().x`,
`xs[i].y`, and value chains `a.b.c` (which the token classifier can't tell from
`namespace.Type.member`) now resolve. A token stream can't delimit the receiver,
so `member_receiver_span` walks the AST to the member-access `Field(obj, member)`
node and yields `obj`'s span; `computed_member` then reuses `inferred_member` on
its committed type. Wired into the `Computed` arm and the non-namespace
`Qualified` fallback. The walk is **file-level** — over every expression-bearing
declaration (function bodies, impl/interface methods, and module `let`/`const`
initializers), pruned by declaration span — so a computed receiver in a module
`let g = make().field;` resolves like one in a function body (no `enc.fn_decl`
special-case). This works for free because CH19 already records the types of
top-level initializer nodes. Still lenient — no record (or an `Unknown` receiver
type) resolves to nothing rather than guessing.

**Generic-type-parameter navigation is done (2026-07-05)** — a `T` in `fn f<T>`,
`struct Box<T>`, `impl Box<T>`, `enum Opt<T>`, or an interface resolves to its
`<T>` introduction. `type_param_span` finds the generic declaration enclosing the
cursor (a method's own params shadow the surrounding impl/interface's), keyed off
`TypeParam.span`. Checked after locals and before top-level names, so a type
param shadows a same-named top-level type. Definition navigates (across the full
set now: functions, types/structs/enums/interfaces, consts, module `let`s, enum
variants, methods, fields, `self`, params/locals, namespaces, and type params).

**Semantic references are done (2026-07-05)** — `textDocument/references` is
registered and resolves by identity, not text: `SymbolId.same` compares owning
file + name + name-span, `references.collect_in` resolves every same-named
identifier in a document and keeps only the ones that match, and
`Analysis.references_at` scans **every open document** in its own owner-correct
context (so `f`'s local `x` and `g`'s local `x` stay distinct;
`includeDeclaration` honored). Scope is the open document set — a reference in a
closed on-disk file isn't found yet (a workspace scan, reading `dependents_of`
from disk, is the follow-up).

**Semantic rename is done (2026-07-05)** — `textDocument/rename` is registered
and rewrites exactly the identity-matched occurrences (`references.matching_spans`
shared with find-references), grouped into a `WorkspaceEdit`. The new name is
validated as a legal identifier (`rename.is_identifier`, lexer-checked — a
keyword is rejected). Scope is the open document set, like references.

**Phase 3 is functionally complete** for the planned features (definition, hover,
references, rename, plus inferred-receiver member resolution). Remaining
follow-ups, all deferred: a **workspace scan** so references/rename reach closed
on-disk files (read `dependents_of` from disk, not just open buffers); a
**pre-rename collision check** (the new name already bound in an affected scope —
today the checker flags any clash on the next publish); **primitive-receiver**
member resolution (`"s".split()` — a `Primitive` carries no `TypeId`); **complete
field identity** (a field's declaration name and its `S { field: … }` literal uses
don't resolve to the field yet, so field references are member-access-only and
rename declines fields); and further renderers — completion / signature help /
semantic tokens.

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
