import Foundation
import Network
import CryptoKit

/// Bonjour only locates a candidate. TLS-PSK and device authentication still establish trust.
@MainActor
public final class WorkspaceDiscovery {
    public nonisolated static func identifier(for secret: Data) -> String {
        SHA256.hash(data: Data("nocturne-discovery-v1\0".utf8) + secret)
            .map { String(format: "%02x", $0) }.joined()
    }

    private var browser: NWBrowser?
    private var result: CheckedContinuation<NWEndpoint?, Never>?
    private var deadline: Task<Void, Never>?

    public init() {}

    public func find(secret: Data, timeout: TimeInterval = 2) async -> NWEndpoint? {
        cancel()
        guard !Task.isCancelled else { return nil }
        let id = Self.identifier(for: secret)
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: WorkspaceProtocol.service, domain: "local."), using: .tcp)
        self.browser = browser
        return await withCheckedContinuation { continuation in
            result = continuation
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                Task { @MainActor in
                    guard let self, let browser, self.browser === browser else { return }
                    for candidate in results {
                        if case .bonjour(let record) = candidate.metadata, record["id"] == id {
                            self.finish(candidate.endpoint); return
                        }
                    }
                }
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                Task { @MainActor in
                    guard let self, let browser, self.browser === browser else { return }
                    if case .failed = state { self.finish(nil) }
                }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000)) } catch { return }
                self?.finish(nil)
            }
            browser.start(queue: .main)
        }
    }

    public func cancel() { finish(nil) }

    private func finish(_ endpoint: NWEndpoint?) {
        browser?.browseResultsChangedHandler = nil; browser?.stateUpdateHandler = nil
        browser?.cancel(); browser = nil
        deadline?.cancel(); deadline = nil
        let continuation = result; result = nil
        continuation?.resume(returning: endpoint)
    }
}
