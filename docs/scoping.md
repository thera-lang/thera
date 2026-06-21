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
- **Three independent name spaces.** A name is resolved in exactly one of:
  - **values** — functions (incl. `native fn`), consts, and local bindings;
  - **types** — `type`/`enum`/`interface` declarations, built-ins, type parameters;
  - **namespaces** — the bindings introduced by `import`.

  The spaces don't collide: a `type Set` and a value `Set` can coexist; `a[i]`
  vs `Set` vs `set(...)` are disambiguated by syntactic position.
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
`const`, `impl`) are **mutually visible**, regardless of declaration order and
regardless of `pub`. `pub` controls only *cross-library* visibility (below), not
visibility within the file.

A top-level name may shadow a prelude name **within its file** (the file's own
declaration wins for bare references in that file). Doing so is discouraged — the
prelude is soft-reserved — and the duplicate-definition diagnostic reports it.

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
- **A *constructed* type must be reachable bare** (same-file, prelude, or via
  `as _`): a struct/enum literal names its type with a bare identifier —
  `Point { x: 1 }` — and `ns.Point { … }` does not parse. So a library whose types
  you *construct* (not merely annotate with) is an `as _` import. Qualification
  (`ns.Type`) covers type annotations, static calls (`ns.Type.method`), and enum
  construction (`ns.Enum.Variant`), but not struct-literal construction.
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
  `foo.hawk`'s *private* symbols (the filenames match) — referenced through the
  import's namespace. This is the one exception to cross-file privacy.

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

1. **Bare resolution spans the whole closure.** `function_for` falls back to a
   single `library.functions` map built last-wins across *every* file in the
   import closure, and the type/const tables are likewise one flat global map. So
   a bare name reaches libraries the file never imported, and a same-named
   definition in a later-loaded file silently wins. → Bare lookup must be
   restricted to **same-file + prelude**; cross-library names must go through a
   namespace.
2. **Qualified resolution ignores the public surface.** `ns.name` only checks
   *that* `ns` is some namespace, then looks `name` up in the global table
   (`namespace_exposes` is defined but never called). So `lib.helper` can bind to
   a `helper` from another library entirely. → Qualified lookup must verify
   `name ∈ ns`'s surface and resolve **within that library**.
3. **Namespaces are closure-wide, not per-file.** `is_namespace` consults the
   union of all imports across the closure, so a file can qualify with a namespace
   it never imported. → Namespaces must be scoped to the **current file's**
   imports.
4. **Privacy is unenforced.** Because of (1), a private (`fn`, not `pub`)
   top-level name is reachable cross-file through the global fallback. → A private
   name must be invisible outside its file (and its `foo_test.hawk`).
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
   - **`check --qualified`** (`qualify_lint`) warns on every bare reference an import
     exposes — the migration checklist, driven to zero before enforcement.

A natural sequencing: adopt `as _` for the pervasively-used foundational libraries
and qualify the rest (6, driven by the lint, byte-identical under the lenient
resolver); enrich the element model with per-library ownership and per-file
imports (5); implement surface-checked qualified resolution and
same-file+`as _`+prelude bare resolution (1–4); then enforce privacy and tighten
the diagnostics.
