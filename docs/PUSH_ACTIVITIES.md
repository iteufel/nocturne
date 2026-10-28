# Agent attention: review and integration handoff

## Isolation and exact basis

- Repository: `https://github.com/iteufel/nocturne.git`.
- Independent clone: `/private/tmp/nocturne-push-activities`, branch `feature/push-activities`.
- Exact starting commit: `49ee687583adb5b82617cdc024f4bbdcf92cb861`.
- Created using `git clone --no-hardlinks /private/tmp/nocturne-callkit ...` and explicitly checked out that commit. Only committed objects were copied; none of the CallKit worker's uncommitted files were copied or changed. Origin was reset to the GitHub URL. No fetch/push/deploy/merge, credential creation, APNs transmission or user notification was performed.
- The separate worker `01a183c1-b2e2-77b1-ac1e-a291532453ff` owns `/private/tmp/nocturne-callkit`. This change contains no CallKit work.

## Implemented behavior

Settings → Agent attention has two independent, default-off switches. Enabling notifications requests the person's iOS notification permission. Enabling Live Activities uses the system's ActivityKit authorization. No permission prompt runs merely because the app launches.

While an authenticated workspace is connected, pending permissions and supported questions produce generic local notifications and foreground-started Live Activities. There is one activity per request, showing a short opaque request ID. Commands, tool arguments, provider question text, host names, repository paths and transcripts remain in the app's existing Chats review UI. Activities have an authoritative stale date; completed, expired, disconnected or deselected requests are removed. On cold launch, activities with no corresponding in-memory pending request are ended. A notification tap/review action only opens Chats; it never selects an answer or switches hosts/sessions from untrusted payload data.

Direct **Allow once** / **Deny** actions are available for typed once-only provider choices. ACP `allow_always`/`reject_always`, arbitrary option labels and general question answers are never inferred to be once-only decisions. Widgets use `LiveActivityIntent`, run in the app process, and declare `requiresLocalDeviceAuthentication`. Notification decisions declare `authenticationRequired`. Both entry points foreground the app to present authentication UI and additionally run `LAContext.deviceOwnerAuthentication`, including on an already unlocked device. The selected button decision executes after authentication without choosing an option again. Authentication cancellation fails closed. Rendering, token callbacks, receiving a push, stale cleanup and expiry cannot approve.

A decision requires the exact current request UUID, paired host key fingerprint, provider ID, session ID, expiry and offered option. After authentication these are checked again against the currently connected workspace; no automatic reconnect, host switch, retry or grant occurs. The local one-shot gate consumes the action before network suspension. The Mac independently checks the actual pending provider request and matching session, consumes it synchronously, and replies on the original RPC ID. A failed/uncertain send cannot re-arm the same local action; inspect Chats to establish the actual provider state.

Host requests expire after at most five minutes (a shorter provider question timeout is honored). Expiry cancels Codex/ACP permission requests, grants no extra permissions, and resolves incomplete question groups with an empty answer map. The host handles Codex `serverRequest/resolved` cleanup, cancellation, completion and disconnect. Resolution compares string and numeric RPC IDs without coercing them into each other. Supervisor worker requests retain their original worker session association while being presented in the owning supervisor session; the supervisor's dynamic tool cannot call this approval path.

The deadline is an optional backward-compatible field. Old hosts/clients still decode the protocol. Old requests without authoritative expiry/action metadata retain in-app review, with no new external action surface. A new host's expiry applies even when an old client displays its prompt longer.

## Provider API findings (checked 2026-10-28)

The existing Mac implementation owns a Codex app-server stdio process or an ACP v1 process. Its authenticated `chatPermission` operation already routes real pending provider RPC requests; this is the authority reused here.

- Codex command/file/permissions approvals remain on their existing provider methods. `availableDecisions`, when supplied, restricts the safe accept/decline subset. Permission grants retain the existing requested subset and turn scope. This does not amend provider approval policies, sandbox policies, account grants or connector access.
- Current official Codex documentation describes MCP app/connector approvals through provider user-input requests, and MCP elicitation as a separate server request. The local installed CLI's `app-server generate-json-schema --experimental` output confirmed question/answer and request-resolution shapes. The adapter supports `item/tool/requestUserInput` and its documented `tool/requestUserInput` spelling: one to three fixed-choice, non-secret questions, up to eight choices each, unique question IDs and labels. All questions must receive explicit selections in Chats before one exact `answers` response is sent on the provider RPC ID. They get review-only notifications/activities, not direct authorization buttons. No label-based Accept/Decline heuristic is used.
- Secret, free-text, “Other”, malformed and unsupported forms are rejected with a provider-client fallback. `mcpServer/elicitation/request`, including URL/OAuth and structured forms, is **not implemented**. An arbitrary GitHub-MCP approval cannot be promised: it works here only if the running provider actually exposes it through the supported fixed-choice user-input or permission flow. External ChatGPT/GitHub-MCP approvals, other clients' processes, or other supervisors' requests have no generic approval endpoint in this app.
- ACP uses original `session/request_permission` option IDs. Only the protocol's exact `allow_once` and `reject_once` kinds enable outside-app actions.

Official sources:

- [Apple: notification server responsibilities](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server)
- [Apple: APNs registration and device-token lifecycle](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Apple: authenticated notification actions](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/authenticationrequired)
- [Apple: interactive widgets and Live Activities; execution in app process](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Apple: local-device intent authentication](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy/requireslocaldeviceauthentication)
- [Apple: Activity lifecycle and foreground start constraints](https://developer.apple.com/documentation/activitykit/activity)
- [Apple: remote ActivityKit updates](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)
- [Official OpenAI documentation: app-server approvals, MCP tool-call approvals, questions and elicitation](https://learn.chatgpt.com/docs/app-server)
- [ACP: request permission](https://agentclientprotocol.com/protocol/tool-calls#requesting-permission)

## Remote push: prepared boundaries, NOT a working deployment

`AgentAttention.pushPayload()` produces a generic **review-only** APNs alert payload, containing only opaque request/host/provider/session locators, kind and expiry. It accepts no arbitrary alert text or decision. Locator dates currently use Foundation Codable’s default seconds since 2001-01-01; APNs `apns-expiration` uses Unix seconds since 1970, so a relay must convert from the typed Date rather than forwarding that JSON number as a header. `DarkAppDelegate` handles token registration/failure and notification responses. `AttentionPushRegistration.receiveToken` is an optional operator-owned authenticated registration callback. It defaults to nil: no APNs registration or token upload happens without integration. It is invoked on fresh APNs tokens; tokens are neither logged nor persisted by this code. When installed before app launch and notifications were enabled, registration runs each launch; enabling notifications also registers. Widget activities currently use `pushType: nil`.

**Not present:** token registration backend, relay sender, Mac-to-relay event bridge, device/account enrollment, persistence/reconciliation of offline pending requests, remote activity token handling/push-to-start, and a reconnect/review flow for notifications received after process termination. A push payload is never authority. Remote notifications cannot currently authorize an offline request; a decision fails closed unless the exact request is still current on the authenticated connection. A review tap opens Chats without recovering a different host/thread.

In particular, ordinary `ChatHostSession` agent processes are connection-owned and close/cancel on disconnect. Supervisor workers have a longer host-owned lifecycle, but there is no configured relay sink for their events in this patch. A reliable remote service must address host event ownership/lifetime and authenticated pending-request retrieval; just adding APNs credentials does not solve this. Socket background persistence and silent push are not reliable substitutes. macOS remains the existing approval authority; there is no new macOS notification UI.

Operator work required before claiming remote push:

1. Use the existing Apple Developer team; enable Push Notifications for `app.nocturne.client` and sign with a matching profile and `aps-environment` (`development` for sandbox, `production` for distribution). This patch deliberately does not add that entitlement or alter credentials. Sign the new `app.nocturne.client.attention` widget extension under the same team. No App Group or shared Keychain access is needed by this extension. Configure `NOCTURNE_ATTENTION_PROVISIONING_PROFILE_SPECIFIER` if manual profiles are used, alongside the existing app/Files profile settings. The archive script passes this value and exports the widget profile mapping; its default profile name is `Nocturne Attention App Store` (a name reference only, not a generated profile). Generated extension signing follows the existing `NOCTURNE_CODE_SIGN_*` and team settings.
2. Supply the optional token callback **before** `AgentAttentionCenter.bind`. Implement an authenticated HTTPS registration service that binds tokens to the enrolled user/device/paired host, replaces rotated tokens, supports explicit unlink/revocation, and separates sandbox/production tokens. Never send pairing secrets to a relay, accept caller-supplied ownership, or print tokens. Add lifecycle handling to unregister host subscriptions on forgetting/unpairing and disable delivery when the person opts out. These server/subscription contracts are integration requirements, not implemented endpoints.
3. Feed the relay only from authenticated Mac-owned pending events. Deduplicate per request and authorized device; persist expiry and resolved/cancelled state atomically. Ensure agents survive the intended offline interval safely, or explicitly notify only for host-owned supervisor work. Retrieve/reconcile pending state over the existing authenticated workspace before enabling any decisions after reconnection. Preserve the original provider/session/process binding; do not recreate a completed provider request.
4. Operate an APNs HTTP/2/TLS sender with an existing server-held signing key or certificate (never in the app). Use `api.sandbox.push.apple.com` or `api.push.apple.com`, `apns-topic: app.nocturne.client`, `apns-push-type: alert`, appropriate alert priority, and `apns-expiration` no later than the request's Unix expiry. Set a per-request collapse ID, handle 410/invalid tokens, bound retries to request lifetime, and stop sending when resolved. APNs delivery is best-effort; duplicate, delayed or missing notifications never change authorization state. Avoid a global collapse ID that replaces unrelated requests.
5. If remote Live Activity updates are later added, separately collect/revoke ActivityKit push tokens, use `apns-push-type: liveactivity` and topic `app.nocturne.client.push-type.liveactivity`, monotonic event timestamps, `stale-date`, and explicit end events. App device tokens are not ActivityKit tokens. Do not put secret request contents in `attributes`/`content-state`. Push-to-start and its token lifecycle need separate implementation and availability checks; neither is implied by `NSSupportsLiveActivities`.
6. On a signed physical device verify notification/Live Activity permissions, locked and unlocked auth, cancellation, stale/replayed actions, expiry, app termination/relaunch, host changes, APNs sandbox/production separation and offline recovery. Do this only with explicit authorization to send test pushes. No such push or device test was performed here.

## Validation

- `bash scripts/test-attention.sh`: dependency-free SwiftPM harness copies the **production** protocol/permission/question/host-adapter sources (no replacement provider implementation) and runs 11 passing XCTest cases. The provider is a local Python JSON-RPC fixture, with no model/API/network requests. Tests cover exact host/provider/session/expiry, absent/completed/replayed requests, generic review payloads, legacy decoding, unsupported/secret forms, real RPC one-shot decisions, restricted provider choices, timeout cancellation, provider resolution, grouped answers and incomplete-group expiry.
- `bash scripts/check-attention-sdk.sh`: compiles the complete real Shared module for macOS and iOS Simulator using the tracked native transport headers; type-checks affected host sources, the widget/intent against real Apple SDKs in extension mode, and the iOS attention controller against a small `ClientModel` boundary fixture with the real connection/chat models. It also checks Ruby generator syntax and plist syntax. The boundary fixture is explicit in the script; this is **not a full app build**.
- The test harness passed all 11 cases on the final run; SwiftPM required execution outside the workspace sandbox after startup stalled inside. The SDK checks ran inside the sandbox. The Ruby `xcodeproj` gem is not installed here, so the generator was syntax-checked, not executed.
- Xcode 27.0 (`27A266a`), Swift 6.4, iOS 17 minimum deployment. The host SDK check reports an existing `Packet` Sendable warning in `ChatHostSession`; no new errors.
- Full `swift test` / Xcode app linking, extension embedding, signing, UI snapshots, physical-device authentication, APNs and suspended-app delivery have not been verified. The independent checkout starts without `Vendor/`; `scripts/bootstrap.sh ios-simulator` is required for full app checks. No CallKit checkout dependency/cache was modified or reused as a build output.

## File list and CallKit integration

New:

- `Sources/Shared/AgentAttention.swift`: locator, generic APNs payload, one-shot gate.
- `Sources/Shared/ChatPermission.swift`: moved permission DTOs, optional typed action/expiry/kind.
- `Sources/Shared/NocturneError.swift`: unchanged error enum extracted for independent testing.
- `Sources/HostKit/CodexAttentionQuestions.swift`: bounded fixed-choice provider parsing.
- `Sources/Client/AgentAttentionCenter.swift`: opt-in settings state, authenticated system actions, activity/notification cleanup, optional APNs registration boundary.
- `Sources/AttentionActivity/AttentionActivity.swift`: shared attributes and authenticated intent.
- `Sources/AttentionWidget/AttentionWidget.swift`: WidgetKit Live Activity and Dynamic Island UI.
- `Resources/Attention-Info.plist`: widget extension metadata.
- `Tests/AttentionTests.swift`, `Tests/AttentionHostTests.swift`: protocol and local-RPC security tests.
- `scripts/test-attention.sh`, `scripts/check-attention-sdk.sh`: isolated reproducible checks.
- `docs/PUSH_ACTIVITIES.md`: this handoff.

Modified:

- `Sources/Shared/ChatProtocol.swift`, `Sources/Shared/Protocol.swift`: moved DTO/error declarations, no duplicate types.
- `Sources/Shared/ChatWorkspaceModel.swift`: exact-current-request decision route.
- `Sources/HostKit/ChatAgentSession.swift`: expiry, session checks, resolution, provider questions and action typing.
- `Sources/HostKit/ChatHostSession.swift`: pass exact active session to provider approval.
- `Sources/HostKit/ChatSupervisorService.swift`: preserve worker binding and metadata.
- `Sources/Client/NocturneApp.swift`: notification lifecycle callbacks and coordinator binding.
- `Sources/Client/ClientSettingsView.swift`: two default-off switches and honest remote availability text.
- `Resources/Client-Info.plist`: `NSSupportsLiveActivities`.
- `scripts/generate-project.rb`: compile shared activity code in app/widget, create/embed/sign widget target, regenerate activity plist support.
- `scripts/archive-ios.sh`: include the widget profile reference in archive/export settings (not executed).
- `Tests/ChatTests.swift`: existing fixtures now supply the required exact session; replay/mismatched-session assertions.

Review this branch independently. For later integration, cherry-pick the local commit into a separate integration branch based on the agreed common base; do not merge or modify the active CallKit worker's checkout. The current CallKit edits observed at the start overlap only `scripts/generate-project.rb` (the worker was also editing ClientModel/voice files, which this patch does not touch). Preserve both the CallKit frameworks/build settings and the new activity target/generator additions. If CallKit later adds app-delegate hooks or audio/session lifecycle changes, preserve these notification callbacks and bind only once. Activity code does not configure `AVAudioSession`, CallKit, microphone, call lifetime or streaming suspension. After resolving any later overlaps, rerun generator + both attention scripts + the full iOS/CallKit tests and signed-device checks. Nothing is merged automatically.
