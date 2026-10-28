import Foundation
import NocturneKit

enum MicrophoneInstallation {
    static func install() async throws {
        let source = Bundle.main.resourceURL!.appendingPathComponent("NocturneMicrophone.driver")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("Contents/MacOS/NocturneMicrophone").path) else {
            throw NocturneError.remote(L("This build does not include Nocturne Microphone. Reinstall Nocturne."))
        }
        // The OS authorization dialog is shown only after the user presses Install.
        // Do not restart coreaudiod: that would interrupt every audio app on the Mac.
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let destination = "/Library/Audio/Plug-Ins/HAL/NocturneMicrophone.driver"
        let command = "/bin/mkdir -p /Library/Audio/Plug-Ins/HAL && /usr/bin/ditto " + quote(source.path) + " " + quote(destination)
            + " && /usr/sbin/chown -R root:wheel " + quote(destination) + " && /bin/chmod -R a+rX,go-w " + quote(destination)
        let script = "do shell script \"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
        try await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                throw NocturneError.remote(detail.contains("-128") ? L("Microphone installation was cancelled.") : L("Couldn’t install Nocturne Microphone. ") + detail)
            }
        }.value
    }
}
