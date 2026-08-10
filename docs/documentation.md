# Documentation & examples

**What this is:** how Thera code is documented, and how everything a document
claims about code is kept true. It covers the doc-comment model (the three
comment forms, the summary sentence, the Markdown subset, symbol references),
the three tiers a code example comes in and how to choose between them, and the
tooling that verifies every one of them.
[language.md § Documentation](language.md#documentation) carries the syntax and
the enforced rules in brief; the detail lives here.

The governing principle: **anything the toolchain can verify about prose, it
should.** Thera's documentation is written for an audience of LLMs and coding
agents first, and that audience trusts documents uncritically — an agent reading
a doc that teaches syntax the compiler rejects will write that syntax.
Unverified prose is therefore not neutral, it is a liability, and the amount of
it should trend to zero. The scaling frame behind this is
[scale.md](scale.md#the-scaling-model--four-failure-modes) failure mode 4
(trustworthiness of prose).

> **Status.** This doc is written in the present tense, as the settled target.
> The conventions are adoptable in source today and the corpus already follows
> most of them; the verification machinery is partly built. See
> [§ Implementation status](#implementation-status) for exactly what runs today
> and what is still specification.

## The doc model

### Three comment forms

Thera distinguishes documentation from ordinary comments lexically, so tooling
can extract one without scraping the other:

| Form  | Role             | Attaches to                                                       |
| ----- | ---------------- | ----------------------------------------------------------------- |
| `///` | **item doc**     | the declaration immediately below it                              |
| `//!` | **file doc**     | the enclosing file (sits at the top, above the first declaration) |
| `//`  | ordinary comment | nothing — an internal aside, never extracted                      |

```thera
//! std.fs — filesystem access: read and write files, list directories,
//! query metadata. All paths are POSIX (forward-slash) regardless of host.
//!
//! Import as: import std.fs;

/// The contents of the file at `path`, decoded as UTF-8.
///
/// **Errors:** returns `Err` if the file does not exist or is unreadable.
@extern('fs_read_text')
pub native fn read_text(path: String) -> Result<String, Error>

// internal: the native validates UTF-8 and maps errno → FsError  ← not a doc
```

A declaration's doc is the contiguous run of `///` lines directly above it; a
blank line or an ordinary `//` line ends the run. Because `//` is never
extracted, an internal note may sit directly above a declaration without
becoming its documentation — the disambiguation a position-only rule (Go's "the
comment above the symbol") cannot provide.

That rule has one consequence worth stating early, because it shapes the tooling
below: **a `//` line cannot appear inside a doc comment.** Any mechanism that
would need one — a suppression comment, an out-of-band annotation — has to be
spelled some other way. See [§ Opting out](#opting-out-no_check-and-no_run).

A directory library's **barrel** `//!` header is the **package doc** — the
single thing an agent reads to understand a whole library. A recommended
`Import as:` line gives the exact import to copy. It is the only doc convention
above the symbol level; everything coarser than a library is a generated index
([scale.md item 5](scale.md#5-generated-api-index)), not hand-written prose.

### The summary sentence

The **first sentence** of any doc (through the first `.`) is its summary. It
must:

- **stand alone** — it appears by itself in one-line contexts (a symbol index,
  editor hover, a package's table of contents), with no further lines for
  support;
- **add information beyond the name** — if the name and signature already say
  everything, write no doc at all rather than restate them. A doc that only
  echoes the signature (`/// Returns the length.` on `len(self) -> Int`) is
  worse than none.

A blank `///` line separates the summary from any further paragraphs. Functions
lead with the result as a noun phrase ("The substring of code points in
`[start, end)`."), not "This function returns…".

**When to document.** Every `pub` symbol should carry a doc comment _unless its
name and signature are fully self-describing_. Private symbols are documented
only where the intent is non-obvious. Brevity is a feature: the goal is the
shortest doc that adds something a reader couldn't get from the signature.

### Markdown

Doc comments are Markdown, restricted to a small, predictable subset (anything
outside it is treated as plain text). This list is also what `thera fmt` reads
when it refills comment prose: a paragraph reflows, while everything below keeps
the line structure you gave it. A `` `code` `` span and a `[Symbol]` reference
are never split across lines.

- **Inline:** `` `code` `` and `**bold**`.
- **Links & references:** `[text](path)` is an ordinary Markdown link, used to
  cross-reference other docs. `[Symbol]` (no trailing `(…)`) is a **resolvable
  symbol reference** — see [§ Symbol references](#symbol-references).
- **Lists:** `-` bullets and `1.` ordered lists.
- **Code blocks:** fenced only, tagged per
  [§ The fence tag is the contract](#the-fence-tag-is-the-contract). Indented
  code blocks are **not** supported (they force an ambiguous indent-width rule
  under the `///` prefix); a fence is delimited, needs no measuring, and is the
  form LLMs read and emit most reliably.

There are **no ATX headers** (`#`, `##`) in doc comments — `#` would invite
long, sectioned docs that cut against the brevity goal, and a symbol's name is
already its title. When a longer doc genuinely needs sections, use a small fixed
set of **bold-label paragraphs** instead:

| Label          | Use                                                                                          |
| -------------- | -------------------------------------------------------------------------------------------- |
| `**Example:**` | a usage example (usually a fenced `thera` block)                                             |
| `**Errors:**`  | the conditions under which a `Result` returns `Err`                                          |
| `**Traps:**`   | the conditions under which the call traps (see [Runtime faults](language.md#runtime-faults)) |
| `**Note:**`    | a caveat or non-obvious consequence                                                          |
| `**See:**`     | a cross-reference to a related symbol (`[Symbol]`) or doc                                    |

### Parameters

Document parameters **in prose**, naming them in backticks (`` `index` ``) —
there is no `@param` tag vocabulary. Document a parameter only when its name and
type do not already convey its role: units, valid ranges, edge behavior, or how
it relates to another parameter. The return value is described in the summary,
not in a separate tag.

```thera
/// The substring of code points in the half-open range `[start, end)`.
/// Indices are clamped to the string's length, so a reversed or out-of-range
/// range yields a shorter or empty string.
pub fn slice(self, start: Int, end: Int) -> String { ... }
```

### Symbol references

`` `code` `` and `[Symbol]` are not interchangeable. A backtick span is **inert
text** the tooling never reads. `[Symbol]` is a **checked, navigable reference**
— a shorthand naming a declared symbol the way code does (`[Display]`,
`[String.slice]`, `[fs.read_text]`), resolved from the documented file's scope.

- Doc tooling links it: hover and `thera doc` render it as a jump target.
- It is **resolve-or-error**: a `[Symbol]` that no longer resolves is a
  `doc-reference` warning, on the same footing as the `doc-example` warning
  below. This is the doc-rot protection — a rename that misses a doc mention
  gets caught rather than silently detaching.
- `thera rename` rewrites `[Symbol]` mentions along with code references
  ([scale.md item 8](scale.md#8-mechanical-refactors-as-cli-operations)), which
  is what keeps the corpus resolvable through a sweep.

Use `[Symbol]` when you want a reference navigable and verified; use backticks
for any other code-shaped text. Backticks always work, so the bracket form is a
pure opt-in upgrade, never required.

The promotion path from warning to `check` error is deliberately gated on two
things: the corpus being clean, and `thera rename` existing so that a sweep
cannot manufacture a wall of new errors. Until both hold, a broken reference is
a warning
([scale.md item 7](scale.md#7-doc-reference-integrity-promoted-to-errors)).

## Examples come in three tiers

Code examples are the highest-value documentation content for an LLM — they are
the thing it imitates — and also the content that rots fastest. The organizing
principle is **minimize code that lives as strings**: only the smallest examples
sit inside comments, and anything bigger is real code that participates in
checking and refactors with no special tooling at all.

Size decides the tier:

| Example                                              | Lives in                                         | Verified by                                                      | Reached from                     |
| ---------------------------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------- | -------------------------------- |
| **One call**, one to five lines                      | a fenced `thera` block in a `///` / `//!` doc    | `thera check` (compile), `thera test` (run, if it has an oracle) | inline, at the symbol            |
| **A workflow**, several calls with real control flow | an `@example` fn in the sibling `foo_test.thera` | `thera test` (always compiled and run)                           | a `/// @file#fragment` reference |
| **A whole program**                                  | `examples/*.thera`                               | `bin/test.sh` (compiled and run)                                 | an ordinary Markdown link        |

Push down a tier whenever an example stops being a single idea. A twelve-line
block inside a `///` is a workflow example wearing the wrong hat: it is
unreadable in hover, invisible to find-references, and will not be touched by a
rename.

## Tier 1 — fenced examples in doc comments

Locality is the point. A block in a `///` surfaces in editor hover and in
`thera doc` output right beside the API it illustrates, which is where a reader
who is already looking at the symbol will actually see it.

### The fence tag is the contract

A fence's info string states what the block claims to be, and the toolchain
holds it to exactly that claim.

**In a doc comment, Thera is the default.** A bare fence inside `///` or `//!`
is Thera and is verified — a doc comment lives inside a `.thera` file, so code
in it is Thera unless it says otherwise. The point of the default is that a new
example is verified _without anyone remembering to ask for it_; the failure mode
of an opt-in tag is silent, and silence is what this whole arrangement exists to
remove.

**In a Markdown file, it is opt-in.** A `.md` file is language-agnostic prose,
and `docs/` is full of JSON, shell, and EBNF fences; there a block is Thera only
when tagged `thera`.

| Fence in a `///` / `//!` doc comment | Rendered | Compile-checked | Run                 |
| ------------------------------------ | -------- | --------------- | ------------------- |
| ` ``` ` (bare) or ` ```thera `       | yes      | **yes**         | if it has an oracle |
| ` ```thera,no_run `                  | yes      | **yes**         | no                  |
| ` ```thera,no_check `                | yes      | no              | no                  |
| ` ```text `, ` ```sh `, ` ```json `  | yes      | no              | no                  |

| Fence in a `.md` file                  | Rendered | Compile-checked | Run                 |
| -------------------------------------- | -------- | --------------- | ------------------- |
| ` ```thera `                           | yes      | **yes**         | if it has an oracle |
| ` ```thera,no_run `                    | yes      | **yes**         | no                  |
| ` ```thera,no_check `                  | yes      | no              | no                  |
| ` ``` ` (bare), ` ```sh `, ` ```json ` | yes      | no              | no                  |

**Attributes are comma-separated**, after the language tag — the spelling Rust's
doctests use, so it is already familiar. A space after the comma is accepted and
`thera fmt` normalizes to the tight form. Attributes always need the explicit
`thera` tag: ` ```thera,no_run `, never a bare ` ```,no_run `. An unrecognized
attribute is a `doc-example` warning rather than a silent skip, so a typo
(`thera,norun`) cannot quietly disable verification.

**Non-Thera content gets a real tag.** Preformatted text that is not Thera — a
syntax table, a grammar fragment, sample program output, a diagnostic transcript
— is ` ```text `, or the language it actually is. Inside a doc comment this is
now required rather than optional, which is the one cost of the default above.

### Opting out: `no_check` and `no_run`

The two attributes name the stage they switch off, so they form a ladder:
`no_run` disables running, `no_check` disables compiling and therefore running
too.

- **`no_run`** — compile-checked, never executed. For a block whose effects are
  real: opening a socket, writing a file, spawning a process, sleeping. The
  static bar still catches the rot class that matters (fictional syntax,
  fictional APIs, names stale after a rename).
- **`no_check`** — rendered, never checked. For **design fiction**: an example
  of an API that does not exist yet. Reach for it only when `no_run` genuinely
  cannot work. Every `no_check` block is a small permanent liability, and the
  honest lifecycle is that it becomes a plain `thera` block the week its API
  lands — so a `no_check` block should have an issue behind it.

These are the only opt-outs, and that is deliberate. The `doc-example` warning
has **no `// ignore:` form** — the standard suppression comment is a `//` line,
and a `//` line inside a doc comment would terminate the doc run it sits in (see
[§ Three comment forms](#three-comment-forms)). Nothing can be hidden from the
reader to appease the tool.

That constraint is a feature: an opt-out has to be visible in the rendered doc,
where the person trusting the example can see it.

### The doc-example dialect

A doc example is compiled as a Thera source file, with three relaxations. Each
exists because REPL shape is what makes a small example readable, and a
verification rule that fought that shape would just push authors to stop tagging
their fences.

**1. A bare expression statement is legal.** It compiles as if discarded
(`let _ = …`), so the canonical one-liner works verbatim:

````thera
/// The substring of the code points in the half-open range `[start, end)`.
///
/// ```thera
/// 'hello'.slice(1, 4)   // => 'ell'
/// ```
pub native fn slice(self, start: Int, end: Int) -> String
````

**2. An unused `Result` is not an error.** `fs.read_text(path)` on a line of its
own reads fine in an example and would be a mistake in real code.

**3. `...` elides code.** It is legal wherever a block body, a statement, an
expression, or a member list is omitted, and it type-checks as a **diverging
hole** — like `throw` — so the enclosing signature still checks in full:

```thera
pub fn get(self, index: Int) -> Option<T> { ... }

if config.port.is_some() { ... }
```

This is what lets a block whose whole point is a _signature_ or a _shape_ stay
verified rather than degrading to `no_check`. A block containing `...` is
compile-only: it is never run, even if it carries an oracle. Outside a doc
example `...` is not Thera, and the diagnostic says so.

The spelling is the three ASCII dots. The corpus also writes the single
character `…` in this position; that is prose punctuation, it is not typeable
without effort, and `thera fmt` rewrites it to `...` inside a verified block.

### What compiles, and what does not

A doc example is **a whole source file**, so the shapes that work are the shapes
a file can hold. Size is not the boundary — a one-line fragment and a
twelve-line program are equally fine — and neither is statement-versus-function.

**Wrapper synthesis.** Top-level declarations (`fn`, `struct`, `enum`,
`interface`, `impl`, `import`) stay at the top level; every loose statement is
collected, in source order, into a synthesized
`fn main() -> Result<Int, Error>`. Writing `?` in a loose statement therefore
works, which matters — the corpus leans on it heavily. A block that declares its
own `main` gets no wrapper.

| The block is                                  | Compiles |
| --------------------------------------------- | -------- |
| a bare expression — `'hello'.slice(1, 4)`     | yes      |
| a sequence of statements                      | yes      |
| declarations — `fn`, `struct`, `enum`, `impl` | yes      |
| declarations _and_ loose statements, mixed    | yes      |
| its own `fn main`                             | yes      |
| a signature with an elided body — `{ ... }`   | yes      |

**Imports.** The prelude (`std.core`) is ambient as always, and in a doc comment
the **documented library is auto-imported under its own namespace** — a block in
`sdk/std/path/path.thera` writes `path.components('a/b')` with no import line.
Any _other_ library the block reaches for it imports itself, including from
inside a `sdk/std` doc comment: a `std.net` example that calls `io.read_all`
owes an `import std.io;`. A Markdown fence has no documented library, so it
writes every import it needs — which is the right default there anyway, since a
reader copying out of `docs/` needs those lines.

**The one real constraint: an example must be self-contained.** Every name it
uses it must define, import, or receive from the documented library. This is the
rule that actually bites, because the natural way to write a small example is to
assume a variable into existence:

````thera
/// ```
/// names.sort((a, b) => a < b);          // ✗ what is `names`?
/// ```

/// ```
/// let names = ['bo', 'al'];             // ✓
/// names.sort((a, b) => a < b);
/// names                                 // => ['al', 'bo']
/// ```
````

Binding the context is nearly always an improvement rather than a tax: the
example becomes copy-pasteable, and it gains something concrete for a `// =>`
oracle to pin. Where the setup would genuinely drown the point being
illustrated, that is the signal to move the example down a tier — a
[`@example` function](#tier-2--example-functions) can afford a few lines of
scaffolding, a `///` block cannot.

### Running is opt-in by shape

Compile-checking is the universal bar. **Running is opt-in, and the opt-in is an
oracle** — the same marker is both the assertion and the run-me signal, so there
is no separate attribute to forget. The directive vocabulary is shared verbatim
with the [`tests/lang`](../tests/lang/README.md) conformance harness, because
two spellings of one idea is exactly the drift this doc exists to prevent.

| Directive                 | Mode  | Meaning                                                                                |
| ------------------------- | ----- | -------------------------------------------------------------------------------------- |
| `// => <value>`           | run   | debug-format the expression on this line and compare to `<value>`                      |
| `// expect: <line>`       | run   | the next line of the program's stdout, compared in order                               |
| `// expect error: <text>` | check | the block must **fail** to compile, with a diagnostic on this line containing `<text>` |

A block with any `// expect error:` is a check-mode block; a block with `// =>`
or `// expect:` is a run-mode block; a block with neither is compile-only. The
two modes do not mix, and a block that mixes them is a `doc-example` warning.

````thera
/// **Example:**
/// ```thera
/// let xs = [10, 20, 30];
/// xs.get(1)             // => Some(20)
/// xs.get(9)             // => None
/// println('${xs.len()} items');   // expect: 3 items
/// ```
````

The `// =>` transform is also what makes REPL-style lines legal as _assertions_
rather than as discarded expressions: the harness rewrites the line into a
comparison, so a wrong value fails rather than being computed and thrown away.

Check-mode blocks are how a document demonstrates a diagnostic — the compiler's
own error becomes the thing under test:

````thera
/// ```thera
/// let x = if c { 1 };   // expect error: missing else
/// ```
````

### Determinism

A run-mode block executes with its **ambient capabilities pinned**, so that
`no_run` stays rare and an example that touches the clock is still an example
rather than a flake. Before the synthesized `main` runs, the harness freezes the
ambient clock at `2026-01-01T00:00:00Z` (epoch millis `1767225600000`), seeds
the RNG at `0`, and gives the block an empty environment. These are the ambient
counterparts of `std.testing`'s `fixed_clock` / `fixed_env` doubles
([stdlib.md § the ambient-capability model](stdlib.md)), installed rather than
passed — a doc example has no seam to thread a capability through.

Anything genuinely unpinnable — a network call, a real filesystem write, a
subprocess — gets `no_run`.

### Identity and reporting

A doc example's name is **`path:line` of its opening fence**. No naming
ceremony, clickable in every terminal and editor, and stable under edits
elsewhere in the file. A failure reports that name, then the failing oracle's
own line under it, in the standard `path:line:column: message` diagnostic shape:

```
$ thera test sdk/std
sdk/std/core/string.thera:30: doc example failed
  sdk/std/core/string.thera:31:5: expected 'ell', got 'ello'

Ran 214 tests and 38 doc examples for 22 files; 1 failure.
```

## Tier 2 — `@example` functions

Once an example needs several calls, real error handling, or a helper, it stops
belonging in a string. An `@example` function is **ordinary code in the existing
sibling test file** — so renames, checking, find-references, and `thera fmt` all
work on it with zero special handling, which is the entire argument for the
tier.

```thera
// sdk/std/path/path_test.thera

import std.testing;

import 'path' as _;

/// Point a source path at the artifact it compiles to, alongside it.
@example
fn example_output_path() -> Result<Void, Error> {
    let src = 'src/main.thera';
    let out = path.join(path.dirname(src), '${path.stem(src)}.thera-bc');
    testing.assert_eq(actual: out, expected: 'src/main.thera-bc')?;

    // `with_extension` is the one-call form of the same rewrite.
    testing.assert_eq(actual: path.with_extension(src, 'thera-bc'), expected: out)?;
    return Result.Ok(void);
}
```

- **Shape.** Same as `@test`: no arguments, returns `Result<Void, Error>`. It
  lives in `foo_test.thera` beside the `@test` functions and is compiled and run
  by the test runner on the same terms — an example that returns `Err` is a
  failure, and the white-box access a test file gets applies here too.
- **How it differs from `@test`.** An `@example` is _rendered_, so it is written
  to be read: it shows the workflow, and asserts only where an assertion is
  itself part of the story. A `@test` is written to be thorough.
- **It is reported separately.** `thera test` counts examples apart from tests
  (`Ran 214 tests and 3 examples …`), because a failing example is a
  documentation bug and a failing test is a code bug.

### Referencing an example from a doc

A doc site pulls an example in with a reference on a line of its own:

```thera
/// The path's segments, slash-separated, with no empty segments.
///
/// **Example:**
/// @path_test.thera#example_output_path
pub fn components(path: String) -> List<String> { ... }
```

The `file#fragment` shape is one agents already know, and it degrades
gracefully: even with no tooling at all it is a breadcrumb a reader can follow
by hand. With tooling, `thera doc` and hover **inline the referenced function
body** at that point, so the rendered doc reads as though the example were
written inline — which is the point of the whole arrangement.

- **The path is relative to the referencing file**, and names a sibling test
  file in practice.
- **References are explicit; there is no name magic.** Go-style
  `Example<Symbol>` name matching detaches silently on rename — the failure mode
  is a doc that quietly loses its example, which is precisely the rot this
  design exists to stop. An explicit reference is validated resolve-or-error by
  the same machinery as `[Symbol]`.
- **An `@example` that nothing references is a warning**
  (`unreferenced-example`). An example nobody reads is a test with worse
  assertions; either reference it or make it a `@test`.
- The `example_*` naming is a convention for readability only. Nothing matches
  on it.

## Tier 3 — programs in `examples/`

A complete, runnable program lives in [`examples/`](../examples/) and is
compiled and run by `bin/test.sh`, with a handful of representative programs
having their stdout pinned. Docs reach them by ordinary Markdown link. There is
nothing special here — that is the tier's virtue, and it is the one tier that
has always worked.

Where a _library_ ships a demo program (`pkgs/github/example.thera`), it
currently sits inside the library it demonstrates. That works but conflates the
library's importable surface with a program that consumes it; the layout
question belongs to
[scale.md item 4](scale.md#4-a-package-unit--manifest-declared-dependencies-layering).

## Verification

Two commands, split by what they cost. Compile-checking is fast, deterministic,
needs no sandbox, and catches the entire observed rot class — so it belongs in
the edit loop. Running costs more and belongs in the test run.

### `thera check` — compile

`thera check` extracts every verified fence from the `.thera` files **in its
target set** and compile-checks it. A block that does not compile is a
**warning**, tagged with the rule name `doc-example`:

```
$ thera check sdk/std
sdk/std/core/string.thera:31:5: warning: doc example does not compile:
  no method `slize` on `String` (doc-example)

Checked 22 source files; 0 issues found; 1 warning.
```

Two scoping decisions make this safe to have on by default:

- **Warning, not error.** A doc comment is not the program. A stale example must
  never stop unrelated code from running or emitting — the failure mode where an
  agent cannot run its own project because a library's doc comment drifted is
  far worse than the drift. Warnings are reported by `check` and by the LSP, and
  leave the exit code at 0.
- **Target set only, never the import closure.** `check` walks a program's
  imports to type-check it, but it extracts doc examples only from the files it
  was pointed at. Your dependencies' documentation is not your diagnostic.

The gate is `--fatal-warnings`, which `bin/test.sh` already passes over
`pkgs sdk/std examples` — so this repo's own corpus is held to a clean bill at
check time, while a downstream user of the SDK is not.

Promotion to error follows the same policy as `[Symbol]` references: available
once the corpus is clean and the extractor has enough mileage to be trusted, and
not before.

### `thera test` — run

`thera test` compile-checks every verified fence and additionally **runs** the
oracle-bearing ones, alongside the `@test` and `@example` functions. Here a
failure is a test failure and the exit code is 1. This is the gate that keeps
the executable claims true:

```
$ thera test sdk/std
sdk/std/path/path.thera:212: doc example failed
  sdk/std/path/path.thera:213:1: expected 'src/main.md', got 'src/main.thera.md'

Ran 214 tests, 38 doc examples and 3 examples for 22 files; 1 failure.
```

### Markdown: the `--docs` flag

Fences in `*.md` are verified on the same contract, but only when asked:

```
$ thera check --docs docs/
$ thera test --docs docs/
```

`--docs` adds the Markdown files under the target to the set. It is opt-in
rather than automatic so that a directory sweep never tries to compile the
fences in a README, a changelog, or a vendored third-party document — the corpus
a project wants verified is a deliberate choice, not everything that happens to
be on disk.

`bin/test.sh` passes it for `docs/` and `sdk/doc/`, which is what would have
caught the bugs that motivated this design: [`docs/stdlib.md`](stdlib.md)
shipping a `serve(addr, handler)` form that never compiled, and
[`language.md`](language.md)'s four stale examples (`s.parse<Int>()` twice,
`json.decode<User>`, `args.first()`), all found by hand.

## Choosing where to put an example

The short version, in the order the decision actually gets made:

1. **Is it one call?** Fenced `thera` block at the symbol. Add `// =>` if the
   result is worth pinning; that is nearly always.
2. **Does it need more than about five lines, or a helper?** `@example` fn in
   the sibling `foo_test.thera`, referenced with `/// @file#fragment`.
3. **Is it a program someone would run?** `examples/`.
4. **Does the API not exist yet?** `thera,no_check`, and open an issue — a
   `no_check` block is a debt, not a resting state.
5. **Does it have real side effects?** `thera,no_run`.

And the rule that ties the tiers together: if you are about to reach for
`no_check` because the block would not compile, ask first whether it is really
design fiction. Usually it is not — it is a fragment missing the two lines that
would bind its context, and that is the signal to pick 1 (bind them) or 2 (move
it down a tier), not to switch verification off.

## Implementation status

Written as the settled target; here is where the machinery actually stands. The
table below is mirrored as a checklist in the tracking epic,
[issue #165](https://github.com/thera-lang/thera/issues/165) — with
[#126](https://github.com/thera-lang/thera/issues/126) (phase 1) and
[#128](https://github.com/thera-lang/thera/issues/128) (doc-comment tooling) as
its sub-issues. See the [roadmap](roadmap.md#developer-tooling) for how this arc
sits against the rest of developer tooling.

| Piece                                                        | Status                                                                                              |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| `///` / `//!` / `//` lexing, comment side channel            | **done**                                                                                            |
| The conventions above; `sdk/std` migrated to `///` / `//!`   | **done** (`pkgs/cli` and `examples/` not yet migrated)                                              |
| `examples/` compiled and run by `bin/test.sh`                | **done**                                                                                            |
| `@test` functions, `thera test`                              | **done**                                                                                            |
| Attaching docs to AST nodes                                  | **done** — `docs.attach` (`pkgs/cli/docs.thera`), a span-keyed side table                           |
| Fence extraction + compile-check, `doc-example` warning      | pending — **phase 1**, the high-order bit                                                           |
| The doc-example dialect (bare exprs, unused `Result`, `...`) | pending — lands with phase 1                                                                        |
| Making `sdk/std`'s examples self-contained                   | pending — lands with phase 1; see the snapshot below                                                |
| `--docs` (Markdown fences)                                   | pending — phase 2                                                                                   |
| `@example`, `/// @file#fragment` references, inlining        | pending — phase 3, lands with the doc generator ([scale.md item 5](scale.md#5-generated-api-index)) |
| `// =>` / `// expect:` / `// expect error:` oracles          | pending — phase 4                                                                                   |
| `lint --fix` sweep: trailing-comment results → `// =>`       | pending — phase 5                                                                                   |
| `[Symbol]` resolution + `doc-reference` warning              | pending                                                                                             |
| LSP hover showing item/file docs                             | pending                                                                                             |

Phasing is deliberate. Phase 1 alone catches every bug that motivated the work —
all of them were **statically** wrong — so it is worth landing before anything
that needs a runner. The later phases are upgrades to blocks that already
compile.

Two things should land _with_ phase 1 rather than after it, because they are
what makes the existing corpus taggable at all: the doc-example dialect (without
it, `sdk/std`'s 109 REPL-shaped fences all fail) and `...` elision (without it,
14 of language.md's most illustrative blocks would have to degrade to
`no_check`). The dialect is language surface, so it wants
[conformance](conformance.md) IDs when it lands.

## Corpus snapshot (2026-08)

What the verification faces on day one:

| Source                 | Tagged `thera` | Untagged | Notes                                                                                                      |
| ---------------------- | -------------- | -------- | ---------------------------------------------------------------------------------------------------------- |
| `sdk/std` doc comments | 109            | 3        | REPL-shaped; the 3 untagged are a flag table and two `openssl` transcripts, and now need a `text`/`sh` tag |
| `docs/language.md`     | 73             | 5        | 14 tagged blocks elide                                                                                     |
| `docs/stdlib.md`       | 2              | 29       | design fiction; migrates to `thera,no_check` as its APIs land                                              |

**Measured, not estimated.** The extraction and wrapper above were prototyped
and run against all 109 `sdk/std` blocks (`dev/doc_example_survey.py`):

| Outcome                                                      | Blocks |
| ------------------------------------------------------------ | ------ |
| compile clean already                                        | **49** |
| reference a name they never bind — `names.sort(…)`           | **41** |
| elide, with `...` or `…`                                     | 7      |
| reference a type or library they never import (`Auth`, `io`) | 2      |
| everything else                                              | 10     |

Of that last row, six are artifacts of the prototype's line-based extraction
(the real pass is parser-based) — and **two are genuinely broken
documentation**, which is the point of the exercise, found in an afternoon:
`sdk/std/net/net.thera` documents `'…'.to_bytes()`, a method that does not exist
(it is `bytes()`), and `sdk/std/testing/env.thera` documents
`fixed_env({ 'PORT': '8080' }, …)` using `{…}` map-literal syntax, which is not
Thera. Both are exactly the rot class this arc exists to stop, and both had
survived review.

So phase 1 is verification **and** a bounded migration: roughly 41 blocks gain
the binding or import they assume, 7 settle on `...`, 3 gain a non-Thera tag,
and 2 get fixed. That is the honest cost, and it is one sweep, once — after
which the default keeps it swept.
