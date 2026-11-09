# iOS agent calls

Voice sessions started in Nocturne are outgoing CallKit VoIP calls to **Nocturne Agent**. The existing paired-Mac signaling and Codex WebRTC media remain the transport; these are not cellular/PSTN calls. No default-calling-app or CarPlay entitlement is added. The existing microphone permission and audio background mode are retained.

`ClientVoiceCall` maps CallKit start/end/mute actions onto `ClientVoiceChat`. The app mute control requests the same system mute action, and the delegate changes the actual WebRTC audio track before fulfilling it. System hangup stops local media immediately, sends the existing voice-stop request and closes the dedicated voice connection. Host disconnects, provider resets, action failures/timeouts and media errors remove the system call as well. A new call is blocked while CallKit still has an active/ending call.

The media peer prepares `.playAndRecord` / `.voiceChat` with Bluetooth HFP and manual WebRTC audio. It does not activate the session itself. CallKit's `didActivate`/`didDeactivate` callbacks are forwarded to WebRTC's external activation API; playback/capture require both the SDP answer and system activation. Connected status additionally requires server acknowledgement and WebRTC readiness. CallKit manages the route, including the receiver, wired accessories and HFP; the integration does not force the speaker or A2DP. WebRTC's automatic audio configuration is aligned with this policy and restored after teardown.

Interruptions, audio-service resets and unexpected system deactivation end the voice session and ask the user to restart. There is no automatic recording restart after an interruption. Route changes are handled by the native WebRTC audio device; a route change alone is not treated as hangup. Actual route changes and audio quality still require device testing.

## Desktop streaming

The pinned SDL desktop-audio implementation independently changes shared audio-session activation. Starting voice therefore closes a desktop stream and awaits its complete teardown before preparing CallKit audio. Starting another desktop stream or its microphone during voice shows an instruction to end voice first. App-window video uses a separate path without SDL audio. This explicit restriction avoids a desktop close/background transition deactivating an otherwise established system call; concurrent desktop audio would require a separate SDL audio-ownership change.

## Lock screen and vehicles

CallKit supplies the system call UI and end/mute actions, including the locked-device call experience. The caller handle and localized name are **Nocturne Agent**. Presentation depends on iOS and device state; no custom lock-screen view is installed. Calls are excluded from Recents because this app has no standalone redial route to a particular Mac and conversation.

Bluetooth HFP makes compatible vehicle hands-free audio available. Vehicle firmware, Bluetooth metadata support and CarPlay decide which name, screen and controls appear. CallKit cannot guarantee a particular car display, button mapping, automatic route selection or a custom Nocturne CarPlay interface. No CarPlay app entitlement is requested.

## Incoming agent calls: deferred

The current protocol starts voice from an already open client conversation. There is no server-generated call invitation, acceptance/decline/expiry handling, PushKit registration, device-token store or APNs sender. Implementing reliable agent-initiated ringing is therefore a larger client/server feature and is intentionally omitted.

Apple supports background/locked-device incoming VoIP ringing through **PushKit + APNs + CallKit**. This requires the ordinary Push Notifications capability/`aps-environment` signing entitlement and matching provisioning, VoIP/background configuration, per-device token registration/revocation, an authenticated server invitation flow and APNs provider authentication/topic/environment configuration. A VoIP push must promptly report a real incoming call to CallKit, including when waking the app; it cannot be used as a generic background task. Ringing respects system policies such as Do Not Disturb. An active socket can carry an invitation while the app runs; it does not replace APNs for launching/waking a suspended or terminated app. No push credentials, capabilities or production configuration were created.

## Verification

The added `VoiceChatClientTests` fixtures cover system activation gating, real track mute delegation, system hangup/server stop, rejection before server voice start, deactivation/provider failure, busy-call guards and cancellation while awaiting desktop teardown. Existing voice fixtures inject a system-call fake, so tests do not place calls or record audio.

On 2026-10-28, the three iOS voice client files and `CodexVoicePeer` passed Swift type checking/module compilation against the real shared sources, the installed iOS 27.0 SDK and the pinned checksum-verified WebRTC 155 framework. The CallKit delegate compiles without concurrency warnings. A standalone simulator harness then passed **22 loopback TLS voice fixtures**, including all six added lifecycle tests. It compiled the real shared sources and voice state machine, used the test audio/system-call adapters, replaced only the streaming bridge identity helper with a disposable test identity, and supplied aborting native-WAN stubs (that path was not exercised). The app UI/screenshot portion and complete `ClientModel` suspension test were excluded from that standalone harness. This verifies state/signaling behavior, not actual CallKit service callbacks or WebRTC audio I/O.

The complete app build and normal Xcode test bundle execution are not verified: bootstrap stops because Rust/rustup is absent, the `xcodeproj` Ruby gem is absent, and the installed Xcode 27.0 is below the project's documented 27.1 requirement. No physical iPhone, lock-screen, Bluetooth, vehicle or incoming push test was performed.

Before release, run the iOS voice fixture suite under the supported toolchain, then test on an iPhone: start/lock/end and mute from both app and system UI; deny microphone permission; disconnect Mac/network during startup and active audio; interrupt with another call; reset audio services; connect/disconnect wired and Bluetooth HFP routes; close a desktop stream before starting voice; repeat rapid start/end and background transitions. Verify car display/controls only on the intended vehicle. Do not infer hardware behavior from fixture results.

## Apple references (checked 2026-10-28)

- [Making and receiving VoIP calls](https://developer.apple.com/documentation/callkit/making-and-receiving-voip-calls) — outgoing actions and system audio activation.
- [CXProviderDelegate](https://developer.apple.com/documentation/callkit/cxproviderdelegate) — system end/mute/reset and activation callbacks.
- [Bluetooth HFP category option](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp) and [voiceChat](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat) — duplex voice routing.
- [Supporting PushKit notifications](https://developer.apple.com/documentation/pushkit/supporting-pushkit-notifications-in-your-app) — entitlement, device tokens and server requirements.
- [Responding to VoIP notifications](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit) — wakeup, APNs and immediate CallKit reporting.
