# Chat activity and approval policies

Independent task/PR. Base: `49ee687583adb5b82617cdc024f4bbdcf92cb861` on `main`. Checkout: `/private/tmp/nocturne-chat-status-approvals`. No CallKit, push notification, ActivityKit, release or TestFlight changes.

The left conversation list shows actual provider phases (working, thinking, tool activity), outstanding approval requests, completion, interruption and failure. The initial “Sending request” label describes the client's submitted request. Progress is indeterminate: no timer-derived percentages. History replay does not produce live activity. Disconnect resets statuses; completed states remain visible in this connection. The supervisor's dedicated row also shows activity.

## Codex App Server

- Command and file requests expose once/session/deny/stop decisions. An explicit `availableDecisions` list is authoritative; empty, malformed and unknown-only lists cannot gain allow options. Legacy servers without that field use the documented native response choices.
- A persistent command rule is offered only for an exact `proposedExecpolicyAmendment`. Its original structured response stays on the host. The UI shows the prefix and warns that a saved Codex rule can affect other chats. Revoke that rule in Codex's rules on the Mac; changing a chat policy does not erase provider-saved grants.
- Additional-permission requests support turn/session scope. Denial grants an empty profile. No additional sandbox access is inferred.
- Managed network requests display their host/protocol. Persistent network-policy amendments are not implemented; unsupported decision objects are omitted.
- The chat policy defaults to the existing `on-request` behavior. Only a concrete picker selection creates a per-chat, per-provider-process override, passed on subsequent text `turn/start` calls. `untrusted` uses Codex's trusted-command behavior; `never` (“Automatic within sandbox”) denies escalation rather than approving everything. The sandbox is unchanged. Select the default again to undo. Reconnecting or replacing the provider process clears the override. Voice retains its existing separate default. Available choices are filtered through `configRequirements/read` when supported. Managed-provider rejection remains visible as a failed turn.
- No pending approval is auto-answered by the policy. Unsupported interactive requests still require the provider's Mac client.

Protocol checked against installed Codex-generated schemas (`codex app-server generate-json-schema`) and [official App Server documentation](https://developers.openai.com/codex/app-server).

## Claude / ACP v1

Nocturne uses `claude-agent-acp`, not the Claude Messages API. Only provider-advertised `configOptions` or legacy `modes` appear. `session/set_config_option` or `session/set_mode` applies the user's concrete selection. No invented Auto, session or permanent mode is added. Provider descriptions and the current mode remain visible; changing back uses the same picker. `current_mode_update` updates the displayed legacy mode.

Permission option IDs are passed back unchanged. `allow_always`/`reject_always` retain the adapter's own persistence scope; the UI directs revocation to the provider on the Mac rather than promising a chat-local lifetime that ACP does not specify. Sensitive/mandatory interactive behavior remains the provider's responsibility, with every incoming permission request still displayed for a user decision.

See [ACP v1 tool permissions](https://agentclientprotocol.com/protocol/v1/tool-calls), [session config options](https://agentclientprotocol.com/protocol/v1/session-config-options), and [session modes](https://agentclientprotocol.com/protocol/v1/session-modes).

## Compatibility and verification

`activity`, option scope and configuration descriptions are optional wire fields. Status uses the existing `configured` event kind without replacing configuration options, so older clients ignore the added metadata. Updated server and client are needed for the new controls/status; older hosts retain their existing behavior. No capabilities or paired-device rights are added.

Run `bash scripts/test-chat-policy.sh` for focused XCTest fixtures using the production protocol and host sources, without Rust/WebRTC/streaming downloads. Run the full `swift test --filter 'ChatTests|ChatStatusApprovalTests'` after normal bootstrap. The focused suite covers exact persistent payloads, restricted/malformed decisions, session grants, profile denial, stale/provider-resolved requests, explicit/reversible/chat-isolated policy, ACP modes and persistence, real status events and terminal failure, and old wire decoding. Existing authenticated chat tests also assert waiting/completion/disconnect status.

Local focused suite: 10 tests passed. All shared production sources compile for the iOS 17 simulator. Local SwiftUI compilation is blocked by the environment's macro-plugin sandbox; full app/UI tests and full bootstrapped SwiftPM tests remain CI validation, not claimed as local passes. No live inference, notifications, pushes, test messages, capture or device permission prompts are used by the focused suite.
