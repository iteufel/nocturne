import AppKit
import Combine
import NocturneKit

@MainActor
public final class MacClientModel: ObservableObject {
    @Published public private(set) var pairedServers = PairedServerList()
    @Published public private(set) var session: MacDesktopSession?
    @Published public var error: String?
    @Published public var showAddHost = false
    private var loaded = false
    private var identity: WorkspaceIdentity?
    private let read: (String) throws -> Data?
    private let write: (Data, String) throws -> Void
    private let makeIdentity: () throws -> WorkspaceIdentity
    static let account = "mac-client-paired-servers"

    public init(read: @escaping (String) throws -> Data? = SecureStore.read,
                write: @escaping (Data, String) throws -> Void = { try SecureStore.write($0, account: $1) },
                makeIdentity: (() throws -> WorkspaceIdentity)? = nil) {
        self.read = read; self.write = write
        self.makeIdentity = makeIdentity ?? {
            try MacClientIdentity.load().workspace(name: Host.current().localizedName ?? "Nocturne Mac")
        }
    }
    public func load() {
        guard !loaded else { return }
        do {
            let data = try read(Self.account)
            pairedServers = try data.map { try JSONDecoder().decode(PairedServerList.self, from: $0) } ?? PairedServerList()
            loaded = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    public func addHost(_ code: String) -> Bool {
        do {
            guard let url = URL(string: code.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw NocturneError.invalidInvitation }
            let invitation = try PairingInvitation(url: url)
            if let local = try read("server-key"), local == invitation.secret {
                throw NocturneError.remote("This is your own Mac’s pairing code. Copy a code from the other Mac’s Pair a device window.")
            }
            try open(invitation)
            showAddHost = false; return true
        } catch {
            self.error = (error as? NocturneError) == .invalidInvitation
                ? "This pairing code is invalid. Copy a new code from Pair a device on the other Mac."
                : error.localizedDescription
            return false
        }
    }
    public func connect(_ id: String) {
        do {
            guard let paired = pairedServers[id] else { return }
            try open(paired.invitation)
        } catch { self.error = error.localizedDescription }
    }
    private func open(_ invitation: PairingInvitation) throws {
        load()
        guard loaded else { throw NocturneError.remote("Unlock your Keychain and try again to keep your saved hosts.") }
        guard session == nil else { throw NocturneError.remote("Disconnect your current desktop before connecting to another Mac.") }
        if identity == nil { identity = try makeIdentity() }
        guard let identity else { throw NocturneError.invalidFrame }
        error = nil
        let stream = MacDesktopSession(invitation: invitation, identity: identity)
        stream.onAuthenticated = { [weak self, weak stream] refreshed in
            guard let self, let stream, self.session === stream else { throw NocturneError.disconnected }
            var saved = self.pairedServers
            saved.pair(refreshed)
            try self.save(saved)
        }
        session = stream
    }
    public func disconnect() { session?.stop(); session = nil }
    public func forget(_ id: String) {
        do {
            guard session?.serverID != id else { throw NocturneError.remote("Disconnect this Mac before forgetting it.") }
            guard loaded else { throw NocturneError.remote("Unlock your Keychain and load your saved hosts first.") }
            var saved = pairedServers; saved.remove(id); try save(saved)
        } catch { self.error = error.localizedDescription }
    }
    private func save(_ list: PairedServerList) throws {
        guard loaded else { throw NocturneError.disconnected }
        try write(JSONEncoder().encode(list), Self.account)
        pairedServers = list
    }
}
