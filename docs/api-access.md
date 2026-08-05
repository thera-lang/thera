# API access for Thera tools

**What this is:** the plan for letting Thera programs call third-party HTTP APIs
— GenAI, MCP, GitHub, and the long tail. It has three arcs, deliberately
ordered: (1) the **platform substrate** every API client needs and Thera mostly
lacks; (2) **one hand-written client** as a forcing function that finds those
gaps and settles what a Thera API client should look like; (3) an **OpenAPI
generator** that turns that shape into a repeatable one, so the Nth API costs
days instead of weeks. It closes with a measurable method for choosing which
APIs to target next. Items graduate the same way [scale.md](scale.md)'s do: a
decided semantic lands in [language.md](language.md) or [stdlib.md](stdlib.md),
a scoped piece of work becomes a [roadmap](roadmap.md) arc, and the item here
shrinks to a pointer.

## Why this is load-bearing

Thera's stated target domain is CLI tools and agent scripts
([overview.md](overview.md)). Nearly every such tool is a client of some HTTP
API — it calls a model, opens a PR, reads a bug tracker, uploads an artifact.
Today Thera can call **none** of them: `std.http` is `http://`-only, and every
API worth calling is HTTPS-only. This is not a nice-to-have adjacent to the
target domain; it is a hard gate across the middle of it.

The second-order argument is dogfood. Thera's pitch is that it maximizes the
productivity of LLMs and coding agents. A Thera program that calls Claude or
Gemini is the shortest path from that claim to a demonstration — and the
client's ergonomics are a direct, honest test of whether the language's
distinguishing features (errors as values, default arguments, exhaustive match,
interfaces) actually pay off on the code agents write most.

## The strategy, in one line

**OpenAPI 3.x is the interchange format; the emitter is written in Thera; the
runtime substrate is where the real work is.**

### Why OpenAPI and not a vendor

The commercial SDK generators — Stainless, Speakeasy, Fern, liblab — are SaaS
products that emit SDKs for a fixed language list, and there is no path to
getting Thera onto it. What they all _consume_ is OpenAPI. Supporting OpenAPI
puts Thera downstream of the same artifact that produces the official
Python/TypeScript SDKs for the APIs we care about. The 2026-08 supply-side
survey (all fetched and verified, not taken from documentation claims; re-run it
with `dev/spec_survey.py`, which is where every number below comes from):

| API          | Spec                                                      | Version | Size    |
| ------------ | --------------------------------------------------------- | ------- | ------- |
| Anthropic    | the URL in `.stats.yml` of the official SDK repos         | 3.1.0   | 1.8 MB  |
| OpenAI       | `openai/openai-openapi` (officially published)            | 3.1.0   | 2.8 MB  |
| Gemini       | `generativelanguage.googleapis.com/$discovery/OPENAPI3_0` | 3.0.3   | 100 KB  |
| GitHub       | `github/rest-api-description`                             | 3.0.3   | 12.9 MB |
| Cloudflare   | `cloudflare/api-schemas`                                  | 3.x     | 23 MB   |
| Vercel       | `openapi.vercel.sh`                                       | 3.x     | 9.8 MB  |
| Fly Machines | `docs.machines.dev/spec/openapi3.json`                    | 3.x     | 138 KB  |
| **AWS**      | **Smithy, not OpenAPI** (`aws/api-models-aws`)            | —       | —       |

Two caveats worth carrying forward. Anthropic's spec is real and public but is
**not advertised as a supported artifact** — the URL is content-hash-pinned per
SDK release, so a client's manifest re-reads `.stats.yml` to find the current
one, and the pin is a feature (see § Arc 3, determinism). And **AWS is the one
structural holdout**: everything AWS is modeled in Smithy. If AWS ever matters,
that is a second ingestion path, not a reason to weaken the OpenAPI decision.

Both `3.0` and `3.1` appear in the slate above, so the reader must accept both.
`3.2` (Sept 2025) is near-superset of 3.1 and can wait for a spec that uses it;
`2.0` is out of scope.

### Why write the emitter rather than adopt one

Two credible open-source generators could be extended to target Thera:

- **[OpenAPI Generator](https://github.com/OpenAPITools/openapi-generator)** —
  50+ targets, most battle-tested. Adding Thera is a Java class plus Mustache
  templates.
- **[Kiota](https://github.com/microsoft/kiota)** — better architecture: it
  builds a URI-space tree from the spec, filters it, lowers to a
  language-agnostic code model, and a per-language `LanguageWriter` emits text.
  Dart support was contributed by the community, which is the existence proof
  that the extension point works for a small language.

Both are rejected for the same two reasons. First, each drags an external
toolchain (a JVM, a .NET runtime) into a build whose defining property is that
it needs none — the checked-in bootstrap snapshot exists precisely so the build
is self-contained. Second, and more decisive: **both still require implementing
a per-language runtime layer** (Kiota's `abstractions` + serialization + auth
libraries; OpenAPI Generator's equivalent), which is the expensive half. If the
runtime layer is unavoidable either way, the emitter — a filtered tree-walk
producing text, over a spec `std.json` already parses — is the cheap half, and
writing it in Thera buys output that matches Thera's own idioms instead of
fighting a template system designed for Java.

Kiota's design is still worth reading as prior art; § Arc 3 borrows its
URI-space-tree filtering wholesale.

## Arc 1 — the platform substrate

What a real API client needs, and where Thera stands. Ordered by how hard they
gate the rest.

### 1. HTTPS — **done, graduated**

The gate is open: `http.get('https://…')` works, chain- and host-verified
against the bundled roots. [http-tls.md](http-tls.md) stage 4 replaced the
client's "not supported" branch with `net.connect_tls`, and `HttpError` gained a
`Tls(String)` variant — its own rather than a `Connect`, because it is the one
connect failure a retry cannot fix, which is the distinction item 5's retry
policy has to make. Verified against live failure modes (unknown issuer, expired
certificate, host-name mismatch), each arriving as `Tls` with the specific
reason.

Stage 5 then closed the test story: `tls_accept` plus a file-private
`net.accept_tls` give a real client↔server handshake in one process, so the TLS
stack is covered with no network — including the security assertion that an
untrusted certificate is refused. Two coverage notes carry forward: the trust
seam deliberately stops at `std.net` (reaching it from `std.http` would mean
making trust injection public API), so a full `https` **round trip** is a gated
live smoke rather than a hermetic test; and the test certificate is checked in
with a 2052 expiry rather than minted.

The arc also paid a dividend the plan didn't anticipate. Wiring TLS in hit a
front-end hole — **a generic bound could only name a bare type**, so
`fn f<S: io.Reader>` did not parse and no generic could be bounded by an
interface from another library — which has since been fixed (qualified bounds
and super-interfaces both resolve through the namespace now; see the roadmap's
_Changelog_). Worth recording because Arc 2 would have hit it on day one: a
typed client is generic code over `std` interfaces, and that was exactly the
combination that didn't compile. The http client's one connect-and-write path is
now `fn open<S: io.Reader + io.Writer + io.Closer>` — spelled `exchange` when it
first consumed the fix, before item 2 made it the streaming entry point.

### 2. Streaming responses and SSE — **done, graduated**

Token streaming is the default interaction mode for every GenAI API, and
server-sent events are the transport all three of Anthropic, OpenAI, and Gemini
use for it — so a client that could only await a complete response was a toy for
the flagship use case. It isn't one now: `http.stream(request)` returns once the
head is in, with the body as an `io.Reader`, and `std.http.sse` decodes a
`text/event-stream` off it event by event. `send` is that plus a capped read
plus the close, so the buffered and streaming paths cannot drift. The API
surface is in [stdlib.md](stdlib.md) § `std.http`; what the three stages settled
is in the roadmap's _Changelog_.

Two things from it that this document had wrong, both worth carrying because
they are the kind of mistake that gets baked in:

- **The `[DONE]` sentinel is not part of SSE.** It is an OpenAI convention, and
  Anthropic doesn't use it — its stream terminates with `event: message_stop`.
  So it belongs to layer (c), per API, and the framing layer does not know it.
- **SSE landed as `std.http.sse`, not a top-level `std.sse`.** The format
  depends only on `std.io`, but an event stream is always something an HTTP body
  delivers, and the top-level namespace shouldn't grow a name per format riding
  on one.

**What's left is layer (c), the typed event stream**, and it is Arc 2's: the
framing layer yields `Iterator<Event>` with `data` as a `String`, and turning
that into an API's own event enum needs that API's schema. Choosing between an
iterator, a fiber `channel`, and a callback is one line on § the client-shape
checklist; all three are buildable over an `Iterator<Event>`.

### 3. Typed JSON — structs in, structs out — **substrate done**

**Problem.** A generated client is mostly types. Getting a Thera struct into and
out of JSON is the single highest-volume operation in every client. **Was.**
`std.json` was a dynamic `Json` enum with `parse`/`stringify` and constructors,
whose accessors suit a _lenient_ reader and not a client: hand-decoding one
Anthropic response cost roughly a page.

**Now.** `json.Cursor` is the strict counterpart — a `Json` paired with where it
came from, so navigating accumulates a path and a failure names it
(`expected a string at $.content[1].text, got number`) — plus
`json.DecodeError`, `json.opt`, and `obj`'s `omit_nulls` for the encode
direction. Surface in [stdlib.md](stdlib.md) § `std.json`; the arc, its
measurements, and the alternatives rejected along the way are in
[typed-json.md](typed-json.md).

**The recommendation held.** Explicit codecs, no `@derive(json)` and no
reflection: a generator does not need a derive, and emitted
`from_json`/`to_json` pairs are ordinary, greppable Thera that participate in
checking and refactors. Hand-writing them against the cursor is 51 code lines
for the whole Messages response, which is not painful enough to reopen the
question.

The schema-to-type mapping, validated by hand against a real response rather
than assumed:

| OpenAPI construct               | Thera                                 | Validated                       |
| ------------------------------- | ------------------------------------- | ------------------------------- |
| `object` with fixed properties  | `struct`                              | ✓                               |
| `oneOf` + `discriminator`       | `enum` with a variant per branch      | ✓ (string-literal `match` arms) |
| `enum` of strings               | `enum` (plus a raw-string round trip) | ✓                               |
| nullable / not in `required`    | `Option<T>`                           | ✓                               |
| `array`                         | `List<T>`                             | ✓                               |
| unmodeled / `true` schema       | `Json` (the honest escape hatch)      | ✓                               |
| `additionalProperties: {T}`     | `Map<String, T>`                      | not exercised                   |
| `allOf`                         | flattened into one struct             | not exercised                   |
| `anyOf` without a discriminator | **open question** — see below         | not exercised                   |

Anthropic's spec alone contains 928 component schemas with 527 `anyOf`, 238
`oneOf`, 229 `discriminator`, and 165 `allOf` occurrences — so none of these
rows is hypothetical. **But the `anyOf` figure was misleading, and the survey
caught it:** 480 of those 527 are `anyOf: [T, {type: null}]`, which is 3.1's
idiomatic spelling of `Option<T>` and not a union at all. Only **47** are
genuinely untagged, 22 of them unions of `$ref`s. Undiscriminated `anyOf` is a
real row, but a far smaller one than "527" implied — see § Choosing targets.
**Status.** The library is done and the six rows a real response exercises are
validated; the last three want a schema that uses them, which is Arc 3's problem
rather than a reason to guess now.

### 4. Forward compatibility — **settled**

**Problem.** Tomorrow the API adds a content-block type, a stop reason, or an
error code. A client that decodes into a closed Thera enum and matches
exhaustively will **fail on a response it should have tolerated** — and it will
fail for every user at once, remotely triggered, with no code change on our
side. This is the defining bug class of generated clients and it interacts
directly with Thera's exhaustive `match`.

**Decided, with tests behind it** ([typed-json.md](typed-json.md) § Findings 6).
Two rules, and they are a pair:

1. **Every wire-decoded enum gets an `Unknown` variant, uniformly** —
   `Unknown(Json)` where the branch carries a body, `Unknown(String)` for a bare
   string enum, so the raw value survives for a caller to inspect or log. Decode
   never fails on an unrecognized tag. The cost is one `match` arm per consumer,
   which is correct rather than regrettable: the case is real. Uniform, not
   opt-out-able by an `x-` extension — a spec cannot know it will never be
   extended, and a per-schema exception is a footgun with no upside.
2. **Tolerating an unknown tag is not tolerating a missing one.** A block with
   no `type` at all is a decode error, because there is nothing to dispatch on:
   that is a malformed document, not a new feature. Losing this distinction
   would turn every shape bug in the discriminator into a silent `Unknown`.

**Status.** Settled and exercised — `pkgs/anthropic` decodes a real
`web_search_tool_result` block it has never heard of, with the blocks around it
still decoding.

### 5. Reliability — retries, timeouts, redirects, pooling

**Problem.** Real API traffic is 429s, 529/overloaded, transient 5xx, and slow
responses. A client without retry-with-backoff is not usable unattended, which
is exactly the mode agent scripts run in. **Today.** Deferred alongside TLS in
[stdlib.md](stdlib.md): redirect following, connection pooling, and per-request
timeouts. `HttpError` already distinguishes `Connect` / `Timeout` / `Status` /
`Body` / `Protocol`, which is the right vocabulary to retry against.
`fiber.select` and `fiber.with_timeout` exist, so bounding a wait is available
today. **Direction.** Retry with exponential backoff + jitter, honoring
`Retry-After`; an idempotency policy (retrying a non-idempotent POST needs the
API's blessing — several GenAI APIs supply idempotency keys); per-request
timeout distinct from per-connection; redirects and keep-alive as independent
follow-ons. Where this lives is a real question: a shared `std.http` retry
policy, or per-client logic the generator emits? **Shared** is the better answer
— retry behavior is not API-specific and should not be duplicated N times.

One timeout shape the streaming work surfaced and left here: the useful bound on
a token stream is **"no event for N seconds"**, not "the whole stream within N
seconds", and `fiber.with_timeout` only gives the latter. It also has to treat
an SSE keep-alive comment as liveness — a comment produces no event but does
mean the peer is alive, so a per-event clock that ignores comments would cancel
a healthy stream. **Status.** Open. Retry is required for Arc 2; pooling and
redirects are not.

### 6. Auth and secrets

**Problem.** Every API needs a credential, usually from the environment, and it
must never reach a log or an error message. **Today.** `std.env` exists with the
ambient-capability model ([stdlib.md](stdlib.md)), which is the right shape: an
ambient free function plus an opt-in capability interface for tests.
**Direction.** Mostly convention rather than machinery: a client reads its key
from a named env var by default and accepts an override. The one piece of real
design is **redaction** — a credential-carrying value should not be printable
via `Debug`, and today nothing prevents that. Bearer/API-key is the whole slate
for now; OAuth device flow and AWS SigV4 are deliberately out of scope (see §
Choosing targets — they are a ranking criterion, not a v1 feature). **Status.**
Open, small.

### 7. Multipart and binary bodies

**Problem.** File uploads (a Files API, a GitHub release asset) need
`multipart/form-data`; downloads need to not go through `String`. **Today.**
`Bytes` and `BytesBuilder` make this buildable; nothing exists. **Direction.**
Defer until a chosen target actually needs it. Named here so the generator
doesn't silently emit a broken operation — an unsupported content type must be a
generation-time error, not a runtime surprise. **Status.** Deferred, tracked.

### 8. Hermetic testing

**Problem.** Tests that hit a live API are slow, flaky, cost money, and need a
credential in CI. Every client and every generated client needs a test story.
**Today.** `std.http.server` exists (plaintext HTTP/1.1), and
[http-tls.md](http-tls.md) stage 5 is the hermetic **in-process TLS loop** —
which is exactly the machinery an API-client test needs. **Direction.** Lean on
stage 5 rather than inventing a parallel mechanism: spin a local TLS server,
point the client's `base_url` at it, assert on the exchange. Recorded-fixture
replay is the cheaper complement for response-decoding tests (a captured
response body plus its decode is a pure function — no server needed). Both are
worth having; the decode tests are far more numerous. **Status.** Open;
**synergy worth noting** — stage 5 was already planned for TLS and now pays for
two things.

## Arc 2 — one hand-written client, as a forcing function

**Why hand-write first.** Generating before you know what good output looks like
means generating the wrong thing at scale — and at scale nobody notices, because
nobody reads generated code. The first client is a specification-by-example of
the generator's target: it fixes the shape, and it flushes out Arc 1's gaps in
the order a real caller hits them rather than the order we guessed.

**Which API: Anthropic Messages.** The reasons, in order of weight:

1. **It exercises every substrate gap at once** — HTTPS, SSE streaming, deeply
   nested discriminated unions (content blocks), 429/529 retry, long timeouts.
   One client, maximum coverage of Arc 1.
2. **The interesting surface is tiny.** 89 paths / 131 operations in the full
   spec, but a genuinely useful client is `POST /v1/messages` (streaming and
   not), `POST /v1/messages/count_tokens`, and `GET /v1/models`. Small enough to
   hand-write carefully; rich enough to be representative.
3. **It is dogfood.** See § Why this is load-bearing.
4. **The spec is public and machine-readable**, so the hand-written client and
   the eventually-generated one derive from the same source of truth — which
   makes the diff between them the generator's acceptance test (§ Arc 3).

**Scope.** The three operations above. Explicitly not: Batches, Files, the Admin
API, or the `?beta=true` path variants (a Stainless spelling that the generator
will have to decide about later, but not now).

**Where it lives — open.** Not `sdk/std`: this is ecosystem tier by
[stdlib.md](stdlib.md)'s own line. But Thera has no package manager and no
third-party package story, so "where does a non-std library live" is genuinely
unanswered — it is the same hole [scale.md](scale.md) item 4 (a package unit +
manifest) is circling. Interim proposal: `pkgs/`, alongside `cli`. Flagging it
rather than settling it here, because the answer should come from item 4.

### The client-shape checklist

This is the list Arc 2 exists to answer. Each is a decision the generator will
then make hundreds of times, so each is worth getting right once, by hand, with
a real caller in front of it.

- **Construction and config.**
  `Client.new(api_key:, base_url:, timeout:, max_retries:)` versus ambient free
  functions. The ambient-capability model from [stdlib.md](stdlib.md) is the
  precedent to follow or consciously break.
- ~~**Optional fields.**~~ **Answered: the direct call, with default
  arguments.** An all-fields struct literal is not viable (Thera struct fields
  have no per-field defaults, so every construction would spell all of them) and
  a wither chain reimplements the feature the language already has. A minimal
  request names three arguments and nothing else. **The one tax:** an
  `Option<T>` parameter does not accept a bare `T`, so every optional argument a
  caller passes is spelled `Option.Some(0.5)`. See
  [typed-json.md](typed-json.md) § Encoding — the cost is recorded, and no
  implicit `Some`-wrap is proposed on one client's evidence.
- **Errors.** How HTTP status maps onto a client error enum (rate-limited,
  overloaded, invalid-request, auth-failed, server-error), and how that composes
  with `HttpError` underneath. `Result` throughout; the question is the shape of
  the payload and how much of the API's own error body survives into it.
- **Streaming surface.** `Iterator<Event>` versus a channel versus a callback.
  All three are buildable; only one should be blessed.
- **Naming.** How `operationId` and the URL hierarchy become Thera names and
  namespaces — flat (`anthropic.create_message`) versus Kiota's resource tree
  (`client.messages.create`). Qualified-by-default imports and the
  discoverability argument in [scale.md](scale.md) both bear on this.
- **Pagination.** An iterator that fetches lazily; nothing here needs it yet,
  but the shape should be chosen before GitHub arrives.
- **Forward compatibility.** Arc 1 item 4 — settle `Unknown(Json)` here.

## Arc 3 — the OpenAPI generator

A `thera api` subcommand (name TBD) that reads an OpenAPI description and emits
Thera source.

**Filtering is mandatory, not an optimization.** Cloudflare is 23 MB of JSON;
GitHub 12.9 MB; even Anthropic carries 928 component schemas. Whole-spec
generation would produce hundreds of thousands of lines of Thera that nobody
reads — directly against everything [scale.md](scale.md) argues for. So the unit
of generation is **a named set of operations**: the manifest lists them, the
generator emits those plus transitively-reachable schemas and nothing else. This
is Kiota's URI-space-tree design, and it is the single most important structural
decision in this arc.

**Construct priority, from the survey.** The order to implement in, and the
evidence for it. Two populations were measured and they disagree, so the order
is by _slate_ frequency with the population as a tiebreak: the slate is what we
are actually generating, while the population says what the long tail will need.

| Tier                       | Constructs                                                   | Why                                                                                                                                                                                                      |
| -------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1 — universal**          | `$ref`, `enum`, `format`, `additionalProperties`, `nullable` | Present in nearly every spec in both populations (`$ref` in 163 of 177 sampled 3.x specs, `enum` 150, `format` 148). Nothing works without these.                                                        |
| **2 — slate-critical**     | `oneOf` + `discriminator`                                    | Dominant in the slate (Anthropic 238/229, OpenAI 266/105) and **near-absent in the population** — `discriminator` appears in 2 of 177 sampled specs. A GenAI/Stainless shape, and our targets are GenAI. |
| **3 — long-tail-critical** | `allOf` flattening                                           | Only 165 in Anthropic and 40 in OpenAI, but 49 of 177 sampled specs use it, and Cloudflare has 3708. Cheap to defer for the slate, mandatory past it.                                                    |
| **4 — defer to `Json`**    | untagged `anyOf`, `not`, `patternProperties`                 | 660 untagged `anyOf` across the whole slate, 395 of them Cloudflare's; `not` 7 total; `patternProperties` 1. Below the threshold where a fallback is embarrassing.                                       |

The population sample deliberately **excludes Swagger 2.0** (about 40% of
APIs.guru): 2.0 is out of scope and has no `oneOf`/`anyOf`/`nullable` at all, so
leaving it in described a format we are not targeting.

**Pipeline.** Deliberately the same shape as the front-end's own, because it is
the same kind of program and the pieces already exist:

```
spec (std.json) → resolve $refs → filter to selected operations
  → API model (operations, schemas) → Thera code model → emit → thera fmt
```

**The first arrow is the one open gate.** `std.json` can ingest a spec of any
size on the slate — 1.4 s for GitHub's 12.9 MB, 2.5 s for Cloudflare's 23.3 MB,
counts matching a Python reference — so ingestion is not a performance problem.
But **Anthropic publishes only YAML** (`.yml`; swapping the extension 404s) and
Thera has no YAML reader. Three ways out, none free: add `std.yaml`; find or
host a JSON rendition (OpenAI publishes both, Anthropic does not); or convert
out of band in the manifest step, which breaks the build's no-external-toolchain
property. It has to be decided before Arc 3 can regenerate its own acceptance
test.

**A manifest per generated client**, checked in: the spec URL, a **content hash
pin**, the selected operations, and any name overrides. The pin is what makes
regeneration reproducible and makes an upstream spec change a visible, reviewed
event rather than a silent drift. It is also the natural place for the
`.stats.yml` indirection Anthropic requires.

**Output is committed, not generated at build time.** This is the opposite of
[scale.md](scale.md) item 5's decision to reject committed doc artifacts, and
the reason for the difference is worth stating: doc artifacts were rejected
because their staleness window is _adversarial_ — an agent consults the index
precisely while a local change is in flight. A generated client has no such
window: it changes only when the **upstream spec** changes, which is neither
frequent nor local. And committing it is what makes it readable — by agents, by
`thera doc`, by hover, by grep. Freshness is guarded by a CI check that
regenerates and diffs, exactly the shape of the existing bootstrap fixpoint
check.

**Determinism is a hard requirement.** Stable ordering everywhere, so
regenerating an unchanged spec produces a byte-identical tree and the CI diff is
empty. The bootstrap fixpoint is the precedent and the discipline already exists
in the repo.

**Acceptance test: regenerate Anthropic and diff against Arc 2's hand-written
client.** Not byte-equality — but every semantic difference must be
_explainable_, and each unexplainable one is either a generator bug or a lesson
to fold back into the emitter. This is what makes Arc 2 an investment rather
than throwaway work.

**Non-goals for v1.** Server stubs; content types beyond JSON and text; OAuth
flows; webhooks and callbacks; Smithy and Google Discovery ingestion; gRPC;
OpenAPI 2.0.

## Choosing targets — discovery and ranking

"Which API next" should be a table, not an opinion. The repo already works this
way — [scale.md](scale.md)'s import decisions came out of a 167-file/541-edge
survey, and its caching arcs came out of `dev/bench_session.thera` measurements.
The same move applies here.

**Where candidates come from.** [APIs.guru](https://apis.guru) is the largest
open directory of OpenAPI descriptions — **2,529 APIs**, machine-readable, each
entry carrying a spec URL. That plus a hand-list of the obvious targets (the
table in § Why OpenAPI) is the candidate pool. Kiota's API description search
and the Postman public network are secondary sources.

**Ranking criteria.** Score each candidate on:

1. **Is there an official machine-readable spec?** A near-binary gate and by far
   the biggest discriminator. Vendor-published and hash-pinnable beats
   community-maintained.
2. **Spec quality**, and this is _measurable_: schema nesting depth, the
   `oneOf`/`discriminator` histogram, how often `additionalProperties: true` is
   used as an escape hatch, whether the document validates at all. ~~percentage
   of operations carrying an `operationId`~~ — **dropped, on evidence**: it is
   100% on all seven hand-list APIs, so it discriminates nothing among the
   candidates that matter. Keep it as a gate for a spec from the long tail, not
   as a ranking column.
3. **Filtered surface size** — how many operations does a realistic tool
   actually need? Five, or five hundred?
4. **Feature demand** — does it require SSE, multipart, websockets, OAuth? Each
   is Arc 1 work, and the cost belongs in the ranking.
5. **Fit to the CLI-tool / agent domain** — Thera's stated target, not "popular
   APIs" generally.
6. **Auth cost** — bearer/API-key (cheap) < OAuth device flow (moderate) < AWS
   SigV4 (expensive, and Smithy anyway).

**How to run it — `dev/spec_survey.py`.** It resolves each hand-list URL
(following Anthropic's `.stats.yml` indirection), caches the specs under
`build/spec-cache/`, and reports three things: the per-API ranking table, the
construct histogram, and the transitive schema closure of a named operation set.
`--guru N` adds a sample of APIs.guru for the population-wide view.

### The table

Measured 2026-08. `Depth` is maximum schema nesting; `SSE`/`Multipart` are
whether the spec declares those media types anywhere.

| API        | Version | Size    | Paths | Ops  | Schemas | Depth | SSE | Multipart | Auth declared       |
| ---------- | ------- | ------- | ----- | ---- | ------- | ----- | --- | --------- | ------------------- |
| anthropic  | 3.1.0   | 1.8 MB  | 89    | 131  | 928     | 10    | —   | yes       | — (none)            |
| openai     | 3.1.0   | 2.8 MB  | 182   | 288  | 1394    | 20    | yes | yes       | http/bearer         |
| gemini     | 3.0.3   | 100 KB  | 16    | 25   | 48      | 8     | —   | —         | — (none)            |
| github     | 3.0.3   | 12.9 MB | 808   | 1220 | 969     | 20    | —   | —         | — (none)            |
| cloudflare | 3.0.3   | 23.3 MB | 2039  | 3272 | 6542    | 43    | yes | yes       | apiKey, http/bearer |
| vercel     | 3.0.3   | 10.0 MB | 272   | 377  | 88      | 35    | —   | —         | http/bearer, oauth2 |
| fly        | 3.0.1   | 139 KB  | 68    | 98   | 173     | 9     | —   | —         | — (none)            |

`operationId` coverage is **100% on all seven**, which is why criterion 2 lost
that column. Four of seven declare no `securitySchemes` at all, so **auth is not
derivable from the spec** for most of the slate — including Anthropic, whose
`x-api-key` appears only in prose and examples. The generator has to be told.

### What the survey changed

- **Filtering is vindicated with numbers**, not asserted. A realistic
  three-operation client needs a small fraction of the schemas: **Anthropic 165
  of 928 (18%)**, Fly 45 of 173 (26%), OpenAI 73 of 1394 (5%), **GitHub 28 of
  969 (3%)**. Generating GitHub whole would emit 34× the types a pull-request
  tool needs. `--closure <api>` reproduces this.
- **Anthropic's `?beta=true` variants are 91% of the paths**, not a footnote: 80
  of 89 paths and 120 of 131 operations carry `?beta=true` inside the _path
  key_. A generator that treats path keys as URL paths would emit 120 operations
  with a literal `?beta=true` in the path, which is wrong — the query string
  belongs in the query. This is now a gating decision for Arc 3 rather than
  "something to decide later".
- **Anthropic does not model streaming at all.** `CreateMessageParams` has a
  `stream: boolean` property, and the 200 response declares only
  `application/json` — zero occurrences of `event-stream` in the whole document.
  So the spec says you may ask for a stream and never says what arrives. **Layer
  (c), the typed event stream, cannot be generated from the spec**; it has to be
  hand-written or hand-taught, which retroactively justifies leaving it to
  Arc 2.
- **Vercel inlines almost everything**: 88 component schemas for 377 operations,
  at depth 35. A generator that emits one Thera type per component schema would
  emit 88 types and have nowhere to put the rest, so most request/response types
  need _synthesized_ names. Vercel is the specimen for that problem; nothing
  else in the slate has it.
- **Two nullability spellings, both in the slate.** 3.0 writes `nullable: true`
  (GitHub 3955, Cloudflare 2226, Vercel 1977); 3.1 writes
  `anyOf: [T, {type: null}]` (Anthropic 480, OpenAI 844). They look nothing
  alike and both mean `Option<T>`. "The reader must accept both" was an abstract
  claim; this is the concrete form.
- **`std.json` can ingest these specs.** Parsing the 12.9 MB GitHub document
  takes **1.4 s** and the 23.3 MB Cloudflare document **2.5 s** on the Tier-0
  interpreter, with path and schema counts identical to Python's. Arc 3's
  ingestion is not gated on performance. **It is gated on YAML**: Anthropic
  publishes only `.yml` (swapping the extension 404s) and Thera has no YAML
  reader. OpenAI publishes both `openapi.yaml` and `openapi.json`, and the rest
  of the slate is JSON — so Anthropic is the single spec that needs `std.yaml`,
  or a converted rendition, or a manifest step that breaks the
  no-external-toolchain property.

### Slate, unchanged by the survey but better justified

1. **Anthropic** — Arc 2, hand-written. Half done
   ([typed-json.md](typed-json.md)).
2. **OpenAI + Gemini** — the first generated clients. Together they prove one
   generator handles three shapes of the same domain, and Gemini is valuably
   _different_: a Google-flavored 3.0.3 document derived from a Discovery
   service, not a Stainless-shaped 3.1. Gemini is also the cheapest thing on the
   slate — 25 operations, 48 schemas, depth 8, no SSE or multipart declared.
3. **GitHub** — 12.9 MB and 3.0.3. Proves filtering under real load (3%
   closure), and is the single most-called API in the CLI-tool domain.
4. **Fly Machines** is the dark-horse fourth: 98 operations, 173 schemas, no
   `oneOf`/`anyOf`/`discriminator` **at all**, and squarely in the agent domain.
   It is the one spec on the slate a v1 generator could handle completely.
5. **Cloudflare last, if ever.** It carries 395 of the slate's 660 untagged
   `anyOf` and 3708 of its 4008 `allOf`, at depth 43 — most of the hard cases in
   the whole survey, for an API that is not central to the target domain.

### MCP is a peer, not a downstream

Worth stating plainly so it doesn't get mis-sequenced: **MCP is not an OpenAPI
API.** It is JSON-RPC over stdio or streamable HTTP with its own published JSON
Schema (~108 KB), so a Thera MCP client and server are hand-written libraries,
not generator output. They therefore do **not** wait on Arc 3 — they need only
Arc 1 (items 1, 2, 5) and the shape lessons from Arc 2.

They are also arguably the highest-value single target in this whole document
for the stated domain, because the value runs both ways: an MCP _client_ lets a
Thera tool consume the entire MCP ecosystem without generating anything, and an
MCP _server_ library makes Thera a language people write agent tools _in_. That
second one is the closer fit to Thera's thesis. Sequence it right after Arc 2's
streaming work, in parallel with Arc 3.

## Suggested order

1. **Arc 1 item 1 — HTTPS.** The gate. Already in flight as
   [http-tls.md](http-tls.md) stage 4; nothing else starts first.
2. **Arc 2, non-streaming.** Messages + count_tokens + models, hand-written.
   Forces items 3 (typed JSON), 4 (forward compat), 5 (retry), 6 (auth) into the
   open in the order a caller meets them.
3. ~~**Arc 1 item 2 — streaming + SSE**~~ — **done**, and done _before_ step 2
   rather than after it. The ordering argument survived: the part a client was
   supposed to drive is layer (c), the typed event stream, which was
   deliberately left to Arc 2 for exactly that reason. Layers (a) and (b) are
   protocol, not API. Streaming Messages and Arc 1 item 8 (hermetic tests, on
   TLS stage 5) still belong with step 2.
4. ~~**The spec survey.**~~ **Done** — `dev/spec_survey.py`, results in §
   Choosing targets. It paid for itself as predicted: a construct priority
   ordered by measured frequency, filtering vindicated with closure numbers, and
   three things the plan had wrong (the `anyOf` count, Anthropic's `?beta=true`
   share, and that no spec on the slate models streaming).
5. **Arc 3 v1**, acceptance-tested by regenerating Anthropic and diffing against
   step 2.
6. **Second and third targets** — Gemini, then GitHub.

**MCP** can start any time after step 3, in parallel.

## Open questions

- **Where do non-`std` packages live?** Blocks Arc 2's landing spot; belongs to
  [scale.md](scale.md) item 4, not here.
- ~~**Emitted JSON codecs vs. a `@derive(json)`.**~~ **Settled: emitted.** The
  counter-case was that hand-written clients want a derive; hand-writing the
  whole Messages response against `json.Cursor` is 51 code lines, which is not
  painful enough to buy a language feature.
- ~~**Default arguments vs. an options struct**~~ **Settled: default
  arguments**, with the `Option.Some(…)` tax recorded at item 3's checklist
  entry above.
- **Undiscriminated `anyOf`** — still open, but **measured down from alarming to
  ordinary**: 47 genuinely untagged occurrences in Anthropic (not 527 — 480 of
  those are 3.1's `Option<T>` spelling), 50 in OpenAI, 34 in GitHub, 0 in Gemini
  and Fly. 395 of the slate's 660 are Cloudflare's alone. Untagged union decode
  by trial? A `Json` fallback? The Messages response uses none, so the
  typed-JSON arc could not settle it by hand — and at these counts a `Json`
  fallback may simply be the answer.
- ~~**Forward-compat `Unknown(Json)`**~~ **Settled: universal, no opt-out** —
  see item 4.
- **Flat names vs. a resource tree** for generated API surfaces.
- **Does the generator ship as a `thera api` subcommand** (sharing the AST
  printer and formatter with `pkgs/cli`) or as a separate tool?
