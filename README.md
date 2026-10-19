# Nocturne

A native SwiftUI workspace for streaming your computer to iPhone and iPad, with an interactive terminal and file transfer. **Nocturne Server is one macOS application.** It runs the Sunshine server executable directly as a managed child process and owns its lifetime, configuration, authentication, and pairing. There is no nested Sunshine.app, separate companion, Sunshine installation, or web setup step.

## Run

Download the signed and notarized Mac server from [GitHub Releases](https://github.com/iteufel/nocturne/releases).
Quit any older server, unzip the download, and move **Nocturne Server.app** to Applications.
GitHub builds, Mac releases, and TestFlight automation are documented in [the release guide](docs/RELEASING.md).

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

## Connect

1. Open **Nocturne Server** and select **Start server**. Allow screen/system audio capture and Accessibility for input when macOS asks. These permissions belong to Nocturne Server.
2. In **Sharing**, enable terminal/file access if wanted and choose the shared folder. Both features start disabled. Configure displays in **Nocturne Server → Settings…** while the server is stopped.
3. Choose **Pair a device**. On iPhone/iPad, choose **Add computer → Scan QR code** and scan the Mac's screen. Pairing completes automatically, including video, through the authenticated connection. Each QR code enrolls one device and expires after five minutes.
4. Choose **Desktop** to stream. Swipe inward from the right edge of the stream to open its controls. The menu opens terminal/files alongside the video. On large windows they appear to the side; smaller windows use a bottom panel.

Nearby computers are discovered automatically. Selecting an unpaired computer opens QR pairing. New devices must scan a QR code from Nocturne Server; manual PIN entry, address-based pairing, pasted links, and external pairing links are not supported. Already paired computers remain available.

Paired Macs are rediscovered when their IP address changes, including after moving both devices to another local network. Update both apps for workspace discovery by a stable pairing identity; existing QR pairings continue to work without scanning again. The client retries workspace connections while foregrounded and saves the authenticated address for video, terminal, files, and microphone access. Remote access is disabled by default, with `https://nocturne.alkal.de` preconfigured as the broker. For access from other networks, enable **Remote access** in the Mac server settings, keep the default broker or enter your own, and scan a new QR code. Nocturne tries local connections first, then uses an encrypted Rust transport that attempts peer-to-peer NAT traversal with relay fallback. See [online broker setup](docs/REMOTE_ACCESS.md). An interrupted video stream or file transfer must be started again.

Selecting a discovered computer requires explicit pairing approval before its library or desktop can open. Cached streaming certificates alone cannot grant access. A new video pairing is saved only after both QR workspace authorization and the streaming handshake succeed. **Forget computer** removes its streaming approval, and forgetting the paired Mac also removes its linked video connection.

## Mac apps in iPad windows

Choose **Apps** in the client's sidebar or tab bar to browse the paired Mac's installed applications, with their icons and open windows. Tap an app to launch it; when it has several windows, choose the one to share. Long-press an app to open a particular existing window directly. Refresh the list after opening or closing windows on the Mac.

On iPad, each selected Mac window opens in a separate native Nocturne window. Use iPad windowing or Stage Manager to arrange several side by side. Selecting an already open stream returns to its existing iPad window. Up to four app windows per device (eight across the host) can stream independently. iPhone opens one app window inside the client.

Only the selected window is captured, including when another app covers it on the Mac. Resizing the iPad window resizes that actual Mac window in points and updates Retina video without restarting the desktop engine or other streams. Mac apps may enforce a minimum window size; Nocturne preserves the resulting aspect ratio. Touch, dragging, right-click by holding, two-finger scrolling, hardware keyboards/mice, and the toolbar's software keyboard control the selected window. Closing the stream leaves the app running and restores its original window size unless it was manually resized on the Mac. Backgrounding releases that scene's capture; returning reconnects it.

Both apps must support app windows. The Mac server needs **Screen Recording** and **Accessibility** permission. Apps without an open, capturable, resizable window report an error. App streams currently carry H.264 video and input; audio, game controllers, other windows, app menus, and separate dialog windows are not included. Desktop streaming remains available for those uses. Individual window control uses a runtime-checked macOS window-ID bridge in the directly distributed server.

**Devices → Your devices** lists paired streaming devices and connected workspaces by name, with a separate **Remove…** action for each. Removing one device closes its terminal/file sessions, disables its active stream, and revokes its pairing without disconnecting the others. Saved devices remain visible while the server is stopped. “Connected” indicates an open workspace connection; streaming-only clients are shown as “Paired”.

One **Stop server** stops capture, streaming, terminal sessions, and transfers. Quitting the Mac app stops its child engine. **Reset all pairing** revokes video certificates and rotates the workspace key together.

## Adaptive and headless displays

On iOS, choose **Settings → Resolution → Match device** (the default for new installations). With the Mac server stopped, enable **Nocturne Server → Settings → Displays → Headless virtual monitor**, then start the server and pair using its QR code. Nocturne creates a Retina virtual display with the same pixel dimensions as the client's video area. Rotation, iPad window resizing, and opening the stream's tools panel update that size automatically. Video briefly reconnects to negotiate the new resolution; terminal tabs stay running. Dimensions are even and capped at 4096 pixels per side while preserving aspect ratio. Fixed resolution choices remain available. Match device reports missing display control instead of silently scaling video over an unchanged desktop.

Enable **Turn off connected Mac displays** before starting the server to move the Mac's windows onto the streamed desktop. The virtual display becomes the only active monitor. Disconnecting, backgrounding the client, removing its device, or stopping the server restores the saved display modes and arrangement. A missing client heartbeat releases the display after 20 seconds. **Restore Mac displays** is also available in the Mac menu bar. An internal recovery process restores monitors if the main server app exits unexpectedly.

The same virtual display supports a headless Mac without an HDMI dummy plug or separate display app. It stays available between streams until the server stops, including when physical screens are connected. Physical screens keep their layout unless the separate monitor-off option is enabled. The Mac must be awake with a logged-in desktop; Nocturne does not unlock FileVault or bypass the login screen. Turn off **Headless virtual monitor** to select a physical monitor instead; choose a fixed resolution on iOS in that mode. Existing physical-monitor selections remain unchanged after upgrading. Automatic Mac display control requires the authenticated Nocturne workspace connection, and only one stream can own it at a time.

Virtual display creation and monitor disabling use runtime-checked private macOS interfaces. These features are intended for the directly distributed Mac app, not a Mac App Store build. If unavailable on a macOS release, the app reports the failure and a connected display can be selected instead.

## Devices and input

- Native Apple Liquid Glass on iOS/iPadOS 26+ and macOS 26+: floating tabs, system sidebars/toolbars, glass action buttons, and stream controls. Earlier systems use native bordered controls and materials. Choose System, Light, or Dark in Nocturne → Settings → Appearance on iOS, or **Nocturne Server → Settings…** (⌘,) on macOS. Content surfaces honor Reduce Transparency; the terminal and video retain a dark canvas.
- iPhone and iPad: native tabs, sidebar navigation, rotation, Split View/window resizing, safe areas, and a persistent stream workspace with automatic resolution renegotiation. Stream controls stay hidden until you swipe inward from the right edge; there is no floating button or persistent bar. A brief hint explains the gesture when a stream starts, and VoiceOver offers an Open stream controls action.
- **Settings → Stream display → Fill entire screen**, also available in the live controls menu, switches between safe-area fit (the default) and the entire display. Safe-area fit keeps video clear of the camera, rounded corners, and home indicator. The choice is saved, applies immediately, and follows rotation and tools-panel resizing. Match device briefly reconnects when the video dimensions change; fixed resolutions retain their aspect ratio.
- iPhone Duo: responds to the actual scene size for compact/expanded layouts. There is no invented hinge API or second-phone controller mode. Dedicated Duo hardware verification is still required.
- Choose **Settings → Controls → Input mode → Touch or Trackpad**, or change it from the stream controls menu while connected. Touch clicks where you tap; hold for a right-click or move your finger to drag. Trackpad moves the pointer with one finger, taps to click, uses a two-finger tap for right-click, and scrolls with two fingers. Hold one finger before moving to drag. A three-finger tap opens the keyboard. The choice is saved and changes immediately without reconnecting the video.
- Bluetooth keyboards, mice, trackpads, and MFi/Xbox/PlayStation controllers use native input. Pair accessories in iOS Settings. Mouse/trackpad accessories work in either input mode, including UIKit input when pointer lock is unavailable in a window or Split View.
- The bundled engine uses VideoToolbox for H.264/HEVC, with client controls for resolution, bitrate, frame rate, HDR, pacing, touch input, and statistics. Hardware and network conditions determine supported combinations.
- macOS gamepad emulation requires a compatible **Virtual HID Broker** installation/driver. Nocturne includes controller forwarding; this Mac does not have that driver. Physical controller forwarding, latency, HDR, and system-audio playback require device testing.

## Microphone and voice chat

Forward the iPhone/iPad microphone (including its current wired, USB, or Bluetooth headset input) to Discord or a game **on the Mac**:

1. In **Nocturne Server → Sharing**, choose **Install microphone input…**, approve the macOS administrator prompt, and restart the Mac. The driver is bundled with Nocturne Server; no separate audio-routing app is needed.
2. Enable **Client microphone** in Sharing. Pair the client using the Nocturne Server QR code and reconnect it after enabling this feature.
3. In Discord or your game’s audio settings, choose **Nocturne Microphone** as the input. Keep the game’s output on its normal device so it continues through the video stream.
4. Start a stream, swipe inward from the right edge, enable **Microphone** in Stream controls, and allow iOS microphone access. The toggle shows capture status; turn it off to mute.

Each stream starts muted. Backgrounding, disconnecting, changing audio devices, audio interruptions, or a video reconnect during resizing mutes it again. Unmute explicitly to resume. One client can own the Mac input at a time. Disabling Client microphone, removing the device, or stopping the server flushes its audio. Use headphones to reduce game-audio feedback; Bluetooth hands-free microphone use may lower playback quality.

This feature requires both Nocturne apps and an authenticated workspace connection; standard Sunshine/GameStream-only hosts do not expose it. Traffic is encrypted, uses a separate socket from terminal/files, and is not recorded. The input driver stays available to Mac apps and produces silence while muted. It does not change the Mac’s default input or output.

The installation is `/Library/Audio/Plug-Ins/HAL/NocturneMicrophone.driver`. To uninstall, move only that bundle to Trash using Finder with administrator approval, then restart the Mac. Driver installation/restart is a user action; building or running tests does not install it.

## Terminal and files

The terminal is SwiftTerm connected to a real `/bin/zsh -l` PTY on the Mac. Open up to eight independent tabs with **+**, switch between them, and close a single shell with its tab’s **×**. Tabs are available in both the Terminal workspace and the stream tools panel. Escape, Tab, Control, and arrows come from the terminal keyboard’s built-in accessory; there is no duplicate shortcut strip.

Shells and running commands stay on the Mac when the mobile app backgrounds, disconnects, or quits. Reconnecting restores the same tabs, working directories, shell variables, and buffered output (the latest 512 KiB per tab). Finished shells remain readable until you close their tabs. The Mac server must stay running: closing a tab, disabling Terminal, removing its device, stopping the server, or quitting the Mac app ends the affected shells. Sessions do not survive a Mac/server restart.

File transfer is bidirectional, chunked, cancellable, and restricted to the selected shared folder. Uploads remain invisible until committed and cannot overwrite an existing file. Symlinks, path traversal, and non-regular files are rejected with descriptor-based filesystem operations. Downloads use the native iOS share sheet, including Save to Files; uploads use the native document picker and file URL drop support.

The paired Mac also appears in Apple’s **Files** app. Enable **File sharing** on the Mac and pair or reconnect Nocturne, then open **Files → Browse → Locations → Nocturne**. Enable the location when asked. If it is hidden, use **More (…) → Edit** to enable Nocturne. Browse subfolders, preview documents, and copy files to your device or another app. The Mac must be reachable and Nocturne Server running; the extension connects independently while Nocturne is in the background. **Settings → Apple Files → Refresh Files location** retries registration after reconnecting.

The Files location provides browsing and downloads; send new files through Nocturne’s Files tab. Access stays inside the Mac’s chosen shared folder. Forgetting the paired Mac removes the location and its extension credentials; disabling File sharing blocks new reads immediately and removes the location when Nocturne reconnects. Copies already saved to your device remain available.

Pairing QR codes contain a private 256-bit transport key and a single-use enrollment token that expires after five minutes. Each device also proves possession of its own streaming certificate on every workspace connection; the proof is bound to that TLS session. A certificate alone cannot register a new workspace device, and a removed device cannot reuse the old shared key or invitation to regain access. Update both apps for workspace protocol version 4; an existing workspace-only pairing may need a fresh QR code. Keys are stored in Keychain, never in Bonjour or UserDefaults. Workspace traffic uses authenticated TLS-PSK; video uses the upstream pairing and encrypted transport implementation. Terminal access runs as the Mac user and is explicitly opt-in.

Streaming approval is stored separately in Keychain and bound to the computer ID and both certificates. Discovery and cached transport credentials cannot grant it. The direct server runtime is pinned to Sunshine `v2026.1018.5342`, an official prerelease containing the fix for duplicate certificate records when re-pairing; its download checksum is verified by bootstrap.

## Verification

```sh
swift test
NOCTURNE_TEST_APP_WINDOWS=1 swift test --filter AppWindowTests/testNativeWindowCaptureAndResize
bash scripts/test-microphone-driver.sh
NOCTURNE_ENGINE_EXECUTABLE="$PWD/.build/XcodeMac/Build/Products/Debug/Nocturne Server.app/Contents/MacOS/nocturne-stream-host" swift test
```

The second command starts a real engine on its standard ports: stop the Mac app first. It verifies authenticated administration, application-library initialization, individual removal from a two-device roster, persistence across restart, reset, and shutdown. Other tests use real TLS connections, PTYs, and files; they check wrong-key rejection, certificate/signature binding, single-use invitation handling, one-device revocation while another connection and shell remain active, permission revocation, multiple terminal tabs, commands completing while disconnected, reconnect without duplicate output, retained exit output, bounded scrollback, per-device terminal ownership and limits, detached-shell cleanup, bounded framing, transfer integrity, cancellation, traversal/symlink rejection, and no-overwrite races.

Client authorization and stream-stop regressions run in the actual iOS app (choose an installed simulator):

```sh
xcodebuild test -workspace Nocturne.xcworkspace -scheme Nocturne \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath .build/Xcode -parallel-testing-enabled NO \
  -only-testing:NocturneClientTests \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

See [verification notes](docs/VERIFICATION.md) for build and device evidence and [implementation notes](docs/IMPLEMENTATION.md) for ownership and protocol details.

Display sizing, ownership, authenticated disconnect, removal, and heartbeat expiry are included in `swift test`. Native display checks are opt-in because they change the Mac's real display layout:

```sh
NOCTURNE_TEST_DISPLAYS=1 swift test --filter testNativeVirtualDisplaysMatchRequestedPixelDimensions
NOCTURNE_TEST_DISPLAY_SWITCH=1 swift test --filter testNativeDisplayLeaseDisablesAndRestoresOriginalScreens
```

## License

GPL-3.0. Nocturne is an independent project built using the Moonlight iOS client, Sunshine, and SwiftTerm. Upstream names are retained in source attribution, not used as Nocturne's product name. See [third-party notices](THIRD_PARTY_NOTICES.md) and [LICENSE](LICENSE). Distribution requires the corresponding source and applicable license notices, plus normal Apple signing/notarization for the intended channel.
