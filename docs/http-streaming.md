# Streaming bodies and SSE for `std.http`

**What this is:** the design and staged plan for the other half of `std.http`'s
read path — a response whose body arrives incrementally, the server-sent-events
framing that rides on it, and where the typed event stream above that belongs.
This is [api-access.md](api-access.md) Arc 1 item 2 graduated into its own plan;
it is the item that gates every GenAI client, because token streaming is the
default interaction mode for all of them.

**Complete: all four stages have landed.** The codec streams
([wire.thera](../sdk/std/http/wire.thera): `Framing`, `BodyReader`,
`Wire.stream_response`), with the buffered `read_response` defined as that plus
a capped drain; [std.http.sse](../sdk/std/http/sse/sse.thera) decodes a
`text/event-stream` over any reader; and the client has `http.stream` /
`http.with_stream` ([client.thera](../sdk/std/http/client.thera)), with `send`
now defined as `stream` plus that same drain plus the close. So a
`text/event-stream` reaches a caller event by event, over `http` or `https`,
with nothing in between holding it whole. What each stage settled is marked
_(settled)_ below.

## Goals & non-goals

- **Primary goal — a response body you can read as it arrives.** Today
  `Response.body` is `Bytes`: the codec reads the whole body before the caller
  sees anything, capped at `MAX_BODY_BYTES` (32 MiB). For a token stream that is
  not a limitation, it is a wrong answer — the response does not end until the
  model stops talking.
- **Goal — SSE framing as a library, not as client code.** All three of
  Anthropic, OpenAI, and Gemini stream over `text/event-stream`. The framing is
  small, fiddly, and identical for all of them, so it belongs in one tested
  place.
- **Goal — the buffered path keeps every property it has.** `http.get(url)`
  returning a `Response` with `body: Bytes` stays the common case and stays
  capped. Streaming is an opt-in second door, not a migration.
- **Non-goal — a typed event stream.** Decoding an SSE event's `data` into a
  client's own event enum is Arc 2's job (§ layer (c)); nothing here should know
  what Anthropic's event names are.
- **Non-goal — streaming _request_ bodies.** `Request.body` stays `Bytes`. The
  upload direction is real (multipart, Arc 1 item 7) but nothing on the slate
  needs it: a Messages request is small JSON regardless of how large the
  response is.
- **Non-goal — SSE reconnection.** The spec's `Last-Event-ID` + `retry`
  machinery exists to resume a dropped stream, and a GenAI completion is not
  resumable — a dropped Messages stream is restarted, not continued. Parse both
  fields and hand them to the caller; do not reconnect on their behalf.
- **Non-goal — trailers.** A chunked body may carry a trailer block after its
  last chunk. Today's codec reads it and discards it; the streaming reader does
  the same. Named so it is a known gap rather than a surprise.

## The seam already exists — halfway

The codec never had a whole-body read: `Wire` is a buffered reader that pulls
16 KiB at a time and the framing walkers (`read_exact`, `read_chunked`,
`read_to_eof`) already consume incrementally. What was missing was a **public
surface that doesn't drain first** — every path funnelled into a
`BytesBuilder` before returning. So layer (a) is a refactor with a new door on
it, not new machinery.

The other half of the seam is `io.Reader`. A body that implements it composes
with everything already written against it — `io.lines` for the SSE line split,
`io.read_all` and `io.copy` for the boring cases — and with `net.TlsStream`
underneath, unchanged.

## Layer (a) — the streaming body

Three pieces, all in [wire.thera](../sdk/std/http/wire.thera):

```
enum Framing { Empty, Length(Int), Chunked, ToEof }   // how the body is delimited

struct BodyReader { … }                 // the unread body; impl io.Reader
    fn read_some(self, max: Int) -> Result<Bytes, HttpError>   // honest primitive
    fn is_complete(self) -> Bool

struct ResponseStream { status, headers, body: BodyReader }
    fn is_ok(self) -> Bool
    fn buffered(self) -> Result<Response, HttpError>           // give up streaming
```

`Wire.stream_response(to_head:)` reads the status line and headers, derives the
framing, and returns a `ResponseStream` whose body has not been touched.
`Wire.read_response` is then **defined as** `stream_response(…)?.buffered()`,
which is what keeps the two paths from drifting: there is one framing decision
(`framing_of`) and one body walker (`BodyReader`), and the buffered form is a
capped drain over it.

Three details worth recording, because each is a place the refactor could have
silently lost something.

- **`read_some` versus `read`.** The `io.Reader` impl must return
  `Result<Bytes, Error>`, which throws away the `HttpError` variant — and
  `Protocol` versus `Body` is exactly the "whose bug is it" distinction the
  codec works to preserve. So `read_some` is the honest primitive and the
  interface method widens, the same split `io.BufReader` makes between
  `read_line` and its `Iterator` impl.
- **The cap moves, and only for streaming.** `MAX_BODY_BYTES` is a property of
  *assembling a body in memory*, so it lives in the drain, not in the reader.
  The streaming path is therefore **deliberately uncapped** — which is correct
  (an event stream is unbounded by design) and is the one security-relevant
  asymmetry here: `io.read_all` over a `BodyReader` is an unbounded read, and a
  caller who wants a bound should use `buffered()`, which has one.
- **An oversized frame is still refused before it is read.** The old code
  checked a `content-length`, and each declared chunk size, against the cap
  before reading the bytes. The drain preserves that by consulting the reader's
  remaining *declared* frame size each time around, so a 1 GiB `content-length`
  is still a `Body` error rather than 32 MiB of wasted reads. (The residual
  overshoot is one read window, 64 KiB, on a chunked body whose first chunk
  declares more than the cap.)

## Layer (b) — SSE framing

**Where it lives: `std.http.sse`** — its own directory
(`sdk/std/http/sse/sse.thera`) inside the `http` folder. SSE is a framing over a
byte stream and depends only on `std.io`, but in practice an event stream is
always something an HTTP response body delivers, and the top-level `std.*`
namespace should not grow a name for every format that rides on one. The
directory is what makes it a library rather than an internal file: from outside,
a library's one importable surface is its barrel, and a nested directory fronted
by its own barrel is its own library — so `import std.http.sse` resolves, while
a plain `sse.thera` beside `client.thera` would be private to `std.http`.

Re-exporting through the `http` barrel instead was the third option and is worse
on two counts: `http.Event` / `http.Decoder` are very generic names in the
namespace whose most-written line is `http.get(url)`, and the barrel pulls in
the client, so an SSE consumer would drag TLS along with it — the coupling the
wire/client/server split exists to avoid.

_(This replaces an earlier decision here to make it a top-level `std.sse`, which
was wrong on the namespace question. One of the two reasons given for it —
"a sibling file would be unreachable from outside the directory" — is true of a
**file** and not of a **nested directory**, and reading it as a reason to leave
the folder was the error. It has a sharp edge worth recording: `std.http.server`
is a plain file inside `std/http/`, so `import std.http.server` is a check error
today and the server is reachable only from its sibling tests, which is why
nothing outside the SDK uses it. See the roadmap's Networking punchlist.)_

The format (WHATWG HTML § server-sent events), in the order it bites:

- UTF-8 text, split into lines. A line is `field: value`; **one** optional
  leading space is stripped from the value, and a line with no colon is the
  field with an empty value.
- A line starting with `:` is a **comment**, which is what servers send as a
  keep-alive. Ignore it — but note that ignoring it is not the same as no line
  arriving, which matters if a future timeout is measured per-event.
- A **blank line dispatches** the accumulated fields as one event. A record
  with no `data` field is not dispatched at all.
- `data` **accumulates**: repeated `data:` lines join with `\n` between them,
  which is how a JSON payload containing newlines is sent.
- `event` names the type (default `message`), `id` sets the last-event-id,
  `retry` is a reconnection delay in milliseconds. Unknown fields are ignored.

Shape, mirroring `io.BufReader` deliberately — an honest primitive that reports
failures plus an `Iterator` impl for the ergonomic form:

```
struct Event { let name: String; let data: String; let id: Option<String>;
               let retry: Option<Int>; }

struct Decoder { … }
    fn new(_ src: io.Reader) -> Decoder
    fn read_event(self) -> Result<Option<Event>, Error>   // None at end of stream
    fn error(self) -> Option<Error>
impl Iterator<Event> for Decoder

fn events(_ src: io.Reader) -> Decoder
```

Line splitting reuses `io.lines`, which gets the buffering, the `\r\n` strip,
and the trailing-partial-line rule right. **One correction to the sketch in
[api-access.md](api-access.md):** the `[DONE]` sentinel is _not_ part of SSE —
it is an OpenAI convention, and Anthropic does not use it (its terminator is
`event: message_stop`). So `[DONE]` must not be special-cased in the framing
layer; recognizing it is layer (c)'s business, per API.

## Layer (c) — the typed event stream

Out of scope here, on purpose. Layer (b) yields `Iterator<Event>` with `data` as
a `String`; turning that into an API's own event enum needs that API's schema,
and choosing between an iterator, a fiber `channel`, and a callback is one line
on Arc 2's client-shape checklist. What this plan owes Arc 2 is that all three
are buildable over an `Iterator<Event>`, and they are.

## The client surface, and who closes the connection

This is the one genuinely new design problem, and it is not in the codec.
`exchange` in [client.thera](../sdk/std/http/client.thera) closes the connection
on the way out of every path — safe today precisely because the body is already
in memory by then. A streaming body is read *after* the call returns, so the
connection has to outlive it, and Thera has no destructors: nothing reclaims a
socket the caller forgets.

Two shapes, and they are not exclusive:

1. **`http.stream(request) -> Result<ResponseStream, HttpError>`**, where the
   returned value is an `io.Closer` and closing it is the caller's job. Direct,
   composes with everything, and leaks a descriptor if the caller drops it.
2. **A scoped form** — `http.streaming(request, do: (resp) => …)` — that closes
   on every path out of the callback, the way `fiber.with_timeout` bounds a
   wait. No leak is possible, at the cost that the body cannot escape the
   callback (which is the point).

**Recommendation: build (1), bless (2).** (2) is sugar over (1) and can land
with it or after it; (1) has to exist either way because the generator (Arc 3)
emits code that holds a stream across function boundaries.

Two smaller decisions fall out: the streaming response must **not** be a
`wire.Response` (its body is a reader, so it cannot pretend), and a caller who
abandons a body partway leaves the connection in an indeterminate state — which
costs nothing today, since there is no pooling and the connection is closed
rather than reused.

_(settled, stage 3)_ Both shapes landed together, as `http.stream` and
`http.with_stream(request, handle: …)`. Three things the sketch didn't say:

- **`send` is now defined as `stream` plus the drain plus the close**, which
  deleted the old `exchange` outright. The same move layer (a) made in the
  codec, with the same payoff: one connect-and-write path, so the buffered and
  streaming clients cannot drift. It also puts every existing client test on the
  streaming path.
- **The client's type is `http.Stream`, not `wire.ResponseStream`.** The barrel
  re-exports the codec's type too, so both names exist in `http`; the difference
  is the last field, which owns the connection. Worth knowing when reading a
  signature, and the doc comment on each points at the other.
- **Ownership transfers on success and only on success.** `open` closes the
  connection itself on the failure path, because nothing owns it yet — the path
  a retry loop hits most, and the one that leaks if you write the obvious thing.

_(settled, stage 3)_ **Closing twice is an `Err`, not a crash** — the runtime
refuses a close on a connection it no longer holds. Which makes
`let _ = s.close()` the right spelling wherever a close might be redundant, and,
less obviously, is the only way a test can observe from outside that a close
happened at all: reading the body won't do it, because a `BodyReader` still
hands back buffered bytes long after the socket underneath is gone.

## Testing

Layers (a) and (b) are pure functions of a byte stream, so both test with no
sockets at all — `io.from_bytes` in, assertions out, exactly how
[wire_test.thera](../sdk/std/http/wire_test.thera) already works. That covers
the fiddly half: chunk boundaries that split a frame, a `data` field spanning
lines, a comment between events, a record with no `data`, an event dispatched
across two reads.

The one thing that needs a peer is stage 3, and `std.http.server` already is
one: a handler that writes a chunked `text/event-stream` body over the plaintext
loopback listener is a complete SSE server for test purposes, and the existing
`serving(...)` helper in [client_test.thera](../sdk/std/http/client_test.thera)
stands it up. No TLS is needed to test streaming — TLS is a stream, and stage 1
of this plan is about what rides on one.

The case worth engineering deliberately: **assert that the body is genuinely
incremental**, not merely correct. A test that reads one event before the server
has written the rest is the only one that would catch a regression back into
"drain, then hand it over".

_(settled, stage 3)_ It is a handshake, and the shape matters. The server writes
the head and the first event, then waits to be told the first arrived before
writing the second, and **reports back whether the go-ahead came** — so the
assertion is on that flag rather than on any timing. The wait is bounded by
`fiber.select([go, fiber.after(2s)])` rather than being a bare `receive`, which
is what makes a regression **fail** instead of deadlocking the suite: a client
that read the body whole would block until the server gave up, and then be told
that it had. Verified by mutation — draining the body before reading the first
event fails the test in about two seconds.

## Staged plan

1. ~~**Streaming bodies in the codec.**~~ _Done._ `Framing`, `BodyReader`
   (`io.Reader` + `read_some`), `ResponseStream`, `Wire.stream_response`, and
   `read_response` redefined as `stream_response(…)?.buffered()`. Framing
   validation and the oversize checks are unchanged in behaviour and now live in
   one place each.
2. ~~**`std.sse`.**~~ _Done, as **`std.http.sse`**_ — see above for the move.
   `Event`, `Decoder` over any `io.Reader` (`read_event` + `Iterator<Event>`),
   `events(src)`. Pure Thera over `io.lines`, tested in memory. Three things the
   sketch didn't say: `retry` ended up on the `Decoder` rather than on `Event`,
   because a `retry:`-only record dispatches no event and the value would have
   nowhere to go; `id` is carried forward across events, since the spec's
   last-event-id buffer is not cleared between records; and an `id` containing
   NUL is dropped, which is a header-injection guard for any caller that later
   implements resumption, not pedantry.
3. ~~**The client streaming surface.**~~ _Done._ `http.stream(request)`
   returning a connection-owning `http.Stream`, plus `http.with_stream`; `send`
   redefined over `stream`; and the end-to-end hermetic tests against an SSE
   handler on the loopback server — including the incrementality assertion,
   which is mutation-checked (making the client read the body whole first fails
   it, in bounded time rather than by hanging).
4. ~~**Docs.**~~ _Done._ [stdlib.md](stdlib.md) § `std.http` lost "bodies are
   buffered whole" and gained `std.http.sse`; the roadmap has the changelog
   entries; [api-access.md](api-access.md) Arc 1 item 2 is a pointer here.

## Open questions to settle

- ~~**Where does SSE live** — a file under `std.http` or its own library?~~
  _Settled in stage 2:_ **`std.http.sse`**, a nested directory library. See §
  layer (b), including the correction to the answer this doc first gave.
- ~~**A lone `\r` as a line terminator.** The SSE spec allows CR, LF, or CRLF;
  `io.lines` splits on LF and strips a trailing CR, so a stream terminated with
  bare CRs would arrive as one enormous line.~~ _Settled in stage 2: accept the
  gap._ The cheap fix the question proposed — post-splitting each line on `\r` —
  turns out not to be a fix at all: with bare CRs, `io.lines` yields nothing
  until it reaches an LF or end-of-stream, so a **live** CR-delimited stream
  would still block, and post-splitting would only rescue a finite one. A real
  fix means a CR-or-LF splitter with its own buffering, duplicating
  `io.BufReader` for a terminator no server emits. Documented as unsupported
  instead; if it is ever needed, the splitter belongs in `std.http.sse`, not in
  `io.lines`, whose contract is fine as it is.
- **Does `stream_response` belong on the request side too?** A server handler
  receiving a large upload has the same problem in reverse. The machinery is
  already generic (`framing_of` + `BodyReader` don't care which direction they
  are reading), so this is a surface decision, not new work — but nothing needs
  it yet.
- **Per-event timeouts.** `fiber.with_timeout` can bound a whole stream, but the
  useful bound on a token stream is "no event for N seconds". That interacts
  with SSE keep-alive comments (a comment resets the clock without producing an
  event) and belongs with Arc 1 item 5's timeout work, not here.
- **Connection reuse.** A fully-consumed body leaves the connection at a clean
  message boundary, which is the precondition for keep-alive. `is_complete` is
  the bit that would gate it. Nothing to do until pooling exists; the reader
  just shouldn't make it impossible, and it doesn't.
