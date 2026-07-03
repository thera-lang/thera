# Name resolution & scoping

**What this is:** the precise rules for how a name in Hawk source resolves to a
declaration — lexical scope, file (library) scope, the prelude, and
**qualified-only** cross-library access — plus the resolution algorithm and the
gaps where today's implementation still diverges. The reference-level summary
lives in [language.md](language.md) (Imports, Visibility); this is the normative
spec the front-end resolver is held to.

## Core model

- **A `.hawk` file is a library.** It is also the unit of privacy. (A directory
  fronted by a barrel is a library too; see [language.md](language.md) → Imports.)
- **One name space per scope — with position-aware resolution.** Syntactic
  position still determines what a name is *looked up as* — a value (functions
  incl. `native fn`, consts, local bindings), a type (`type`/`enum`/`interface`,
  built-ins, type parameters), or an import namespace — but declarations share
  **one name space per scope**: a scope may introduce a given name at most
  once, across *all* declaration kinds. Two same-file top-level declarations of
  the same name collide even when their kinds differ (`fn max` + `const max`,
  `fn Config` + `struct Config`, `import std.fs;` + `fn fs`) — a check error,
  exactly like a same-kind duplicate.

  Rationale: one name, one meaning — a reader (or an agent) never needs the
  syntactic position to know which declaration a name denotes. *(Decision
  2026-07. Supersedes the earlier "three independent name spaces" model, which
  was never implemented — the corpus measured zero cross-kind reuse, so the
  stricter rule cost nothing. Enforcement is tracked in
  [audit_2026_07.md](audit_2026_07.md) → X2.)*
- **Qualified-only cross-library access (by default).** A name defined in
  *another* library is reachable only through that library's **namespace**
  (`fs.read_text`, `parser.parse_tokens`). The **prelude** (`std.core`) is the
  built-in exception: its public names are available unqualified. There is **no
  global namespace** — a bare name never reaches into a library this file didn't
  import.

  Rationale: every non-local, non-prelude name shows its origin syntactically
  (`fs.read_text` is visibly `fs`'s), which is what an agent or reader needs to
  follow provenance, and it removes the whole-program ambiguity a global fallback
  creates.
- **`as _` — opt-in unqualified import.** `import 'ast' as _;` binds **no
  namespace**; it brings the library's public names into this file's scope
  **unqualified** (the explicit escape hatch for a library used pervasively, where
  qualifying every reference would be noise). It's per-file and opt-in, so the
  default stays qualified and predictable. See [Imports](#imports--namespaces).

## Lexical scope (within a function)

- **Bindings.** Parameters and `let` bindings introduce value names. A name is in
  scope from its binding to the end of the enclosing block.
- **Block structure.** `if`/`while`/`for` bodies, `match` arms, and block
  expressions each open a nested scope; a binding introduced inside does not
  escape it. A `match` arm's constructor pattern binds its payload names within
  that arm; a `for` pattern binds within the loop body.
- **Shadowing.** An inner binding may shadow an outer one of the same name; a
  local binding shadows any same-named top-level or prelude value. A call through
  a value binding (`f(x)` where `f` is a `let`-bound lambda or a function-typed
  parameter) resolves to the binding, never to a function of the same name.
- **`self`.** Inside an instance method, `self` is the receiver binding; the
  `Self` *type* denotes the receiver's type.

## File (library) scope — top-level declarations

Within a file, all top-level declarations (`fn`, `type`, `enum`, `interface`,
`const`, `let`, `impl`) are **mutually visible**, regardless of declaration order
and regardless of `pub`. `pub` controls only *cross-library* visibility (below),
not visibility within the file.

**One name space applies here**: a file may introduce a top-level name at most
once across all kinds — `fn`, `type`/`enum`/`interface`, `const`/`let`, and the
namespace bound by an `import` — any second introduction is a duplicate-name
error, kind notwithstanding.

A top-level name may shadow a prelude name **within its file** (the file's own
declaration wins for bare references in that file). Doing so is discouraged — the
prelude is soft-reserved — and is meant to be diagnosed; the diagnostic was lost
when duplicate checking became same-file-only (the T4 uniqueness lift) and is
tracked in [audit_2026_07.md](audit_2026_07.md).

### Reserved type names

The type names the **language itself speaks** are reserved: user code may not
declare a `type`/`enum`/`interface` (native or not) named

> `Result`, `Option`, `Ordering`, `List`, `Map`, `Set`, `String`, `Int`,
> `Bool`, `Double`, `Bytes`, `Iterator`, `Error`, `SourceLoc`, `Void`

— a check error (decision 2026-07). These names appear in signatures (`Void`),
sugar (`?`/implicit-`Ok`, `#loc`), literals, and protocols (`for` iteration,
`error(...)`), so a user declaration would make the reserved meaning ambiguous
at every use site — exactly the confusion Hawk is designed to prevent. The list
is deliberately *not* the whole core surface: semantics attach to the **core
types by identity**, never to names, so utility types that merely live in core
(`BytesBuilder`, `Args`, `Indexed`, …) are ordinary owner-resolved names a user
library may redeclare. Value names (`fn`/`const`) are not reserved; casing
conventions keep them unambiguous. Only the core SDK itself declares the real
ones.

## The prelude (`std.core`)

`std.core` is auto-imported into every file and is the **one unqualified import**:
its public names (`Result`/`Option`/`Error`, `Eq`/`Display`/`Debug`,
`println`/`print`/`eprintln`, …) resolve bare. `Result`/`Option` are ordinary
prelude enums, so their variants are still constructed qualified by the enum
(`Result.Ok`, `Option.None`) — `Result` is the (prelude) type name, not a
namespace. The built-in types (`Int`/`Double`/`Bool`/`String`/`List`/`Map`/`Set`/
`Bytes`) and their methods are likewise always in scope.

The prelude holds only language-fundamental types, traits, and verbs — never
common domain nouns — precisely because its names occupy every file's bare scope.

## Imports & namespaces

```hawk
import std.fs;                 // namespace: fs
import 'parser/parser';        // namespace: parser   (trailing path segment)
import std.testing as testing; // namespace: testing  (explicit alias)
import 'ast' as _;             // no namespace — ast's public names come in bare
```

- An `import` binds **one namespace** in the importing file: its `as` alias, or
  the trailing path segment of the import path (`std.fs` → `fs`,
  `util/strings` → `strings`).
- **`import 'x' as _;`** binds **no** namespace and instead makes `x`'s public
  names resolve **bare** in this file (it slots into bare resolution, below). Use
  it for a library referenced pervasively. The cost is the reader must know `x`'s
  surface to attribute a bare name to it — so it's opt-in, not the default. If two
  `as _` imports expose the same name, there's no qualifier to disambiguate with;
  resolve it by importing one of them normally (qualified) instead.
- **A *constructed* type is reachable bare or qualified.** A struct literal may
  name its type bare — `Point { x: 1 }` (same-file, prelude, or via `as _`) — or
  qualified — `ns.Point { x: 1 }` (which *does* parse and is used, e.g.
  `element.LibraryNamespace { … }`); the qualified form is surface-checked like any
  `ns.member`. Qualification (`ns.Type`) also covers type annotations, static
  calls (`ns.Type.method`), and enum construction (`ns.Enum.Variant`).
- The namespace's **public surface** is the imported library's own `pub`
  declarations, plus — transitively — the public surfaces of that library's
  `pub import`s (the basis of barrels). A plain `import` does not re-export.
- A namespace binding is **file-local**: it exists only in the file that wrote the
  `import`. Another file must write its own `import` to use the library.
- If a re-exporting barrel would expose the same public name from two files, the
  **barrel** is the error (the conflict is the barrel author's, never the
  consumer's).

## Visibility (privacy)

- The privacy unit is the **source file**. A top-level declaration is **private to
  its file** unless marked `pub`.
- A private declaration is part of its file's bare scope (mutually visible
  in-file) but is **not** in the library's public surface — so no other library
  can reach it, qualified or otherwise.
- Methods are exposed individually: a method is callable cross-library only when
  it is `pub fn`. Making a `type`/`enum` `pub` exposes all its fields/variants
  (there is no per-field `pub`).
- **Test white-box access.** A `foo_test.hawk` importing `foo` additionally sees
  `foo.hawk`'s *private* top-level names as **bare** names (the filenames match) —
  its public names are still reached through the `foo` namespace, as in any
  importer. This is the one exception to cross-file privacy.

## Resolution algorithm

For each syntactic position, resolution tries the ordered steps and stops at the
first match; failing all steps is a located error.

### A bare value name `name` (a reference, or the callee of `name(...)`)

1. an in-scope **local binding** (param/`let`) → that binding;
2. a **same-file top-level** function or const named `name` → that declaration;
3. a public function/const named `name` exposed by an **`as _` import** → it;
4. a **prelude** public function or const named `name` → that declaration;
5. otherwise **unresolved** → `undefined name: name`. A bare name is *never*
   resolved against a library imported with a namespace (it must be qualified).

### A qualified value name `ns.name` (a reference, or `ns.name(...)`)

1. `ns` must be an **import namespace of the current file**, not shadowed by a
   local binding named `ns`;
2. `name` must be in `ns`'s **public surface**; else
   `name is not exported by library ns`;
3. resolves to that library's `pub` declaration of `name`.

### A bare type name `T` (an annotation, struct literal, or static receiver)

1. an in-scope **type parameter** named `T` → `TypeParameter(T)`; `Self` → the
   receiver type;
2. a **built-in** (`Int`/`String`/`List`/`Map`/…) → that built-in;
3. a **same-file** `type`/`enum`/`interface` named `T` → it;
4. a public type named `T` exposed by an **`as _` import** → it;
5. a **prelude** public type named `T` → it;
6. otherwise **unknown type**.

### A qualified type name `ns.T`

As `ns.name` above, but resolved in the **type** space (`ns` must expose `T`).

### Members

Member access is resolved through the **receiver**, not a namespace:

- **Instance method / field** `recv.m(...)` / `recv.f` — resolved against the
  static type of `recv` and the `impl`s visible on that type. An `impl` may live
  in any file that can see the type (and, for `impl I for T`, the interface);
  cross-library, only `pub fn` methods are callable. Dynamic dispatch applies for
  interface-typed and bounded-generic receivers.
- **Static method** `T.m(...)` and **enum construction** `E.V(...)` — `T`/`E` is
  resolved as a type name (bare or `ns.`-qualified) first, then the member is
  selected within it. `e.name()` on an enum value yields the variant name.

Qualification therefore applies to **free functions, consts, and type names** —
the things a library owns at top level. Methods and variants are selected within
an already-resolved receiver/type and are not separately namespace-qualified.

## Implementation gaps (what diverges today)

The rules above are the target. The current resolver diverges as follows; these
are the violations to address.

1. **Bare *value* resolution is restricted.** *(Resolved for values; types
   pending.)* A bare value name is accepted only when it is in scope, declared in
   the current file (`file_owned`), bare-legal from another library
   (`file_bare_surface` = the prelude + `as _` imports), a built-in, or an import
   namespace this file binds — see `is_defined_name`. A name owned by a library the
   file never imported is `undefined` even if it sits in the closure's flat
   `functions` table (pinned by `mod-no-bare-fallback`). The same gate has not yet
   been applied to bare **type** references (`check_type_ref` still consults the
   flat `type_defs`), so the type-position analogue of this hole remains; closing
   it needs the per-file legality threaded through type checking. The underlying
   `functions`/`type_defs` tables are still flat (a same-named cross-file
   definition is guarded by the duplicate-name diagnostic, not yet by ownership —
   gap 5).
2. **Qualified resolution doesn't resolve within the owning library.** The
   *surface* check is now done — a qualified `ns.name`/`ns.T`/`ns.Point { … }` to a
   non-public (or absent) member is rejected (`check_member_visible` →
   `namespace_exposes`, in the resolution gates). What remains is *resolution*:
   `name` is still looked up in the global flat table after the surface check, not
   resolved **within `ns`'s library**, so it isn't owner-correct by construction
   (a same-name cross-library symbol is kept distinct only by the duplicate
   diagnostic). → Phase 2 (the `Scope` abstraction) resolves within the library.
3. **Namespaces are per-file.** *(Resolved.)* `is_namespace` consults the
   **current file's** own imports — the loader threads a per-file table
   (`LoadedImports.file_namespaces`, file key → namespace → surface) into both the
   element model (`LibraryElement.file_namespaces`, queried via `namespaces_in`)
   and codegen (`ModuleScope.file_has_namespace`), replacing the former
   closure-wide union. A file can no longer qualify with a namespace it never
   imported. (Surface-checking the qualified name and resolving *within* that
   library is gap 2; per-library ownership of the value/type tables is gap 5.)
4. **Privacy of *values* is enforced; white-box test access is implemented.**
   *(Resolved for values.)* With gap 1's value gate, a private (`fn`, not `pub`)
   top-level name owned by another library is no longer bare-reachable. The
   exception — a `foo_test.hawk` may use `foo.hawk`'s private names **bare** — is
   implemented in the loader (`bare_surface_for` adds the matching `foo.hawk`'s
   full surface to the test file's bare-legal set; the filenames match), pinned by
   `vis-whitebox-test`. (Private *types* await the type-position gate, gap 1.)
5. **The element model is one flat global table.** `build_library` merges the
   whole closure into single `functions`/`type_defs`/`consts` maps, discarding
   which library owns each name. Per-library resolution needs per-library symbol
   tables plus each file's import list. → The element model must track ownership
   and per-file imports, not a single global surface.
6. **The codebase uses bare cross-library references.** The self-hosted front-end
   and stdlib call cross-file functions bare (`load_imports`, `parse_tokens`,
   `compile_program`, …) and rely on the global fallback. Under qualified-only
   these must be **migrated to qualified form** (`loader.load_imports`, …). This
   migration must land together with (1)–(3), or the build breaks.
7. **Guards / scaffolding in place.** Three pieces of the target already exist,
   ahead of the resolver change:
   - the duplicate-top-level-name diagnostic surfaces global-table collisions at
     `check` (mitigates (1)/(2); becomes a same-file-redefinition check once the
     resolver is module-scoped);
   - **`import 'x' as _;`** (unqualified import) is implemented end to end — parser,
     and the lint treats its names as bare-legal; under the lenient resolver it's a
     no-op at runtime (bare names already resolve), so it can be adopted now;
   - **`qualify_lint`** flags every bare reference an import exposes. It drove the
     migration to zero and is now **promoted to a hard `check` error** (it runs in
     `checker.check`), so a bare cross-library reference is rejected and aborts
     compilation. This enforces the qualified-only rule for imported names at the
     diagnostic level even though resolution underneath is still lenient (gaps
     1–5). Its one hole: a bare name from a library that's in the closure but not
     imported by the file isn't an "imported name", so it isn't flagged — closing
     that needs the resolution rework below.

**Status (Phases 1 and 2 done — values; types done since).** Resolution runs
through a single `FileScope` per file; value resolution is owner-correct and
global value-name uniqueness is lifted (gaps 2 and 5 closed for values). The
type side (Phase 2e S5 below) has since landed as the `TypeId` arc —
[lsp_v2.md](lsp_v2.md) Phase 1 (T1–T4): `Type` carries its owning file,
type resolution is owner-correct, and type-name uniqueness is lifted; its
remaining tail is tracked in [audit_2026_07.md](audit_2026_07.md). The Phase 1
detail below is retained for history.

**Status (Phase 1 done).** Migration (6) is **done** and guarded at 0.
Qualified-only and `pub` visibility are now **enforced by construction in the
resolution gates**, and the two transitional lints (`qualify_lint` /
`visibility_lint`) are **deleted**. Resolved: per-file namespaces (3); the bare gate
for **values _and_ types** (1) — `check_expr`'s `Ident` and `check_named_type`
(shared by `check_type_ref` and the `Struct` arm), with `current_file` threaded
through the top-level signature checkers — with **no global last-wins fallback** in
either name space; `value` privacy + the white-box test exception (4); and the
**surface** half of qualified access (2) — a qualified `ns.name`/`ns.T` to a
non-public member is rejected at the access site (`check_member_visible` /
`check_qualified_receiver`). Pinned by `mod-qualified-only`(+`-type-reject`),
`vis-pub`(+`-type-reject`), `mod-no-bare-fallback`(+type), `mod-ns-file-local`,
`vis-whitebox-test`. (Closing the type gate also forced the type-side of migration
(6): bare type refs to un-imported libraries — e.g. `server.hawk`'s
`Reader`/`Writer` — were qualified.)

- the loader threads per-file tables — `file_namespaces` (namespace → surface) and
  `file_bare_surface` (the prelude + `as _` imports, plus a `foo_test.hawk`'s
  white-box view of `foo.hawk`) — into the element model and codegen;
- the element model adds `file_owned` (each file's own top-level names);
- the gates check legality against scope ∪ `file_owned` ∪ `file_bare_surface` ∪
  built-ins, turning a bare-but-qualifiable name into "qualify as `ns.name`" and a
  qualified non-public member into "not a public member of `ns`".

## Remaining — Phase 2: the `FileScope` abstraction

(Subsumes gaps 2-resolution and 5.) The element model still merges the closure into
flat `functions`/`type_defs`/`consts` maps, so a qualified `ns.name` is
*surface-checked* but still *resolved* in the global table — not **within `ns`'s
library** — and that flat table **forces global name uniqueness** across the whole
closure (`check_duplicates` is closure-wide; two libraries can't share a top-level
name like `parse`). Phase 2 replaces the flat tables with a per-file resolution
object that returns the owning element, making resolution correct-by-construction
and lifting the uniqueness limit.

### Shape: one `FileScope` per file (not an interface zoo)

The lexical tier already works — locals/params are a `Map<String, Type>` threaded
through every consumer, consulted first. Phase 2 touches only the **static tier**
(top-level / imports / prelude / builtins), the part backed by the flat tables. That
tier is a single value type, **`FileScope`**, built once per file:

- `resolve_value(name) -> Option<ValueElement>` — own decls → `as _`/white-box →
  prelude → (built-in value names), first hit wins.
- `resolve_type(name) -> Option<TypeElement>` — type-params/`Self` → built-ins → own
  → `as _` → prelude.
- `resolve_namespace(name) -> Option<FileScope-public-view>` — a namespace **binds
  the imported library's scope, viewed publicly**.
- `resolve_public_value/type(name)` — the public-surface variants, used when
  resolving *into* a namespace.

A qualified `ns.name` is then `resolve_namespace(ns)?.resolve_public_value(name)` —
resolved **within the owning library** by construction (closes gap 2), and because
each file's decls live in its own symbol table, `std.json.parse` and `std.toml.parse`
never collide (lifts the uniqueness limit). The roadmap's earlier "per-kind impls
(Local/File/Library/Prelude/Builtin)" collapse: *Local* = the existing Map (kept
separate); *Prelude*/*Builtin* = extra tiers every `FileScope` consults; *Library* =
another file's `FileScope` seen publicly. One type, no interface hierarchy, no
hot-path dynamic dispatch.

### The enabling data-model change (owner-correctness)

Today a namespace surface is a **name set** (`LibraryNamespace { names, collisions }`)
and elements are fetched by bare name from the global table. To resolve a public name
*within its owning library*, the surface must remember **which file each public name
comes from**: extend `LibraryNamespace` (and the bare/white-box surfaces) with a
`name -> defining-file` origin map, populated by `collect_surface`/`bare_surface_for`
in the loader (which already visit each contributing `LibrarySource`, so they have the
`file_path`). Then `build_library` keeps **per-file symbol tables** — `file_owned`
generalized from a name `Set` to a `Map<file_key, {types, functions, consts}>` of
*elements* (today only `file_functions` is per-file) — and `FileScope` resolves a
public name by going to its origin file's table. The global
`functions`/`type_defs`/`consts` maps are deleted once every consumer is migrated.

Subtlety: `impl` blocks and interface flattening attach methods to a `TypeDefElement`
*by name*; with per-file type tables, an `impl Foo` in file B must attach to the `Foo`
visible from B's scope (own → imports → built-ins), not a global `Foo`. This is the
same coherence question as `impl` orphan rules; Phase 2 resolves the impl target
through the file's scope to preserve today's behavior.

### Sequence (suite-green + fixpoint-idempotent at each step)

**2a–2d — done.** `FileScope` introduced (2a) and adopted as the single resolution
authority by the checker (2b), inference (2c), and codegen's namespace resolution
(2d). All behavior-preserving; `FileScope` is a facade over the still-flat tables.

**2e — lift the limit (done, for values).** The key realization: uniqueness is
forced by exactly one enforcement point (`check_duplicates`, closure-wide).
Everything else was built and switched on *while names were still globally unique*,
where per-file resolution and flat-table resolution return the same element — so
each step stayed behavior-preserving with the **fixpoint as the oracle** (a different
resolution changes the emitted bytecode and breaks it). So 2e landed not as one
atomic change but as the sequence below, ending in one tiny behavior flip:

- **S1 (additive)** — per-file element tables `file_type_defs`/`file_consts` in
  `build_library` (mirroring `file_functions`), holding *references* to the shared
  element objects (so a cross-file `impl` still mutates the one type element).
- **S2 (additive)** — origin maps: `LibraryNamespace.origin` (public name → owning
  file) and `file_bare_surface` as name → owning file, populated in the loader's
  `collect_surface`/`bare_surface_for`. Nothing reads S1/S2 yet.
- **S3** — `FileScope.resolve_qualified_*(ns, name)` resolves within `ns`'s origin
  file.
- **S4** — `FileScope` bare resolution reads per-file tables + bare origins; drop
  the global fallback.
- **S5 — deferred (types).** S4 established that type resolution can't be made
  owner-correct the way values can: `resolve_type_def` also serves an
  already-resolved `Type.Interface(name)` whose type may be owned by any closure
  file, and a `Type` carries only the **name** — so by-name lookup is unambiguous
  only while type names are globally unique. Lifting *type-name* uniqueness needs an
  **origin threaded into every `Type`** (inference, unification, codegen type
  table) — a separate arc (tracked in [roadmap.md](roadmap.md)), to be done with an
  architecture review. So 2e lifts uniqueness for **values (functions/consts)**;
  type names stay globally unique. `resolve_type_def` and the resolver's
  `resolve_type_ref` stay global by-name.
- **S6** — codegen `emit_namespace_call` resolves a qualified call via the origin
  file (`file_functions[origin][name]`), not `resolve_global_function`'s last-wins.
- **S7 (cleanup)** — delete the now-dead global flat `functions`/`consts` (+
  `function_for`'s global fallback). `type_defs` stays (the global by-name type
  lookup). Deletion is the proof of deadness — a remaining reader fails to compile.
- **S8 (the only behavior change)** — relax `check_duplicates` for functions/consts
  (types stay strict); add a conformance test (two libraries each `pub fn parse`,
  both called qualified, dispatching to different functions). The value-uniqueness
  lift.

See [roadmap.md](roadmap.md) → _Resolution correctness_.
