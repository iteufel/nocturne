import Foundation
import NocturneKit

public protocol MicrophoneOutput: AnyObject {
    func start() throws
    func write(_ pcm: Data) throws
    func stop()
}

/// Accessed only on WorkspaceServer's serial queue. A lease belongs to a connection,
/// not merely to a paired identity, so another connection cannot inject into it.
final class MicrophoneSession {
    private let output: MicrophoneOutput
    private let now: () -> TimeInterval
    private var connection: UUID?
    private var session: String?
    private var sequence: Int64 = -1
    private var lastFrame: TimeInterval = 0

    init(output: MicrophoneOutput, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.output = output; self.now = now
    }
    func handle(_ packet: Packet, connection: UUID) throws -> Packet {
        expire()
        var reply = packet.reply()
        switch packet.operation {
        case .microphoneStart:
            guard self.connection == nil else { throw NocturneError.remote("Another microphone is already connected to this Mac.") }
            try output.start()
            self.connection = connection; session = UUID().uuidString; sequence = -1; lastFrame = now()
            reply.sessionID = session; reply.name = "Nocturne Microphone"
        case .microphoneAudio:
            guard self.connection == connection, let session, packet.sessionID == session else { throw NocturneError.permissionDenied }
            guard let data = packet.data, data.count == MicrophoneFormat.bytesPerFrame,
                  let sequence = packet.offset, sequence >= 0, sequence > self.sequence else { throw NocturneError.invalidFrame }
            do { try output.write(data) } catch { stop(); throw error }
            self.sequence = sequence; lastFrame = now()
        case .microphoneStop:
            // Late stop packets cannot release another connection or a newer lease.
            if self.connection == connection, packet.sessionID == session { stop() }
        default: throw NocturneError.invalidFrame
        }
        return reply
    }
    func disconnected(_ connection: UUID) { if self.connection == connection { stop() } }
    func expire() { if connection != nil, now() - lastFrame >= MicrophoneFormat.timeout { stop() } }
    func stop() {
        guard connection != nil else { return }
        output.stop(); connection = nil; session = nil; sequence = -1
    }
}
