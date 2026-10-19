//! Nocturne's local TCP/UDP adapter over authenticated, peer-to-peer QUIC.
//! Only workspace TLS is reachable until Swift authorizes the TLS device proof.
mod datagram;
mod ffi;

use anyhow::{Context, Result, bail, ensure};
use iroh::{
    Endpoint, EndpointAddr, RelayUrl, SecretKey,
    endpoint::{Connection, RelayMode, presets},
};
use std::{
    collections::HashMap,
    net::{Ipv4Addr, SocketAddr},
    sync::{Arc, Mutex, Weak},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream, UdpSocket},
    sync::Semaphore,
    task::{JoinHandle, JoinSet},
    time::timeout,
};

const ALPN: &[u8] = b"nocturne/tunnel/1";
const WORKSPACE: u16 = 48555;
const TCP_PORTS: &[u16] = &[47984, 47989, 48010];
const UDP_PORTS: &[u16] = &[47998, 47999, 48000, 48002, 48010];
const DEADLINE: Duration = Duration::from_secs(20);
type Sources = Arc<Mutex<HashMap<u16, Weak<Peer>>>>;
type UdpTargets = Arc<Mutex<HashMap<u32, Arc<UdpSocket>>>>;
type ClientTarget = (Arc<UdpSocket>, Arc<Mutex<Option<SocketAddr>>>);

#[derive(Default)]
struct HostState {
    sources: Sources,
    peers: Mutex<HashMap<usize, Arc<Peer>>>,
}
struct Peer {
    connection: Connection,
    device: Mutex<Option<String>>,
}
impl Peer {
    fn authorized(&self) -> bool {
        self.device.lock().unwrap().is_some()
    }
}

pub struct Tunnel {
    endpoint: Endpoint,
    tasks: Vec<JoinHandle<()>>,
    host: Arc<HostState>,
    connection: Option<Connection>,
    pub workspace_port: u16,
}
impl Drop for Tunnel {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
        for peer in self.host.peers.lock().unwrap().values() {
            peer.connection.close(0u32.into(), b"server stopped");
        }
        if let Some(connection) = &self.connection {
            connection.close(0u32.into(), b"client stopped");
        }
        let endpoint = self.endpoint.clone();
        ffi::runtime().spawn(async move {
            endpoint.close().await;
        });
    }
}
impl Tunnel {
    pub fn id(&self) -> String {
        self.endpoint.id().to_string()
    }
    /// 0 = a normal LAN socket; 1 = remote device authorized; -1 = identity conflict.
    pub fn authorize(&self, source_port: u16, device: &str) -> i32 {
        let Some(peer) = self
            .host
            .sources
            .lock()
            .unwrap()
            .get(&source_port)
            .and_then(Weak::upgrade)
        else {
            return 0;
        };
        let mut current = peer.device.lock().unwrap();
        if current.as_ref().is_some_and(|current| current != device) {
            return -1;
        }
        *current = Some(device.into());
        1
    }
    pub fn revoke(&self, device: &str) {
        for peer in self.host.peers.lock().unwrap().values() {
            if peer.device.lock().unwrap().as_deref() == Some(device) {
                peer.connection.close(1u32.into(), b"device removed");
            }
        }
    }
    pub fn route(&self) -> i32 {
        let Some(connection) = &self.connection else {
            return 0;
        };
        if connection.close_reason().is_some() {
            return 0;
        }
        if connection
            .paths()
            .iter()
            .any(|p| p.is_ip() && p.is_selected())
        {
            1
        } else {
            2
        }
    }
}

fn relay_url(value: &str) -> Result<RelayUrl> {
    let url: RelayUrl = value.parse()?;
    let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    ensure!(
        url.scheme() == "https" || (url.scheme() == "http" && local),
        "Use an HTTPS broker URL (HTTP is allowed only on loopback)"
    );
    ensure!(
        url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.path() == "/",
        "The broker URL must be an origin without credentials, path, or query"
    );
    Ok(url)
}

async fn endpoint(relay: RelayUrl, key: Option<[u8; 32]>, relay_only: bool) -> Result<Endpoint> {
    // Minimal avoids public DNS/DHT discovery or fallback to anyone else's relay.
    let mut builder = Endpoint::builder(presets::Minimal)
        .alpns(vec![ALPN.to_vec()])
        .relay_mode(RelayMode::custom([relay]));
    if let Some(key) = key {
        builder = builder.secret_key(SecretKey::from_bytes(&key));
    }
    if relay_only {
        builder = builder.clear_ip_transports();
    }
    Ok(builder.bind().await?)
}

pub async fn start_host(url: &str, key: [u8; 32], workspace_port: u16) -> Result<Tunnel> {
    start_host_mode(url, key, workspace_port, false).await
}
async fn start_host_mode(
    url: &str,
    key: [u8; 32],
    workspace_port: u16,
    relay_only: bool,
) -> Result<Tunnel> {
    ensure!(workspace_port > 0, "Invalid workspace port");
    let endpoint = endpoint(relay_url(url)?, Some(key), relay_only).await?;
    let host = Arc::new(HostState::default());
    let ep = endpoint.clone();
    let state = host.clone();
    let task = tokio::spawn(async move {
        let slots = Arc::new(Semaphore::new(8));
        let mut peers = JoinSet::new();
        loop {
            tokio::select! {
                incoming = ep.accept() => {
                    let Some(incoming) = incoming else { break; };
                    let Ok(slot) = slots.clone().try_acquire_owned() else { incoming.refuse(); continue; };
                    let state = state.clone();
                    peers.spawn(async move {
                        let _slot = slot;
                        if let Ok(Ok(connection)) = timeout(DEADLINE, incoming).await {
                            let _ = serve_peer(connection, state, workspace_port).await;
                        }
                    });
                }
                _ = peers.join_next(), if !peers.is_empty() => {}
            }
        }
    });
    // A broker outage does not prevent LAN use. The endpoint reconnects in the background.
    Ok(Tunnel {
        endpoint,
        tasks: vec![task],
        host,
        connection: None,
        workspace_port,
    })
}

struct PeerGuard {
    state: Arc<HostState>,
    id: usize,
    connection: Connection,
}
impl Drop for PeerGuard {
    fn drop(&mut self) {
        self.connection.close(0u32.into(), b"tunnel closed");
        self.state.peers.lock().unwrap().remove(&self.id);
    }
}
struct SourceGuard {
    sources: Sources,
    port: u16,
}
impl Drop for SourceGuard {
    fn drop(&mut self) {
        self.sources.lock().unwrap().remove(&self.port);
    }
}
struct FlowGuard {
    targets: UdpTargets,
    id: u32,
}
impl Drop for FlowGuard {
    fn drop(&mut self) {
        self.targets.lock().unwrap().remove(&self.id);
    }
}

async fn serve_peer(
    connection: Connection,
    state: Arc<HostState>,
    workspace_port: u16,
) -> Result<()> {
    let peer = Arc::new(Peer {
        connection: connection.clone(),
        device: Mutex::new(None),
    });
    let id = connection.stable_id();
    state.peers.lock().unwrap().insert(id, peer.clone());
    let _guard = PeerGuard {
        state: state.clone(),
        id,
        connection: connection.clone(),
    };
    let mut tasks = JoinSet::new();
    let targets = UdpTargets::default();
    let incoming_targets = targets.clone();
    let incoming_connection = connection.clone();
    tasks.spawn(async move {
        let mut assembler = datagram::Assembler::default();
        while let Ok(data) = incoming_connection.read_datagram().await {
            if let Some((flow, packet)) = assembler.receive(data) {
                let socket = incoming_targets.lock().unwrap().get(&flow).cloned();
                if let Some(socket) = socket {
                    let _ = socket.send(&packet).await;
                }
            }
        }
    });
    let slots = Arc::new(Semaphore::new(48));
    let mut expiry = tokio::time::interval(Duration::from_secs(30));
    expiry.tick().await;
    loop {
        tokio::select! {
            stream = connection.accept_bi() => {
                let (send, recv) = stream?;
                let Ok(slot) = slots.clone().try_acquire_owned() else { drop(send); drop(recv); continue; };
                let peer = peer.clone(); let state = state.clone(); let targets = targets.clone();
                tasks.spawn(async move { let _slot = slot; let _ = serve_stream(peer, state, workspace_port, targets, send, recv).await; });
            }
            _ = expiry.tick() => { ensure!(peer.authorized(), "Workspace authentication timed out"); }
            _ = tasks.join_next(), if !tasks.is_empty() => {}
        }
    }
}

async fn serve_stream(
    peer: Arc<Peer>,
    state: Arc<HostState>,
    workspace_port: u16,
    targets: UdpTargets,
    mut send: iroh::endpoint::SendStream,
    mut recv: iroh::endpoint::RecvStream,
) -> Result<()> {
    let mut header = [0u8; 7];
    timeout(DEADLINE, recv.read_exact(&mut header)).await??;
    let kind = header[0];
    let port = u16::from_be_bytes(header[1..3].try_into()?);
    let flow = u32::from_be_bytes(header[3..7].try_into()?);
    let allowed = if kind == 0 {
        port == WORKSPACE || (peer.authorized() && TCP_PORTS.contains(&port))
    } else {
        kind == 1 && peer.authorized() && UDP_PORTS.contains(&port)
    };
    if !allowed {
        send.write_all(&[0]).await?;
        bail!("Port is not authorized");
    }
    if kind == 0 {
        let target = if port == WORKSPACE {
            workspace_port
        } else {
            port
        };
        let tcp = timeout(DEADLINE, TcpStream::connect((Ipv4Addr::LOCALHOST, target))).await??;
        tcp.set_nodelay(true)?;
        let source_port = tcp.local_addr()?.port();
        let _source = if port == WORKSPACE {
            state
                .sources
                .lock()
                .unwrap()
                .insert(source_port, Arc::downgrade(&peer));
            Some(SourceGuard {
                sources: state.sources.clone(),
                port: source_port,
            })
        } else {
            None
        };
        send.write_all(&[1]).await?;
        copy_tcp(tcp, send, recv).await?;
    } else {
        let socket = Arc::new(UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await?);
        socket.connect((Ipv4Addr::LOCALHOST, port)).await?;
        {
            let mut flows = targets.lock().unwrap();
            ensure!(
                flows.len() < 16 && !flows.contains_key(&flow),
                "Too many UDP flows or duplicate flow"
            );
            flows.insert(flow, socket.clone());
        }
        let _flow = FlowGuard { targets, id: flow };
        send.write_all(&[1]).await?;
        let mut data = vec![0u8; 65_507];
        let mut sequence: u32 = 0;
        loop {
            tokio::select! {
                result = socket.recv(&mut data) => {
                    let size = match result {
                        Ok(size) => size,
                        // Audio pings start before RTSP opens the media listener.
                        // An ICMP port-unreachable response must not destroy this
                        // flow: later pings (also after an engine restart) reuse it.
                        Err(error) if matches!(error.kind(),
                            std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::ConnectionReset
                        ) => continue,
                        Err(error) => return Err(error.into()),
                    };
                    send_packet(&peer.connection, flow, sequence, &data[..size]);
                    sequence = sequence.wrapping_add(1);
                }
                _ = recv.read_u8() => break,
                _ = peer.connection.closed() => break,
            }
        }
    }
    Ok(())
}

fn send_packet(connection: &Connection, flow: u32, sequence: u32, data: &[u8]) {
    let mtu = connection.max_datagram_size().unwrap_or(0).min(1110);
    for part in datagram::fragments(flow, sequence, data, mtu) {
        let _ = connection.send_datagram(part);
    }
}

async fn copy_tcp(
    tcp: TcpStream,
    mut send: iroh::endpoint::SendStream,
    mut recv: iroh::endpoint::RecvStream,
) -> Result<()> {
    let (mut read, mut write) = tcp.into_split();
    tokio::try_join!(
        async {
            tokio::io::copy(&mut read, &mut send).await?;
            send.finish()?;
            Ok::<_, anyhow::Error>(())
        },
        async {
            tokio::io::copy(&mut recv, &mut write).await?;
            write.shutdown().await?;
            Ok::<_, anyhow::Error>(())
        }
    )?;
    Ok(())
}

async fn open(
    connection: &Connection,
    kind: u8,
    port: u16,
    flow: u32,
) -> Result<(iroh::endpoint::SendStream, iroh::endpoint::RecvStream)> {
    timeout(DEADLINE, async {
        let (mut send, mut recv) = connection.open_bi().await?;
        let mut header = vec![kind];
        header.extend_from_slice(&port.to_be_bytes());
        header.extend_from_slice(&flow.to_be_bytes());
        send.write_all(&header).await?;
        let mut reply = [0];
        recv.read_exact(&mut reply).await?;
        ensure!(reply == [1], "Remote port is not authorized");
        Ok((send, recv))
    })
    .await?
}

pub async fn start_client(url: &str, id: &str, streaming: bool) -> Result<Tunnel> {
    start_client_mode(url, id, false, streaming).await
}
async fn start_client_mode(
    url: &str,
    id: &str,
    relay_only: bool,
    streaming: bool,
) -> Result<Tunnel> {
    let relay = relay_url(url)?;
    let addr = EndpointAddr::new(id.parse()?).with_relay_url(relay.clone());
    let endpoint = endpoint(relay, None, relay_only).await?;
    let mut tunnel = Tunnel {
        endpoint,
        tasks: vec![],
        host: Arc::default(),
        connection: None,
        workspace_port: 0,
    };
    let connection = timeout(DEADLINE, tunnel.endpoint.connect(addr, ALPN))
        .await
        .context("The online Mac did not respond")??;
    tunnel.connection = Some(connection.clone());
    let mut tcp = vec![(
        TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?,
        WORKSPACE,
    )];
    tunnel.workspace_port = tcp[0].0.local_addr()?.port();
    let mut udp = HashMap::<u32, ClientTarget>::new();
    if streaming {
        for &port in TCP_PORTS {
            tcp.push((
                TcpListener::bind((Ipv4Addr::LOCALHOST, port))
                    .await
                    .context("A streaming proxy port is already in use")?,
                port,
            ));
        }
        for &port in UDP_PORTS {
            udp.insert(
                u32::from(port),
                (
                    Arc::new(UdpSocket::bind((Ipv4Addr::LOCALHOST, port)).await?),
                    Arc::default(),
                ),
            );
        }
    }
    // Bind everything before spawning. A partially bound tunnel never survives an error.
    for (listener, port) in tcp {
        let connection = connection.clone();
        tunnel.tasks.push(tokio::spawn(async move {
            let slots = Arc::new(Semaphore::new(32));
            let mut tasks = JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let Ok((socket, _)) = accepted else { break; };
                        let Ok(slot) = slots.clone().try_acquire_owned() else { continue; };
                        let connection = connection.clone();
                        tasks.spawn(async move {
                            let _slot = slot;
                            let _ = socket.set_nodelay(true);
                            if let Ok((send, recv)) = open(&connection, 0, port, 0).await { let _ = copy_tcp(socket, send, recv).await; }
                        });
                    }
                    _ = tasks.join_next(), if !tasks.is_empty() => {}
                    _ = connection.closed() => break,
                }
            }
        }));
    }
    for (&flow, (socket, source)) in &udp {
        let socket = socket.clone();
        let source = source.clone();
        let connection = connection.clone();
        tunnel.tasks.push(tokio::spawn(async move {
            let mut data = vec![0u8; 65_507];
            let mut sequence: u32 = 0;
            let mut control = None;
            loop {
                tokio::select! {
                    result = socket.recv_from(&mut data) => {
                        let Ok((size, address)) = result else { break; };
                        if control.is_none() {
                            match open(&connection, 1, flow as u16, flow).await {
                                Ok(stream) => control = Some(stream),
                                Err(_) => continue,
                            }
                        }
                        *source.lock().unwrap() = Some(address);
                        send_packet(&connection, flow, sequence, &data[..size]);
                        sequence = sequence.wrapping_add(1);
                    }
                    _ = connection.closed() => break,
                }
            }
        }));
    }
    if !udp.is_empty() {
        tunnel.tasks.push(tokio::spawn(async move {
            let mut assembler = datagram::Assembler::default();
            while let Ok(packet) = connection.read_datagram().await {
                if let Some((flow, data)) = assembler.receive(packet)
                    && let Some((socket, source)) = udp.get(&flow)
                {
                    let address = *source.lock().unwrap();
                    if let Some(address) = address {
                        let _ = socket.send_to(&data, address).await;
                    }
                }
            }
        }));
    }
    Ok(tunnel)
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh_relay::server::{RelayConfig, Server, ServerConfig};

    async fn broker() -> Result<(Server, String)> {
        let mut config = ServerConfig::default();
        config.relay = Some(RelayConfig::new((Ipv4Addr::LOCALHOST, 0)));
        let server = Server::spawn(config).await?;
        let url = format!("http://{}", server.http_addr().unwrap());
        Ok((server, url))
    }
    async fn exchange(
        client: &Tunnel,
        target: &TcpListener,
        host: &Tunnel,
        device: &str,
    ) -> Result<()> {
        let mut local = TcpStream::connect((Ipv4Addr::LOCALHOST, client.workspace_port)).await?;
        let (mut remote, source) = timeout(DEADLINE, target.accept()).await??;
        let payload = vec![17; 196_608];
        local.write_all(&payload).await?;
        let mut got = vec![0; payload.len()];
        timeout(DEADLINE, remote.read_exact(&mut got)).await??;
        assert_eq!(got, payload);
        assert_eq!(host.authorize(source.port(), device), 1);
        assert_eq!(host.authorize(source.port(), "other-device"), -1);
        remote.write_all(b"authenticated").await?;
        let mut response = [0; 13];
        timeout(DEADLINE, local.read_exact(&mut response)).await??;
        assert_eq!(&response, b"authenticated");
        Ok(())
    }
    #[tokio::test]
    async fn relay_only_tcp_authorization_udp_and_device_revocation() -> Result<()> {
        let (broker, url) = broker().await?;
        let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let host = start_host_mode(&url, [7; 32], target.local_addr()?.port(), true).await?;
        timeout(DEADLINE, host.endpoint.online()).await?;
        let first = start_client_mode(&url, &host.id(), true, false).await?;
        let connection = first.connection.as_ref().unwrap();
        assert_eq!(first.route(), 2);
        assert!(open(connection, 0, 47989, 0).await.is_err());
        assert!(open(connection, 1, 47998, 1).await.is_err());
        assert!(open(connection, 0, 47990, 0).await.is_err()); // Never expose admin.
        assert!(open(connection, 0, 22, 0).await.is_err());
        exchange(&first, &target, &host, "first").await?;
        let second = start_client_mode(&url, &host.id(), true, false).await?;
        exchange(&second, &target, &host, "second").await?;

        // Use an available streaming UDP port without disturbing a running Mac app.
        let mut echo = None;
        for &port in UDP_PORTS {
            if let Ok(socket) = UdpSocket::bind((Ipv4Addr::LOCALHOST, port)).await {
                echo = Some((port, socket));
                break;
            }
        }
        let (port, echo) = echo.context("All streaming UDP ports are occupied")?;
        let (_send, _recv) = open(connection, 1, port, 4).await?;
        let payload = vec![32; 4000];
        send_packet(connection, 4, 1, &payload);
        let mut buffer = vec![0u8; 8192];
        let (size, source) = timeout(DEADLINE, echo.recv_from(&mut buffer)).await??;
        assert_eq!(&buffer[..size], &payload);
        echo.send_to(&payload, source).await?;
        let mut assembler = datagram::Assembler::default();
        let returned = timeout(DEADLINE, async {
            loop {
                if let Some(packet) = assembler.receive(connection.read_datagram().await?) {
                    break Ok::<_, anyhow::Error>(packet);
                }
            }
        })
        .await??;
        assert_eq!(returned, (4, payload));
        assert!(open(connection, 1, port, 4).await.is_err()); // No flow replacement.
        assert!(open(connection, 1, 47990, 5).await.is_err());
        host.revoke("first");
        timeout(Duration::from_secs(3), connection.closed()).await?;
        assert_eq!(first.route(), 0);
        exchange(&second, &target, &host, "second").await?;
        drop(first);
        drop(second);
        drop(host);
        broker.shutdown().await?;
        Ok(())
    }
    #[tokio::test]
    async fn media_udp_survives_early_ping_and_listener_restart() -> Result<()> {
        for relay_only in [true, false] {
            media_udp_startup_and_restart(relay_only).await?;
        }
        Ok(())
    }
    async fn media_udp_startup_and_restart(relay_only: bool) -> Result<()> {
        let (broker, url) = broker().await?;
        let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let host = start_host_mode(&url, [9; 32], target.local_addr()?.port(), relay_only).await?;
        timeout(DEADLINE, host.endpoint.online()).await?;
        let client = start_client_mode(&url, &host.id(), relay_only, false).await?;
        exchange(&client, &target, &host, "device").await?;
        let connection = client.connection.as_ref().unwrap();

        // Moonlight starts audio pings before RTSP starts Sunshine's UDP listener.
        // Reserve an available media port, then leave it closed for the first ping.
        let mut reservation = None;
        for &port in UDP_PORTS.iter().rev() {
            if let Ok(socket) = UdpSocket::bind((Ipv4Addr::LOCALHOST, port)).await {
                reservation = Some(socket);
                break;
            }
        }
        let reservation = reservation.context("All streaming UDP ports are occupied")?;
        let address = reservation.local_addr()?;
        drop(reservation);
        let (_send, _recv) = open(connection, 1, address.port(), 6).await?;
        send_packet(connection, 6, 0, b"early audio ping");
        tokio::time::sleep(Duration::from_millis(200)).await;

        let mut media = UdpSocket::bind(address).await?;
        let mut assembler = datagram::Assembler::default();
        let mut buffer = [0; 2048];
        for sequence in 1..=14 {
            if sequence == 2 {
                // Display preparation can restart the engine with the workspace
                // (and these authenticated QUIC flows) still connected.
                drop(media);
                send_packet(connection, 6, sequence, b"ping during restart");
                tokio::time::sleep(Duration::from_millis(200)).await;
                media = UdpSocket::bind(address).await?;
            } else if sequence > 2 {
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            let payload = vec![sequence as u8; 1024];
            send_packet(connection, 6, sequence, &payload);
            let (size, source) = timeout(Duration::from_secs(1), media.recv_from(&mut buffer))
                .await
                .context("Media pings stopped after a closed-port response")??;
            assert_eq!(&buffer[..size], &payload);
            media.send_to(&payload, source).await?;
            let returned = timeout(Duration::from_secs(1), async {
                loop {
                    if let Some(packet) = assembler.receive(connection.read_datagram().await?) {
                        break Ok::<_, anyhow::Error>(packet);
                    }
                }
            })
            .await??;
            assert_eq!(returned, (6, payload));
        }
        if relay_only {
            assert_eq!(client.route(), 2);
        } else {
            assert_eq!(client.route(), 1);
        }
        drop(client);
        drop(host);
        broker.shutdown().await?;
        Ok(())
    }
    #[tokio::test]
    async fn upgrades_to_peer_to_peer_and_survives_broker_shutdown() -> Result<()> {
        let (broker, url) = broker().await?;
        let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let host = start_host_mode(&url, [8; 32], target.local_addr()?.port(), false).await?;
        timeout(DEADLINE, host.endpoint.online()).await?;
        let client = start_client_mode(&url, &host.id(), false, false).await?;
        exchange(&client, &target, &host, "device").await?;
        timeout(DEADLINE, async {
            while client.route() != 1 {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await?;
        broker.shutdown().await?;
        exchange(&client, &target, &host, "device").await?;
        drop(client);
        drop(host);
        Ok(())
    }
    #[test]
    fn broker_url_rejects_cleartext_remote_and_credential_leaks() {
        for url in [
            "http://broker.example.com",
            "https://user:secret@example.com",
            "https://example.com/path",
            "https://example.com/?token=secret",
            "https://example.com/#secret",
            "file:///tmp/relay",
        ] {
            assert!(relay_url(url).is_err(), "{url}");
        }
        assert!(relay_url("https://broker.example.com").is_ok());
        assert!(relay_url("http://127.0.0.1:3340").is_ok());
    }
}
