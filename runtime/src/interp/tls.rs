//! The TLS session under the `tls_*` natives: a `rustls` connection plus the pump
//! that drives it against a **non-blocking** transport. Stage 2 of
//! docs/http-tls.md §Staged plan.
//!
//! rustls is bring-your-own-I/O — it owns the handshake state machine and the
//! plaintext↔ciphertext buffers, and the caller moves bytes. That is exactly the
//! shape the socket natives already have, so a TLS op is the same three steps every
//! time, and every step is resumable:
//!
//!  1. `drain` — push whatever ciphertext rustls has queued at the socket;
//!  2. `fill` — pull ciphertext off the socket and feed it to rustls;
//!  3. attempt the plaintext operation.
//!
//! When the socket won't take (or give) more, the pump returns
//! [`Progress::Blocked`] and the native parks on readiness; the `call.native`
//! re-runs and re-enters the pump. **That is safe because all partial state lives
//! in the `Connection` — which lives in the socket registry, not on the stack — so
//! a retry resumes rather than restarts.** The one place that is not true for free
//! is [`TlsSession::write`]: plaintext handed to rustls is consumed, so re-feeding
//! it on a retry would send it twice. The fix is structural — the only park in
//! `write` happens *before* any plaintext is fed, and the amount fed comes back as
//! a count for the Thera side to loop over, the same discipline `socket_write` uses
//! (see its comment in natives.rs, and the tests at the bottom of this file).
//!
//! This layer is generic over the transport so those invariants can be tested
//! against an in-memory pipe, with no sockets and no scheduler: the unit tests
//! below force a block at every step and assert the retry neither loses nor
//! duplicates a byte. The complementary rustls-level tests (certificate and
//! hostname verification, the root bundle) live in runtime/tests/tls.rs.

use std::cell::RefCell;
use std::io::{self, ErrorKind, Read, Write};
use std::sync::Arc;

use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, Connection, RootCertStore};

/// How far a pump got. `Blocked` is the caller's cue to park on socket readiness
/// and re-run the native, which re-enters the pump where this one left off.
pub(super) enum Progress<T> {
    Done(T),
    Blocked,
}

/// Why a TLS op failed. Kept apart from `std::io::Error` so the Thera side can
/// tell "the socket broke" (mapped to the usual `NetError` kinds) from "TLS
/// refused" — a bad certificate must not read as a generic I/O hiccup.
#[derive(Debug)]
pub(super) enum TlsError {
    /// The underlying socket failed.
    Io(io::Error),
    /// TLS itself refused: certificate or hostname verification, a protocol
    /// violation, a peer alert.
    Protocol(rustls::Error),
    /// The host name isn't usable as a TLS server name (so there is nothing to
    /// verify a certificate against).
    Hostname(String),
    /// The peer closed the TCP connection where TLS requires more — mid-handshake,
    /// or before the `close_notify` that ends a stream cleanly. Reported rather
    /// than passed off as a plain EOF: a silently accepted truncation is an attack
    /// surface, not a tidy shutdown (docs/http-tls.md §Goals). `.0` says where.
    Truncated(&'static str),
}

/// What a `fill` achieved.
enum Fill {
    /// Ciphertext was read and processed; try the operation again.
    Fed,
    /// The socket had nothing more right now.
    Blocked,
    /// The socket is at EOF. Whether that is a clean end or a truncation is
    /// rustls's verdict, not ours — ask its reader.
    Eof,
}

/// A TLS session: the rustls connection for one socket. Lives in the socket
/// registry beside the `TcpStream` it wraps (see natives.rs `Socket::Tls`), which
/// is what makes the pump resumable across a park.
#[derive(Debug)]
pub(super) struct TlsSession {
    conn: Connection,
}

impl TlsSession {
    /// A client session for `host`, which is both the SNI name sent and the name
    /// the server's certificate must match. No I/O — `handshake` does that.
    pub(super) fn client(config: Arc<ClientConfig>, host: &str) -> Result<Self, TlsError> {
        let name = ServerName::try_from(host.to_string())
            .map_err(|_| TlsError::Hostname(host.to_string()))?;
        let conn = ClientConnection::new(config, name).map_err(TlsError::Protocol)?;
        Ok(Self {
            conn: Connection::Client(conn),
        })
    }

    /// Drive the handshake as far as the socket allows. `Done` means the session is
    /// ready for plaintext — and, for a client, that the server's certificate chain
    /// and name both verified: rustls reports a bad certificate as an error here,
    /// never as a completed handshake.
    ///
    /// Idempotent: everything partial is in the `Connection`, so a retry resumes.
    pub(super) fn handshake<S: Read + Write>(
        &mut self,
        sock: &mut S,
    ) -> Result<Progress<()>, TlsError> {
        loop {
            // Flush *before* testing: rustls stops calling itself "handshaking" the
            // moment it has written its own Finished, which is still queued here.
            if !self.drain(sock)? {
                return Ok(Progress::Blocked);
            }
            if !self.conn.is_handshaking() {
                return Ok(Progress::Done(()));
            }
            match self.fill(sock)? {
                Fill::Fed => {}
                Fill::Blocked => return Ok(Progress::Blocked),
                Fill::Eof => return Err(TlsError::Truncated("during the TLS handshake")),
            }
        }
    }

    /// Up to `max` bytes of plaintext. An **empty** result is EOF: the peer sent
    /// `close_notify`. Idempotent — a retry that finds nothing decrypted yet has
    /// consumed nothing.
    pub(super) fn read<S: Read + Write>(
        &mut self,
        sock: &mut S,
        max: usize,
    ) -> Result<Progress<Vec<u8>>, TlsError> {
        debug_assert!(max > 0, "an empty read is indistinguishable from EOF");
        let mut buf = vec![0u8; max];
        loop {
            // Plaintext rustls already holds, which is also where the two ends of a
            // stream surface: `Ok(0)` for a clean `close_notify`, `UnexpectedEof`
            // for a socket that just stopped.
            match self.conn.reader().read(&mut buf) {
                Ok(n) => {
                    buf.truncate(n);
                    return Ok(Progress::Done(buf));
                }
                Err(e) if e.kind() == ErrorKind::WouldBlock => {}
                Err(e) if e.kind() == ErrorKind::UnexpectedEof => {
                    return Err(TlsError::Truncated("without a TLS close_notify"));
                }
                Err(e) => return Err(TlsError::Io(e)),
            }
            // Nothing decrypted yet. Get our own records out first — a request the
            // caller wrote may still be queued, and waiting for a reply we haven't
            // asked for is a deadlock — then wait for theirs.
            if !self.drain(sock)? {
                return Ok(Progress::Blocked);
            }
            match self.fill(sock)? {
                Fill::Fed => {}
                Fill::Blocked => return Ok(Progress::Blocked),
                // Loop once more so rustls grades the EOF (above). It cannot answer
                // `WouldBlock` again — having seen EOF, its reader answers `Ok(0)`
                // or `UnexpectedEof` — so this doesn't spin.
                Fill::Eof => {}
            }
        }
    }

    /// Hand `data` to rustls to encrypt and return **how much it took**, which may
    /// be short: its outgoing queue is size-capped, and that cap is the
    /// backpressure a plaintext writer sees. The caller loops over the remainder
    /// (`io.write_all`), exactly as for a short `socket_write`.
    ///
    /// The idempotency hazard lives here, and the shape is the fix: the only park
    /// (`Blocked`) is returned *before* any plaintext is fed, so a retry re-feeds
    /// nothing. Do not add a park after the feed — that is the double-send bug
    /// `feeding_the_same_plaintext_twice_double_sends` demonstrates.
    pub(super) fn write<S: Read + Write>(
        &mut self,
        sock: &mut S,
        data: &[u8],
    ) -> Result<Progress<usize>, TlsError> {
        debug_assert!(!data.is_empty(), "an empty write cannot make progress");
        // Drain first: it makes room in the capped queue below, and — being pure
        // socket flushing — it is safe to repeat on a retry.
        self.drain(sock)?;
        // Infallible in rustls, and the *only* place plaintext is consumed: once
        // per call, never on a retry.
        let taken = self.conn.writer().write(data).map_err(TlsError::Io)?;
        if taken == 0 {
            // The queue is full. Parking is right only if readiness can empty it;
            // if rustls has nothing to send, waiting would hang instead.
            return if self.conn.wants_write() {
                Ok(Progress::Blocked)
            } else {
                Err(TlsError::Io(io::Error::new(
                    ErrorKind::WriteZero,
                    "the TLS session accepted no plaintext",
                )))
            };
        }
        // Best effort: get the record moving now rather than at the next op. A
        // socket that won't take it is not an error — the bytes stay queued and the
        // next `drain` (any op, including `close`) sends them.
        self.drain(sock)?;
        Ok(Progress::Done(taken))
    }

    /// Send `close_notify` and flush it — the graceful end of a TLS stream, which
    /// is what lets the peer tell a finished stream from a truncated one. The
    /// caller closes the socket once this is `Done`.
    ///
    /// Idempotent: rustls queues at most one `close_notify` per session (a second
    /// `send_close_notify` is a no-op), so a retry only re-flushes.
    pub(super) fn close<S: Read + Write>(
        &mut self,
        sock: &mut S,
    ) -> Result<Progress<()>, TlsError> {
        self.conn.send_close_notify();
        // One queue holds both, so this flushes any unsent application data ahead
        // of the alert, in order.
        if self.drain(sock)? {
            Ok(Progress::Done(()))
        } else {
            Ok(Progress::Blocked)
        }
    }

    /// Would a `read` return without parking? True when plaintext is buffered, and
    /// also at an end of stream (EOF and errors are reported by `read`, not waited
    /// on) — the contract `socket_is_ready` needs to keep a TLS stream selectable.
    pub(super) fn has_plaintext(&mut self) -> bool {
        !matches!(
            self.conn.reader().into_first_chunk(),
            Err(e) if e.kind() == ErrorKind::WouldBlock
        )
    }

    /// Push queued ciphertext at the socket. `true` when the queue is empty,
    /// `false` when the socket wouldn't take the rest (rustls keeps the remainder
    /// and its position, so repeating this is free).
    fn drain<S: Write>(&mut self, sock: &mut S) -> Result<bool, TlsError> {
        while self.conn.wants_write() {
            match self.conn.write_tls(sock) {
                // A sink that accepts nothing is a blocked sink; treating it as
                // progress would spin.
                Ok(0) => return Ok(false),
                Ok(_) => {}
                Err(e) if e.kind() == ErrorKind::WouldBlock => return Ok(false),
                Err(e) => return Err(TlsError::Io(e)),
            }
        }
        Ok(true)
    }

    /// Pull ciphertext off the socket and let rustls process it.
    fn fill<S: Read + Write>(&mut self, sock: &mut S) -> Result<Fill, TlsError> {
        match self.conn.read_tls(sock) {
            Ok(0) => Ok(Fill::Eof),
            Ok(_) => match self.conn.process_new_packets() {
                Ok(_) => Ok(Fill::Fed),
                Err(e) => {
                    // rustls has queued a fatal alert naming the reason; give the
                    // peer that before we hang up. Best effort — the socket may
                    // already be gone, and the TLS error is the one that matters.
                    let _ = self.drain(sock);
                    Err(TlsError::Protocol(e))
                }
            },
            Err(e) if e.kind() == ErrorKind::WouldBlock => Ok(Fill::Blocked),
            Err(e) => Err(TlsError::Io(e)),
        }
    }
}

thread_local! {
    /// The client config, built on first use. Shared by every connection on this
    /// thread deliberately: it carries the root store (~150 trust anchors, too
    /// expensive to rebuild per connection) *and* the session-resumption cache, so
    /// sharing it is what makes resumption work at all.
    static CLIENT_CONFIG: RefCell<Option<Arc<ClientConfig>>> = const { RefCell::new(None) };
}

/// The production client config: verify the chain and the host name against the
/// bundled Mozilla root store, no client certificate (docs/http-tls.md §Runtime
/// crate settles both choices; the test-only trust-injection seam is stage 3).
pub(super) fn default_client_config() -> Arc<ClientConfig> {
    CLIENT_CONFIG.with(|c| {
        c.borrow_mut()
            .get_or_insert_with(|| {
                let roots = RootCertStore {
                    roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
                };
                Arc::new(
                    ClientConfig::builder()
                        .with_root_certificates(roots)
                        .with_no_client_auth(),
                )
            })
            .clone()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
    use rustls::{ServerConfig, ServerConnection};

    /// A transport double: an in-memory pipe whose per-call caps let a test say
    /// "the socket takes nothing right now" or "it takes one byte at a time", which
    /// is how the pump gets walked through every `Blocked` return deterministically.
    #[derive(Default)]
    struct Wire {
        /// Ciphertext the session has written, heading for the peer.
        out: Vec<u8>,
        /// Ciphertext waiting for the session to read.
        inbox: Vec<u8>,
        /// Bytes accepted per `write`; `None` is unlimited, `Some(0)` blocks.
        write_cap: Option<usize>,
        /// Bytes handed over per `read`; `None` is unlimited, `Some(0)` blocks.
        read_cap: Option<usize>,
        /// Report EOF, rather than `WouldBlock`, once `inbox` runs dry.
        eof: bool,
    }

    impl Wire {
        fn open() -> Self {
            Self::default()
        }
    }

    impl Write for Wire {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let n = self.write_cap.unwrap_or(usize::MAX).min(buf.len());
            if n == 0 {
                return Err(ErrorKind::WouldBlock.into());
            }
            self.out.extend_from_slice(&buf[..n]);
            Ok(n)
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl Read for Wire {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.inbox.is_empty() {
                return if self.eof {
                    Ok(0)
                } else {
                    Err(ErrorKind::WouldBlock.into())
                };
            }
            let n = self
                .read_cap
                .unwrap_or(usize::MAX)
                .min(buf.len())
                .min(self.inbox.len());
            if n == 0 {
                return Err(ErrorKind::WouldBlock.into());
            }
            buf[..n].copy_from_slice(&self.inbox[..n]);
            self.inbox.drain(..n);
            Ok(n)
        }
    }

    /// A test CA and a `localhost` leaf signed by it — the same shape as the PKI in
    /// runtime/tests/tls.rs, kept separate because these are unit tests of the
    /// session pump (that file tests the rustls stack itself).
    struct Pki {
        ca: rustls::pki_types::CertificateDer<'static>,
        leaf: rustls::pki_types::CertificateDer<'static>,
        key: PrivateKeyDer<'static>,
    }

    fn pki() -> Pki {
        let ca_key = rcgen::KeyPair::generate().unwrap();
        let mut ca_params = rcgen::CertificateParams::new(Vec::new()).unwrap();
        ca_params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
        let ca = ca_params.self_signed(&ca_key).unwrap().der().clone();
        let issuer = rcgen::Issuer::new(ca_params, ca_key);

        let leaf_key = rcgen::KeyPair::generate().unwrap();
        let leaf = rcgen::CertificateParams::new(vec!["localhost".to_string()])
            .unwrap()
            .signed_by(&leaf_key, &issuer)
            .unwrap();
        Pki {
            ca,
            leaf: leaf.der().clone(),
            key: PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key.serialize_der())),
        }
    }

    /// The other end: a rustls server plus everything it has decrypted so far. It
    /// drains its plaintext as it reads, because rustls caps its receive buffer —
    /// a test that pushes more than that through has to keep up.
    struct Peer {
        conn: ServerConnection,
        plaintext: Vec<u8>,
    }

    impl Peer {
        /// Take everything on the wire, decrypt it, and queue whatever it replies.
        /// This stands in for the scheduler giving the peer a turn, which is also
        /// what a park does — hence one call per `Blocked` in the tests below.
        fn pump(&mut self, wire: &mut Wire) {
            let ciphertext = std::mem::take(&mut wire.out);
            let mut rd = &ciphertext[..];
            while !rd.is_empty() {
                match self.conn.read_tls(&mut rd) {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(e) => panic!("the peer could not read: {e}"),
                }
                self.conn.process_new_packets().unwrap();
                self.collect();
            }
            self.collect();
            let mut reply = Vec::new();
            while self.conn.wants_write() {
                self.conn.write_tls(&mut reply).unwrap();
            }
            wire.inbox.extend(reply);
        }

        fn collect(&mut self) {
            let mut buf = [0u8; 8192];
            // `Ok(0)` is a clean end, an `Err` is `WouldBlock` (nothing decrypted
            // yet); either way there is nothing more to take right now.
            while let Ok(n) = self.conn.reader().read(&mut buf) {
                if n == 0 {
                    return;
                }
                self.plaintext.extend_from_slice(&buf[..n]);
            }
        }
    }

    /// A client session trusting only the test CA, and the matching server.
    fn pair() -> (TlsSession, Peer) {
        let pki = pki();
        let mut roots = RootCertStore::empty();
        roots.add(pki.ca.clone()).unwrap();
        let client = TlsSession::client(
            Arc::new(
                ClientConfig::builder()
                    .with_root_certificates(roots)
                    .with_no_client_auth(),
            ),
            "localhost",
        )
        .unwrap();
        let conn = ServerConnection::new(Arc::new(
            ServerConfig::builder()
                .with_no_client_auth()
                .with_single_cert(vec![pki.leaf], pki.key)
                .unwrap(),
        ))
        .unwrap();
        (
            client,
            Peer {
                conn,
                plaintext: Vec::new(),
            },
        )
    }

    /// Handshake to completion, counting the parks on the way. Every `Blocked` is a
    /// park: the native returns, the poller wakes it, and the same call re-enters
    /// the pump — the retry these tests exist to exercise.
    fn handshake(client: &mut TlsSession, peer: &mut Peer, wire: &mut Wire) -> usize {
        let mut parks = 0usize;
        loop {
            match client.handshake(wire).unwrap() {
                Progress::Done(()) => break,
                Progress::Blocked => {
                    parks += 1;
                    peer.pump(wire);
                }
            }
        }
        // The client finishes first (it stops handshaking once its own Finished is
        // out), so hand that last flight over before anyone sends plaintext.
        peer.pump(wire);
        assert!(!peer.conn.is_handshaking(), "the peer never completed");
        parks
    }

    #[test]
    fn a_handshake_survives_a_transport_that_moves_one_byte_at_a_time() {
        let (mut client, mut peer) = pair();
        // Every socket write takes a single byte and every read gives one back, so
        // the pump meets a partial record at every step.
        let mut wire = Wire {
            write_cap: Some(1),
            read_cap: Some(1),
            ..Wire::open()
        };
        let parks = handshake(&mut client, &mut peer, &mut wire);
        assert!(parks > 0, "the pump never had to wait for the peer");

        // And the session works afterwards, still a byte at a time.
        assert!(matches!(
            client.write(&mut wire, b"ping").unwrap(),
            Progress::Done(4)
        ));
        peer.pump(&mut wire);
        assert_eq!(peer.plaintext, b"ping");
    }

    #[test]
    fn a_read_reassembles_plaintext_delivered_a_byte_at_a_time() {
        let (mut client, mut peer) = pair();
        let mut wire = Wire::open();
        handshake(&mut client, &mut peer, &mut wire);

        peer.conn.writer().write_all(b"hello, plaintext").unwrap();
        peer.pump(&mut wire);
        // One byte per read, so most retries see an incomplete record and must
        // resume from what rustls already holds.
        wire.read_cap = Some(1);
        let mut got = Vec::new();
        while got != b"hello, plaintext" {
            match client.read(&mut wire, 64).unwrap() {
                Progress::Done(chunk) => {
                    assert!(!chunk.is_empty(), "EOF before the message arrived");
                    got.extend(chunk);
                }
                Progress::Blocked => panic!("parked with {} bytes still queued", wire.inbox.len()),
            }
        }
    }

    #[test]
    fn a_blocked_write_retried_with_the_same_plaintext_sends_it_once() {
        // The invariant the whole design turns on (docs/http-tls.md §Park/retry).
        // The socket takes nothing, so rustls's outgoing queue fills and `write`
        // returns `Blocked` — the point where the native parks and the scheduler
        // re-runs it *with the same arguments*. Feeding plaintext before that park
        // would put a second copy on the wire.
        let (mut client, mut peer) = pair();
        let mut wire = Wire::open();
        handshake(&mut client, &mut peer, &mut wire);

        let payload: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let mut sent = 0usize;
        let mut parks = 0usize;
        wire.write_cap = Some(0); // nothing leaves: the queue has to back up
        while sent < payload.len() {
            match client.write(&mut wire, &payload[sent..]).unwrap() {
                Progress::Done(n) => sent += n,
                Progress::Blocked => {
                    parks += 1;
                    // The socket becomes writable and the native re-runs from the
                    // same offset — verbatim, as the interpreter would.
                    wire.write_cap = None;
                    let Progress::Done(n) = client.write(&mut wire, &payload[sent..]).unwrap()
                    else {
                        panic!("still blocked on a writable socket");
                    };
                    sent += n;
                    peer.pump(&mut wire);
                    wire.write_cap = Some(0);
                }
            }
        }
        assert!(parks > 0, "the queue never filled — this proved nothing");
        // Flush the tail: any op drains the queue, and `close` must (it goes out
        // ahead of the `close_notify`).
        wire.write_cap = None;
        while matches!(client.close(&mut wire).unwrap(), Progress::Blocked) {}
        peer.pump(&mut wire);

        assert_eq!(peer.plaintext.len(), payload.len());
        assert_eq!(peer.plaintext, payload);
    }

    #[test]
    fn feeding_the_same_plaintext_twice_double_sends() {
        // The deliberate break that gives the test above teeth: this is what a pump
        // that re-fed its argument after a park would do, and the peer sees both
        // copies. Nothing stops a future edit from reintroducing it *except* that
        // `write` parks only before the feed.
        let (mut client, mut peer) = pair();
        let mut wire = Wire::open();
        handshake(&mut client, &mut peer, &mut wire);

        for _ in 0..2 {
            assert!(matches!(
                client.write(&mut wire, b"POST /once").unwrap(),
                Progress::Done(10)
            ));
        }
        peer.pump(&mut wire);
        assert_eq!(peer.plaintext, b"POST /oncePOST /once");
    }

    #[test]
    fn a_blocked_close_retried_sends_one_close_notify() {
        // `close` is the other native that must not repeat itself: two alerts on
        // the wire is a protocol error. Measured against a close that never parked
        // — the retried one must put the same bytes out, not more.
        let straight = {
            let (mut client, mut peer) = pair();
            let mut wire = Wire::open();
            handshake(&mut client, &mut peer, &mut wire);
            assert!(matches!(
                client.close(&mut wire).unwrap(),
                Progress::Done(())
            ));
            wire.out.len()
        };

        let (mut client, mut peer) = pair();
        let mut wire = Wire::open();
        handshake(&mut client, &mut peer, &mut wire);
        wire.write_cap = Some(0);
        for _ in 0..3 {
            assert!(matches!(
                client.close(&mut wire).unwrap(),
                Progress::Blocked
            ));
        }
        wire.write_cap = None;
        assert!(matches!(
            client.close(&mut wire).unwrap(),
            Progress::Done(())
        ));
        assert_eq!(
            wire.out.len(),
            straight,
            "the retried close put more than one close_notify on the wire"
        );

        // And the peer sees a clean end rather than a truncation.
        peer.pump(&mut wire);
        assert_eq!(peer.conn.reader().read(&mut [0u8; 4]).unwrap(), 0);
    }

    #[test]
    fn a_close_notify_reads_as_eof() {
        let (mut client, mut peer) = pair();
        let mut wire = Wire::open();
        handshake(&mut client, &mut peer, &mut wire);

        peer.conn.send_close_notify();
        peer.pump(&mut wire);
        let Progress::Done(chunk) = client.read(&mut wire, 64).unwrap() else {
            panic!("parked instead of reporting EOF");
        };
        assert!(chunk.is_empty(), "expected EOF, got {} bytes", chunk.len());
    }

    #[test]
    fn a_socket_that_ends_without_close_notify_is_a_truncation() {
        // The security-relevant half of the pair above: a socket that just stops is
        // reported, never passed off as the end of the stream.
        let (mut client, mut peer) = pair();
        let mut wire = Wire::open();
        handshake(&mut client, &mut peer, &mut wire);
        wire.inbox.clear();
        wire.eof = true;

        match client.read(&mut wire, 64) {
            Err(TlsError::Truncated(_)) => {}
            Err(e) => panic!("expected a truncation, got {e:?}"),
            Ok(_) => panic!("a truncated stream must not read as EOF"),
        }
    }

    #[test]
    fn a_peer_that_vanishes_mid_handshake_is_a_truncation() {
        let (mut client, _peer) = pair();
        let mut wire = Wire {
            eof: true,
            ..Wire::open()
        };
        assert!(matches!(
            client.handshake(&mut wire),
            Err(TlsError::Truncated(_))
        ));
    }

    #[test]
    fn has_plaintext_tracks_whether_a_read_would_park() {
        let (mut client, mut peer) = pair();
        let mut wire = Wire::open();
        handshake(&mut client, &mut peer, &mut wire);
        assert!(!client.has_plaintext());

        peer.conn.writer().write_all(b"ready").unwrap();
        peer.pump(&mut wire);
        // Nothing is *decrypted* yet — whether the socket has bytes is the socket's
        // question, and `socket_is_ready` asks it separately.
        assert!(!client.has_plaintext());
        assert!(matches!(
            client.read(&mut wire, 2).unwrap(),
            Progress::Done(_)
        ));
        assert!(client.has_plaintext(), "3 bytes are still buffered");
    }

    #[test]
    fn an_unusable_host_name_is_rejected_before_any_io() {
        let err = TlsSession::client(default_client_config(), "not a host name").unwrap_err();
        assert!(matches!(err, TlsError::Hostname(_)));
    }

    #[test]
    fn the_client_config_is_built_once_per_thread() {
        // Rebuilding it per connection would re-clone the whole root bundle and
        // throw away the session cache with it. (That the bundle populates a config
        // at all is runtime/tests/tls.rs's `webpki_roots_populate_a_client_config`.)
        assert!(Arc::ptr_eq(
            &default_client_config(),
            &default_client_config()
        ));
    }
}
