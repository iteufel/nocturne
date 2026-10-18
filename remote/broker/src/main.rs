//! Nocturne's rendezvous and encrypted relay service. It never receives pairing keys.
use anyhow::{Context, Result, ensure};
use iroh_relay::server::{
    CertConfig, ClientRateLimit, QuicConfig, RelayConfig, Server, ServerConfig, TlsConfig,
};
use std::{env, fs::File, io::BufReader, net::SocketAddr, num::NonZeroU32};

fn setting(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.into())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();
    let dev = env::args().any(|arg| arg == "--dev");
    let http: SocketAddr = setting(
        "NOCTURNE_BROKER_HTTP",
        if dev {
            "127.0.0.1:3340"
        } else {
            "0.0.0.0:8080"
        },
    )
    .parse()?;
    ensure!(
        !dev || http.ip().is_loopback(),
        "--dev must bind a loopback address"
    );
    let mut relay = RelayConfig::new(http);
    let rate = setting("NOCTURNE_BROKER_BYTES_PER_SECOND", "12500000").parse::<NonZeroU32>()?;
    relay.limits.client_rx = Some(ClientRateLimit::new(rate));
    relay.key_cache_capacity = Some(4096);
    let mut config = ServerConfig::default();
    if !dev {
        let cert_path = env::var("NOCTURNE_BROKER_CERT")
            .context("Set NOCTURNE_BROKER_CERT to the public TLS certificate chain PEM")?;
        let key_path = env::var("NOCTURNE_BROKER_KEY")
            .context("Set NOCTURNE_BROKER_KEY to the TLS private key PEM")?;
        let certs = rustls_pemfile::certs(&mut BufReader::new(File::open(cert_path)?))
            .collect::<std::io::Result<Vec<_>>>()?;
        let key = rustls_pemfile::private_key(&mut BufReader::new(File::open(key_path)?))?
            .context("No TLS key in PEM")?;
        let tls = rustls::ServerConfig::builder_with_provider(std::sync::Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()?
        .with_no_client_auth()
        .with_single_cert(certs, key)?;
        relay.tls = Some(TlsConfig::new(
            setting("NOCTURNE_BROKER_HTTPS", "0.0.0.0:443").parse::<SocketAddr>()?,
            CertConfig::Manual { server_config: tls },
        ));
        // QUIC address discovery supports NAT traversal; expose this UDP port too.
        config.quic = Some(QuicConfig::new(
            setting("NOCTURNE_BROKER_QUIC", "0.0.0.0:7842").parse::<SocketAddr>()?,
        ));
    }
    config.relay = Some(relay);
    config.metrics_addr = Some(setting("NOCTURNE_BROKER_METRICS", "127.0.0.1:9090").parse()?);
    let server = Server::spawn(config).await?;
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! { result = tokio::signal::ctrl_c() => result?, _ = term.recv() => {} }
    }
    #[cfg(not(unix))]
    tokio::signal::ctrl_c().await?;
    server.shutdown().await?;
    Ok(())
}
