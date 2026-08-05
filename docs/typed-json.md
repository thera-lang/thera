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

### Stage 2 — the `std.json` decode surface — **done**

`json.Cursor` and `json.DecodeError`, 129 code lines in
[json.thera](../sdk/std/json/json.thera) with 20 tests of their own. The design
falls straight out of finding 2: if the unit of decoding has to be a value
paired with its location, make that a type, let navigation accumulate the path,
and let the readers report it. See [stdlib.md](stdlib.md) § `std.json` for the
surface and § The delta below for what it bought.

### Stage 3 — the encode direction — **done**

Request construction: a Messages request has three required fields and a tail of
six optional ones, which is the concrete form of api-access.md's most
interesting Thera-specific question — **default arguments versus an options
struct**. The library side turned out to be two small functions (`json.opt` and
`obj`'s `omit_nulls`); the answer to the question, and the one language gap the
whole arc found, are in § Encoding, and the ergonomics below.

### Stage 4 — graduate — **mostly done**

Landed: the surface in [stdlib.md](stdlib.md) § `std.json`; api-access.md item 3
rewritten with the mapping table's six exercised rows marked validated, item 4
marked settled, and three of its open questions closed; the arc summarized in
the [roadmap](roadmap.md)'s _Changelog_.

**What keeps this document alive** is the evidence below — the measurements, and
the two things deliberately _not_ changed (no `try_map`, no implicit
`Some`-wrap), which are worth being able to re-read before anyone proposes them
again. It should be folded away and deleted once Arc 3 has a schema that
exercises `allOf`, `additionalProperties`, and an undiscriminated `anyOf`, since
those are the three mapping-table rows this arc could not validate by hand.

## Findings

From stage 1 — [pkgs/anthropic/](../pkgs/anthropic/), decoding the Messages
response against `std.json` unchanged. The baseline to beat was **101 code lines
of generic plumbing** (a `decode.thera` sibling, deleted in stage 2) to support
**62 code lines of actual decoders**
([messages.thera](../pkgs/anthropic/messages.thera)), covered by 16 tests. The
code below is quoted from that state, not from the tree.

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

### 7. No front-end holes — and one thing better than expected

**String-literal `match` patterns work.** Both dispatches were first written as
`if` chains on the tag; they are `match`es now, and the discriminator dispatch
reads the way the spec's `oneOf` does. `stop_reason_of` went from 20 lines to 8.

Otherwise:

Unlike the TLS arc, which hit a language gap on day one (a generic bound could
not name a qualified type), everything here type-checked on the first attempt:
generic functions returning `Result<T, DecodeError>`,
`for … in list.enumerate()`, structural `Eq` on `Option<StopReason>` in
assertions, string-literal `match` arms, and `?` inside a struct literal's field
initializers. **The language was not the problem; the library is.** So stage 2
was library work, and no language change is proposed on this evidence.

## The delta

Stage 1's decoders rewritten on `json.Cursor`, keeping the same tests plus two
the cursor made worth adding. Every number is the same file measured the same
way (non-blank, non-comment lines):

|                                 | stage 1     | stage 2                           |
| ------------------------------- | ----------- | --------------------------------- |
| generic plumbing in the package | 101 lines   | **0** — `decode.thera` deleted    |
| the decoders themselves         | 62 lines    | **51 lines**                      |
| error paths threaded by hand    | 10 literals | **0**                             |
| shared, in `std.json`           | —           | 129 lines, once, for every client |

The line counts are the least of it. Three things changed in kind:

- **The path duplication is gone.**
  `usage_from_json(root.field('usage').object()?)` spells `usage` once. There is
  no longer a way to write a decoder that reports a location it is not reading.
- **Two failure messages got more accurate**, not just cheaper. A fractional
  number read as an integer said `expected number at $.frac, got number` and now
  says `expected an integer`; and a required field that is present but `null`
  said `missing required field $.id`, which was simply wrong, and now says
  `expected a string at $.id, got null`. Stage 1 could not tell those apart —
  `get` answers `Null` for both — and the cursor's `present` flag is what does.
- **Finding 4 partly dissolved.** `Option<String>` → `Option<StopReason>` is now
  `.opt_string()?.map(stop_reason_of)`, one line, because `stop_reason_of` is
  total. A fallible `map` is still absent, but the case that seemed to want one
  was an artifact of reading and converting in a single step. What remains is
  the list loop, two lines and now building no paths — so **no `try_map` is
  proposed**.

Two findings are deliberately left standing rather than fixed. Finding 3's
absent-versus-null conflation is _resolved_ for required fields and _exposed_
for optional ones: `opt_*` still reads both as `None`, because that is what
almost every API means, and `present`/`is_null` are there for the API that gives
them different meanings. Finding 5 is closed by `DecodeError` living in
`std.json`, so two libraries' decode failures are now the same type and an
application composing them can handle "a decode failed" once.

## Encoding

[requests.thera](../pkgs/anthropic/requests.thera) is the request side: a
`Request` struct, a `create` constructor, and `request_to_json`. Two library
additions carried it, both small enough to argue that encoding was never the
hard direction:

- **`json.opt(value, encode)`** — `Some(v)` through `encode`, `None` as
  `Json.Null`. `encode` is normally a constructor
  (`json.opt(req.top_k, json.int)`), which is what makes this one function
  rather than six `opt_int`/`opt_str` variants.
- **`json.obj(fields, omit_nulls: true)`** — drops the `Null`-valued entries, so
  an absent optional field is absent from the body rather than
  `"temperature": null`. Own entries only, not recursive, and per-call, so an
  API that means something by an explicit `null` builds that part with the flag
  off.

Together they make `request_to_json` one line per field, with no conditional
insert and no `mut` map — the encoder reads as the request's shape, the same way
the decoders read as the response's.

### Default arguments do pay off — with one specific tax

`create` takes the three required fields and defaults the six optional ones to
`Option.None`, so the common call names three arguments and nothing else:

```thera
let req = anthropic.create(
    model: 'claude-sonnet-4-5-20250929',
    messages: [anthropic.user('hello')],
    max_tokens: 1024,
);
```

That is the shape api-access.md hoped for, and it beats the alternatives on real
grounds rather than taste. An all-fields **struct literal** is not viable: Thera
struct fields have no per-field defaults, so every construction would spell all
nine. A **wither chain** (`.with_temperature(0.7)`) is thirty-odd lines of
library code to reimplement the feature the language already has.

**The tax:** an `Option<T>` parameter does not accept a bare `T`, so every
optional argument a caller _does_ pass is spelled `Option.Some(…)`.

```thera
    temperature: Option.Some(0.5),     // what you write
    temperature: 0.5,                  // what you want to write
```

Thirteen characters of ceremony per optional argument, on the calls agents write
most, and it lands squarely on the feature that was supposed to be the
advantage. `a_full_request_carries_every_field` in
[requests_test.thera](../pkgs/anthropic/requests_test.thera) is the evidence:
nine arguments, six of them wrapped.

**No change is proposed here, deliberately.** The obvious fix is an implicit
`Some`-wrap, by analogy with the implicit `Ok`-wrap Thera already has — but that
analogy is weaker than it looks. The implicit `Ok` is a **return-position** rule
([language.md](language.md) § `throw`), while this would be an
**argument-position** coercion, and language.md states flatly that there are "no
implicit conversions of any kind". A new coercion site is a language-design
decision with reach far beyond JSON, and it should be made on more evidence than
one client's request builder. What this arc contributes is the evidence: the
cost is real, it is concentrated in exactly the high-volume position, and it is
the only ergonomic complaint the whole arc produced.

### One front-end bug, found and fixed

`json.arr(values.map(json.str))` — a **namespace-qualified function used as a
value** — type-checked and then failed to compile, with
`field access on non-struct value` blamed on the reference. Codegen's namespace
branch knew `ns.CONST` and `ns.global` but not `ns.fn`, so it fell through to
struct field access; the bare `xs.map(str)` had always worked.

A check-clean program that cannot be compiled is the worst shape a front-end bug
can take, so it is fixed here rather than worked around
([codegen.thera](../pkgs/cli/codegen/codegen.thera) — one branch, emitting
`ClosureNew` over the resolved unit, the qualified counterpart of
`load_function_value`). Ordinary `pub fn`s and `native fn`s both resolve. Pinned
by
[tests/lang/functions/qualified_fn_reference.thera](../tests/lang/functions/qualified_fn_reference.thera),
which covers both.

This is the arc's one language-level finding, and it is the same shape as the
TLS arc's: reaching for an ordinary composition of two documented features
(first-class functions, qualified names) across a library boundary, and finding
the combination had never been exercised.
