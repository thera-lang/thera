# TLS for `std.http`

**What this is:** the design and staged plan for adding TLS to Thera's HTTP
stack, so `std.http` can fetch `https://` URLs. It covers the runtime crate
choice (and what it buys beyond TLS), the native ABI, how a TLS session rides
the existing non-blocking-socket park/retry model, the Thera-side `TlsStream`
surface, and a test strategy that stays hermetic. This is a plan, not yet
executed — see the roadmap's _Networking punchlist_ for where it sits (item 3,
"the last thing between `std.http` and complete").

## Goals & non-goals

- **Primary goal — the client speaks `https://`.** Today `std.http` is
  `http://`-only: an `https://` URL parses, then fails at `connect` with a
  precise "no TLS" message ([client.thera](../sdk/std/http/client.thera) —
  `default_port` already resolves 443, and the scheme branch is the one place
  the absence surfaces). Closing that gap is the whole point.
- **Verify the server; standard roots.** Full certificate-chain and hostname
  verification against the platform/bundled root store, on by default. A `https`
  request to a host with a bad or self-signed cert is a `Result.Err`
  (`HttpError.Connect` / a new TLS-flavored variant), never a trap and never
  silently insecure.
- **Non-goal (for v1) — client certificate auth.** Mutual TLS is a later add;
  the common case is server-auth only.
- **Non-goal (for v1) — a public server-TLS surface.** `std.http.server` stays
  plaintext-HTTP/1.1 (TLS terminated upstream, per
  [server.thera](../sdk/std/http/server.thera)). **But** the runtime will grow a
  TLS _accept_ native anyway, used only by the test harness (see § Testing) —
  the public `serve_tls` stays deferred, the native that would back it lands
  early because the in-process test loop needs it.
- **Non-goal — the other things deferred with TLS.** Redirect following,
  connection pooling, and streaming bodies ([stdlib.md](stdlib.md) § std.http)
  are independent and stay deferred; TLS does not unblock or require them.

## The seam already exists

The wire codec and client are built on `io.Reader`/`Writer`/`Closer`
interface-typed streams, so **nothing above the socket needs to change** — the
codec neither knows nor cares whether the stream underneath is a `net.TcpStream`
or a `TlsStream`. Concretely:

- [client.thera](../sdk/std/http/client.thera) already parses the scheme, sets
  `default_port` to 443 for `https`, and has a single `if url.scheme == 'https'`
  branch that returns the "not supported" error. TLS replaces that branch with
  "resolve → connect → **wrap the connected stream in a `TlsStream`**", and
  hands the wrapped stream to the same codec path the plaintext client uses.
- The wire codec (`wire.thera`) takes an interface-typed stream. Interface
  dispatch (`call.virtual`) means `TlsStream` implementing
  `Reader + Writer + Closer` is a drop-in.

So the work is entirely **below** the codec: a runtime TLS session, its natives,
and a thin Thera `TlsStream` wrapper.

## Runtime crate: `rustls`

Add **`rustls`** — pure-Rust TLS, no OpenSSL/system-library dependency, matching
the established "adopt a vetted best-of-breed Rust crate" pattern (`regex`,
`sha2`, `mio`). It would be the runtime's **5th deliberate dependency**. rustls
is _bring-your-own-I/O_: a `ClientConnection` owns the handshake state machine
and read/write plaintext↔ciphertext buffers, and you drive the actual socket —
which fits the existing non-blocking-socket model exactly (see § Park/retry).

Two sub-decisions, both with a real trade-off to settle before coding.

> **The overriding weight is security posture, not ergonomics.** TLS is the one
> part of this stack where a defect is a remotely-exploitable vulnerability, and
> the threat model to design for is a near-future one where a disclosed 0-day is
> weaponized within hours, not weeks. So when these decisions are actually made,
> the dominant criteria are: **a named security-response process and a track
> record of fast, coordinated patches**; **a maintainer base large and funded
> enough that CVEs get triaged promptly**; **how quickly a fix propagates to us**
> (which is as much about our own update discipline — see below — as the
> upstream's); and **audit history**. Build ergonomics, pure-Rust-ness, and
> dep-set tidiness are real but **secondary** — they break a tie between options
> that are both strong on security, and never outweigh a worse security posture.
> The corollary is an operational commitment, not just a crate pick: whatever we
> choose, the TLS/crypto deps go on a **fast patch track** — `cargo audit`/
> `cargo deny` in CI, Dependabot (or equivalent) enabled, and a standing
> intent to ship a runtime patch release promptly on an advisory rather than
> batching it with feature work.

1. **Crypto provider.** rustls needs a provider for the primitives (AEAD, ECDHE,
   signatures, HKDF). Options, to be judged first on the security weighting above:
   - **`aws-lc-rs`** (rustls's default) or **`ring`** — the battle-tested
     choices, with the largest deployment base and, for `aws-lc-rs`, a funded
     security team and FIPS lineage; this is where the fast-patch, well-audited
     argument is strongest. The cost is that **both pull in a C/assembly build
     step** (a C compiler; on some platforms cmake/nasm) — the runtime's _first_
     dependency needing a C toolchain (every prior dep is pure Rust (`sha2`) or
     libc-only (`mio`)), a CI/dev-bar and reproducible-build consideration, but a
     _secondary_ one under the weighting.
   - **A RustCrypto-backed provider** (`rustls` + a RustCrypto provider) — keeps
     the **pure-Rust** property and consolidates with the existing `sha2`
     (RustCrypto) dependency. Attractive on tidiness, but it must clear the
     security bar on its own merits — assess its maintenance funding, audit
     history, and patch cadence against the hardened providers rather than
     defaulting to it for cleanliness. Worth evaluating, but **not** presumptively
     preferred: a cleaner dep graph does not beat a stronger security-response
     record.
2. **Root store.** `webpki-roots` (the Mozilla bundle, compiled in —
   deterministic, no platform dependency) vs `rustls-native-certs` (reads the OS
   trust store — picks up enterprise/custom roots, but platform-variable). The
   determinism/reproducibility case leans **`webpki-roots`** (matching the
   slash-path / UTC / reproducible-everything stance elsewhere), **but note the
   security wrinkle:** a compiled-in bundle only reflects root-store changes —
   including **removing a newly-distrusted CA** — when we bump the dep, so this
   choice makes our patch discipline load-bearing for trust decisions, whereas
   `rustls-native-certs` inherits OS-managed root updates automatically. That
   trade (reproducibility vs automatic trust updates) is exactly the kind the
   security weighting has to arbitrate when the decision is made.

## What adding `rustls` buys beyond TLS

The user's question: does any of this pay off apart from the `https` feature?
Honestly, **the crate itself is mostly TLS-specific** — but two pieces of the
work are durable groundwork, and one dependency choice has latent reach:

1. **The crypto provider is a superset that a future `std.crypto` could stand
   on.** AEAD encryption, HMAC, sign/verify, HKDF — the tier
   [stdlib.md](stdlib.md) currently cedes to the ecosystem ("full crypto / TLS
   primitives → ecosystem") — are exactly the primitives the provider already
   ships. Adopting a real provider now means that tier, if it's ever promoted,
   needs **no new dependency**. If we pick the RustCrypto-backed provider, this
   is especially clean: the whole RustCrypto family (already in-tree via `sha2`)
   becomes the natural, consistent home for a `std.crypto`.
2. **The stream-wrapping refactor is what `std.net` promotion wants.**
   Generalizing the runtime `Socket` registry from "a plain TCP endpoint" to "a
   stream that may be plain **or** wrapped in a protocol layer", plus a reusable
   "resolve → connect → wrap" client seam, is precisely the shape a _committed_
   `std.net` needs (it's flagged provisional today). Any future
   streaming-protocol client (a WebSocket, a TLS-fronted database driver) reuses
   that seam. **The refactor outlasts the crate.**
3. **`rcgen` as a dev-dependency** (test cert generation, § Testing) is reusable
   for every future networking test, not just TLS.

Net: don't adopt `rustls` _for_ the side benefits — adopt it for `https` — but
the provider choice and the registry refactor are worth making with (1) and (2)
in mind, because they're where the non-TLS value actually is.

## Native ABI

A `tls_*` native layer sits **parallel to** the `socket_*` natives
([natives.rs](../runtime/src/interp/natives.rs)), reusing the socket handle and
registry underneath. The rustls session lives in the runtime registry
_alongside_ the raw socket; Thera holds an opaque `Int` handle inside a
`TlsStream`, the same pattern as `TcpStream` / `Regex` / `File`.

```
tls_connect(socket_handle, hostname)  -> Result<tls_handle, Error>   // start handshake
tls_handshake(tls_handle)             -> Result<Void, Error>         // drive to completion (parks)
tls_read(tls_handle, max)             -> Result<Bytes, Error>        // plaintext; empty = EOF
tls_write(tls_handle, data)           -> Result<Int, Error>          // plaintext; returns count
tls_close(tls_handle)                 -> Result<Void, Error>         // close_notify + drop
// test-only (public serve_tls stays deferred):
tls_accept(socket_handle, cert, key)  -> Result<tls_handle, Error>   // server side, for the test loop
```

Registry shape: extend the `Socket` enum (or add a sibling registry) with a
variant that owns `{ raw TcpStream, rustls Connection }`. `hostname` is passed
to `tls_connect` for SNI + certificate-name verification. The raw socket stays
registered for `READABLE | WRITABLE` exactly as now — the TLS layer changes
_what the native does with readiness_, not _how it parks_.

## Park/retry mechanics — the load-bearing part

This is where TLS meets the scheduler, and where the design has to be careful.
The existing rule ([mod.rs](../runtime/src/interp/mod.rs) `ParkRequest::Ready`):
a socket native **attempts its syscall first**; on `EWOULDBLOCK` it calls
`park_ready(handle)`, the `call.native` **re-executes on wake**, and the native
must be **idempotent across that retry**. Sockets are registered for
`READABLE | WRITABLE`, so _either_ edge wakes the handle's waiters and the
native re-attempts.

That model maps onto rustls cleanly because rustls's want-read / want-write both
reduce to "the underlying socket wasn't ready":

- **The pump loop.** Each TLS native runs a fixed pump against the rustls
  `Connection`: (a) if rustls `wants_write`, flush its outgoing ciphertext to
  the socket (`write_tls`); (b) if it `wants_read` (or we need more input), read
  ciphertext from the socket and feed it (`read_tls` + `process_new_packets`);
  (c) attempt the actual plaintext operation. If any socket step returns
  `EWOULDBLOCK`, call `park_ready(handle)` and return the discarded placeholder
  — the native re-runs on the next readiness edge (read _or_ write; the single
  registration covers both directions, so want-read and want-write need no
  separate park kinds). **This is `BlockRetry`/`Ready`'s discipline,
  unchanged.**
- **Idempotency — reads and handshake are naturally safe.** rustls buffers all
  partial state _inside_ the `Connection` (which lives in the registry, not on
  the stack), so a retry that re-enters the pump resumes from the buffered state
  — no progress is lost or double-applied. Handshake and `tls_read` are
  therefore idempotent for free, like `socket_read`/`accept`.
- **The one hazard — `tls_write` must not re-encrypt.** rustls's plaintext
  writer buffers into the connection and encrypts once; the danger is a native
  that re-feeds the _same_ plaintext on retry (double-send), the same trap
  `socket_write` avoids by returning a count. **Design the write native the same
  way:** feed plaintext into rustls **once per distinct call** and return how
  much was accepted, then let the Thera side (`io.write_all`) loop — with the
  wrinkle that "accepted into the rustls buffer" and "flushed to the socket" are
  two stages. Candidate resolutions, to pick during implementation:
  - Feed all plaintext to rustls (it buffers unbounded), return the full count,
    and treat flushing the ciphertext as the pump's job on this and subsequent
    calls (including at `tls_close`, which must flush before `close_notify`).
    Risk: unbounded internal buffering if the peer stalls.
  - Split "buffer" from "flush" à la `socket_connect` / `socket_connect_finish`,
    so retry never re-buffers. More natives, but mirrors the existing precedent
    for a non-idempotent socket op. This is **the** open ABI decision;
    everything else is mechanical. Flag it, pick it deliberately, and pin it
    with a mutation-style test (break idempotency, prove a test catches a
    double-write) the way the poller invariants were pinned.
- **`tls_close`** sends rustls's `close_notify` (a graceful-shutdown record that
  must be flushed to the socket) _then_ closes the underlying socket via the
  existing `socket_close` path — which already wakes poll waiters, so
  cancellation semantics are inherited.
- **DNS/connect are unchanged.** `tls_connect` wraps an _already-connected_
  socket, so resolve (`socket_resolve`, worker pool) and connect
  (`socket_connect` + `socket_connect_finish`, poller) happen first exactly as
  for a plaintext connection. TLS is a wrap on top, not a new connect path.

## Thera surface: `TlsStream`

A thin wrapper implementing the `std.io` streaming protocol, so it's
interchangeable with `net.TcpStream` under the wire codec:

```
pub struct TlsStream { let /* opaque handle to socket + rustls session */; }
impl TlsStream {
    // Wrap a connected TcpStream, drive the handshake, verify the cert for `host`.
    pub fn connect(_ stream: net.TcpStream, host: String) -> Result<TlsStream, Error>;
}
impl Reader for TlsStream { fn read(self, max: Int) -> Result<Bytes, Error>; }
impl Writer for TlsStream { fn write(self, _ data: Bytes) -> Result<Int, Error>; }
impl Closer for TlsStream { fn close(self) -> Result<Void, Error>; }
```

Placement question (decide during § layout): `TlsStream` most naturally lives in
the provisional `std.net` (it _is_ a socket-layer stream), keeping `std.http`'s
only change the scheme branch in `client.thera`. That does grow `std.net`'s
provisional surface with a TLS type — acceptable since it stays internal until
`std.net` is committed, and `std.http` is the sole consumer. The client picks
`TcpStream` vs `TlsStream` by scheme and passes either to the same codec.

`HttpError`: add a TLS variant (or fold into `Connect(String)`) so a
cert/handshake failure is matchable and renders a clear message.

## Testing

The blocker the client↔server in-process loop (spawn a listener fiber, fetch
from it, join — the pattern the plaintext HTTP tests use) hits: **TLS needs a
certificate**, and there's no server-TLS surface to terminate against. Options
considered:

1. **Live external endpoint** (`https://example.com`). Rejected as the suite's
   backbone — non-hermetic, network-dependent, flaky, and non-reproducible. Keep
   only as an **opt-in smoke** gated on an env var (`THERA_NET_TESTS`), off by
   default, so a real end-to-end path _can_ be exercised on demand.
2. **Rust-level in-memory handshake test** — a rustls client and server over an
   in-memory duplex (no sockets), asserting the pump loop and the ABI's
   idempotency (including the deliberate-break write test). Cheap, fully
   deterministic, and the right home for the invariant tests. **Do this.**
3. **In-process TLS loop with a self-signed cert** — the mirror of the plaintext
   HTTP test. Generate a cert at test time with **`rcgen`** (dev-dependency),
   stand up a TLS listener in a fiber via the **`tls_accept` native** (the
   reason it lands even though public `serve_tls` is deferred), and connect the
   client with that cert trusted. Requires a **client trust-injection seam**:
   the `tls_connect` native takes an optional "trust these PEM roots" / "accept
   this cert" parameter used _only_ by the harness (never surfaced in
   `std.http`'s public API). This is the closest analogue to the existing
   hermetic HTTP loop and the highest-value functional test. **Do this** — it's
   what makes the whole `https` path testable without the network.

**Recommendation:** (2) + (3) as the hermetic core (deterministic, no network),
plus (1) as an off-by-default live smoke. Building `tls_accept` for (3) is the
one place we do server-side TLS work ahead of exposing it — a deliberate,
documented choice, not scope creep: it's cheap once the client session machinery
exists (rustls server config vs client config) and it's what unlocks the
in-process loop.

## Staged plan

1. **Crate + provider spike.** Add `rustls` with the chosen provider and root
   store; a Rust-only in-memory client↔server handshake over a duplex buffer.
   Settles the provider/build-cost decision (§ crate) before any Thera surface.
2. **Client TLS natives + registry.** `tls_connect` / `tls_handshake` /
   `tls_read` / `tls_write` / `tls_close`; the registry variant owning
   `{ socket, rustls Connection }`; the pump loop and the park/retry wiring. Pin
   the write-idempotency invariant (§ Park/retry) with a break-it test.
3. **`TlsStream` Thera wrapper** (`Reader`/`Writer`/`Closer`) + the
   trust-injection seam on `tls_connect` for tests.
4. **Wire it into `std.http`.** Replace the `https` error branch in
   `client.thera` with resolve → connect → wrap; add the `HttpError` TLS
   variant.
5. **Tests.** `tls_accept` + `rcgen` in-process loop (§ Testing #3); the
   env-gated live smoke (#1). Update the `https_reports_that_tls_is_missing`
   test — its precondition is now gone.
6. **Docs.** Flip [stdlib.md](stdlib.md) § std.http from "`http://` only" to
   "https supported"; move the roadmap _Networking punchlist_ item 3 to the
   Changelog; note the still-deferred redirects/pooling/streaming and the
   deferred _public_ server TLS.

## Open questions to settle

- **Crypto provider**: RustCrypto-backed (pure Rust, consolidates with `sha2`)
  vs `aws-lc-rs`/`ring` (hardened, largest deployment base, first C-toolchain
  build in the tree). The crux is **security posture and patch cadence** (§
  Runtime crate) — audit history, funded maintenance, response speed — with
  build cost and dep tidiness as secondary tie-breakers.
- **Patch-track commitment**: `cargo audit`/`cargo deny` in CI, Dependabot on,
  and a standing intent to ship a prompt runtime patch on a TLS/crypto advisory
  rather than batching it. An operational decision to make alongside the crate
  pick, not after.
- **`tls_write` idempotency shape**: buffer-all-and-count vs split buffer/flush
  natives (§ Park/retry). The one genuinely non-mechanical ABI call.
- **Root store**: bundled `webpki-roots` (deterministic, but distrusting a CA
  needs a dep bump) vs `rustls-native-certs` (automatic OS-managed trust updates,
  platform-variable). Reproducibility vs automatic trust updates — the security
  weighting arbitrates.
- **`TlsStream` placement**: `std.net` (natural, grows a provisional surface) vs
  a private sibling under `std.http`.
- **Trust-injection seam**: how the test-only "trust this cert" knob is passed
  to `tls_connect` without leaking into the public `std.http` API.
