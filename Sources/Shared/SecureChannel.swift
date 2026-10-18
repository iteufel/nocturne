import Foundation
import Network
import Security
import CryptoKit

public enum SecureTransport {
    public static func parameters(secret: Data) -> NWParameters {
        precondition(secret.count == 32)
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        // Standard TLS-PSK: both peers must possess the out-of-band 256-bit pairing key.
        // No certificate trust bypass and no plaintext fallback.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
        let identity = Data("nocturne-v1".utf8)
        secret.withUnsafeBytes { key in
            identity.withUnsafeBytes { id in
                sec_protocol_options_add_pre_shared_key(options, DispatchData(bytes: key) as __DispatchData, DispatchData(bytes: id) as __DispatchData)
            }
        }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        return parameters
    }
}

/// All callbacks and writes run on one serial queue. A complete frame is one NWConnection send.
public final class SecureChannel {
    public let connection: NWConnection
    public let queue: DispatchQueue
    public var onPacket: ((Packet) -> Void)?
    public var onReady: (() -> Void)?
    public var onClose: ((Error) -> Void)?
    private var closed = false
    public init(connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "nocturne.channel")) {
        self.connection = connection; self.queue = queue
    }
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready: self.onReady?(); self.receiveHeader()
            case .failed(let error): self.finish(error)
            case .cancelled: self.finish(NocturneError.disconnected)
            case .waiting(let error): self.finish(error)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, self.connection.state != .ready else { return }
            self.finish(NocturneError.timeout)
        }
    }
    public func send(_ packet: Packet, completion: ((Error?) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { completion?(NocturneError.disconnected); return }
            do {
                let data = try FrameCodec.encode(packet)
                self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    completion?(error)
                    if let error = error { self?.finish(error) }
                })
            } catch { completion?(error); self.finish(error) }
        }
    }
    public func cancel() {
        // The owner releases its channel immediately on disconnect. Retain it until
        // cancellation runs, otherwise the socket and host subscription stay alive.
        queue.async { self.finish(NocturneError.disconnected) }
    }
    public func boundChallenge(_ nonce: Data) throws -> Data {
        guard nonce.count == 32,
              let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { throw NocturneError.invalidFrame }
        let label = "EXPORTER-Nocturne-Workspace-v2"
        guard let secret = sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, label.utf8.count, label, 32) else {
            throw NocturneError.remote("The secure connection could not verify this device. Reconnect to try again.")
        }
        // Bind the signature to this TLS session. A former device that knows the transport
        // key cannot relay another device's signature onto a different connection.
        let binding = Data(secret as DispatchData)
        guard binding.count == 32 else { throw NocturneError.invalidFrame }
        return Data(SHA256.hash(data: nonce + binding))
    }
    private func receiveHeader() {
        receiveExactly(4) { [weak self] header in
            guard let self = self else { return }
            do {
                let count = try FrameCodec.length(header)
                self.receiveExactly(count) { [weak self] data in
                    guard let self = self else { return }
                    do { self.onPacket?(try JSONDecoder().decode(Packet.self, from: data)); self.receiveHeader() }
                    catch { self.finish(error) }
                }
            } catch { self.finish(error) }
        }
    }
    private func receiveExactly(_ count: Int, completion: @escaping (Data) -> Void) {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, complete, error in
            guard let self = self, !self.closed else { return }
            if let data = data, data.count == count { completion(data) }
            else { self.finish(error ?? NocturneError.disconnected) }
        }
    }
    private func finish(_ error: Error) {
        guard !closed else { return }; closed = true
        connection.stateUpdateHandler = nil; connection.cancel()
        onClose?(error)
        onPacket = nil; onReady = nil; onClose = nil
    }
}
