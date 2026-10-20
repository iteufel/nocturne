import Foundation

/// The desktop must be prepared before the client starts video at its new size.
public enum StreamDisplayPreparation {
    // Creating a framebuffer and waiting for capture readiness can outlast an
    // ordinary workspace request. The host bounds preparation to 50 seconds.
    public static let requestTimeout: TimeInterval = 60

    public static func request(size: StreamDisplaySize, sessionID: String, matchesDevice: Bool,
                               workspaceLinked: Bool, capabilities: [String]) throws -> Packet? {
        guard workspaceLinked else {
            if matchesDevice {
                throw NocturneError.remote("To match the desktop to this device, pair using the QR code in Nocturne Server. For a computer without Nocturne display control, choose a fixed resolution in Settings.")
            }
            return nil
        }
        guard capabilities.contains("display") else {
            if matchesDevice {
                throw NocturneError.remote("Choose a fixed resolution such as 1080p in Settings to stream this computer. Match device requires display control and a compatible monitor on the host.")
            }
            return nil
        }
        var packet = Packet(.displayPrepare)
        packet.sessionID = sessionID
        packet.display = size
        return packet
    }
}
