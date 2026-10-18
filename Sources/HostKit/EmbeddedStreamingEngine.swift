import Foundation
import CryptoKit
import Security
import NocturneKit
import Darwin

public struct StreamPairingRequest: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let address: String
}

public struct StreamDevice: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let fingerprint: String
    public let enabled: Bool
}

/// The directly bundled Sunshine server executable belongs to Nocturne: private configuration, native administration,
/// and one lifecycle with the workspace listener. No separately installed application is used.
@MainActor
public final class EmbeddedStreamingEngine {
    public var onUnexpectedExit: ((String) -> Void)?
    public let directory: URL
    public var isRunning: Bool { process?.isRunning == true }
    public var logURL: URL { directory.appendingPathComponent("engine.log") }
    private var process: Process?
    private var api: EngineAPI?
    private var generation = UUID()
    private var logHandle: FileHandle?
    private struct Launch {
        let executable: URL
        let name: String
        let display: String
    }
    private var launch: Launch?
    public init(directory: URL) { self.directory = directory }

    public func start(executable: URL, name: String, display: String = "") async throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NocturneError.remote("The bundled streaming engine is missing. Rebuild Nocturne Server with scripts/bootstrap.sh.")
        }
        let epoch = UUID(); generation = epoch
        let password = try SecureStore.randomKey().base64EncodedString()
        try prepare(name: name, display: display, password: password)
        let output = directory.appendingPathComponent("console.log")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output); try handle.truncate(atOffset: 0); logHandle = handle
        let child = Process(); child.executableURL = executable
        child.arguments = [directory.appendingPathComponent("engine.conf").path]
        child.currentDirectoryURL = directory
        child.standardInput = FileHandle.nullDevice; child.standardOutput = handle; child.standardError = handle
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                self.onUnexpectedExit?("The streaming engine stopped (code \(child.terminationStatus)). Review the server log, then start again.")
            }
        }
        process = child
        do {
            try child.run()
            // A successful authenticated API response is the readiness signal, not merely a PID.
            let readinessDeadline = Date().addingTimeInterval(25)
            while Date() < readinessDeadline {
                try Task.checkCancellation()
                guard generation == epoch else { throw CancellationError() }
                guard child.isRunning else { throw NocturneError.remote("The streaming engine could not start. Check screen permissions and the server log.") }
                if api == nil, let certificate = try? Self.certificateDER(at: directory.appendingPathComponent("cert.pem")) {
                    api = EngineAPI(certificate: certificate, password: password)
                }
                if let api, (try? await api.request("/api/pin")) != nil {
                    guard generation == epoch, child.isRunning else { throw CancellationError() }
                    launch = Launch(executable: executable, name: name, display: display)
                    return
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw NocturneError.remote("The streaming engine did not become ready. Check screen permissions and whether another server is using its ports.")
        } catch {
            if generation == epoch { stop() }
            throw error
        }
    }

    /// Sunshine reads output_name at process startup. A replacement framebuffer
    /// must be selected explicitly; updating its config alone does not switch a
    /// running encoder. Keep the workspace listener, PTYs and paired keys intact.
    public func selectDisplay(_ display: UInt32) async throws {
        guard display != 0, isRunning, let launch else { throw NocturneError.disconnected }
        let target = String(display)
        guard launch.display != target else { return }
        stop()
        try await start(executable: launch.executable, name: launch.name, display: target)
    }

    public func stop() {
        generation = UUID(); api?.invalidate(); api = nil; launch = nil
        let child = process; process = nil; child?.terminationHandler = nil
        if let child, child.isRunning {
            child.terminate()
            // Reap our own child before completing Stop or application termination.
            let deadline = Date().addingTimeInterval(2)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        try? logHandle?.close(); logHandle = nil
    }

    public func pendingPairings() async throws -> [StreamPairingRequest] {
        guard let api else { throw NocturneError.disconnected }
        let response = try await api.request("/api/pin")
        return (response["pairings"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let address = $0["address"] as? String else { return nil }
            return StreamPairingRequest(id: id, name: $0["name"] as? String ?? "Device", address: address)
        }
    }

    public func approve(_ request: StreamPairingRequest, pin: String, name: String) async throws {
        guard pin.utf8.count == 4, pin.utf8.allSatisfy({ (48...57).contains($0) }), !name.isEmpty, name.utf8.count <= 128 else {
            throw NocturneError.remote("Enter the four-digit PIN shown on your device.")
        }
        guard let api else { throw NocturneError.disconnected }
        let result = try await api.request("/api/pin", body: ["pairing_id": request.id, "pin": pin, "name": name])
        guard result["status"] as? Bool == true else { throw NocturneError.remote("Pairing did not complete. Check the PIN and try again.") }
    }

    /// A QR-authorized client may approve only a pending video pairing from its own IP address.
    /// Ambiguous requests require the native PIN screen instead of approving another device.
    public func pairAuthorizedClient(pin: String, name: String, address: String) async throws {
        let epoch = generation
        for _ in 0..<24 {
            try Task.checkCancellation()
            guard generation == epoch else { throw NocturneError.disconnected }
            let requests = try await pendingPairings().filter { Self.normalizedAddress($0.address) == Self.normalizedAddress(address) }
            if requests.count > 1 { throw NocturneError.remote("Several devices are pairing at this address. Enter the PIN in Nocturne Server → Devices.") }
            if let request = requests.first { try await approve(request, pin: pin, name: name); return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NocturneError.remote("The video pairing request was not found. Enter the PIN in Nocturne Server → Devices.")
    }

    public func resetPairing() async throws {
        guard let api else { throw NocturneError.disconnected }
        let result = try await api.request("/api/clients/unpair-all", body: [:])
        guard result["status"] as? Bool == true else { throw NocturneError.remote("The streaming pairings could not be reset.") }
    }

    public func pairedDevices() async throws -> [StreamDevice] {
        guard let api else { throw NocturneError.disconnected }
        let result = try await api.request("/api/clients/list")
        guard result["status"] as? Bool == true, let clients = result["named_certs"] as? [[String: Any]] else {
            throw NocturneError.remote("The device list could not be loaded. Try refreshing it.")
        }
        // The API owns names/enablement. Its persisted public certificates supply the exact
        // identity shared by workspace authentication; names and IP addresses never identify a device.
        let saved = try savedDevices()
        return try clients.map { client in
            guard let id = client["uuid"] as? String, let name = client["name"] as? String,
                  let enabled = client["enabled"] as? Bool, let identity = saved.first(where: { $0.id == id }) else {
                throw NocturneError.remote("The device list changed. Refresh to try again.")
            }
            return StreamDevice(id: id, name: name, fingerprint: identity.fingerprint, enabled: enabled)
        }
    }

    public func savedDevices() throws -> [StreamDevice] {
        let url = directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let root = object["root"] as? [String: Any] else { throw NocturneError.invalidFrame }
        // Boost property_tree serializes an empty collection as an empty string.
        if root["named_devices"] == nil || root["named_devices"] as? String == "" { return [] }
        guard let clients = root["named_devices"] as? [[String: Any]] else { throw NocturneError.invalidFrame }
        return try clients.map { client in
            guard let id = client["uuid"] as? String, let pem = client["cert"] as? String,
                  let der = Self.certificateDER(pem: pem), SecCertificateCreateWithData(nil, der as CFData) != nil else { throw NocturneError.invalidFrame }
            return StreamDevice(id: id, name: client["name"] as? String ?? "Device",
                fingerprint: WorkspaceIdentity.fingerprint(der),
                enabled: client["enabled"] as? Bool ?? (client["enabled"] as? String != "false"))
        }
    }

    public func removeDevice(_ id: String) async throws {
        guard let api else { throw NocturneError.disconnected }
        // Disabling terminates sessions for this certificate only. Unpair alone leaves an
        // existing stream alive when other clients are paired.
        let disabled = try await api.request("/api/clients/update", body: ["uuid": id, "enabled": false])
        guard disabled["status"] as? Bool == true else { throw NocturneError.remote("This device could not be disconnected. Refresh the list and try again.") }
        let removed = try await api.request("/api/clients/unpair", body: ["uuid": id])
        guard removed["status"] as? Bool == true else { throw NocturneError.remote("Access is disabled, but the device could not be removed. Try again.") }
    }

    /// No plaintext administrative password is written to disk or passed on the command line.
    private func prepare(name: String, display: String, password: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let salt = try SecureStore.randomKey().prefix(8).map { String(format: "%02x", $0) }.joined()
        let credentials: [String: String] = ["username": "nocturne", "salt": salt, "password": Self.credentialHash(password: password, salt: salt)]
        try Self.writePrivate(try JSONSerialization.data(withJSONObject: credentials), to: directory.appendingPathComponent("credentials.json"))
        let apps = directory.appendingPathComponent("apps.json")
        var applicationList: [String: Any]
        if fm.fileExists(atPath: apps.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: apps)) as? [String: Any] else { throw NocturneError.invalidFrame }
            applicationList = existing
        } else {
            applicationList = ["apps": [["name": "Desktop"]]]
        }
        // The engine requires the env node, even when there are no environment overrides.
        if applicationList["env"] == nil { applicationList["env"] = [String: String]() }
        try Self.writePrivate(try JSONSerialization.data(withJSONObject: applicationList), to: apps)
        let config = Self.configuration(directory: directory, name: name, display: display)
        try Self.writePrivate(Data(config.utf8), to: directory.appendingPathComponent("engine.conf"))
    }
    static func configuration(directory: URL, name: String, display: String) -> String {
        func safe(_ value: String) -> String { value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "#", with: "") }
        var options: [String: String] = ["sunshine_name": safe(name), "system_tray": "disabled", "upnp": "disabled",
            "origin_web_ui_allowed": "pc", "encoder": "videotoolbox", "port": "47989", "min_log_level": "2",
            "ping_timeout": "10000", "install_steam_audio_drivers": "disabled"]
        for (key, file) in ["credentials_file": "credentials.json", "file_state": "state.json", "pkey": "key.pem", "cert": "cert.pem", "file_apps": "apps.json", "log_path": "engine.log"] {
            options[key] = directory.appendingPathComponent(file).path
        }
        if !display.isEmpty { options["output_name"] = safe(display) }
        return options.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"
    }
    static func credentialHash(password: String, salt: String) -> String {
        // Sunshine util::hex defaults to reverse byte order and uppercase characters.
        SHA256.hash(data: Data((password + salt).utf8)).reversed().map { String(format: "%02X", $0) }.joined()
    }
    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func certificateDER(at url: URL) throws -> Data {
        let pem = try String(contentsOf: url, encoding: .utf8)
        guard let data = certificateDER(pem: pem), SecCertificateCreateWithData(nil, data as CFData) != nil else { throw NocturneError.invalidFrame }
        return data
    }
    private static func certificateDER(pem: String) -> Data? {
        let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: base64)
    }
    private static func normalizedAddress(_ address: String) -> String { address.replacingOccurrences(of: "::ffff:", with: "").lowercased() }
}

private final class EngineAPI: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let certificate: Data
    private let authorization: String
    private var session: URLSession!
    init(certificate: Data, password: String) {
        self.certificate = certificate; authorization = "Basic " + Data("nocturne:\(password)".utf8).base64EncodedString()
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func invalidate() { session.invalidateAndCancel() }
    func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:47990" + path)!)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Same-origin local administration; matches the embedded engine's documented CSRF policy.
            request.setValue("https://127.0.0.1:47990", forHTTPHeaderField: "Origin")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_048_576,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NocturneError.remote("The embedded streaming engine refused the request. Check the server log.")
        }
        return result
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.port == 47990,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              SecCertificateCopyData(leaf) as Data == certificate else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
