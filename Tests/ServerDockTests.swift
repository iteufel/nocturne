import AppKit
import XCTest

@MainActor
final class ServerDockTests: XCTestCase {
    /// Observe the packaged app with Screen sharing enabled; never launch capture or change displays here.
    func testRunningServerHasOnlyOneDockApplication() throws {
        guard let path = ProcessInfo.processInfo.environment["NOCTURNE_RUNNING_SERVER_APP"] else {
            throw XCTSkip("Set NOCTURNE_RUNNING_SERVER_APP to a running app with its server started.")
        }
        let bundleURL = URL(fileURLWithPath: path).standardizedFileURL
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == bundleURL
        }
        let main = try XCTUnwrap(applications.first { $0.executableURL?.lastPathComponent == "Nocturne" })
        let engine = try XCTUnwrap(applications.first { $0.executableURL?.lastPathComponent == "nocturne-stream-host" },
            "Enable Screen sharing and apply before running this check; a stopped helper cannot verify the regression.")
        XCTAssertEqual(main.activationPolicy, .regular, "The main app must retain its Dock icon and menus")
        XCTAssertTrue(main.isFinishedLaunching, "The main app must finish launching")
        XCTAssertNotEqual(engine.activationPolicy, .regular, "The streaming helper must not create a bouncing second Dock icon")
        XCTAssertEqual(applications.filter { $0.activationPolicy == .regular }.count, 1)
    }
}
