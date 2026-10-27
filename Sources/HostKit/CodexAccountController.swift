import Foundation
import Combine
import NocturneKit

/// Codex manages its ChatGPT OAuth flow and credential store. No tokens leave this process boundary.
@MainActor
public final class CodexAccountController: ObservableObject {
    @Published public private(set) var status = "Checking Codex sign-in…"
    @Published public private(set) var signedIn = false
    @Published public private(set) var busy = false
    @Published public private(set) var error: String?
    private var rpc: AgentRPC?
    private var configuration: ChatAgentConfiguration?
    private var directory: URL?
    private var loginID: String?
    private var loginStarting = false
    private var earlyLoginResults: [String: [String: Any]] = [:]

    public init() {}
    public func refresh(configuration: ChatAgentConfiguration?, directory: URL) async {
        guard !busy, loginID == nil else { return }; busy = true; defer { busy = false }
        do { try await connect(configuration: configuration, directory: directory); try await read() }
        catch is CancellationError { return }
        catch { self.error = ChatVoice.failure(error.localizedDescription); status = "Codex sign-in unavailable"; signedIn = false }
    }
    public func login(configuration: ChatAgentConfiguration?, directory: URL, open: (URL) -> Void) async {
        guard !busy, loginID == nil else { return }; busy = true; error = nil; defer { busy = false }
        do {
            try await connect(configuration: configuration, directory: directory)
            guard let rpc else { throw NocturneError.disconnected }
            loginStarting = true; earlyLoginResults = [:]
            defer { loginStarting = false; earlyLoginResults = [:] }
            let reply = try await rpc.call("account/login/start", ["type": "chatgpt"])
            guard self.rpc === rpc else { throw CancellationError() }
            guard reply["type"] as? String == "chatgpt", let id = reply["loginId"] as? String,
                  let text = reply["authUrl"] as? String, let url = URL(string: text), url.scheme == "https" else { throw NocturneError.invalidFrame }
            loginID = id; status = "Finish ChatGPT sign-in in your browser"; open(url)
            if let completed = earlyLoginResults.removeValue(forKey: id) { completeLogin(completed) }
        } catch is CancellationError { return }
        catch { self.error = ChatVoice.failure(error.localizedDescription) }
    }
    public func cancelLogin() async {
        guard let id = loginID else { return }
        _ = try? await rpc?.call("account/login/cancel", ["loginId": id], timeout: 5)
        loginID = nil; status = "ChatGPT sign-in cancelled"
    }
    public var awaitingLogin: Bool { loginID != nil }
    private func connect(configuration: ChatAgentConfiguration?, directory: URL) async throws {
        guard let configuration, configuration.transport == .codex else { throw NocturneError.remote("Configure a native Codex App Server provider first.") }
        if self.configuration == configuration, self.directory == directory, rpc?.closed == false { return }
        rpc?.close(); rpc = nil; loginID = nil
        let next = try AgentRPC(configuration: configuration, directory: configuration.workingDirectory(fallback: directory), chatGPTOnly: true)
        next.onNotification = { [weak self, weak next] method, params in
            guard let self, self.rpc === next else { return }
            if method == "account/login/completed" {
                if let id = params["loginId"] as? String, self.loginStarting, self.loginID == nil, self.earlyLoginResults.count < 4 {
                    // A notification can arrive in the same stdout read as the start response.
                    self.earlyLoginResults[id] = params
                } else { self.completeLogin(params) }
            } else if method == "account/updated" { Task { @MainActor [weak self] in try? await self?.read() } }
        }
        next.onExit = { [weak self] _ in self?.signedIn = false; self?.loginID = nil; self?.status = "Codex disconnected" }
        rpc = next; self.configuration = configuration; self.directory = directory
        _ = try await next.call("initialize", ["clientInfo": ["name": "nocturne", "title": "Nocturne", "version": "1.0"], "capabilities": ["experimentalApi": true]])
        next.notify("initialized")
    }
    private func completeLogin(_ params: [String: Any]) {
        guard let id = params["loginId"] as? String, id == loginID else { return }
        loginID = nil
        if params["success"] as? Bool == true {
            Task { @MainActor [weak self] in
                do { try await self?.read() }
                catch is CancellationError { return }
                catch { self?.error = ChatVoice.failure(error.localizedDescription); self?.status = "Codex sign-in unavailable" }
            }
        } else { status = "ChatGPT sign-in failed"; error = ChatVoice.failure(params["error"] as? String ?? "Sign-in was not completed.") }
    }
    private func read() async throws {
        guard let rpc else { throw NocturneError.disconnected }
        let result = try await rpc.call("account/read", ["refreshToken": false])
        guard self.rpc === rpc else { throw CancellationError() }
        let account = result["account"] as? [String: Any]
        signedIn = account?["type"] as? String == "chatgpt"
        status = signedIn ? "Signed in with ChatGPT" : "ChatGPT sign-in required for voice"
        error = nil
    }
    public func close() {
        rpc?.onExit = nil; rpc?.close(); rpc = nil; loginID = nil
        loginStarting = false; earlyLoginResults = [:]; busy = false
    }
}
