import XCTest
import AppKit
import Network
import CryptoKit
import Security
import NocturneKit
@testable import NocturneHostKit

final class BrowserProtocolTests: XCTestCase {
    func testMacAddressesRemainUnmodifiedAndOnlyWebDestinationsAreAccepted() throws {
        for address in ["http://localhost:3000/path?q=1", "http://127.0.0.1:8080/", "http://[::1]:8080/", "http://192.0.2.1/", "https://example.invalid/a#b"] {
            XCTAssertEqual(try BrowserProtocol.destination(address).absoluteString, address)
        }
        for address in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "nocturne://pair", "https://user:secret@example.invalid", "https://example.invalid:0", "https://example.invalid:65536", "https://", "http://local host/", "http://localhost/\nfoo"] {
            XCTAssertThrowsError(try BrowserProtocol.destination(address), address)
        }
    }
    func testBoundedBrowserFrameFitsAuthenticatedFraming() throws {
        var packet = Packet(.browserCommand)
        packet.sessionID = UUID().uuidString
        packet.browserFrame = .init(page: UUID().uuidString, url: "https://example.invalid", title: "Fixture", canGoBack: false,
            canGoForward: false, loading: false, jpeg: Data(repeating: 0x42, count: BrowserProtocol.maximumImageBytes))
        let data = try FrameCodec.encode(packet)
        XCTAssertLessThan(data.count, WorkspaceProtocol.maximumFrame)
        XCTAssertEqual(try JSONDecoder().decode(Packet.self, from: data.dropFirst(4)).browserFrame?.jpeg?.count, BrowserProtocol.maximumImageBytes)
    }
    func testAuthorizationRevokesQueuedCommandsAndDoesNotReopenAfterDisconnect() {
        let access = BrowserAuthorization()
        XCTAssertNil(access.token)
        access.update(enabled: true)
        let first = access.token; XCTAssertNotNil(first)
        access.update(enabled: false); XCTAssertNil(access.token)
        access.update(enabled: true); XCTAssertNotEqual(first, access.token)
        access.close(); access.update(enabled: true); XCTAssertNil(access.token)
    }
}

@MainActor
final class BrowserHostTests: XCTestCase {
    private func command(_ action: BrowserCommand.Action, id: String, value: String? = nil, page: String? = nil, x: Double? = nil, y: Double? = nil) -> Packet {
        var packet = Packet(.browserCommand); packet.sessionID = id; packet.browserCommand = .init(action, value: value, page: page, x: x, y: y); return packet
    }
    private func ready(_ host: RemoteBrowserHost, access: BrowserAuthorization, id: String, title: String, prefix: Bool = false) async throws -> BrowserFrame {
        var last: BrowserFrame?
        for _ in 0..<120 {
            let reply = try await host.handle(command(.frame, id: id), authorization: access)
            last = reply.browserFrame
            if let frame = reply.browserFrame, (prefix ? frame.title.hasPrefix(title) : frame.title == title), frame.jpeg != nil, !frame.loading { return frame }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("WebKit did not render fixture title: \(title); actual: \(last?.title ?? "nil"); url: \(last?.url ?? "nil"); notice: \(last?.notice ?? "nil")")
        throw NocturneError.timeout
    }
    private func open(_ host: RemoteBrowserHost, access: BrowserAuthorization, id: String) async throws {
        _ = NSApplication.shared
        _ = try await host.handle(command(.open, id: id), authorization: access)
    }
    func testMacRendererLoadsRelativeAbsoluteResourcesRedirectsCookiesAndWebSockets() async throws {
        let fixture = try BrowserFixture(); try await fixture.start(); defer { fixture.stop() }
        let access = BrowserAuthorization(); access.update(enabled: true)
        let host = RemoteBrowserHost(), id = UUID().uuidString
        defer { host.reset() }
        try await open(host, access: access, id: id)
        _ = try await host.handle(command(.navigate, id: id, value: fixture.url("/redirect")), authorization: access)
        let frame = try await ready(host, access: access, id: id, title: "ready:asset:socket-ok:browser=private")
        XCTAssertEqual(frame.url, fixture.url("/page"))
        let jpeg = try XCTUnwrap(frame.jpeg)
        XCTAssertNotNil(NSImage(data: jpeg)); XCTAssertLessThanOrEqual(jpeg.count, BrowserProtocol.maximumImageBytes)
        for path in ["/redirect", "/page", "/asset", "/absolute", "/socket"] { XCTAssertTrue(fixture.paths.contains(path), path) }
        XCTAssertTrue(fixture.peers.allSatisfy { $0.contains("127.0.0.1") || $0.contains("::1") })
        XCTAssertTrue(fixture.hosts.allSatisfy { $0 == "localhost:\(fixture.port)" })
        // An old frame must not click/type on a newly navigated origin.
        _ = try await host.handle(command(.navigate, id: id, value: fixture.url("/next")), authorization: access)
        do { _ = try await host.handle(command(.text, id: id, value: "stale", page: frame.page), authorization: access); XCTFail("Stale input accepted") } catch {}
        _ = try await ready(host, access: access, id: id, title: "next")
    }
    func testHTTPSRejectsUntrustedFixtureWithoutTrustOrHTTPFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-browser-tls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try TestDeviceIdentity()
        try identity.pem.write(to: root.appendingPathComponent("cert.pem"), atomically: true, encoding: .utf8)
        let key = try XCTUnwrap(SecKeyCopyExternalRepresentation(identity.key, nil)) as Data
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n" + key.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END RSA PRIVATE KEY-----\n"
        try pem.write(to: root.appendingPathComponent("key.pem"), atomically: true, encoding: .utf8)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import socket, ssl, sys
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[1], sys.argv[2])
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(10)
        print(listener.getsockname()[1], flush=True)
        try:
            connection, _ = listener.accept()
            with context.wrap_socket(connection, server_side=True) as stream:
                if stream.recv(4096): print('UNEXPECTED_HTTP_REQUEST', flush=True)
        except (ssl.SSLError, TimeoutError, ConnectionError):
            pass
        finally:
            listener.close()
        """, root.appendingPathComponent("cert.pem").path, root.appendingPathComponent("key.pem").path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var portBytes = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { portBytes.append(byte) }
        let port = try XCTUnwrap(String(data: portBytes, encoding: .utf8).flatMap(UInt16.init))
        let host = RemoteBrowserHost(), access = BrowserAuthorization(); access.update(enabled: true)
        let id = UUID().uuidString; defer { host.reset() }
        try await open(host, access: access, id: id)
        _ = try await host.handle(command(.navigate, id: id, value: "https://localhost:\(port)/"), authorization: access)
        var refused = false
        for _ in 0..<100 {
            let frame = try await host.handle(command(.frame, id: id), authorization: access).browserFrame
            if frame?.notice != nil { refused = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(refused, "Untrusted HTTPS must fail instead of accepting a certificate or trying HTTP")
        // The fixture only observes a rejected TLS handshake, never an HTTP request.
        if process.isRunning { process.terminate() }; process.waitUntilExit()
        let remainder = try output.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertFalse(String(decoding: remainder, as: UTF8.self).contains("UNEXPECTED_HTTP_REQUEST"))
    }
    func testNumericIPv4AndIPv6LoopbackRouteToMacFixtures() async throws {
        for (bind, address) in [("127.0.0.1", "127.0.0.1"), ("::1", "[::1]")] {
            let fixture = try BrowserFixture(bind: bind, host: address); try await fixture.start(); defer { fixture.stop() }
            let host = RemoteBrowserHost(), access = BrowserAuthorization(); access.update(enabled: true)
            let id = UUID().uuidString; defer { host.reset() }
            try await open(host, access: access, id: id)
            _ = try await host.handle(command(.navigate, id: id, value: fixture.url("/page")), authorization: access)
            let frame = try await ready(host, access: access, id: id, title: "ready:asset:socket-ok:", prefix: true)
            XCTAssertEqual(frame.url, fixture.url("/page"))
            XCTAssertTrue(fixture.hosts.allSatisfy { $0 == address + ":" + String(fixture.port) })
        }
    }
    func testSessionsDoNotShareCookiesAndAnotherConnectionCannotUseOrCloseThem() async throws {
        let fixture = try BrowserFixture(); try await fixture.start(); defer { fixture.stop() }
        let a = RemoteBrowserHost(), b = RemoteBrowserHost(), access = BrowserAuthorization(); access.update(enabled: true)
        let aid = UUID().uuidString, bid = UUID().uuidString
        defer { a.reset(); b.reset() }
        try await open(a, access: access, id: aid)
        _ = try await a.handle(command(.navigate, id: aid, value: fixture.url("/page")), authorization: access)
        _ = try await ready(a, access: access, id: aid, title: "ready:asset:socket-ok:browser=private")
        try await open(b, access: access, id: bid)
        for action in [BrowserCommand.Action.frame, .close, .navigate] {
            do { _ = try await b.handle(command(action, id: aid, value: fixture.url("/next")), authorization: access); XCTFail("Cross-session command accepted") } catch {}
        }
        _ = try await b.handle(command(.navigate, id: bid, value: fixture.url("/cookie")), authorization: access)
        _ = try await ready(b, access: access, id: bid, title: "cookie:")
        access.update(enabled: false)
        do { _ = try await a.handle(command(.frame, id: aid), authorization: access); XCTFail("Revoked request accepted") } catch {}
        access.update(enabled: true)
        do { _ = try await a.handle(command(.frame, id: aid), authorization: access); XCTFail("Old session survived revocation") } catch {}
    }
    func testNativeClicksTypingAndNavigationStayInsidePrivateView() async throws {
        let fixture = try BrowserFixture(); try await fixture.start(); defer { fixture.stop() }
        let host = RemoteBrowserHost(), access = BrowserAuthorization(); access.update(enabled: true)
        let id = UUID().uuidString; defer { host.reset() }
        try await open(host, access: access, id: id)
        _ = try await host.handle(command(.navigate, id: id, value: fixture.url("/input")), authorization: access)
        let initial = try await ready(host, access: access, id: id, title: "input")
        _ = try await host.handle(command(.click, id: id, page: initial.page, x: 0.1, y: 0.04), authorization: access)
        _ = try await host.handle(command(.text, id: id, value: "hello", page: initial.page), authorization: access)
        _ = try await ready(host, access: access, id: id, title: "typed:hello")
        // A normal link click uses WebKit navigation, no source/URL rewriting.
        _ = try await host.handle(command(.click, id: id, page: initial.page, x: 0.08, y: 0.13), authorization: access)
        _ = try await ready(host, access: access, id: id, title: "next")
    }
    func testClosingAndLeaseExpiryTearDownDocumentWebSockets() async throws {
        let fixture = try BrowserFixture(); try await fixture.start(); defer { fixture.stop() }
        let host = RemoteBrowserHost(leaseSeconds: 0.5), access = BrowserAuthorization(); access.update(enabled: true)
        let id = UUID().uuidString; defer { host.reset() }
        try await open(host, access: access, id: id)
        _ = try await host.handle(command(.navigate, id: id, value: fixture.url("/page")), authorization: access)
        _ = try await ready(host, access: access, id: id, title: "ready:asset:socket-ok:browser=private")
        // Stop polling, exactly as when a phone disappears without a graceful close.
        for _ in 0..<60 where fixture.closedSockets == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThan(fixture.closedSockets, 0, "Expired document must release its WebSocket without another command")
        do { _ = try await host.handle(command(.frame, id: id), authorization: access); XCTFail("Expired session remained usable") } catch {}
        let second = UUID().uuidString
        try await open(host, access: access, id: second)
        _ = try await host.handle(command(.navigate, id: second, value: fixture.url("/page")), authorization: access)
        _ = try await ready(host, access: access, id: second, title: "ready:asset:socket-ok:browser=private")
        _ = try await host.handle(command(.close, id: second), authorization: access)
        for _ in 0..<60 where fixture.closedSockets < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThanOrEqual(fixture.closedSockets, 2, "Explicit close must also release the document socket")
    }
    func testNonWebNavigationNeverStartsExternalHandlers() async throws {
        let host = RemoteBrowserHost(), access = BrowserAuthorization(); access.update(enabled: true)
        let id = UUID().uuidString; defer { host.reset() }
        try await open(host, access: access, id: id)
        for url in ["file:///etc/passwd", "javascript:location='https://example.invalid'", "tel:123", "nocturne://pair"] {
            do { _ = try await host.handle(command(.navigate, id: id, value: url), authorization: access); XCTFail("Non-web URL accepted") } catch {}
        }
        _ = try await host.handle(command(.close, id: id), authorization: access)
        do { _ = try await host.handle(command(.frame, id: id), authorization: access); XCTFail("Closed session survived") } catch {}
    }
}

/// Only ephemeral Mac-loopback listeners. Never reaches a LAN/private service or the Internet.
final class BrowserFixture: @unchecked Sendable {
    private let listener: NWListener
    private let addressHost: String
    private let queue = DispatchQueue(label: "nocturne.browser.fixture")
    private let lock = NSLock()
    private var requests: [(String, String, String)] = []
    private var connections: [NWConnection] = []
    private var startFinished = false
    private var closedSocketCount = 0
    var closedSockets: Int { lock.lock(); defer { lock.unlock() }; return closedSocketCount }
    var port: UInt16 { listener.port!.rawValue }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return requests.map { $0.0 } }
    var peers: [String] { lock.lock(); defer { lock.unlock() }; return requests.map { $0.1 } }
    var hosts: [String] { lock.lock(); defer { lock.unlock() }; return requests.map { $0.2 } }
    init(bind: String = "127.0.0.1", host: String = "localhost") throws {
        addressHost = host
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: .any)
        listener = try NWListener(using: parameters)
    }
    func url(_ path: String) -> String { "http://\(addressHost):\(port)" + path }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                guard !self.startFinished else { return }
                switch state {
                case .ready: self.startFinished = true; continuation.resume()
                case .failed(let error): self.startFinished = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection); connection.start(queue: self.queue); self.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections = [] } }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, ended, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            guard buffer.count <= 65_536 else { connection.cancel(); return }
            if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") { self.respond(request, connection: connection) }
            else if !ended, error == nil { self.receive(connection, buffer: buffer) }
        }
    }
    private func watchSocket(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, ended, error in
            guard let self else { return }
            if ended || error != nil || data?.first.map({ $0 & 0x0f == 8 }) == true {
                self.lock.lock(); self.closedSocketCount += 1; self.lock.unlock(); connection.cancel()
            } else { self.watchSocket(connection) }
        }
    }
    private func respond(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        func header(_ name: String) -> String { lines.first { $0.lowercased().hasPrefix(name.lowercased() + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) } ?? "" }
        lock.lock(); requests.append((path, "\(connection.endpoint)", header("Host"))); lock.unlock()
        if path == "/socket" {
            let key = header("Sec-WebSocket-Key") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            let accept = Data(Insecure.SHA1.hash(data: Data(key.utf8))).base64EncodedString()
            var reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
            let message = Data("socket-ok".utf8); reply.append(contentsOf: [0x81, UInt8(message.count)]); reply.append(message)
            connection.send(content: reply, completion: .contentProcessed { [weak self] _ in self?.watchSocket(connection) })
            return
        }
        var status = "200 OK", extra = "", type = "text/html", body = ""
        switch path {
        case "/redirect": status = "302 Found"; extra = "Location: /page\r\n"
        case "/page":
            extra = "Set-Cookie: browser=private; SameSite=Strict; Path=/\r\n"
            body = """
            <!doctype html><title>loading</title><body style="background:#def"><h1>Mac browser fixture</h1>
            <script src="\(url("/absolute"))"></script><script>
            fetch('/asset').then(r=>r.text()).then(asset=>{
              const socket=new WebSocket('ws://'+location.host+'/socket');
              socket.onmessage=e=>{document.title='ready:'+asset+':'+e.data+':'+document.cookie;};
            });</script>
            """
        case "/absolute": type = "application/javascript"; body = "document.body.dataset.absolute='yes';"
        case "/asset": type = "text/plain"; body = "asset"
        case "/cookie": body = "<title>cookie:\(header("Cookie"))</title>"
        case "/input": body = "<title>input</title><input style='position:absolute;top:10px;left:10px;width:250px;height:40px' oninput=\"document.title='typed:'+this.value\"><a style='position:absolute;top:80px;left:10px;width:200px;height:40px' href='/next'>Next page</a>"
        default: body = "<title>next</title><h1>Next page</h1>"
        }
        let bytes = Data(body.utf8)
        let response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(bytes.count)\r\n\(extra)Connection: close\r\n\r\n".utf8) + bytes
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
