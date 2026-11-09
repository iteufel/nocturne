import Foundation

public enum NocturneError: LocalizedError, Equatable {
    case invalidInvitation, invalidFrame, disconnected, timeout, remote(String), invalidPath, permissionDenied, invalidTransfer
    public var errorDescription: String? {
        switch self {
        case .invalidInvitation: return "This QR code is invalid. Scan a new QR code from Nocturne on your Mac."
        case .invalidFrame: return "The server sent an invalid message."
        case .disconnected: return "Connection closed. Reconnect to your Mac to continue."
        case .timeout: return "The Mac did not respond in time. Check that Nocturne is running."
        case .remote(let message): return message
        case .invalidPath: return "This path is outside the shared folder or contains a symbolic link."
        case .permissionDenied: return "Enable this feature in Nocturne on your Mac."
        case .invalidTransfer: return "The transfer is incomplete or out of order. Start it again."
        }
    }
}

