import SwiftUI
import FileProvider
import NocturneKit

@MainActor
final class FilesIntegration: ObservableObject {
    @Published private(set) var locationName: String?
    @Published private(set) var error: String?
    private var generation = UUID()
    private var pending: Task<Void, Never>?

    func configure(invitation: PairingInvitation, certificate: Data, privateKey: Data?, deviceName: String, enabled: Bool) {
        do {
            let account: FilesProviderAccount?
            if enabled {
                guard let privateKey else { throw NocturneError.remote("The device identity could not be shared with Files. Reopen Nocturne and try again.") }
                account = try FilesProviderAccount(invitation: invitation, certificate: certificate, privateKey: privateKey, deviceName: deviceName)
                try SecureStore.write(JSONEncoder().encode(account), account: FilesProviderAccount.keychainAccount)
            } else {
                account = nil
                try SecureStore.delete(FilesProviderAccount.keychainAccount)
            }
            reconcile(account)
        } catch {
            let message = error.localizedDescription
            do { try forget() }
            catch { self.error = message + " " + error.localizedDescription; return }
            self.error = message
        }
    }
    func refresh() {
        do {
            let account = try SecureStore.read(FilesProviderAccount.keychainAccount).map {
                try JSONDecoder().decode(FilesProviderAccount.self, from: $0)
            }
            reconcile(account)
        } catch { self.error = error.localizedDescription }
    }
    func forget() throws {
        // Revoke the extension's credentials synchronously, before asynchronous domain removal.
        try SecureStore.delete(FilesProviderAccount.keychainAccount)
        locationName = nil
        reconcile(nil)
    }
    private func reconcile(_ account: FilesProviderAccount?) {
        let epoch = UUID(); generation = epoch; error = nil
        let previous = pending
        pending = Task {
            await previous?.value
            guard generation == epoch else { return }
            do {
                let domains = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NSFileProviderDomain], Error>) in
                    NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: domains) }
                    }
                }
                for domain in domains where domain.identifier.rawValue != account?.domainIdentifier {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        NSFileProviderManager.remove(domain) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                }
                guard generation == epoch else { return }
                if let account {
                    let domain = NSFileProviderDomain(identifier: .init(account.domainIdentifier), displayName: account.invitation.name,
                        pathRelativeToDocumentStorage: account.domainIdentifier)
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        NSFileProviderManager.add(domain) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                    NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
                    NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { _ in }
                }
                guard generation == epoch else { return }
                locationName = account?.invitation.name
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
            if let name = integration.locationName { LabeledContent("Location", value: name) }
            Text("In Apple Files, open Browse → Locations → Nocturne. Enable the location when asked. If it is hidden, choose More (…) → Edit and enable Nocturne.")
                .font(.caption).foregroundStyle(MoonStyle.secondary)
            Text("Browse folders, preview files, and copy them to your device or another app. To send files to your Mac, use Nocturne’s Files tab. Your Mac must be reachable with Nocturne Server running and File sharing enabled.")
                .font(.caption).foregroundStyle(MoonStyle.secondary)
            if paired { Button("Refresh Files location", action: refresh) }
            if let error = integration.error { Text(error).font(.caption).foregroundStyle(.orange) }
        } header: { Text("Apple Files") }
            .listRowBackground(MoonStyle.surface)
    }
}
