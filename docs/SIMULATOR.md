# Simulator preview: implementation and outstanding control blocker

This is an **incomplete implementation of remote simulator control**. It provides a direct simulator framebuffer preview, not an interactive simulator. Do not describe it as the completed feature or ship it as touch control.

Work is isolated in `/private/tmp/nocturne-simulator`, branch `codex/simulator-channel`, based on `49ee687583adb5b82617cdc024f4bbdcf92cb861` (`origin/main` from the existing local repository). No other worker checkout was modified. T3 Chat is a functional reference from the request; its implementation was not inspected and no claim about its internals is made.

## Architecture and actual support

- The Mac's **Simulator preview** setting is off by default and saved independently of screen sharing. Applying the setting follows the existing server restart/revocation lifecycle. It does not enable screen recording, Accessibility, terminal access, or any new entitlement.
- The client opens **Apps → Simulator**. Discovery uses literal `xcrun simctl list devices available --json`. Only available iOS/iPadOS runtime devices with valid UDIDs are returned; shutdown devices are displayed but cannot be selected for preview. The user starts devices in Xcode on the Mac. No devices/runtimes are created, booted, stopped, erased, installed into, or reconfigured by this implementation.
- `simulatorList`, `simulatorOpen`, `simulatorFrame`, and `simulatorClose` use the existing workspace TLS/pairing transport, enrollment token, challenge signature, and per-device authorization. The authenticated host session gates every operation; no separate listener or unauthenticated HTTP/WebSocket helper exists. `simulator-preview-v1` is advertised only when explicitly enabled. Existing clients do not send the new optional operations.
- A preview lease is bound to the connection UUID. Another socket, including one authenticated with the same device identity, cannot capture or close it. There is one lease per connection and at most two on the host. Discovery is single-flight and cancellable; frames are single-flight per lease, limited to two requests per second. Pulling frames renews a 20-second lease. Explicit Stop, leaving the screen, app background, connection loss, revocation, host stop, expiry, and capture error release it. Switching devices awaits release of the old lease before opening the next.
- Capture is `xcrun simctl io <selected-UDID> screenshot --type=png <private-temporary-file>`. It reads the simulator framebuffer, not the desktop, Simulator/Device Hub window, bezel, title bar, or another display. A mode-0700 temporary directory is removed on success, failure, and cancellation. The existing process runner has bounded diagnostics/output, a 45-second command deadline, cancellation, and forced termination after its grace period. Host expiry can cancel a slow capture earlier.
- Actual native framebuffer width and height accompany every image. Portrait/landscape changes and device-size switches therefore do not depend on a guessed model-name table or the Mac window's size. Preview JPEGs preserve aspect ratio, have a maximum 1280-pixel long edge, and are capped at 512 KiB before JSON/base64 encoding. The client fits the already oriented image inside its available area. This is a low-rate preview, not a 30/60-fps video stream; audio is absent.
- Device sizes are available after the first successful frame. Discovery does not invent logical point sizes, Retina scale, or a portrait/landscape-left/right orientation from `simctl list`, which supplies none of these. Foldable/multiple-display routing is not implemented; the CLI's default screenshot display is used.

## Input and orientation blocker

There is **no production touch injection backend** in this change. `simulatorInput` explicitly fails as unavailable, the client has no input gesture recognizer, and no touch capability is advertised. The geometry helper is tested infrastructure only: it maps aspect-fit view positions through four explicit display rotations into native point coordinates using a backend-supplied pixel size and Retina scale. It rejects letterbox/out-of-bounds/non-finite samples. A screenshot alone cannot establish the necessary scale and left/right orientation, so the helper is never wired to inferred metadata or desktop input.

Apple's current documentation describes mouse/trackpad interactions inside Device Hub and test gestures via XCUIAutomation, but the reviewed documentation does not establish a public, general-purpose stream of arbitrary simulator touch down/move/up events. XCUITest coordinate gestures and `XCUIDevice.orientation` operate in a test context; the orientation API describes physical device orientation separately from UI orientation. Installing/launching a test runner, taking over a personal test session, or silently changing simulator state was outside the allowed verification scope. No such runner was installed.

A private CoreSimulator/SimulatorKit/HID backend could be researched separately on an isolated, explicitly owned test device, with runtime/version checks, cancellation of all active contacts, exact scale/orientation metadata, and stale-frame rejection before any input is accepted. None of those private APIs is used or claimed to work here. A verified, deliberately selected backend remains necessary to complete the requested touch channel. Remote rotation, multitouch, keyboard input, Home/lock buttons, and boot/shutdown are unsupported.

The iOS viewer uses public SwiftUI/UIKit and the existing workspace protocol. The Mac implementation requires installed Xcode command-line tools and access to CoreSimulator, which may be unavailable in a sandbox. No App Store compatibility or approval is promised. Private host APIs would need an explicit distribution decision; Apple App Review guideline 2.5.1 requires public APIs, and Mac App Store sandbox/self-containment requirements are additional constraints. This PR does not change permissions or entitlements to get around them.

## Verification (2026-10-28)

Run `python3 scripts/test-simulator.py` on a Mac with Xcode. The harness compiles the production Packet/frame types, simulator manager/backend, process runner, and settings using the installed Swift compiler and runs a local XCTest bundle. It copies the production `RemoteAccess` value type verbatim while omitting the unrelated native Rust tunnel implementation; it never substitutes the simulator protocol or backend. No dependency downloads, listener, simulator service, runtime installation, or personal simulator data are needed. The same `Tests/SimulatorTests.swift` is also discovered by the normal package test target.

Result: **14 tests passed, 0 failures** in the isolated XCTest harness.

Fixture coverage includes JSON discovery/filtering, frame wire size/roundtrip, native dimensions and aspect ratio across Retina portrait/landscape and smaller displays, real PNG-to-JPEG encoding, literal command allowlist/UDID validation/temp cleanup, sanitized failures, saved opt-in defaults, cross-connection denial, idempotent close, expiry, host lease bounds, frame throttling, capture/discovery cancellation and single-flight behavior, unsupported input, and all four coordinate rotations/letterboxes. These geometry tests do not verify real simulator touch handling.

SDK checks: full `Sources/Shared` module on macOS and iOS; full `Sources/HostKit` module on macOS; new `SimulatorWorkspace.swift` against the iOS SDK. Full Mac app checking reached an existing SwiftUI macro/plugin sandbox failure (`sandbox-exec: sandbox_apply: Operation not permitted` in `MacAppsWorkspace.swift`); no permission expansion was attempted. The dependency-complete app build and normal full SwiftPM suite were not completed in this checkout. Existing Sendable/deprecation warnings remain outside this task.

Installed tools report Xcode 27.0, build 27A266a. The read-only `xcrun simctl help` attempt failed to connect to CoreSimulatorService and reported sandbox-denied access to the CoreSimulator log/device service. Thus current local subcommand help and real simulator capture were not verified. No boot/shutdown/install/erase/reset command was issued. No iPhone/iPad execution, visual runtime verification, real touch verification, TestFlight upload, or merge was performed.

## Primary references reviewed

Accessed 2026-10-28:

- [Apple: Xcode command-line tool reference](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference) — installed Xcode prerequisite and `simctl help` as authoritative command reference.
- [Apple: Getting the Most Out of Simulator (WWDC19)](https://developer.apple.com/videos/play/wwdc2019/418/) — device/runtimes listing and command-specific help.
- [Apple: archived Simulator guide](https://developer.apple.com/library/archive/documentation/IDEs/Conceptual/iOS_Simulator_Guide/InteractingwiththeiOSSimulator/InteractingwiththeiOSSimulator.html) — documented `simctl io … screenshot` and file-based recording. This is archival, not evidence of a new streaming/input API.
- [Apple: Interacting with your app in Device Hub](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-the-ios-or-ipados-simulator) — host UI gestures and orientation controls; no inference that these are exposed as a remote API.
- [Apple: Capturing screenshots and videos from devices](https://developer.apple.com/documentation/xcode/capturing-screenshots-and-videos-from-devices) — native-resolution capture independent of the Mac display.
- [Apple: XCUICoordinate](https://developer.apple.com/documentation/xcuiautomation/xcuicoordinate) and [XCUIDevice.orientation](https://developer.apple.com/documentation/xcuiautomation/xcuidevice/orientation) — test gestures and orientation semantics.
- [Apple: App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — 2.5.1 and Mac App Store constraints in 2.4.5.

## Publication blocker

The authorized attempt to create the independent GitHub branch `codex/simulator-channel` at the documented base was rejected by `github_create_branch` with the exact response `user rejected MCP tool call`. No branch/commit upload or PR creation followed. The rejection was not retried through Git, gh, another API, another identity, or permission changes. There is therefore no PR URL or remote PR-check result. Local commits and an exported patch remain available for review. This does not resolve the separate missing touch-backend blocker.
