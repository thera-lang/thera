# std.toml — a durable config format

**What this is:** the design for a `std.toml` core library — TOML 1.0.0 parsing
plus the same two typed-reading styles `std.json` has — and the staged plan to
build it. It is driven by two manifests that now need to exist:
[api-access.md](api-access.md)'s per-generated-API manifest (`api.toml`: spec
URL, hash pin, selected operations, overrides — each override wanting a comment
saying _why_) and [scale.md](scale.md) item 4's package manifest (declared
dependencies, layering). Both docs currently carry the same blocker in their
open questions: "there is no `std.toml`". This doc is the plan to remove it.

## Why TOML, and why core

**Why TOML.** Both use cases are hand-edited, comment-bearing configuration
read by the toolchain. JSON — the only hand-editable format Thera reads today —
has no comments, and a manifest is exactly the file where the reason for an
override belongs ([api-access.md](api-access.md) § The manifest). YAML is the
other candidate and loses on spec surface: TOML 1.0.0 is a short, stable spec
with an unambiguous data model and a standard conformance suite; YAML is
neither short nor unambiguous. (A `std.yaml` may still happen for a different
reason — Anthropic publishes its OpenAPI spec only as YAML — but that is an
ingestion problem, not a config-format problem, and it should not decide this.)

**Why core rather than ecosystem.** [stdlib.md](stdlib.md) placed TOML in
ecosystem with an explicit promotion clause: _"the first candidate to promote
into core if real use cases pile up. Pivot when the demand is demonstrated, not
speculatively."_ This is that clause firing — two in-repo use cases, both on
the toolchain's critical path: if `check` enforces a package manifest (scale.md
item 4) then the compiler itself is a TOML reader, and a format the compiler
reads cannot live downstream of the compiler. The library needs no natives
(pure Thera over `String`, like `std.json` and `std.encoding`), so promotion
costs nothing on the runtime side.

**Version target: TOML 1.0.0.** 1.1 remains unreleased; adopt it when it ships
if the manifests want anything it adds (trailing commas in inline tables is the
plausible candidate). Nothing below depends on the choice.

## The value model

Deliberately parallel to `Json` — same naming scheme, same structural-enum
shape, same insertion-ordered `Map` so serialization is stable:

```thera
pub enum Toml {
    Bool(Bool),
    Int(Int),                     // TOML integer: i64, all four bases
    Double(Double),               // TOML float, including inf and nan
    Str(String),                  // all four string forms normalize to this
    Datetime(Datetime),           // the one non-JSON shape — see below
    Array(List<Toml>),            // heterogeneous is legal in 1.0
    Table(Map<String, Toml>),     // insertion-ordered
}
```

Two deliberate differences from `Json`, both forced by the format:

- **No `Null`.** TOML has no null; absence is the only optionality. This is a
  feature for the manifest use case — "field absent" is the one optional state,
  so the `Option`-vs-null distinction that JSON decoders wrestle with does not
  exist. `Cursor`'s `opt_*` accessors mean exactly "key absent" and nothing
  else.
- **`Datetime`.** TOML has four date-time kinds (offset date-time, local
  date-time, local date, local time) and `std.time` models none of the local
  three. Rather than invent date/time-of-day types nothing else needs, the
  variant carries a small struct — the kind plus the validated, normalized
  source text — with one bridge for the kind that maps cleanly:

  ```thera
  pub enum DatetimeKind { OffsetDateTime, LocalDateTime, LocalDate, LocalTime }

  pub struct Datetime {
      kind: DatetimeKind,
      text: String,               // validated and normalized (T separator, upper Z)
  }

  impl Datetime {
      /// The instant, for `OffsetDateTime` only — via `time.parse_rfc3339`.
      pub fn to_datetime(self) -> Result<time.DateTime, Error> { … }
  }
  ```

  Neither manifest uses datetimes at all — but a TOML parser that rejects valid
  TOML is not a TOML parser, and this shape is spec-complete, round-trips
  exactly, and costs no new `std.time` surface. If a real use case ever wants
  local dates as values, that is a `std.time` conversation, not a `std.toml`
  one.

## The reading surface — the same two styles as `std.json`

`std.json` settled a two-style reading model and [typed-json.md](typed-json.md)
validated it against a real client; `std.toml` copies it name-for-name so an
agent learns one idiom:

- **Lenient accessors** for exploratory reads: `get(key)` / `at(index)`
  chainable with a miss propagating (a miss yields a sentinel the `as_*`
  accessors all reject — the role `Json.Null` plays in `std.json`; without a
  `Null` variant the likely spelling is `get` returning `Option<Toml>` with
  `as_*` also on `Option<Toml>`, settled in stage 1), plus
  `as_bool/as_int/as_double/as_string/as_array/as_table` returning `Option`,
  and `kind()` for error messages.
- **`toml.Cursor`** for the strict path — and the manifests are exactly its
  use case: a typo'd key or mistyped value should fail with the path that
  names it. Mirrors `json.Cursor`: `field`/`index` navigate and accumulate the
  path, `string()/int()/double()/bool()/datetime()/table()/list()/raw()`
  demand a shape, `opt_*` variants read absent-as-`None`, `unexpected()` for
  caller-side shape errors, `toml.DecodeError` carrying `path` + `message`.

One deliberate divergence: **paths render in TOML's own spelling** —
`expected a string at tool.dependencies[2], got integer` — not `json.Cursor`'s
`$.a.b[0]`. The error points at a line the user wrote in TOML syntax; dotted
keys are how that file spells the path already.

**Mirrored, not shared.** Sharing `Cursor` between the two libraries would
mean a generic cursor over a common value interface — machinery with real
design cost, bought to deduplicate ~150 lines of straightforward code that is
finished the week it is written. Two small copies with identical names is the
better trade; revisit only if a third format reader ever appears.

## Errors

`toml.TomlError` follows `json.JsonError`: a domain error implementing
`Error`, message carrying line/column. TOML has a class JSON lacks — document
errors that are not lexical (duplicate key, redefining a table, extending an
inline table or a static array) — but they are still "this document is
invalid, here's where", and one variant whose message names the violated rule
serves the caller exactly as well as an enum of rule names would. Start with
`Syntax(String)`; split only if a caller demonstrates a need to dispatch on
the class.

## Writing — staged behind demand

Both driving use cases are read-only: manifests are written by hand and read
by tools. So v1 is parse-only, and the write side splits into two very
different features:

- **`toml.stringify` — deferred to its own stage**, landing the week a tool
  first writes a manifest (`thera api init` sketching an `api.toml` is the
  plausible trigger). Deterministic emit with fixed style rules (nested tables
  as `[a.b]` headers, arrays of tables as `[[x]]`, leaves inline, bare keys
  where legal), plus the `json`-style lowercase constructors
  (`toml.str`, `toml.int`, …) which have no purpose before it.
- **Comment-preserving editing — explicitly out of scope.** Updating one field
  in a hand-written manifest without disturbing its comments and layout
  requires a lossless document model (what Rust's `toml_edit` is), which is a
  different, much larger library. If a `thera pkg add`-shaped tool ever needs
  it, it gets its own design; nothing in this arc should pretend to be it.

## Where the code lives

`sdk/std/toml/toml.thera` with tests beside it, per the stdlib convention:

```
sdk/std/toml/
  toml.thera          the library: model, parser, accessors, Cursor
  toml_test.thera     unit tests
  testdata/           the vendored conformance snapshot (see below)
```

Pure Thera, no natives. `std.json`'s scanner + recursive-descent parser is 983
lines including `Cursor`; TOML's grammar is meaningfully wider (four string
forms, four integer bases, datetimes, and the table-definition semantics), so
expect ~1,400–1,600 lines — still comfortably a single-file library.

## Conformance — `toml-test`

TOML has what JSON never had: **an official conformance suite**,
[toml-lang/toml-test](https://github.com/toml-lang/toml-test) — hundreds of
valid documents paired with a JSON encoding of the expected value, and
hundreds of invalid documents that must be rejected. Every serious
implementation runs it, and it concentrates exactly where TOML is genuinely
hard: the table-definition and dotted-key rules (what may be defined, extended,
or appended to, and when).

Plan: **vendor a snapshot** under `sdk/std/toml/testdata/` (MIT-licensed small
text files), with a `@test` runner in `toml_test.thera` that walks it — valid
cases decode the expected-value JSON **with `std.json`** and compare; invalid
cases assert an `Err`. Checked in rather than fetched, for the same reason the
bootstrap snapshot is: the build tolerates no external toolchain and CI stays
hermetic. A `dev/` refresh script (the `spec_survey.py` pattern) re-pulls the
suite when the pin moves. If the full snapshot proves bulky, curate — but
start from "all of it" and cut with evidence, since the invalid set is where
the value is.

## Staged plan

Small, self-contained increments, each landing `cargo test`/`bin/test.sh`
clean, per the working conventions.

### Stage 1 — the model and flat documents

The `Toml` enum, the lenient accessors, and `toml.parse` for documents without
table headers: bare/quoted/dotted keys at the root, comments, all four string
forms (with the escape set, `\u`/`\U` scalar validation, control-character
rejection, CRLF), integers in four bases with underscore rules, floats
including `inf`/`nan` (`math.INFINITY`/`math.NAN` exist), booleans, arrays,
inline tables. Settles the `get`-miss spelling (sentinel vs. `Option`).

### Stage 2 — the table semantics

`[table]` headers, `[[array-of-tables]]`, dotted-key table creation, and the
full definition/extension rules — implicit vs. explicit definition,
redefinition errors, the inline-table and static-array sealing rules. This is
the hard middle of TOML and where most of the invalid conformance cases point;
the stage is done when the semantics match the spec's rules as written, with
the suite as the referee in stage 3.

### Stage 3 — datetimes and the conformance snapshot

The four `Datetime` kinds with validation and normalization, the
`to_datetime()` bridge, then vendor `toml-test` and drive the pass rate to
100% — expect this to flush out edge cases from stages 1–2 (that is its job).

### Stage 4 — `Cursor`

The strict reader, mirrored from `json.Cursor` with TOML-spelled paths. Ends
with a forcing-function test in the typed-json spirit: decode a realistic
`api.toml` (the [api-access.md](api-access.md) § manifest sketch — spec URL,
pin, operations list, overrides table) into typed structs, and let that
exercise report any surface gaps before a real consumer exists.

### Stage 5 — `stringify` and constructors, when a writer appears

Deferred until a tool writes a manifest. Deterministic style rules decided
then; tested by round-trip against the parser plus golden files.

### Graduation — and this doc's retirement

**This doc is transient**: it exists to carry the design through the arc, and
when stage 4 lands (stage 5 being demand-triggered) it is retired rather than
maintained. Anything durable therefore gets inlined elsewhere as it lands,
and the doc's residue is a changelog line, not a document:

- [stdlib.md](stdlib.md) gains the § `std.toml` catalog entry — the durable
  home for the surface and its rationale: the value model and its two
  deliberate deltas from `Json` (no null, the `Datetime` text-carrying shape),
  the mirrored-not-shared `Cursor` decision with TOML-spelled paths, the
  parse-only-until-a-writer-appears line, and the conformance-snapshot
  convention. The "intentionally not in core" list is edited: TOML moves out
  (recording that the promotion clause fired as designed — demand demonstrated
  by two in-repo manifests), YAML/CSV stay ecosystem.
- The module doc (`//! std.toml — …`) carries the reader-facing version of the
  same decisions, the way `std.json`'s header explains its two reading styles.
- [api-access.md](api-access.md)'s "manifest format" open question closes:
  `std.toml` exists, the manifest is `api.toml`, and "separate files, same
  format" stands for item 4's package manifest.
- [scale.md](scale.md) item 4's format constraint ("JSON is the only
  hand-editable format Thera reads today") is rewritten to point at stdlib.md.
- The [roadmap](roadmap.md) changelog records the arc; the toc entry and this
  file are deleted.

## Open questions

- **The `get`-miss spelling.** `Json.get` returns `Json.Null` on a miss to
  keep chains flowing; `Toml` has no null. `Option<Toml>` with accessors on
  the option, or a private miss sentinel, or `get` chains only via `Cursor`?
  Stage 1 settles it; the constraint is that the lenient style must stay
  chainable or it has no reason to exist.
- **Snapshot size.** Vendor all of `toml-test` or a curated subset? Start
  full, measure, cut with evidence.
- **Error granularity.** One `Syntax(String)` variant (the `std.json`
  precedent) vs. splitting lexical from semantic document errors. Default to
  one until a caller needs to dispatch.
- **Where the first `api.toml` schema is specified.** This doc owns the
  format; [api-access.md](api-access.md) § The manifest owns the fields. The
  stage-4 forcing-function test should be written against that section's
  sketch so the two documents cannot drift silently.
