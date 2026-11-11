# Headless capture and the locked desktop

## Sleeping and unplugged displays — November 11 follow-up

Retaining a virtual framebuffer did not cover sleep or a capture source that
stops delivering samples. A read-only local snapshot found a locked, signed-in
console session whose only reported display was inactive and asleep. Nocturne
also had no idle-system-sleep assertion between viewers.

The affected host is a Mac mini that remains online/Ready while the viewer keeps
connecting. The engine's `allow_encoder_probing()` applied a Windows DXGI guard
to macOS too: a nonempty catalog with only inactive displays was rejected before
`platf::display()` could call `wake_display()`. A focused regression using the
actual probe gate, probe entry and platform wake call failed on the pinned code.
The macOS overlay now allows that wake path to run before hardware validation;
other platforms retain the original guard. An unavailable display still fails
its hardware probe. Workspace readiness remains independent of video readiness.

The follow-up keeps a Foundation activity for the server's entire starting/running
lifetime, including idle time and streaming-engine recovery. Stop, startup failure
and destruction release it. Apple's [activity options](https://developer.apple.com/documentation/foundation/processinfo/activityoptions)
allow preventing idle system sleep without keeping a display powered on. This
does not override explicit system sleep or guarantee closed-lid MacBook hosting.

Both desktop transports now avoid selecting an inactive main-display ID or
WindowServer's headless placeholder over the requested virtual source. The engine
polls lock state, source changes, display sleep/wake and shutdown independently of
frame delivery. Encoder probing and waiting for the first sample have five-second
deadlines. Once a first sample arrives, an unchanged desktop has no frame-arrival
timeout. A display asleep for three seconds ends capture rather than repeatedly
waking it. All early exits retire the AVFoundation output and drain callbacks
before releasing the C++ callback state.

`bash scripts/test-stream-lock-screen.sh` reproduced the original infinite
encoder-probe wait with no samples. Its expanded deterministic regressions now
pass under ASan/UBSan. `python3 scripts/test-stream-capture.py --host-only` also
passes, including output cancellation with no samples and cancellation racing
sample delivery, plus wake-before-probe with an inactive display and preservation
of the non-Mac guard. The entire generated Objective-C capture implementation passes
an SDK syntax check. These use simulated OS media boundaries, not a real screen
capture or lock/unlock intervention. The hardware acceptance checks below remain
required for the rebuilt signed app.

On Xcode 27.2, an isolated XCTest bundle compiled the actual Shared, HostKit,
ServerModel and MacClient modules and ran the unmodified DeviceTests, DisplayTests,
ServerSettingsTests and MacClientTests files: **71 tests, 67 passed, four native
display tests skipped, zero failures**. The fixture used the repository's English
resources for assertions that match English messages, without changing system
language settings. Only unrelated Rust FFI entry points were aborting stubs; none
were invoked. A separate check of the production Foundation activity confirmed a
real `PreventUserIdleSystemSleep` assertion existed while held and disappeared
after release. Fixture commands and logs are under ignored `.build/HostVerification`
and `.build/verify-host.py`. Standard `swift test` remains blocked here by the
missing `Vendor/NocturneRemote.xcframework` and absent Rust toolchain. This is not a
full app/release build, remote-transport verification, or installation of the fix.

This is a separate headless/lock-screen fix, based on upstream main commit
`49ee687583adb5b82617cdc024f4bbdcf92cb861` (October 28, 2026), in the isolated
checkout `/private/tmp/nocturne-headless-lockscreen`. It must remain separate from
the CallKit, push, chat-status/approval and release-coordinator PRs. No merge,
release or inclusion in supervisor 01a183d8-b694-7802-bf82-fa9cb0d691e1's PR is authorized.

## Cause and change

`ServerModel.maintainScreenSharing` creates a startup virtual display and calls
`displays.restore()` after engine startup. Lease release, disconnect and heartbeat
expiry also call restore. Previously the native driver's restore unconditionally
destroyed its virtual monitor after restoring physical screens. On a headless Mac,
that removes the only usable framebuffer between streams. A subsequent preparation
creates another one; different requested dimensions also replaced an existing
framebuffer even under loginwindow. This is a code-level lifecycle defect consistent
with the reported failure, not a hardware reproduction of its entire cause.

The native driver now retains an active virtual display while the signed-in console
session has no other usable active display. Idle framebuffer ownership does not keep
authenticated control: the lease, heartbeat, size and device name still clear.
Existing placeholder filtering in `NDDisplayLayout.hasActiveDisplayOtherThan` is
reused; a WindowServer headless placeholder does not count as a usable monitor.
With another usable display the old removal behavior remains. Explicit Stop and
worker EOF release the monitor after physical-display restoration succeeds.

A preparation while locked reuses an existing active virtual display without
selecting its mode or replacing it. A lock arriving during replacement-mode
publication also preserves the old active framebuffer. Session availability and
operation revision are checked again after publication. Stale/inactive displays
are not reused. After unlocking, the next display preparation can apply the requested
mode. The prepare reply's `displayID` identifies the actual retained source;
`display` continues to acknowledge the requested streaming size, which the capture
encoder fits around the source. It does not assert a changed lock-screen resolution.

The existing main-display selection for loginwindow, AVFoundation locked capture,
ScreenCaptureKit ordinary capture, TCC preflight and Accessibility checks remain.
This patch does not grant permissions, create a login helper, change system security
or alter the running Mac's display/lock state for testing.

## Platform boundary

Apple documents [Remote Desktop control of a Mac without a display](https://support.apple.com/guide/remote-desktop/control-or-observe-one-client-computer-apd2450a787/mac).
That supports the user's ARD comparison, but is not a documented equivalence between
ARD's Remote Management service and an ordinary user-session capture app.

Apple's [AVCaptureScreenInput](https://developer.apple.com/documentation/avfoundation/avcapturescreeninput)
describes capture from a `CGDirectDisplayID` and recommends ScreenCaptureKit from
macOS 12.3 onward. Its [display initializer](https://developer.apple.com/documentation/avfoundation/avcapturescreeninput/init(displayid:))
can return nil for an unavailable display. Apple's [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
only processes complete frames. These docs, reviewed October 28, 2026, provide no
blanket guarantee of loginwindow capture or password entry by an ordinary app.
The existing runtime-resolved virtual-display API is private and remains OS-dependent.

A missing/blank/frozen image is a **capture failure**. A visible lock screen whose
keyboard/mouse input macOS rejects is an **input restriction**; preserving a
framebuffer does not establish that credentials can be entered. Accessibility
permission alone does not promise acceptance by a protected login surface. Nocturne
must not bypass either restriction. First login after reboot, FileVault preboot,
logout and another user's inactive session are outside this feature. The existing
signed-in/on-console guard remains, including after asynchronous mode publication.

## Verification and required hardware checks

`DisplayTests` adds deterministic regressions for headless idle startup, locked
reconnect at different requested sizes, release/socket/heartbeat cleanup, explicit
Stop, deferred mode application after unlock, monitor attachment, stale display
replacement, lock during publication and console-session loss during publication.
All framebuffer/layout objects in those tests are fakes. Existing opt-in native tests
remain disabled unless separately authorized. Normal CI command:

```sh
NOCTURNE_TEST_DISPLAYS=0 NOCTURNE_TEST_DISPLAY_SWITCH=0 swift test --filter DisplayTests
```

Local verification on Xcode 27.0: the actual Shared and HostKit Swift sources and
DisplayBridge/PTYBridge/MicrophoneBridge C sources compiled successfully. A standalone
XCTest bundle ran the unmodified `Tests/DisplayTests.swift`: **36 tests, 32 passed,
4 hardware tests skipped, zero failures**, including the real local TLS ownership
regression. The first sandboxed run could not open its local listener; the rerun with
loopback access passed. The fixture linked aborting stubs only for the unrelated
Rust remote-tunnel symbols; none were invoked. This is not verification of Rust
transport or the entire app build. Fixture commands/artifacts are in the isolated
checkout's ignored `.build/display-fixture/` directory.

`swift test --filter DisplayTests` itself could not proceed because
`Vendor/NocturneRemote.xcframework` is absent and no Rust toolchain is installed here.
The PR's normal macOS CI must supply that integration/build check. No dependency,
signing, TCC or system-permission changes were made to work around this.

Hardware acceptance is still required on the affected Mac mini with the actual
signed app and permissions already granted by the user:

1. Start unlocked with no monitor, leave the server idle, lock locally, connect and
   separately record video arrival and whether the visible login UI accepts input.
2. Lock/unlock an active stream; verify main-display capture and return to the
   requested virtual display. Repeat portrait/landscape requests while locked and
   a preparation after unlocking.
3. Disconnect/reconnect, let the heartbeat expire, and stop/restart the server.
   Verify lease revocation independently of retained idle framebuffer ownership.
4. With separate approval for each live display intervention, test monitor
   attachment/removal, display sleep/wake, and the optional physical-monitor-off
   preference. Confirm physical restoration and worker EOF cleanup.
5. Verify denial/revocation of Screen Recording and Accessibility yields a distinct
   permission/capture/input result without granting permissions automatically.

No real monitor creation/removal, sleep/wake, lock/unlock or credential entry was
performed for this fix. Existing earlier hardware notes in VERIFICATION.md are not
verification of this change. A server first started while already locked, with no
surviving usable framebuffer, may still be refused or produce blank capture by
macOS; retaining a framebuffer cannot repair an earlier absent user-session surface.
