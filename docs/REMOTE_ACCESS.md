# Online broker and peer-to-peer connections

Nocturne includes a self-hosted Rust broker and a Rust transport embedded in the
Mac and iOS apps. Enable **Nocturne Server → Settings → Remote access**, enter your
broker's HTTPS origin, start the server, and scan a new QR code. Existing LAN-only
pairings still work; scanning again adds the broker and public endpoint identity
to the pairing saved in Keychain. There is no hosted default or external account.

The client first tries Bonjour and its saved LAN address. If those connections
fail, it connects to the Mac's cryptographic endpoint through the broker. The
transport attempts direct UDP connectivity, including NAT hole punching and
router port mapping. It can establish an encrypted relay connection immediately
and migrate it to peer to peer when a direct path becomes available. Restrictive
NATs and networks that block UDP continue using the relay. The workspace card
shows **Local network**, **Peer to peer**, or **Encrypted relay**. A direct remote
connection can continue carrying traffic if the broker subsequently goes offline;
new remote connections may still need the broker.

The transport uses [iroh's connectivity architecture](https://docs.rs/iroh/1.3.0/iroh/).
Its minimal configuration uses only the configured broker, with no public
discovery/DHT service or third-party relay fallback. The broker assists rendezvous
and forwards encrypted QUIC packets; it receives neither workspace keys nor the
decrypted video, files, terminal, or microphone data. It can see endpoint public
identities, connecting IPs, and traffic volume.

## Run the broker

Use a public Linux machine with a DNS name and a trusted TLS certificate. Open
TCP 443 (relay), UDP 7842 (QUIC address discovery for NAT traversal), and TCP 80
(connectivity probes). Obtain/renew the certificate using your existing ACME
tooling; the broker reads PEM files at startup. Restart it after renewal.

From the repository root:

```sh
mkdir -p remote/certs
# Install fullchain.pem and privkey.pem in remote/certs.
# Allow container UID/GID 10001 to read them; keep the private key restricted.
docker compose -f remote/compose.yaml up -d --build
```

The bundled image terminates TLS itself and runs without root. Its metrics
listener stays on container loopback port 9090. `/ping` provides liveness and
Prometheus metrics are served on `/metrics`. A reverse proxy is not required.
If adding one, it must support the relay's HTTP connection upgrade and preserve
long-lived upgraded connections; UDP 7842 must still reach the broker.

Or compile and run the standalone service (Rust 1.91+):

```sh
cargo build --manifest-path remote/Cargo.toml --locked --release -p nocturne-broker
NOCTURNE_BROKER_CERT=/etc/nocturne/fullchain.pem \
NOCTURNE_BROKER_KEY=/etc/nocturne/privkey.pem \
  remote/target/release/nocturne-broker
```

Environment settings are `NOCTURNE_BROKER_HTTP` (default `0.0.0.0:8080`),
`NOCTURNE_BROKER_HTTPS` (`0.0.0.0:443`), `NOCTURNE_BROKER_QUIC`
(`0.0.0.0:7842`), `NOCTURNE_BROKER_METRICS` (`127.0.0.1:9090`), and
`NOCTURNE_BROKER_BYTES_PER_SECOND` (12,500,000 bytes/s per relay connection).
The standalone process needs permission to bind privileged ports, or port
forwarding to unprivileged listeners. SIGTERM and Ctrl-C shut it down gracefully.
It serves any cryptographically identified iroh endpoint, not an account-based
allowlist. Operate it with capacity/bandwidth monitoring; workspace device access
is authorized separately by the Mac.

For local development, `remote/target/release/nocturne-broker --dev` serves plain
HTTP on `127.0.0.1:3340`. Development mode refuses a non-loopback bind. The apps
accept HTTP only on loopback. A phone needs the real HTTPS broker address; its
loopback address is the phone itself.

## Transport and authentication

The QR's broker URL and endpoint public key locate the Mac; they do not grant
workspace access. Workspace traffic still uses the original end-to-end TLS-PSK,
single-use enrollment token, device certificate proof, and TLS exporter binding.
The host endpoint has its own random private key in the Mac's Keychain. It is
never derived from the shared workspace key or included in a QR. A removed device
therefore cannot derive the Mac's broker identity. Reset pairing rotates both keys.

The tunnel exposes only workspace TCP 48555 until that exact connection passes
workspace authentication. The host associates the proxy's loopback source port
with its QUIC peer and then authorizes that peer for the same device. Streaming
uses TCP 47984, 47989, 48010 and UDP 47998, 47999, 48000, 48002, 48010. The
Sunshine administration port 47990 and arbitrary destinations are never forwarded.
Each TCP socket has an independent QUIC stream. UDP packets use QUIC datagrams
with bounded, expiring fragmentation; lost video packets do not block file or
terminal streams. Microphone TLS reuses the authenticated tunnel on a separate
workspace socket.

There are at most eight host tunnels, 48 incoming streams per tunnel and 16 UDP
flows. Unauthenticated tunnels expire after 30 seconds. Removing a device closes
its tunnel as well as its workspace/video authorization. Stop server, reset
pairing, and client backgrounding release their transport resources. All local
forwarders bind only to loopback. The client preserves the Mac's actual LAN
address and public endpoint identity rather than saving an ephemeral proxy port.
Only one remote streaming host is active per iOS app, matching the current
single saved workspace/stream model.

## Build and verification

Install Rust with [rustup](https://rustup.rs). `scripts/bootstrap.sh` now builds
the native transport for Apple Silicon macOS, iOS devices, and arm64/x86_64 iOS
simulators into the ignored `Vendor/NocturneRemote.xcframework`. A Mac-only shared
test build can use `scripts/build-remote.sh mac`.

The lockfile pins iroh 1.3.0 and libc 0.2.186: libc 0.2.191 restricts
`in6_ifreq` to macOS, while netdev still references it when compiling for
iOS. Other dependencies, including rustls, remain independently locked. No
downloaded dependency source is modified. Review this pin when upstream fixes
iOS compilation.

```sh
cargo test --manifest-path remote/Cargo.toml --locked --workspace
cargo build --manifest-path remote/Cargo.toml --locked -p nocturne-broker
NOCTURNE_BROKER_EXECUTABLE="$PWD/remote/target/debug/nocturne-broker" swift test
```

Rust integration tests run a real local broker and exercise forced relay,
direct-path migration, traffic after broker shutdown, TCP transfer, UDP
fragmentation/round-trip, pre-authentication port denial, and per-device
revocation. Swift integration tests exercise the native library, actual workspace
TLS, single-use QR enrollment, terminal restoration, the separate media socket,
and removal. These local tests do not substitute for testing two physical devices
on different internet connections, cellular handovers, or game-stream quality.

Verified locally on 2026-10-19: five Rust tests, 40 shared/host Swift tests
(four existing display/live-engine tests skipped), and 31 iOS simulator tests
passed. The Mac app and universal iOS simulator app built successfully; native
Rust libraries also built for physical iOS devices. The Linux Docker image
built and passed a non-root HTTPS `/ping` check with a test certificate and a
clean SIGTERM shutdown. No public broker has been deployed or two-network
physical-device streaming test performed.
