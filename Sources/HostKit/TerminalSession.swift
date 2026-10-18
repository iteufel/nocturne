import Foundation
import Darwin
import PTYBridge
import NocturneKit

public final class TerminalSession {
    public let id = UUID().uuidString
    private var master: Int32 = -1
    private var pid: pid_t = -1
    private var source: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private let queue: DispatchQueue
    private let output: (Data) -> Void
    private var stopped = false
    public init(columns: Int, rows: Int, queue: DispatchQueue, output: @escaping (Data) -> Void, exited: @escaping () -> Void) throws {
        self.queue = queue; self.output = output
        pid = nocturne_pty_spawn(&master, NSHomeDirectory(), NSUserName(), UInt16(clamping: min(max(columns, 20), 500)), UInt16(clamping: min(max(rows, 5), 200)))
        guard pid > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        reader.setEventHandler { [weak self] in
            guard let self = self, !self.stopped else { return }
            if self.drainOutput() { self.close(); exited() }
        }
        source = reader; reader.resume()
        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in
            guard let self = self, !self.stopped else { return }
            // A process-exit notification can arrive before the PTY read notification.
            // Deliver its final output before retaining the finished tab for reconnect.
            _ = self.drainOutput()
            var status: Int32 = 0; waitpid(self.pid, &status, WNOHANG)
            self.pid = -1; self.close(); exited()
        }
        processSource = process; process.resume()
    }
    deinit { close() }
    private func drainOutput() -> Bool {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        for _ in 0..<64 {
            let count = Darwin.read(master, &bytes, bytes.count)
            if count > 0 { output(Data(bytes.prefix(count))) }
            else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { return true }
            else if errno == EAGAIN { return false }
        }
        return false
    }
    public func input(_ data: Data) throws {
        guard !stopped, data.count <= 16_384 else { throw NocturneError.disconnected }
        // A short PTY write is surfaced to the caller, never silently dropped.
        let count = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        guard count == data.count else { throw NocturneError.remote("The terminal input buffer is full. Try a smaller paste.") }
    }
    public func resize(columns: Int, rows: Int) {
        guard !stopped else { return }
        nocturne_pty_resize(master, UInt16(clamping: min(max(columns, 20), 500)), UInt16(clamping: min(max(rows, 5), 200)))
    }
    public func close() {
        guard !stopped else { return }; stopped = true
        source?.cancel(); source = nil; processSource?.cancel(); processSource = nil
        if master >= 0 { Darwin.close(master); master = -1 }
        if pid > 0 {
            let child = pid; pid = -1; nocturne_pty_terminate(child)
            DispatchQueue.global().async {
                // Reap promptly; escalate only this session's process group if its shell ignores termination.
                for _ in 0..<20 {
                    var status: Int32 = 0
                    if waitpid(child, &status, WNOHANG) != 0 { return }
                    usleep(50_000)
                }
                kill(-child, SIGKILL); kill(child, SIGKILL)
                var status: Int32 = 0; waitpid(child, &status, 0)
            }
        }
    }
}
