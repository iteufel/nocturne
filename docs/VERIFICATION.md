# Verification — 18 October 2026

## Builds and package

- macOS Apple Silicon development build: passed, signed with the installed Apple Development identity.
- iOS simulator build: passed; installed on iPhone 18 Pro and iPad Pro simulators running iOS 27.
- Generic iOS arm64 build: passed with signing disabled. This checks compilation/linking, not installation on a physical device.
- `codesign --verify --deep --strict` passed on the final Mac application.
- Bundle inspection found **zero nested `.app` bundles**. `Contents/MacOS/nocturne-stream-host` is a direct child process of `Contents/MacOS/Nocturne Server`; its dependencies and assets are in Nocturne's own `Frameworks` and `Resources` directories.
- Shell syntax, Ruby project-generation syntax, and `git diff --check` passed. The upstream client checkout is unchanged; the generated Nocturne project is untracked inside the ignored dependency directory.

Local build logs: `/tmp/nocturne-mac-build.log`, `/tmp/nocturne-ios-build.log`, and `/tmp/nocturne-device-build.log`.

## Automated checks

Nine tests passed, zero failures, using the directly packaged server executable:

```sh
NOCTURNE_ENGINE_EXECUTABLE="$PWD/.build/XcodeMac/Build/Products/Debug/Nocturne Server.app/Contents/MacOS/nocturne-stream-host" swift test
```

Coverage includes actual TLS client/server connections, wrong-key rejection, a 450,000-byte bidirectional file transfer with byte comparison, a real PTY command and resize, permission revocation, upload cancellation, framing bounds, invitation validation, adaptive layout, traversal/symlink rejection, and atomic no-overwrite behavior. The engine integration test starts the real executable, authenticates its local administration API, verifies the desktop library, resets pairing, stops it, and starts it again. Log: `/tmp/nocturne-tests.log`.

## Live app checks

- Nocturne invitation links connected both simulators to the unified Mac server. Fresh iPad video pairing completed through the authenticated workspace channel without a separate server UI.
- Closed the Mac window and quit the final app. Process inspection found neither Nocturne nor its direct server child remaining; TCP ports 47984, 47989, 47990, 48010, and 48555 all rejected connections. Reopening and starting the app succeeded.
- After the user refreshed screen-recording permission, the direct executable successfully initialized H.264/HEVC VideoToolbox capture.
- Real Mac desktop video appeared on both simulators. Rotation retained the active stream. The Mac also initialized its system-audio tap and Opus encoder; audible playback was not measured.
- The iPad terminal opened the Mac's real shell. Typing `printf 'Nocturne terminal verified\n'` produced the expected remote output. Evidence: `artifacts/nocturne-ipad-terminal.png`.
- During a live iPhone stream, the Files panel listed the shared folder and downloaded `Nocturne verification.txt` (79 bytes). The native iOS share sheet offered Save to Files, then the panel displayed the received-file status. Automated tests separately verify upload and download integrity.
- Verification found and fixed missing SDL startup initialization, reconnecting an already-discovered streaming host, and compact landscape navigation/tools layout. These client integration paths were retested through the actual simulator UI.
- The final iPhone landscape build keeps live video beside the Files panel: `artifacts/nocturne-iphone-stream-files.png`. Host status updates now reflect the discovery worker's current state instead of retaining the initial Swift value snapshot; the Online card was verified before launching the final stream.

## Liquid Glass design pass

- Final signed macOS build, iOS simulator build, and generic unsigned iOS arm64 build all passed. Logs: `/tmp/nocturne-glass-mac-build.log`, `/tmp/nocturne-glass-ios-build.log`, and `/tmp/nocturne-glass-device-build.log`.
- Inspected the running macOS 27 application and iPhone 18 Pro/iPad Pro simulators on iOS 27. Verified light and dark appearance, native sidebar/tab selection, Settings, Add computer, Mac Overview/Sharing/Devices, and the terminal/files workspaces. iPhone portrait and landscape navigation both remained usable.
- Verified appearance selection through the actual native menus. Default appearance follows the system; explicit choices persist independently in each app. Apple glass APIs are availability guarded for iOS/macOS 26+, with native control/material fallbacks; older OS runtime appearance was not tested.
- The final iPad build displayed live Mac desktop video beside the terminal. Opening and closing the real shell worked. The 340-point tools panel initially wrapped shortcut text; compact keyboard symbols with full accessibility names fixed it, and the final panel was visually checked again.
- File browsing displayed the real shared test file. The glass Start/Stop controls started and stopped the unified Mac server. The server was stopped after verification and the apps were left open for review.
- Final Mac signature verification passed and bundle inspection again found zero nested `.app` bundles. The streaming executable remains directly managed by Nocturne Server.
- Screenshots: `artifacts/nocturne-glass-mac-dark.png`, `artifacts/nocturne-glass-iphone-dark.png`, and `artifacts/nocturne-glass-ipad-light.png`.

This pass changed presentation and appearance preferences. The nine protocol/engine tests above were run during the preceding functional verification; this pass used native builds and actual app interaction rather than adding tests that duplicate SwiftUI styling.

## Pairing authorization fix

- Reproduced live desktop streaming on an iPhone with no saved Nocturne workspace pairing. Its old streaming certificate and the server's paired flag were enough to open the library and construct a stream controller.
- Added six native iOS authorization tests. Before the fix, the cached-certificate regression failed both the published pairing-state assertion and the actual controller-creation assertion. After the fix, all six pass: missing approval, certificate/host binding and persistence, valid approval, forgetting followed by stale rediscovery, changed certificates, and delayed or already-paired callbacks.
- Live iPhone check: selecting the discovered Mac shows a PIN and no library/stream. Approving that PIN on the Mac opens the library and displays real desktop video. Forgetting the computer and selecting it again requires a new PIN. Both successful PIN exchanges left one server record for that certificate.
- Live iPad check: the private QR invitation on the LAN interface authenticated the workspace and completed video pairing automatically. **Forget paired Mac** removed both links. After relaunch, selecting the rediscovered computer again displayed a PIN, with no library or stream.
- Fresh certificates with the standard protocol client ID received XML status 401 from `/serverinfo`, `/applist`, `/launch`, and `/resume`. A connection without a client certificate failed TLS. These probes pinned the actual server certificate and did not weaken production validation.
- Updated the directly packaged runtime to the checksum-pinned official prerelease `v2026.1018.5342`. The previous release produced duplicate certificate records during re-pairing and then rejected that client. The corrected runtime removes the duplicate identity only after the PIN handshake succeeds. The executable is in `Contents/MacOS/nocturne-stream-host` so native permission checks resolve Nocturne's application identity; there is still no nested application.
- All nine Swift core/server integration tests passed against the updated executable, including authenticated start/reset/stop/restart. The six iOS tests passed on iPhone 18 Pro. macOS signed, iOS simulator, and generic unsigned iOS device builds passed. Final deep/strict signature validation passed, and bundle inspection found zero nested apps.
- Logs: `/tmp/nocturne-pairing-green.log`, `/tmp/nocturne-pairing-core-tests.log`, `/tmp/nocturne-pairing-device-build.log`, `/tmp/nocturne-pairing-mac-build.log`, `/tmp/nocturne-pairing-ui-gate.log`, `/tmp/nocturne-pairing-ui-forget.log`, and `/tmp/nocturne-pairing-ipad-forget.log`.

**Open runtime issue:** two live disconnect checks on this Mac hung in system audio capture. The crash report places `session::audio` inside Core Audio's `AudioDeviceStart`; the runtime terminates after its 10-second session-shutdown watchdog. Video and pairing worked, but clean stream disconnect and audible output are not verified on this runtime/environment. The automated lifecycle test does not start audio/video capture and therefore does not cover this hang. No certificate checks or audio functionality were disabled to hide it. The test server was stopped after verification.

## Individual device management

- The Mac Devices page lists saved streaming identities and authenticated workspace connections, merged by certificate fingerprint. The list loads while stopped, refreshes live, and has a separate confirmed Remove action for each device. Stream-only devices are labeled Paired; Connected refers to an open workspace connection, not a claim about live video activity.
- Workspace protocol 2 adds certificate proof bound to a fresh TLS-session challenge. Single-use, five-minute enrollment tokens replace unrestricted enrollment with the shared transport key. Removed devices cannot reuse a saved invitation; interrupted removals are persisted and can be retried.
- All 13 Swift tests passed with the real packaged engine. Added proof/replay rejection, duplicate-name identity separation, single-use invitation and interrupted-removal persistence, and a real TLS two-device revocation test. That test opens multiple sessions and a partial upload for one identity, removes it, verifies cleanup, keeps the other device’s connection and PTY alive, then verifies denial after restart. The engine test removes one of two distinct certificates with the same name and confirms the other remains enabled across restart. An intermittent “address already in use” failure in the restart test led to waiting for NWListener cancellation before returning from Stop. The full suite and ten additional runs of the revocation/restart test passed afterward.
- All six native iOS pairing-authorization tests passed. Signed macOS, simulator iOS, and generic unsigned iOS device builds passed. Mac deep/strict signature verification passed; there are zero nested applications and the direct streaming executable remains in Contents/MacOS.
- Live UI verification used the iPhone 18 Pro and iPad Pro simulators. Both appeared as separate Connected rows in the Mac app. Removing the iPad through its own row removed only that row and closed its terminal. The iPhone remained connected and ran `printf "other-device-still-connected\\n"` in its existing shell. The removed iPad’s Reconnect action was denied with “This device is no longer paired. Scan a new code in Nocturne Server → Devices.”
- Evidence: `artifacts/nocturne-devices-connected.png`, `artifacts/nocturne-devices-after-removal.png`, and `artifacts/nocturne-devices-ipad-revoked.png`. Logs: `/tmp/nocturne-devices-tests.log`, `/tmp/nocturne-devices-client-tests.log`, `/tmp/nocturne-devices-mac-build.log`, and `/tmp/nocturne-devices-device-build.log`.
- The final Mac build was reopened on Devices with the server stopped. Only the remaining iPhone was listed; the iPad removal persisted. All server ports were closed, and private QR test files were deleted.
- Live video termination was not revalidated in this pass. The Core Audio shutdown hang documented above remains relevant when removing a device during active streaming. This pass verifies workspace-session termination and the actual engine’s per-device disable/unpair administration, without claiming that the audio hang is fixed.

## Terminal tabs, disconnect persistence, and Mac Settings

- Removed the app-owned Escape/Tab/Control-C/arrow strip. SwiftTerm’s built-in keyboard accessory remains. Added up to eight independent tabs per device, individual close buttons, horizontal overflow, focus transfer, retained finished output, and the same tab UI inside the stream tools panel.
- Workspace protocol 3 moves PTY ownership to the Mac’s `TerminalRegistry`. Disconnecting only detaches output subscribers. Reconnect lists the device’s existing tabs and resumes output by byte offset, retaining the most recent 512 KiB per tab. Closing a tab, disabling Terminal, removing its device, or stopping/quitting the server terminates the affected shells. Persistence is in memory and does not span server restarts.
- All 16 shared/server Swift tests passed with the real packaged streaming executable. Three new real TLS/PTY tests cover distinct shell PIDs, preserved variables/directories, commands completing while disconnected, recovery in a new client instance, replay without duplicates, bounded history and renderer reset after a replay gap, final output after exit, cross-device access denial, limits across reconnect, individual close, and detached cleanup on removal/permission revocation/Stop.
- Live background verification exposed a socket cancellation race: a weak queued cancellation could outlive the client’s channel reference and leave the host connection registered. The new disconnect assertion failed before the fix and passed afterward; cancellation now retains the channel through shutdown. UIKit scene delegate callbacks explicitly detach on background and restore on activation instead of depending on the hosted SwiftUI environment’s scene phase.
- iPhone 18 Pro and iPad Pro simulator checks opened two independent tabs, sent commands, quit/relaunched the apps, and restored the same shell PIDs and environment variables. Delayed commands completed while both mobile apps were closed and appeared on reconnect. On the final build, sending iPhone to Home reduced the Mac’s connected count while the shell kept running; returning restored the selected tab and its delayed output. Creating/closing a third phone tab left the second shell running. Closing the iPad’s first tab preserved its second tab. The built-in keyboard accessory remained without the duplicate strip.
- The Mac toolbar has no Appearance control. Nocturne Server → Settings… and Command-comma open the native Settings window. Light/Dark changes were checked visually and the original Dark preference restored. Settings is also linked from the menu bar extra.
- All six native iOS pairing-authorization tests passed again after the lifecycle changes. Final signed macOS, iOS Simulator, and generic unsigned iOS device builds passed. Deep/strict Mac signature verification passed and the bundle contains no nested apps.
- Evidence: `artifacts/nocturne-mac-settings.png`, `artifacts/nocturne-terminal-phone-restored.png`, `artifacts/nocturne-terminal-ipad-restored.png`, and `artifacts/nocturne-terminal-background-return.png`. Logs: `/tmp/nocturne-terminals-all-tests.log`, `/tmp/nocturne-terminals-persistence-tests.log`, `/tmp/nocturne-terminals-disconnect-red.log`, `/tmp/nocturne-terminals-client-tests.log`, `/tmp/nocturne-terminals-mac-build.log`, `/tmp/nocturne-terminals-ios-build.log`, and `/tmp/nocturne-terminals-device-build.log`.
- Temporary QR files and command markers were deleted. The test iPad enrollment was removed to restore the prior roster, and the server was stopped to clean up verification shells. Active video/audio streaming and physical accessories were not revalidated in this pass; the audio shutdown issue above remains open.

## Remaining device checks

Physical iPhone/iPad/iPhone Duo testing, Bluetooth keyboard/mouse/controller input, audible output, HDR, sustained latency, and network interruption/recovery have not been verified. The installed SDK has no dedicated Duo simulator; layouts use scene dimensions and native size classes without inventing a hinge API.

This Mac has no Virtual HID Broker driver, so macOS gamepad emulation is unavailable until a compatible driver is installed. Controller forwarding is integrated in the client. These are development builds, not an App Store/TestFlight or notarized distribution.
