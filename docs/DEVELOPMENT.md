# Development

Build and test Nocturne locally. For signed releases and TestFlight automation, see the [release guide](RELEASING.md). For app setup, see the [usage guide](USAGE.md).

## Build

Targets iOS 17+ and macOS 14+ on an Apple Silicon Mac. Build with Rust 1.91+ (rustup) and Xcode 26 or newer (iOS 26/macOS 26 SDKs) and Ruby's `xcodeproj` gem. Development here uses Xcode 27 and iOS 27 simulators.

```sh
gem install xcodeproj -v 1.27.0
./scripts/bootstrap.sh
open Nocturne.xcworkspace
```

Bootstrap fetches pinned client/terminal sources and the checksum-verified streaming engine, then generates both Xcode projects. `Vendor/` contains build dependencies and is intentionally ignored by Git. The generated workspace and dependency lock are included.

Choose **Nocturne** for iPhone/iPad or **Nocturne Server** for macOS. Select your development team in Xcode when installing on physical devices. Command-line development builds:

```sh
./scripts/build.sh ios
./scripts/build.sh mac
```

For stable macOS permissions across local rebuilds, use your Apple Development identity and team:

```sh
NOCTURNE_SIGNING_IDENTITY='Apple Development' NOCTURNE_DEVELOPMENT_TEAM='<your team ID>' ./scripts/build.sh mac
```

Without these variables the build is ad-hoc signed; macOS may require renewed capture approval after it changes. No team identifier is committed to the projects.

The Mac product is `.build/XcodeMac/Build/Products/Debug/Nocturne Server.app`; the simulator client is `.build/Xcode/Build/Products/Debug-iphonesimulator/Nocturne.app`.

## Tests

```sh
swift test
NOCTURNE_TEST_APP_WINDOWS=1 swift test --filter AppWindowTests/testNativeWindowCaptureAndResize
bash scripts/test-microphone-driver.sh
NOCTURNE_ENGINE_EXECUTABLE="$PWD/.build/XcodeMac/Build/Products/Debug/Nocturne Server.app/Contents/MacOS/nocturne-stream-host" swift test
```

The command with `NOCTURNE_ENGINE_EXECUTABLE` starts a real engine on its standard ports: stop the Mac app first. It verifies authenticated administration, application-library initialization, individual removal from a two-device roster, persistence across restart, reset, and shutdown. Other tests use real TLS connections, PTYs, and files; they check wrong-key rejection, certificate/signature binding, single-use invitation handling, one-device revocation while another connection and shell remain active, permission revocation, multiple terminal tabs, commands completing while disconnected, reconnect without duplicate output, retained exit output, bounded scrollback, per-device terminal ownership and limits, detached-shell cleanup, bounded framing, transfer integrity, cancellation, traversal/symlink rejection, and no-overwrite races.

To verify Dock behavior, launch the built Mac app and choose **Start server**, then run:

```sh
NOCTURNE_RUNNING_SERVER_APP="$PWD/.build/XcodeMac/Build/Products/Debug/Nocturne Server.app" \
  swift test --filter ServerDockTests
```

This read-only check requires both the main app and streaming helper to be running. It verifies that only the main app has a Dock icon and that it has finished launching. Run it again after Stop/Start to check helper replacement. The bundle defaults to `LSUIElement`; the main SwiftUI entry point explicitly adopts regular activation, while helpers retain background activation and the same app identity for capture permissions.

Client authorization and stream-stop regressions run in the actual iOS app (choose an installed simulator):

```sh
xcodebuild test -workspace Nocturne.xcworkspace -scheme Nocturne \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath .build/Xcode -parallel-testing-enabled NO \
  -only-testing:NocturneClientTests \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

To check pairing and switching between two real servers, prefix that command with `TEST_RUNNER_NOCTURNE_MULTI_MAC_INVITATIONS=/path/a.json:/path/b.json`. Each file is a private invitation JSON from a different running `WorkspaceServer`. Use a disposable simulator; the test pairs both, then forgets them.

See [verification notes](VERIFICATION.md) for build and device evidence and [implementation notes](IMPLEMENTATION.md) for ownership and protocol details.

Display sizing, ownership, authenticated disconnect, removal, and heartbeat expiry are included in `swift test`. Native display checks are opt-in because they change the Mac's real display layout:

```sh
NOCTURNE_TEST_DISPLAYS=1 swift test --filter testNativeVirtualDisplaysMatchRequestedPixelDimensions
NOCTURNE_TEST_DISPLAY_SWITCH=1 swift test --filter testNativeDisplayLeaseDisablesAndRestoresOriginalScreens
```

## Distribution

Distribution requires the corresponding source and applicable license notices, plus normal Apple signing/notarization for the intended channel. See the [release guide](RELEASING.md).
