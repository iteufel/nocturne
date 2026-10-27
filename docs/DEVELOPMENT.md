# Development

Build and test Nocturne locally. For signed releases and TestFlight automation, see the [release guide](RELEASING.md). For app setup, see the [usage guide](USAGE.md).

## Build

Targets iOS 17+ and macOS 14+ on an Apple Silicon Mac. Build with Rust 1.91+ (rustup), Xcode 27.1 or newer and Ruby's `xcodeproj` gem. The Duo bar integration uses public iOS 27.1 SDK APIs behind runtime availability checks.

```sh
gem install xcodeproj -v 1.27.0
brew install cmake pkgconf miniupnpc openssl@3
./scripts/bootstrap.sh
open Nocturne.xcworkspace
```

Bootstrap fetches pinned client/terminal sources and the checksum-verified streaming engine, then generates both Xcode projects. `Vendor/` contains build dependencies and is intentionally ignored by Git. The generated workspace and dependency lock are included.

Use `scripts/bootstrap.sh mac`, `ios-simulator`, or `ios-device` to compile only the Rust transport slice needed for that build. The simulator shortcut targets Apple Silicon. Client-only bootstrap also skips downloading the Mac streaming runtime. The default `all` prepares every supported slice, including Intel simulators; rerun it when switching between Mac and iOS development in the same checkout.

CI caches Cargo dependencies per job and Apple platform, and shares Docker build layers between broker verification and publication. The client job boots its disposable iPhone and iPad while one `build-for-testing` compiles the app, then runs both device suites sequentially with `test-without-building`. Run `python3 scripts/tests/test-build-orchestration.py` to check target selection, build reuse, and simulator cleanup without starting a simulator.

Mac builds run `scripts/build-streaming-engine.sh` to compile the pinned Sunshine source with Nocturne's VideoToolbox correction and locked-screen display selection. The CMake overlays leave the upstream checkout unchanged. Sources and incremental build output live in `.build/SunshinePerformanceSource` and `.build/SunshinePerformanceBuild`. Runtime assets and shared libraries come from the verified release; Homebrew provides build tools and headers. The first build downloads and compiles additional dependencies.

Choose the **Nocturne** scheme for iPhone/iPad or **Nocturne Mac** for macOS. Both apps are named Nocturne. Select your development team in Xcode when installing on physical devices. Command-line development builds:

```sh
./scripts/build.sh ios
./scripts/build.sh mac
```

For stable macOS permissions across local rebuilds, use your Apple Development identity and team:

```sh
NOCTURNE_SIGNING_IDENTITY='Apple Development' NOCTURNE_DEVELOPMENT_TEAM='<your team ID>' ./scripts/build.sh mac
```

Without these variables the build is ad-hoc signed; macOS may require renewed capture approval after it changes. No team identifier is committed to the projects.

The Mac product is `.build/XcodeMac/Build/Products/Debug/Nocturne.app`; the simulator client is `.build/Xcode/Build/Products/Debug-iphonesimulator/Nocturne.app`.

## Tests

Chat protocol fixtures run with `swift test --filter ChatTests`. They exercise real stdio processes, Codex legacy and paginated history, ACP replay and capability negotiation, streaming, approvals, cancellation, and authenticated chat revocation. The optional `NOCTURNE_TEST_CODEX=1 swift test --filter ChatTests/testInstalledCodexHistoryReadOnly` checks the installed Codex's local history without starting or resuming an inference turn.

Developer workspace tests run with `swift test --filter 'DeveloperWorkspaceTests|ForgeTests|ChatTests'`. Temporary real repositories cover staging/unstaging, unusual paths, renames, branch comparisons, isolated worktree creation and stale/symlink-safe edits. The authenticated server test verifies thread-directory binding and permission/active-turn guards. `DeveloperClientTests` in the simulator exercises model/worktree/changes/PR flows over real TLS with deterministic media-free forge responses. PR edits are tested with structured payloads and stale-write rejection without modifying real PRs.

Workspace network fixtures bind port `0`, wait for readiness and read `listeningPort`. This avoids collisions with other fixtures and system ephemeral connections; the application's configured listening port is unaffected.

`ChatNavigationTests` covers provider/Mac preference isolation, snooze expiration, draft persistence, exact slash-command routing and bounded PR-agent context. Repository tests commit in disposable checkouts, reject stale index previews, preserve unstaged files and push only to a temporary local bare repository. Forge creation/activity tests use adapters with structured fixture replies; live forge checks only read actual PRs, comments and diffs. Regenerating the Xcode projects must preserve the microphone description and audio background mode needed by Codex voice.

On a Duo vertical-bar scene, `DeveloperClientTests/testNativeChatCanvasScreenshot` also verifies that the actual `ClientRootView` keeps its navigation-managed bar visible and registers the conversation/PR mode actions there. This regression fails when chat hides the system bar and draws an inset duplicate rail. Check screenshots and interactions in cover, open and rotated poses as well; a passing protocol suite alone does not establish correct Duo bar placement.

`NOCTURNE_TEST_CODEX_MODELS=1 swift test --filter ChatTests/testInstalledCodexModelSelectionWithoutInference` tests the installed Codex catalog and settings update on an ephemeral thread without inference. Live forge checks are read-only and require existing Mac CLI authentication:

```sh
NOCTURNE_TEST_FORGES=1 \
NOCTURNE_TEST_GITHUB_REPO=/path/to/github/checkout \
NOCTURNE_TEST_AZURE_REPO=/path/to/azure/checkout \
swift test --filter ForgeTests/testInstalledGitHubAndAzureDevOpsReadOnly
```

On 2026-10-27 both GitHub and Azure DevOps Cloud checks passed for PR listing, details, changed files and a real file diff. Closed PRs are included so a repository without an open PR can still be validated. Azure DevOps Server compatibility is not established by the cloud check.

Voice signaling and diagnostic checks run with `swift test --filter VoiceAudioTests`. The iOS `VoiceChatClientTests` use a real authenticated TLS fixture and an injected media peer to verify offer/answer routing, media readiness, mute, stale leases, failure cleanup, background continuity, cancellation, the real `ClientModel.suspend()` path and native controls. These fixture tests do not call an AI service or record a microphone.

`NOCTURNE_TEST_CODEX_WEBRTC=1 swift test --filter ChatTests/testInstalledCodexWebRTCWithChatGPTSignIn` generates a real native WebRTC offer and opens an ephemeral thread through the installed Codex App Server. It requires a Codex-managed ChatGPT login, strips Platform-key environment variables, and checks the actual v3 SDP-answer notification. It fails on authentication/access/protocol errors rather than skipping or switching to an API key. It stops before enabling microphone capture. `NOCTURNE_TEST_CODEX_VOICE=1 swift test --filter ChatTests/testInstalledCodexVoiceCatalogReadOnly` checks the voice catalog without inference.

Run `python3 scripts/check-codex-webrtc.py --report /tmp/nocturne-webrtc-verification.json` for the real audio/agent check. It needs macOS `say`, `ffmpeg` and Python `aiortc==1.13.0` (install that optional test dependency in a temporary virtual environment). It creates a disposable directory and ephemeral thread, sends synthetic microphone speech, checks the actual file-read output and spoken answer, then closes the call. It exits nonzero on incomplete evidence. Reports contain no OAuth tokens, SDP or authentication headers.

On 2026-10-27, this harness with **Codex 0.164.0**, `account/read → chatgpt`, no `OPENAI_API_KEY`/`CODEX_API_KEY`/`AZURE_OPENAI_API_KEY`, and Nocturne's own client identity successfully negotiated v3. The inherited development-environment identity override was explicitly removed. Synthetic speech asked Codex to read a disposable file; the backing agent executed the read, returned **427**, and the voice agent spoke that number. The successful run received 1,098 audio frames, including 349 audible frames, with 1,216 sent and 1,102 received RTP packets. The unconfigured WebRTC v1 attempt was rejected with `invalid_quicksilver_alpha_header`; source inspection identified the required v3 setting. No request identity or attestation was forged. Native iPhone microphone/speaker quality and physical locked-screen operation remain separate device checks.

```sh
swift test
swift test --filter MacClientTests
NOCTURNE_TEST_APP_WINDOWS=1 swift test --filter AppWindowTests/testNativeWindowCaptureAndResize
bash scripts/test-microphone-driver.sh
bash scripts/test-stream-audio.sh
bash scripts/test-stream-video.sh
python3 scripts/test-stream-capture.py
NOCTURNE_ENGINE_EXECUTABLE="$PWD/.build/XcodeMac/Build/Products/Debug/Nocturne.app/Contents/MacOS/nocturne-stream-host" swift test
```

The command with `NOCTURNE_ENGINE_EXECUTABLE` starts a real engine on its standard ports: stop the Mac app first. It verifies authenticated administration, application-library initialization, individual removal from a two-device roster, persistence across restart, reset, and shutdown. Other tests use real TLS connections, PTYs, and files; they check wrong-key rejection, certificate/signature binding, single-use invitation handling, one-device revocation while another connection and shell remain active, permission revocation, multiple terminal tabs, commands completing while disconnected, reconnect without duplicate output, retained exit output, bounded scrollback, per-device terminal ownership and limits, detached-shell cleanup, bounded framing, transfer integrity, cancellation, traversal/symlink rejection, and no-overwrite races.

`ServerLifecycleTests` and `ServerSettingsTests` cover startup from the saved Sharing toggles, pending edits, Apply/Discard, restart cancellation, login-item approval and registration errors, independent sharing capabilities, and offline video revocation. They use isolated preferences, temporary files, real TLS listeners on test ports, and a failing child executable to verify automatic screen-sharing recovery while a workspace stays connected. Login-item registration is substituted; these tests do not change your Login Items, capture your screen, or verify an actual logout/login.

`test-stream-capture.py` needs the pinned engine source fetched by a Mac build, or `NOCTURNE_ENGINE_SOURCE=/path/to/Sunshine`. It generates the production CMake overlays and checks rejected capture outputs and encoder probes, reconnects, and display changes under AddressSanitizer and UBSan. On macOS it also runs the actual callback registration and delivery methods with manual reference counting against a simulated AVFoundation queue, checking callback lifetime and teardown. It never captures a real screen. The C++ checks also run on Linux with CMake and a C++17 compiler. `--baseline` reproduces the pinned engine's nil-semaphore failure.

To verify Dock behavior, launch the built Mac app, enable **Sharing → Screen sharing**, and apply, then run:

```sh
NOCTURNE_RUNNING_SERVER_APP="$PWD/.build/XcodeMac/Build/Products/Debug/Nocturne.app" \
  swift test --filter ServerDockTests
```

This read-only check requires both the main app and streaming helper to be running. It verifies that only the main app has a Dock icon and that it has finished launching. Run it again after disabling and re-enabling Screen sharing to check helper replacement. The bundle defaults to `LSUIElement`; the main SwiftUI entry point explicitly adopts regular activation, while helpers retain background activation and the same app identity for capture permissions.

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

`test-stream-audio.sh` compiles the generated audio callback with deterministic codec/output boundaries under AddressSanitizer and UBSan. It checks delayed packets, stalled output, startup/underrun buffering, Wi-Fi arrival jitter, and 2.5–20 ms Opus packets. Run `ruby scripts/generate-project.rb` after changing an overlay. To compare against the pinned baseline, pass `Vendor/moonlight-ios/Limelight/Stream/Connection.m` to the script; the unfixed callback fails these checks. `StreamPlaybackTests` exercises the real iOS display link during touch tracking and after shutdown. Neither test substitutes for listening and watching a real device over Wi-Fi.

`test-stream-video.sh` replays periodic Wi-Fi bursts against the production pacing policy under sanitizers. It checks recovery, bounded queue age, unchanged low latency on a steady connection, 30/60/120 fps, and mismatched display refresh rates. Pass `--baseline` to compare the original drain-every-frame behavior. Both audio and video replays include the physical iPad's measured 130 ms interruptions at 30 fps. The 120 fps replay uses a shorter interruption because the upstream decoder queue holds only 15 frames; the adaptive cushion is capped at 12 frames to keep priming reachable.

On an Apple Silicon Mac with hardware encoding available, `bash scripts/test-stream-encoder.sh` verifies that H.264 and HEVC preserve every frame timestamp at the physical iPad's 3200 × 2400 / 30 fps / 5 Mbps settings, including repeated recovery keyframes. Install FFmpeg development libraries with `brew install ffmpeg`, or point `PKG_CONFIG_PATH` at compatible libraries. `--baseline` selects the original encoder flags to reproduce frame dropping. This hardware check is opt-in; it is not a simulator playback test.

After a Mac build has fetched the pinned engine source, `bash scripts/test-stream-lock-screen.sh` compiles its generated macOS display selection and capture callback under AddressSanitizer and UBSan. It checks connecting while locked, switching an active stream across lock/unlock, main-display changes, headless capture, and inactive user sessions. `--baseline` exercises the pinned upstream code and reproduces the missing capture transitions. The test substitutes the OS capture boundary and does not lock your Mac or type any keys. `swift test --filter DisplayTests` also verifies that locked sessions can acquire/release a display lease while logged-out and inactive sessions remain rejected.

Display sizing, ownership, authenticated disconnect, removal, and heartbeat expiry are included in `swift test`. Native display checks are opt-in because they change the Mac's real display layout:

```sh
NOCTURNE_TEST_DISPLAYS=1 swift test --filter testNativeVirtualDisplaysMatchRequestedPixelDimensions
NOCTURNE_TEST_DISPLAY_SWITCH=1 swift test --filter testNativeDisplayLeaseDisablesAndRestoresOriginalScreens
```

## Distribution

Distribution requires the corresponding source and applicable license notices, plus normal Apple signing/notarization for the intended channel. See the [release guide](RELEASING.md).
