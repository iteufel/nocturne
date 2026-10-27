import SwiftUI
import FileProvider
import NocturneKit

@MainActor
final class FilesIntegration: ObservableObject {
    @Published private(set) var locationNames: [String] = []
    @Published private(set) var error: String?
    /// Files domains of every paired Mac, in pairing order. Any other Nocturne location is removed.
    private var domains: [String] = []
    private var generation = UUID()
    private var pending: Task<Void, Never>?

    func configure(invitation: PairingInvitation, certificate: Data, privateKey: Data?, deviceName: String, enabled: Bool) {
        let domain = FilesProviderAccount.domainIdentifier(secret: invitation.secret)
        if !domains.contains(domain) { domains.append(domain) }
        do {
            if enabled {
                guard let privateKey else { throw NocturneError.remote("The device identity could not be shared with Files. Reopen Nocturne and try again.") }
                let account = try FilesProviderAccount(invitation: invitation, certificate: certificate, privateKey: privateKey, deviceName: deviceName)
                try SecureStore.write(JSONEncoder().encode(account), account: account.keychainAccount)
            } else {
                try SecureStore.delete(FilesProviderAccount.keychainAccount(domainIdentifier: domain))
            }
            reconcile(try storedAccounts())
        } catch {
            let message = error.localizedDescription
            do { try forget(invitation) }
            catch { self.error = message + " " + error.localizedDescription; return }
            self.error = message
        }
    }
    func refresh(_ servers: [PairingInvitation]) {
        domains = servers.map { FilesProviderAccount.domainIdentifier(secret: $0.secret) }
        do {
            try migrateLegacyAccount()
            reconcile(try storedAccounts())
        } catch { self.error = error.localizedDescription }
    }
    func forget(_ invitation: PairingInvitation) throws {
        let domain = FilesProviderAccount.domainIdentifier(secret: invitation.secret)
        // Revoke the extension's credentials synchronously, before asynchronous domain removal.
        try SecureStore.delete(FilesProviderAccount.keychainAccount(domainIdentifier: domain))
        domains.removeAll { $0 == domain }
        reconcile(try storedAccounts())
    }
    private func storedAccounts() throws -> [FilesProviderAccount] {
        try domains.compactMap { domain in
            try SecureStore.read(FilesProviderAccount.keychainAccount(domainIdentifier: domain)).flatMap {
                try? JSONDecoder().decode(FilesProviderAccount.self, from: $0)
            }
        }
    }
    private func migrateLegacyAccount() throws {
        guard let data = try SecureStore.read(FilesProviderAccount.legacyKeychainAccount) else { return }
        if let account = try? JSONDecoder().decode(FilesProviderAccount.self, from: data), domains.contains(account.domainIdentifier) {
            try SecureStore.write(data, account: account.keychainAccount)
        }
        try SecureStore.delete(FilesProviderAccount.legacyKeychainAccount)
    }
    private func reconcile(_ accounts: [FilesProviderAccount]) {
        let epoch = UUID(); generation = epoch; error = nil
        let previous = pending
        pending = Task {
            await previous?.value
            guard generation == epoch else { return }
            do {
                let existing = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NSFileProviderDomain], Error>) in
                    NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: domains) }
                    }
                }
                let wanted = Set(accounts.map(\.domainIdentifier))
                for domain in existing where !wanted.contains(domain.identifier.rawValue) {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        NSFileProviderManager.remove(domain) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                }
                guard generation == epoch else { return }
                for account in accounts {
                    let domain = NSFileProviderDomain(identifier: .init(account.domainIdentifier), displayName: account.invitation.name,
                        pathRelativeToDocumentStorage: account.domainIdentifier)
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        NSFileProviderManager.add(domain) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                    NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
                    NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { _ in }
                    guard generation == epoch else { return }
                }
                locationNames = accounts.map(\.invitation.name)
            } catch { if generation == epoch { self.error = error.localizedDescription } }
        }
    }
}

struct FilesIntegrationSettings: View {
    @ObservedObject var integration: FilesIntegration
    let paired: Bool
    let refresh: () -> Void
    var body: some View {
        Section {
            ForEach(Array(integration.locationNames.enumerated()), id: \.offset) { _, name in LabeledContent("Location", value: name) }
            Text("In Apple Files, open Browse → Locations → Nocturne. Each paired Mac is its own location. Enable a location when asked. If it is hidden, choose More (…) → Edit and enable Nocturne.")
                .font(.caption).foregroundStyle(MoonStyle.secondary)
            Text("Browse folders, preview files, and copy them to your device or another app. To send files to your Mac, use Nocturne’s Files tab. Your Mac must be reachable with Nocturne running and File sharing enabled.")
                .font(.caption).foregroundStyle(MoonStyle.secondary)
            if paired { Button("Refresh Files location", action: refresh) }
            if let error = integration.error { Text(error).font(.caption).foregroundStyle(.orange) }
        } header: { Text("Apple Files") }
            .listRowBackground(MoonStyle.surface)
    }
}
