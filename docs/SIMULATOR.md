# Simulator control

Enable **Simulator** in the Mac app, apply the setting, and reconnect the paired iPhone or iPad. Start an iOS simulator in Xcode on the Mac, then open **Apps → Simulator**, select it, and tap, hold or drag on its display. Scroll outside the display to move the surrounding page. Stop releases the control session. Backgrounding or leaving the page also stops it.

The Mac requires a full selected Xcode 27 or newer installation and a running iOS/iPadOS runtime. Nocturne does not create, boot, shut down, erase or install apps into simulators. Rotate or change the simulated device on the Mac; the next frame reflects its actual interface orientation and active display. Unsupported or ambiguous display metadata produces an error instead of guessing an input target.

This is a single-finger control channel with a two-frame-per-second JPEG preview, bounded to 1280 pixels on its longest encoded side and 512 KiB. The reported dimensions retain the native framebuffer size. Audio, multitouch, keyboard input, dedicated hardware buttons and remote rotation commands are outside this feature. Older preview-only hosts remain viewable, with touch disabled in the client.

## Host implementation

`NativeSimulatorBackend` owns a separate CoreSimulator/XPC connection for each lease on a serial worker. Discovery uses literal `xcrun simctl list devices available --json`; only available iOS/iPadOS devices with valid UDIDs are returned. Frame capture reads the selected native IOSurface rather than a desktop or Device Hub window. CoreDevice display metadata supplies the panel identity, pixel dimensions, Retina scale and interface rotation. The matching digitizer service supplies its explicit HID target. Multiple active or mismatched panels are rejected. Older runtime metadata without activity flags is accepted only when it identifies a single integrated display.

The backend uses runtime-checked **private macOS simulator APIs** and the DTUHID/CoreDevice contracts adapted from [Meta idb](https://github.com/meta/idb/tree/291575b7dbcf85525a7900b8f752f1c8175fa1ae). These APIs are not an Apple compatibility guarantee; future Xcode/runtime versions may require an update. Missing services, incompatible versions and request timeouts fail explicitly. This bridge is linked only into the Mac host; the iOS app uses UIKit and the existing workspace protocol. See the [third-party notice and MIT license](../THIRD_PARTY_NOTICES.md).

The active display is checked before and after capture and again for every input sample. JPEG orientation and touch inversion use the same panel rotation. Input coordinates are normalized within the displayed image, excluding letterboxes. The system-gesture edge is set at touch-down and remains fixed throughout that contact. No Accessibility permission, desktop event injection, auxiliary listener or test runner is required for production use.

## Ownership and cancellation

The existing workspace TLS connection, pairing challenge and per-device authorization gate all simulator operations. The setting is off by default and independent of screen sharing. Applying host settings uses the existing restart/revocation lifecycle. `simulator-preview-v1` advertises frames; `simulator-touch-v1` additionally advertises input. Optional geometry/touch fields preserve preview-only client compatibility.

A lease belongs to one authenticated connection. There is at most one controller per simulator, one lease per connection and two host-wide. Touch-down must refer to a recent frame from that lease. Subsequent samples must carry its gesture ID, pinned frame revision and consecutive sequence number. Stale frames, replayed/out-of-order input and another connection's lease cannot inject a contact. The client sends one request at a time, coalesces pending moves and preserves the terminal release event.

The host releases contacts on cancel, display changes, disconnect, revocation, stop and close. An abandoned contact expires after two seconds, independently of continued preview requests; a stationary client hold sends keepalive moves. Idle leases expire after twenty seconds. Pending native opens are awaited before final close so disconnect cannot leave a late connection behind. Native close drains the final release before closing XPC channels. All native requests have bounded waits.

## Verification

Automated checks:

```sh
python3 scripts/test-simulator.py
swift test --filter 'SimulatorTests|SimulatorInputTests'
```

The fixture suite covers discovery, framebuffer encoding and wire bounds, saved opt-in, connection ownership and device revocation over the production TLS server, cancellation during discovery/capture/open, lease and contact expiry, frame throttling, replay/order checks, display changes, panel/digitizer identity and all four coordinate rotations. `SimulatorClientTests` exercises the real client over authenticated loopback TLS, including coalescing under backpressure, release ordering, late replies after stop, preview-only compatibility and UIKit letterbox/cancel behavior. Run that suite with the project's normal iPhone/iPad Xcode test target.

Opt-in native tests require an explicitly selected, owned simulator. Build the inert fixture with `scripts/build-simulator-touch-fixture.sh`, install and open `.build/SimulatorTouchFixture.app` on that simulator, then run:

```sh
NOCTURNE_SIMULATOR_TEST_DEVICE='<selected UDID>' \
NOCTURNE_SIMULATOR_TOUCH_FIXTURE=1 \
swift test --filter SimulatorNativeTests
```

The fixture starts red, changes color for actual UIKit down/move/up events, and marks the received coordinates. The test refuses to send input unless that initial fixture color is present. It verifies the selected framebuffer's dimensions, touches at two known positions and release on disconnect. Relaunch the fixture before each run. For a landscape run, rotate the fixture first and add `NOCTURNE_SIMULATOR_EXPECT_LANDSCAPE=1`; physical orientation alone does not imply that an app's interface rotated.

Local verification on Xcode 27.1 includes native capture, touch coordinates and disconnect release on iPhone Duo (iOS 27.1) and coordinate/disconnect checks on iPad Pro (iOS 27.0) in landscape. The 26 host tests and four client tests on each device passed. Private-API coverage is limited to the tested installed runtimes. These tests do not establish smooth high-frame-rate streaming or physical-device release readiness.
