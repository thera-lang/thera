//! Stage-1 TLS spike (docs/http-tls.md §Staged plan): prove the `rustls` +
//! `aws-lc-rs` + `webpki-roots` + `rcgen` stack builds and handshakes, entirely
//! in memory — no sockets, no network. The `transfer` pump here is the same
//! wants_write/read_tls discipline the `tls_*` natives will run against the
//! readiness poller in stage 2; these tests are the deterministic home for the
//! session-level invariants.

use std::io::{Read, Write};
use std::sync::Arc;

use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer, ServerName};
use rustls::{
    CertificateError, ClientConfig, ClientConnection, ConnectionCommon, Error, RootCertStore,
    ServerConfig, ServerConnection,
};

/// A test CA plus a leaf certificate for `localhost` signed by it, generated
/// fresh per test by `rcgen` — the shape the stage-5 in-process loop will use.
struct TestPki {
    ca_der: rustls::pki_types::CertificateDer<'static>,
    leaf_der: rustls::pki_types::CertificateDer<'static>,
    leaf_key: PrivateKeyDer<'static>,
}

fn test_pki() -> TestPki {
    let ca_key = rcgen::KeyPair::generate().unwrap();
    let mut ca_params = rcgen::CertificateParams::new(Vec::new()).unwrap();
    ca_params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
    let ca_cert = ca_params.self_signed(&ca_key).unwrap();
    let ca_der = ca_cert.der().clone();
    let issuer = rcgen::Issuer::new(ca_params, ca_key);

    let leaf_key = rcgen::KeyPair::generate().unwrap();
    let leaf_params = rcgen::CertificateParams::new(vec!["localhost".to_string()]).unwrap();
    let leaf_cert = leaf_params.signed_by(&leaf_key, &issuer).unwrap();

    TestPki {
        ca_der,
        leaf_der: leaf_cert.der().clone(),
        leaf_key: PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key.serialize_der())),
    }
}

fn server_config(pki: &TestPki) -> Arc<ServerConfig> {
    Arc::new(
        ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![pki.leaf_der.clone()], pki.leaf_key.clone_key())
            .unwrap(),
    )
}

fn client_config(roots: RootCertStore) -> Arc<ClientConfig> {
    Arc::new(
        ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth(),
    )
}

/// Move all pending ciphertext from one connection to the other — the in-memory
/// stand-in for the socket. Mirrors the natives' pump: drain `wants_write` via
/// `write_tls`, feed the peer via `read_tls`.
fn transfer<L, R>(from: &mut ConnectionCommon<L>, to: &mut ConnectionCommon<R>) {
    let mut wire = Vec::new();
    while from.wants_write() {
        from.write_tls(&mut wire).unwrap();
    }
    let mut rd = &wire[..];
    while !rd.is_empty() {
        to.read_tls(&mut rd).unwrap();
    }
}

/// Pump both directions until neither side is handshaking; the certificate
/// verdict surfaces as an `Err` from one side's `process_new_packets`.
fn handshake(client: &mut ClientConnection, server: &mut ServerConnection) -> Result<(), Error> {
    while client.is_handshaking() || server.is_handshaking() {
        transfer(client, server);
        server.process_new_packets()?;
        transfer(server, client);
        client.process_new_packets()?;
    }
    Ok(())
}

#[test]
fn in_memory_handshake_and_echo() {
    let pki = test_pki();
    let mut roots = RootCertStore::empty();
    roots.add(pki.ca_der.clone()).unwrap();

    let mut client = ClientConnection::new(
        client_config(roots),
        ServerName::try_from("localhost").unwrap(),
    )
    .unwrap();
    let mut server = ServerConnection::new(server_config(&pki)).unwrap();

    handshake(&mut client, &mut server).unwrap();
    assert_eq!(
        client.protocol_version(),
        Some(rustls::ProtocolVersion::TLSv1_3)
    );
    assert!(client.peer_certificates().is_some_and(|c| !c.is_empty()));

    // Plaintext round-trips through the encrypted channel both ways.
    client.writer().write_all(b"ping").unwrap();
    transfer(&mut client, &mut server);
    server.process_new_packets().unwrap();
    let mut buf = [0u8; 4];
    server.reader().read_exact(&mut buf).unwrap();
    assert_eq!(&buf, b"ping");

    server.writer().write_all(b"pong").unwrap();
    transfer(&mut server, &mut client);
    client.process_new_packets().unwrap();
    client.reader().read_exact(&mut buf).unwrap();
    assert_eq!(&buf, b"pong");

    // close_notify round-trips: the client's reader sees a clean EOF, not an
    // abrupt-close error — the `tls_close` semantics stage 2 relies on.
    server.send_close_notify();
    transfer(&mut server, &mut client);
    client.process_new_packets().unwrap();
    assert_eq!(client.reader().read(&mut buf).unwrap(), 0);
}

#[test]
fn untrusted_cert_is_rejected() {
    // A client that trusts nothing must refuse the test CA's leaf: an `Err`,
    // never a completed handshake (docs/http-tls.md §Goals).
    let pki = test_pki();
    let mut client = ClientConnection::new(
        client_config(RootCertStore::empty()),
        ServerName::try_from("localhost").unwrap(),
    )
    .unwrap();
    let mut server = ServerConnection::new(server_config(&pki)).unwrap();

    let err = handshake(&mut client, &mut server).unwrap_err();
    assert!(
        matches!(
            err,
            Error::InvalidCertificate(CertificateError::UnknownIssuer)
        ),
        "expected UnknownIssuer, got: {err:?}"
    );
}

#[test]
fn hostname_mismatch_is_rejected() {
    // Trusting the CA is not enough: the leaf is for `localhost`, so a client
    // expecting `example.com` must fail hostname verification.
    let pki = test_pki();
    let mut roots = RootCertStore::empty();
    roots.add(pki.ca_der.clone()).unwrap();

    let mut client = ClientConnection::new(
        client_config(roots),
        ServerName::try_from("example.com").unwrap(),
    )
    .unwrap();
    let mut server = ServerConnection::new(server_config(&pki)).unwrap();

    let err = handshake(&mut client, &mut server).unwrap_err();
    let Error::InvalidCertificate(cert_err) = &err else {
        panic!("expected InvalidCertificate, got: {err:?}");
    };
    assert!(
        format!("{cert_err:?}").contains("NotValidForName"),
        "expected NotValidForName, got: {err:?}"
    );
}

#[test]
fn webpki_roots_populate_a_client_config() {
    // The production trust path: the bundled Mozilla store loads and composes
    // into a `ClientConfig` (the one `tls_connect` will build, minus the
    // test-only trust-injection seam).
    let roots = RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    assert!(roots.roots.len() > 100, "root bundle looks empty/truncated");
    let _ = client_config(roots);
}
