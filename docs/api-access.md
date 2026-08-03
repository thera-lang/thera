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
survey (all fetched and verified, not taken from documentation claims):

| API          | Spec                                                      | Version | Size    |
| ------------ | --------------------------------------------------------- | ------- | ------- |
| Anthropic    | the URL in `.stats.yml` of the official SDK repos         | 3.1.0   | 1.8 MB  |
| OpenAI       | `openai/openai-openapi` (officially published)            | 3.1.0   | 2.8 MB  |
| Gemini       | `generativelanguage.googleapis.com/$discovery/OPENAPI3_0` | 3.0.3   | 460 KB  |
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
combination that didn't compile. The http client now reads
`fn exchange<S: io.Reader + io.Writer + io.Closer>`.

### 2. Streaming responses and SSE

**Problem.** Token streaming is the default interaction mode for every GenAI API
— a client that can only await a complete response is a toy for the flagship use
case. Server-sent events are the transport all three of Anthropic, OpenAI, and
Gemini use for it. **Today.** `Response.body` is `Bytes` — fully buffered,
capped at `MAX_BODY_BYTES` (32 MiB). [stdlib.md](stdlib.md) lists streaming
bodies as explicitly deferred alongside TLS. **Direction.** Three layers, each
independently useful: (a) a **streaming response body** — the response head
arrives, the body is an `io.Reader` (the codec already reads incrementally;
what's missing is a public surface that doesn't drain it first); (b) an **SSE
framing layer** over that reader — `event:` / `data:` / `id:` / `retry:` fields,
blank-line record separation, multi-line `data` concatenation, and the `[DONE]`
sentinel convention; (c) a **typed event stream** — the framing layer yields raw
events; the client decodes each into its own event enum. `Iterator<T>` and the
lazy-iteration arc have landed, so the natural shape is `Iterator<Event>`;
fibers + `channel` make a producer/consumer shape equally available. Which one a
client should expose is an Arc 2 question (see § the client-shape checklist).
**Status.** Open. Item (a) is the one with a design dependency on the codec; (b)
and (c) are pure Thera over it.

### 3. Typed JSON — structs in, structs out

**Problem.** A generated client is mostly types. Getting a Thera struct into and
out of JSON is the single highest-volume operation in every client. **Today.**
`std.json` is a dynamic `Json` enum with `parse`/`stringify` and constructors.
There is no struct mapping and no JSON derive; `Response.json()` hands back a
`Json`. Hand-decoding one Anthropic response by pattern-matching `Json` is
roughly a page of code. **Direction.** The key observation is that **a generator
does not need a derive** — it can emit an explicit `from_json` / `to_json` pair
per struct, and that emitted code is ordinary, readable, greppable Thera that
participates in checking and refactors. The alternative, a `@derive(json)`
attribute alongside the existing `eq`/`debug` derives, is a language feature
with a much larger blast radius. **Recommendation: explicit emitted codecs
first.** Revisit a derive only if hand-written clients (which do want one) prove
painful enough. The schema-to-type mapping this implies:

| OpenAPI construct               | Thera                                 |
| ------------------------------- | ------------------------------------- |
| `object` with fixed properties  | `struct`                              |
| `oneOf` + `discriminator`       | `enum` with a variant per branch      |
| `enum` of strings               | `enum` (plus a raw-string round trip) |
| nullable / not in `required`    | `Option<T>`                           |
| `array`                         | `List<T>`                             |
| `additionalProperties: {T}`     | `Map<String, T>`                      |
| `allOf`                         | flattened into one struct             |
| `anyOf` without a discriminator | **open question** — see below         |
| unmodeled / `true` schema       | `Json` (the honest escape hatch)      |

Anthropic's spec alone contains 928 component schemas with 527 `anyOf`, 238
`oneOf`, 229 `discriminator`, and 165 `allOf` occurrences — so none of these
rows is hypothetical, and undiscriminated `anyOf` is the row that will hurt.
**Status.** Open; the mapping table is the deliverable Arc 2 should validate by
hand before Arc 3 automates it.

### 4. Forward compatibility — the strongly-typed client's classic failure

**Problem.** Tomorrow the API adds a content-block type, a stop reason, or an
error code. A client that decodes into a closed Thera enum and matches
exhaustively will **fail on a response it should have tolerated** — and it will
fail for every user at once, remotely triggered, with no code change on our
side. This is the defining bug class of generated clients and it interacts
directly with Thera's exhaustive `match`. **Today.** Not a problem yet, because
there are no typed clients. **Direction.** Every generated enum decoded from the
wire gets an `Unknown(Json)` variant (name TBD), and decode never fails on an
unrecognized tag. The cost is that every consumer's `match` grows an arm — which
is arguably correct, since the case is real. The open question is whether that
is a convention the generator applies uniformly, or something the spec's `x-`
extensions can opt out of. **Status.** Open. Small, and cheap to get wrong
permanently — decide it in Arc 2, before any generated code exists to migrate.

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
**Status.** Open. Retry is required for Arc 2; pooling and redirects are not.

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
- **Optional fields.** A Messages request has a handful of required fields and a
  long tail of optional ones. Most languages force a builder or an options
  struct here; **Thera has default arguments**, so the direct call
  `messages.create(model: …, messages: …, max_tokens: …, temperature: …)` is
  actually viable. Whether it stays readable at 20 parameters is the question —
  and it is one of the clearest tests of whether a Thera-idiomatic client beats
  the SDK shapes other languages settle for.
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

**Pipeline.** Deliberately the same shape as the front-end's own, because it is
the same kind of program and the pieces already exist:

```
spec (std.json) → resolve $refs → filter to selected operations
  → API model (operations, schemas) → Thera code model → emit → thera fmt
```

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
2. **Spec quality**, and this is _measurable_: percentage of operations carrying
   an `operationId`, schema nesting depth, the `oneOf`/`discriminator`
   histogram, how often `additionalProperties: true` is used as an escape hatch,
   whether the document validates at all.
3. **Filtered surface size** — how many operations does a realistic tool
   actually need? Five, or five hundred?
4. **Feature demand** — does it require SSE, multipart, websockets, OAuth? Each
   is Arc 1 work, and the cost belongs in the ranking.
5. **Fit to the CLI-tool / agent domain** — Thera's stated target, not "popular
   APIs" generally.
6. **Auth cost** — bearer/API-key (cheap) < OAuth device flow (moderate) < AWS
   SigV4 (expensive, and Smithy anyway).

**How to actually run it.** A `dev/` script that fetches N specs from APIs.guru
plus the hand-list and reports, per API: operation count, `operationId`
coverage, and a histogram of OpenAPI constructs used. That turns criterion 2
from a judgment call into a column — but the larger payoff is elsewhere: **the
aggregate construct histogram tells the generator which OpenAPI features to
implement first, in frequency order.** The survey is simultaneously the target
ranking and the generator's work-prioritization, which is a good sign it is the
right artifact to build early. It cheaply doubles as the generator's conformance
corpus.

**Initial slate**, subject to that survey:

1. **Anthropic** — Arc 2, hand-written.
2. **OpenAI + Gemini** — the first generated clients. Together they prove one
   generator handles three shapes of the same domain, and Gemini is valuably
   _different_: a Google-flavored 3.0.3 document derived from a Discovery
   service, not a Stainless-shaped 3.1.
3. **GitHub** — 12.9 MB and 3.0.3. Proves filtering under real load, and is the
   single most-called API in the CLI-tool domain.
4. Then whatever the survey ranks.

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
3. **Arc 1 item 2 — streaming + SSE**, driven by that client; then streaming
   Messages. Arc 1 item 8 (hermetic tests) lands alongside, on TLS stage 5.
4. **The spec survey.** Cheap, and it sets Arc 3's construct priority — so it
   pays for itself before Arc 3 starts rather than after.
5. **Arc 3 v1**, acceptance-tested by regenerating Anthropic and diffing against
   step 2.
6. **Second and third targets** — Gemini, then GitHub.

**MCP** can start any time after step 3, in parallel.

## Open questions

- **Where do non-`std` packages live?** Blocks Arc 2's landing spot; belongs to
  [scale.md](scale.md) item 4, not here.
- **Emitted JSON codecs vs. a `@derive(json)`.** Recommendation is emitted; the
  counter-case is hand-written clients.
- **Default arguments vs. an options struct** for large optional-field sets —
  the most interesting Thera-specific question in the doc.
- **Undiscriminated `anyOf`** — 527 occurrences in Anthropic's spec alone, and
  no obvious Thera type. Untagged union decode by trial? A `Json` fallback?
- **Forward-compat `Unknown(Json)`** — universal convention, or opt-out?
- **Flat names vs. a resource tree** for generated API surfaces.
- **Does the generator ship as a `thera api` subcommand** (sharing the AST
  printer and formatter with `pkgs/cli`) or as a separate tool?
