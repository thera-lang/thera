# Hawk visibility & libraries

**What this is:** how Hawk controls what's visible across files — the privacy
boundary, the `pub` keyword, barrels for aggregating directories, and the
white-box rule for tests. For import _syntax_ and resolution see the
[Imports](language.md#imports) section of the language reference; this doc is
the design rationale and the precise rules.

## Model at a glance

- **Boundary:** the physical `.hawk` source file.
- **Default:** private — a top-level symbol is visible only within its own file.
- **Exposure:** the `pub` keyword makes a symbol part of its library's public
  API.
- **Aggregation:** a file can `pub import` other files, so a single root file
  can present a whole directory as one clean API surface (a _barrel_).
- **Testing:** a sibling `foo_test.hawk` gets white-box access to the private
  symbols of `foo.hawk`.

The design is deliberately conventional — file-granular privacy (as in Dart), a
`pub` keyword (as in Rust), and barrels (as in JS/Dart export files). It is not
new ground; it is the smallest mechanism that satisfies Hawk's constraints:
testing integrates into the tooling, compilation stays explicit and efficient,
and a directory of related code imports as a single unit.

## Terminology

Hawk intentionally has **no "module"** — there is no multi-file unit with shared
privacy (no `part`/`part-of`-style grouping). The relevant terms are:

- **Source file** — a physical `.hawk` file. It is the unit of privacy.
- **Library** — an importable API surface: _either_ a single source file _or_ a
  directory fronted by its barrel. `import std.fs` imports a one-file library;
  `import std.i18n` imports a directory library through its barrel. In the
  common single-file case the source file _is_ the library, which is why "a file
  is a library" reads naturally.
- **Barrel** — a library root file that re-exports the other files in its
  directory (see [Barrels](#barrels-and-directory-libraries)).
- **Exports / public API** — a library's `pub` symbols.

(Note for newcomers from Dart, where "library" can span files via `part`: Hawk's
library is simpler — privacy is always per source file.)

## Visibility rules

A **top-level** declaration — `fn`, `type`, `enum`, `const`, `interface` — is
**private** to its source file unless prefixed with `pub`:

```hawk
pub fn format_date(_ d: Date) -> String { ... }   // part of the public API
fn pad2(_ n: Int) -> String { ... }                // file-private helper
```

Within a file, everything sees everything (privacy never applies inside a file).
Across files, only `pub` symbols are visible — and only once imported.

**Types expose their fields.** Making a `type` (or `enum`) `pub` also exposes
its fields/variants to importers; there is no per-field `pub` and no "make
private" mechanism. This keeps declarations quiet (no `pub` on every field) at
the cost of field-level control, which can be added later if needed. Mutability
is a separate axis, already governed by Hawk's immutable-by-default fields.

**Methods are exposed individually.** A method in an `impl` block is `pub fn` to
be callable from other files; an unmarked method is file-private.

**`impl` blocks may live wherever visibility allows.** An `impl Foo` or
`impl Iface for Foo` can be in any file that can see `Foo` (and the interface).
Coherence (rejecting two overlapping `impl Display for Foo`) is a future
concern; see [follow-ups](#tracked-follow-ups).

## Imports and namespacing

An import **binds a namespace** equal to the trailing path segment; the imported
library's public symbols are referenced through it:

```hawk
import std.fs;
import std.i18n;

let text = fs.read_text('x.toml')?;     // qualified by the namespace
let s    = i18n.format_date(today);
```

This makes barrels safe (a dozen aggregated files can't collide in the
consumer's flat scope) and keeps provenance obvious. Three consequences:

- **`std.core` is the prelude.** It is auto-imported and its names are available
  **unqualified** everywhere: `Result`/`Option`/`Error`, `Display`/`Eq`/`Debug`,
  `println`/`print`. It is the one unqualified import; everything else is
  qualified. (`Result`/`Option` are ordinary enums defined in the prelude, so —
  like any enum — their *variants* are constructed qualified: `Result.Ok(x)`,
  `Option.None`. Match patterns stay bare; see below.)
- **Construction and type references are qualified; match patterns are not.**
  You write `i18n.Locale` as a type and `i18n.Locale.en` to construct, but in
  `match loc { en => …, fr => … }` the variants resolve from the subject's type
  and stay unqualified.
- **Method calls qualify on the receiver, not the namespace.** After
  `let a = cli.Args.new(parameters)`, calls are `a.positional(0)` — `a` is a
  value; only the top-level _name_ `Args` needed the `cli.` namespace.

`as` gives an import an explicit prefix when the default segment is ambiguous,
collides with a local, or you want a shorter name. (`show`/`hide`-style
selective imports are intentionally **not** included yet — see follow-ups.)

## Barrels and directory libraries

A **barrel** re-exports other files with `pub import`, flattening their public
symbols into its own namespace:

```hawk
// sdk/std/i18n/i18n.hawk  — the barrel for the i18n library
pub import 'dates';
pub import 'numbers';
pub import 'locale';
```

A consumer writes one import and sees the combined surface, flattened:

```hawk
import std.i18n;

i18n.format_date(today);    // defined in dates.hawk, surfaced as i18n.*
i18n.format_number(1234);   // defined in numbers.hawk
```

- **`pub import` = `import` + re-export.** It binds the namespace for the
  barrel's own use _and_ republishes the target's public symbols as part of this
  library's API, under this library's namespace (the `i18n.*` flattening above).
- **Plain `import` does not re-export.** A symbol brought in with `import` is
  visible only inside the importing file.
- **Collisions surface at the barrel.** If two re-exported files both export
  `format`, the barrel fails to compile — the conflict is the barrel author's to
  resolve, never the consumer's.

### Directory resolution

A directory is imported through a barrel file **named after the directory**:

```
import std.i18n     →  sdk/std/i18n/i18n.hawk
import 'foo/bar'    →  <dir>/foo/bar/bar.hawk
```

The `<dirname>.hawk` convention (rather than a uniform `index.hawk`) keeps the
file self-describing when opened alone and matches the import's last segment.

## Testing: white-box access

Tests stay co-located with the `_test.hawk` suffix: `foo.hawk` is tested by
`foo_test.hawk` in the same directory. The test file imports its target through
the **normal** import process — nothing special there:

```hawk
// math_test.hawk
import std.testing;
import 'math';

@test
fn test_add() -> Result<Void, Error> {
    testing.assert_eq(actual: math.add(2, 3), expected: 5)?;
    return Ok(void);
}
```

The only special-case is **visibility**: because the names match
(`foo_test.hawk` ↔ `foo.hawk` in the same directory), that one import sees the
target's **private** symbols too — so `math.internal_helper` is reachable from
`math_test.hawk` though not from anywhere else. White-box access is granted by
the filename convention; it does not change how symbols are referenced (still
qualified through the import's namespace), and it applies only to the single
same-named sibling.

This avoids inventing a general `@testable`/package-private visibility axis we
don't otherwise need.

## Resolution algorithm

For an import path `P` (dotted `std.i18n` resolves against the SDK std root;
quoted `'foo/bar'` resolves against the importing file's directory):

1. If `P.hawk` exists and a `P/` directory does **not**, the library is the file
   `P.hawk`.
2. Else if `P/` is a directory, the library is the barrel `P/<last>.hawk` (an
   error if that barrel file is absent).
3. If both `P.hawk` and `P/` exist, it is an error (ambiguous — they are
   mutually exclusive by convention).

The import's namespace is `<last>`. Importing a library exposes its public
surface: its own `pub` symbols plus everything it `pub import`s (flattened).
Import cycles are permitted (declarations resolve before bodies); the loader
guards against re-visiting a file.

## No runtime impact

Visibility and qualification are **front-end** concerns: name resolution applies
them, and they are erased by the time code reaches `.hawkbc` (calls are by
index; there is no notion of "private" or namespaces in the bytecode). Adding
this model needs no runtime or bytecode change.

## Tracked follow-ups

- **Enforce `pub`/privacy (deferred).** Qualified namespace access resolves
  today, but privacy is not yet enforced: a cross-file reference to a non-`pub`
  symbol should be an error, and unqualified resolution should see only the
  local file plus the `std.core` prelude (dropping the current flat fallback).
- **`_test.hawk` white-box access (deferred).** Grant a sibling test import
  visibility of its target's private symbols (see
  [Testing](#testing-white-box-access)); only meaningful once privacy is
  enforced.
- **Selective import** (`show`/`hide`) — deferred until a real need appears.
- **Field-level visibility** — today a `pub` type exposes all its fields; add
  finer control only if a use case demands it.
- **`impl` coherence / orphan rules** — reject overlapping impls; the
  element-model resolver must gather a type's impls across all loaded files.
- **Namespace vs. local shadowing** — an import like `import std.fs` binds `fs`,
  which a same-named local (`let fs = …`) then shadows. It works (the
  initializer resolves the namespace first) but reads awkwardly; the stdlib
  picks namespace names that avoid the common locals (hence `std.cli`, not the
  `args`-shadowing `std.args`). Revisit if it bites.
- **Terminology sweep** — older docs/comments say "module"; migrate them to
  "library"/"source file".
- **Implementation** — the front-end currently flattens all imports into one
  unqualified scope with no privacy; the element-model resolver, the checker's
  name resolution, and codegen's call lowering need to learn namespaces + `pub`.
  The `examples/` are migrated to qualified imports as part of that work.
