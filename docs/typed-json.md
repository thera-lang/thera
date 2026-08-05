# Typed JSON — structs in, structs out

**What this is:** the design and staged plan for getting Thera structs into and
out of JSON well enough to write an API client with. It is
[api-access.md](api-access.md) Arc 1 item 3, pulled forward ahead of item 5
(reliability) on a reversibility argument: a codec convention gets copied into
every file an OpenAPI generator emits, so getting it wrong is a mass migration,
whereas a retry policy slides in under an unchanged `http.send` at any time.

The method is the one Arc 2 prescribes — **hand-write a real client first, and
let it name the gaps** — applied to the one part of Arc 2 that needs neither a
credential nor a network nor an answer to "where do non-`std` packages live": a
recorded response body and its decode are a pure function.

## Goals & non-goals

- **Primary goal — decoding a real API response is ordinary, readable Thera.**
  Not a page of `match` per response type. The measure is the Anthropic Messages
  response: seven fields, a nested struct, a list of discriminated blocks, two
  nullable fields, and a string enum.
- **Errors that say where.** `expected string at $.content[2].text, got number`.
  A generator will emit hundreds of decoders over 928 component schemas; a
  decode failure that names only the expected type is not debuggable at that
  scale. Path quality is a first-class requirement, not a nicety.
- **Validate [api-access.md](api-access.md)'s schema-to-type mapping table by
  hand** before Arc 3 automates it, and settle the two open questions that
  belong to decoding: forward-compatible `Unknown` variants (item 4) and
  undiscriminated `anyOf`.
- **Non-goal — a `@derive(json)` attribute.** api-access.md item 3 recommends
  explicit emitted codecs, on the grounds that a generator does not need a
  derive and emitted code participates in checking, grep, and refactors. This
  arc proceeds on that recommendation; if hand-writing proves painful enough to
  overturn it, that is a finding to record, not a stage to add.
- **Non-goal — a reflection-based `decode<T>`.** `std.json`'s own module doc
  promises one "awaits the reflection arc". Nothing here waits on it, and this
  arc should make the case for it weaker rather than stronger.
- **Non-goal — the rest of the Anthropic client.** Auth, retries, streaming
  Messages, and live calls are Arc 2 proper. This arc borrows exactly as much of
  that client as the JSON question needs.

## Where the code lives

`pkgs/anthropic/`, alongside `pkgs/cli`. The landing spot for non-`std`
libraries is still open ([scale.md](scale.md) item 4 owns it), and `pkgs/` is
api-access.md's own interim proposal — so this is that proposal being taken up,
not an answer. Things that should logically be packages get authored there and
may find other homes later; a generator and its emitted bindings would go the
same way.

## Staged plan

### Stage 1 — the forcing function

Hand-decode the Anthropic Messages response against **today's `std.json`**, with
no library changes at all, and write down what it cost. The response is chosen
because it covers most of the mapping table in one document: `struct` (`Usage`),
`oneOf` + `discriminator` (content blocks), a string `enum` (`stop_reason`),
nullable and absent fields (`Option`), `array` (`List<T>`), and an unmodeled
subschema (`tool_use.input`, whose shape is the tool's own).

The rule for this stage is that the code must be the **best** version achievable
with the current library, not a strawman — otherwise stage 2's delta is
flattering rather than informative.

**Deliverable:** working decoders, fixture tests, and § Findings below.

### Stage 2 — the `std.json` decode surface

Determined by stage 1's findings, deliberately not specified in advance. Then
rewrite stage 1's decoders on top of it and report the delta — in lines, and in
what a decode failure says.

### Stage 3 — the encode direction

Request construction: a Messages request has three required fields and a long
optional tail, which is the concrete form of api-access.md's most interesting
Thera-specific question — **default arguments versus an options struct**. Today
every leaf is wrapped (`json.str(x)`) and an absent optional field means a
conditional insert into a `mut` map, so this stage is where whether Thera's
default arguments actually pay off here gets an answer instead of a prediction.

### Stage 4 — graduate

Decided semantics into [stdlib.md](stdlib.md) or [language.md](language.md),
mapping-table rows marked validated in api-access.md, and this document deleted
— the same way the streaming plan was folded away when its arc closed (see the
[roadmap](roadmap.md)'s _Changelog_).

## Findings

From stage 1 — [pkgs/anthropic/](../pkgs/anthropic/), decoding the Messages
response against `std.json` unchanged. The baseline to beat: **101 code lines of
generic plumbing** ([decode.thera](../pkgs/anthropic/decode.thera)) to support
**62 code lines of actual decoders**
([messages.thera](../pkgs/anthropic/messages.thera)), covered by 16 tests.

### 1. Two thirds of the code is plumbing no client should own

`decode.thera` contains nothing about Anthropic. It is six field readers, each a
two-line wrapper turning an `Option` into a `Result`, times
required-and-optional, plus an arity variant for a value already in hand (an
array element has no key), plus a `kind_of` for naming what was found. **Every
API client would write this same file**, and a generator would emit it once per
generated package. It belongs in `std.json`.

The shape of the gap is specific and worth stating: `std.json`'s accessors are
right for a **lenient** consumer and wrong for a **strict** one. The LSP is the
lenient case — it reads `Option<String>` out of a request, `unwrap_or`s a
default, and never fails ([server.thera](../pkgs/cli/lsp/server.thera)). A
client is the strict case: a required field that is absent or the wrong type is
an error that has to name the field. Nothing in the library serves the second
reading, so the conversion gets written by hand, per field kind, per client.

### 2. A `Json` doesn't know where it came from

This is the finding with the highest consequence. Every reader has the signature
`(value, path, key)` — the path is a _separate argument_ because the value
carries no idea of its own location, and keeping the two in sync is the caller's
job at every level of every decoder. In 62 lines of decoders that is already 10
threaded path literals, and the failure mode is silent: nothing checks that the
`'$.usage'` handed to `usage_from_json` matches the `'usage'` key it was read
from, so a copy-pasted decoder reports confident, wrong locations.

```thera
// the key is spelled twice — once as data, once inside the path, and only
// convention keeps them equal
usage: usage_from_json(req_object(root, '$', 'usage')?, '$.usage')?,
```

Paths are not optional polish: a decode failure that says
`expected string, got number` with no location is not debuggable across 928
component schemas. So the library has to carry the path, which means the unit of
decoding is a **value paired with its location**, not a bare `Json`. That is the
central design consequence for stage 2.

### 3. `get` conflates absent with null

`at.get(key)` answers `Json.Null` both when a key is missing and when it is
present and null. Telling "missing required field `$.id`" from "`$.id` is null"
costs a helper that leans on `is_null` and gets the distinction _only_ for the
required case; for an optional field the two are simply indistinguishable
through the accessors, and recovering the difference means dropping to
`as_object()` and asking the `Map`.

That conflation happens to be correct for Anthropic — absent `stop_sequence` and
`"stop_sequence": null` mean the same thing — but it is not correct in general.
A PATCH-style API where `null` means "clear this field" and absent means "leave
it alone" cannot be modeled at all today, and the generator will meet one.

### 4. Nothing carries a failure out of a lambda

Decoding a list of N elements is a `for` loop over `enumerate()` pushing into a
`mut List`, because `List.map`'s lambda has nowhere to put a `Result`. The same
gap makes `Option<String>` → `Option<StopReason>` a four-line `match` rather
than a `map`. Both shapes recur once per array field and once per nullable enum
field, so a generator emits them hundreds of times. Whether the answer is a
fallible combinator (`try_map`), a decode helper that takes a per-element
decoder, or nothing at all is a stage-2 question — but the cost is real and it
is not Anthropic-specific.

### 5. `std.json` has no decode-error type

`JsonError` is `Syntax(String)` only: it models the **parser's** failures, not a
shape mismatch. So the package declares its own `DecodeError`, and so would
every other client, each with its own path syntax and its own idea of what to
report. Two libraries whose decode errors don't share a type can't be handled
uniformly by an application composing them, which is exactly the situation a
package ecosystem produces.

### 6. What did _not_ bite — the mapping table, mostly validated

Recorded because it is the deliverable api-access.md asked for, and because the
absence of trouble is evidence too:

| Mapping-table row                              | Verdict                                                                                                                                                       |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `object` → `struct`                            | **clean.** A struct literal with `?` in its field initializers means the decoder body _is_ the type's shape, one line per field. Preserve this in stage 2.    |
| `oneOf` + `discriminator` → `enum`             | **clean**, and better than expected — `match` accepts **string literal patterns**, so the dispatch reads the way the spec's `oneOf` does, one arm per branch. |
| string `enum` → `enum`                         | **clean.** `stop_reason_of` is total by construction: seven arms and a fallback, no `Result` needed at all.                                                   |
| nullable / not `required` → `Option<T>`        | **clean**, with finding 3's caveat about which kind of absence it means.                                                                                      |
| `array` → `List<T>`                            | works, but see finding 4 — it is a loop, not a `map`.                                                                                                         |
| unmodeled → `Json`                             | **clean and honest.** `tool_use.input` keeps the tool's own shape rather than being forced into a wrong type.                                                 |
| `allOf` → flattened struct                     | **not exercised.** No `allOf` in this response.                                                                                                               |
| `additionalProperties: {T}` → `Map<String, T>` | **not exercised.**                                                                                                                                            |
| undiscriminated `anyOf`                        | **not exercised**, and still the row expected to hurt. 527 occurrences in Anthropic's spec.                                                                   |

Two decisions this settles rather than merely surveys:

- **Forward-compatible `Unknown` should be the universal convention**
  (api-access.md item 4). It cost one variant per wire-decoded enum and it makes
  decode total in the discriminator, and the test that matters —
  `an_unknown_block_type_decodes_rather_than_failing` — shows the blocks
  _around_ the unknown one still decoding, with the raw value preserved so a
  caller can see what arrived. The cost is the extra `match` arm at each
  consumer, which is correct rather than regrettable: the case is real.
- **Tolerating an unknown tag is not tolerating a missing one.** A block with no
  `type` is an error, because there is nothing to dispatch on — that is a
  malformed document, not a new feature. Pinned by
  `a_block_with_no_type_is_an_error`.

### 7. No front-end holes

Unlike the TLS arc, which hit a language gap on day one (a generic bound could
not name a qualified type), everything here type-checked on the first attempt:
generic functions returning `Result<T, DecodeError>`,
`for … in list.enumerate()`, structural `Eq` on `Option<StopReason>` in
assertions, string-literal `match` arms, and `?` inside a struct literal's field
initializers. **The language was not the problem; the library is.** So stage 2
is expected to be library work, and no language change is proposed on this
evidence.
