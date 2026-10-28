# Browser on the paired Mac

Implementation base: `49ee687583adb5b82617cdc024f4bbdcf92cb861` (main).
Isolated checkout: `/private/tmp/nocturne-browser`; branch: `codex/mac-browser`.
This feature is independent of CallKit, Push and streaming changes.

## Use

On the Mac, open the Agent chats settings and enable **Agent chats** and **Browser on Mac**. The browser switch defaults to off, applies immediately and is saved as `allowBrowser`. Reconnect the paired device after enabling it so it receives `host-browser-v1`.

In Chats, choose the globe button on the right, or **Browser on Mac** in the system toolbar. Wide layouts show a right panel; compact layouts show a sheet. Enter a full `http://` or `https://` address and choose **Go**. Merely opening the panel does not load a website. Tap the image to click; use Type for the focused field, Enter/Tab/Backspace, the scroll controls, Back, Forward and Reload. The displayed current URL comes from Mac WebKit, including redirects; it is distinct from the editable destination field.

`http://localhost:3000`, `http://127.0.0.1:3000` and `http://[::1]:3000` refer to the **Mac's** loopback. Names and LAN addresses resolve/connect from the Mac. They never designate the iPhone's loopback. HTTP addresses remain subject to Apple's transport security policy; there is no automatic HTTPS-to-HTTP downgrade or security exception added by this feature.

## Architecture decision

| Option | Assessment |
| --- | --- |
| iOS WKWebView with URL rewriting / custom schemes | Rejected. Public `WKURLSchemeHandler` cannot handle schemes already owned by WebKit, including HTTPS. Rewriting does not transparently preserve origins, relative/absolute URLs, cookies, redirects, fetches or WebSockets. It cannot provide the requested traffic boundary. |
| iOS WKWebView with a native proxy tunnel | A real option on the supported iOS 17+ baseline: `WKWebsiteDataStore.proxyConfigurations` accepts Network framework CONNECT/SOCKSv5 proxies. `ProxyConfiguration.allowFailover` defaults to false. This would still require an authenticated, bounded stream multiplexer over the pairing transport, lifecycle and destination handling, and verification of localhost bypasses, DNS, WS/WSS and non-proxy protocols such as WebRTC. Merely setting a proxy is not proof of complete tunnelling. |
| Mac-hosted WKWebView with remote image/input transport | Implemented. System WebKit on the Mac owns the document, network process, origins and cookie store. No separate browser binary, installation, download, VPN, listening proxy, certificate installation or trust change is needed. The cost is a remote visual surface rather than local native DOM interaction. |

`BrowserWorkspaceModel` sends `browserCommand` packets over the existing `WorkspaceConnection`. The server's existing TLS-PSK transport and certificate proof/device-enrollment gate run before the operation is dispatched. `HostSession` additionally checks the browser permission. Each authenticated **connection** owns one `RemoteBrowserHost`; session IDs cannot be transferred between sockets, devices or Macs.

A private, offscreen Mac window backs a `WKWebView` with a fresh nonpersistent data store. Mac WebKit performs navigation, rendering and all website networking. The paired connection carries only bounded commands, metadata and JPEG frames. There is no HTML, script, fetch, socket or URL-proxy endpoint exposed to the iPhone, and no script-evaluation command. The sole injected script is fixed scrolling code in WebKit's isolated client world. Pointer and text input are delivered to the private window, never posted as global Mac events.

## Traffic guarantees and limits

All network activity of this browser's web content originates on the Mac: URL loads, DNS, HTTP/HTTPS, relative and absolute subresources, redirects, iframes, WS/WSS and other networking supported by that Mac WebKit version. HTTPS remains ordinary website TLS with normal server-trust handling. The phone has no browser engine or website-loading API in this feature; a failed request clears its displayed frame and shows an error. It never retries the URL through iPhone networking or an external browser. This guarantee follows from where the document executes, not from a URL-rewrite heuristic or a claim that a proxy covers every protocol.

The Mac's existing OS network configuration still applies, including any proxies, VPNs, DNS policies, trust store, local-network controls and ATS rules. Arbitrary external cleartext HTTP or insecure subresources may be blocked by those rules. No ATS settings are changed. Untrusted/self-signed website certificates fail; there is no certificate acceptance button. HTTP authentication and client-certificate challenges are cancelled rather than importing saved credentials. This is not an OS-wide tunnel for other apps or the chat voice feature.

WebKit retains normal origin, CORS, cookie and mixed-content behavior. In the local Xcode 27.0 WebKit run, `[::1]` loaded the page/assets/WebSocket but did not retain the fixture cookie; hostname/IPv4 cookie tests passed. IP-literal cookie policy is left to WebKit, with no host rewrite or cookie-policy bypass. A private profile prevents reuse of Safari cookies or browser history; it does not make web content harmless. A user who opens a session deliberately grants web content the network reach of this Mac, including loopback and LAN, subject to WebKit's own protections. The default-off host permission and authenticated explicit open are the authorization boundary.

The current surface uses a fixed 1024 × 768 desktop viewport, snapshots at about two frames per second (slower on a slow link), one in-flight command/capture per session, JPEGs capped at 600 KB and at most four live sessions per Mac. This suits development tools and ordinary pages, not smooth video, audio playback, DRM, games or latency-sensitive interaction. There is no DOM accessibility tree, text selection/copy, drag-and-drop, file upload/download, tab manager or remote permission-prompt UI. Video/accelerated layers may not appear in snapshots. Browser media audio is not transported to the phone. Mac GUI-session availability and WebKit compatibility remain prerequisites; locked-session behavior is not validated.

## Permissions and lifecycle

- Browser access is a separate, default-off Mac permission. Possession of the transport key alone cannot use it: registered device proof is also required. No extra LAN listener or firewall opening is added.
- Each open creates a fresh ephemeral profile. Closing and reopening starts over; cookies and storage are not transferred to another session or Mac.
- Full HTTP(S) destination URLs are validated and bounded. Embedded credentials, file/javascript/custom-scheme navigation, external-app handling and downloads are rejected. A user-clicked `target=_blank` link stays in the same private session; script popups are blocked. The web page cannot invoke other Nocturne operations.
- File panels return no files. Camera and microphone permissions return deny. Geolocation returns deny on macOS 27+, where Apple exposes the delegate; older versions use WebKit/OS policy with no location usage declaration or grant added. Fullscreen is disabled. Alerts become bounded notices; confirms/prompts are declined. Other platform permissions retain WebKit/OS defaults and are never automatically granted by Nocturne. No new entitlements or permission grants are added.
- A page revision accompanies displayed pixels. Input from an older navigation, or while a page is loading, is rejected. Navigation may finish while a capture is pending; mismatched pixels are discarded.
- Closing/hiding the view, leaving the active scene, switching hosts, revoking access or disconnecting ends the session. Cancelled SwiftUI tasks issue their close command in an uncancelled cleanup task. The Mac also expires a session after 30 seconds without a successful command, with a five-second expiry check. Permission revocation invalidates queued/in-flight results synchronously and schedules context destruction on the main actor. Already completed network requests cannot be undone.
- Teardown destroys the document/view and ephemeral context; `stopLoading` alone would leave established WebSockets alive. Tests observe the actual WebSocket closing on explicit close and lease expiry.

## Verification

Production test entry points after the normal project bootstrap:

```sh
swift test --filter 'Browser(Protocol|Host|Connection)Tests'
# iOS tests are included by scripts/generate-project.rb:
xcodebuild test -workspace Nocturne.xcworkspace -scheme Nocturne \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:NocturneClientTests/BrowserWorkspaceTests
```

The local fixture suite covers relative and absolute resources, redirects, cookie isolation, WS, native clicking/typing/navigation, numeric IPv4/IPv6 loopback, stale-page input, cross-session rejection, explicit close and idle teardown. A self-signed HTTPS fixture must fail normal trust validation before any HTTP request; its temporary test identity is never installed or trusted. Pairing/TLS integration tests cover rendering over actual `SecureChannel` framing, a PSK-only unauthenticated client, default-disabled access, revocation, reconnection and switching between two fixture hosts. No private services or external websites are queried.

The iOS model tests exercise failed navigation without a client-load substitution and close delivery despite SwiftUI task cancellation. The client has only an injected packet-request dependency; image URLs and current-page strings are never fed to a web/network loader.

Local environment limitations: the full app's Vendor frameworks and Rust toolchain are absent. A disposable `.build/browser-harness` compiles the actual Shared/HostKit sources and C bridges without the WebRTC app target; unused Rust QUIC symbols are deferred only in that untracked test harness. This tests the real LAN TLS path, not QUIC relay behavior. Both Shared modules, the HostKit module, Mac settings wiring, iOS browser view and iOS test sources are also checked against the installed Xcode 27.0 SDK. A separate small Mac bundle uses the production Server Info.plist unchanged to verify localhost/IPv4/IPv6 fixture rendering without XCTest-specific transport policy. Full Xcode 27.1 app builds, simulator test execution and release/signing remain GitHub CI checks; there is no merge or release as part of this task.

## Official platform references

Reviewed 2026-10-28, together with the installed public Xcode 27.0 WebKit headers:

- [Apple: register a URL scheme handler](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/seturlschemehandler(_:forurlscheme:)) — registering HTTPS is a programming error.
- [Apple: WKWebsiteDataStore proxy configurations](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/proxyconfigurations-6g21z?language=objc) and [WebKit's public header](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.h) — per-store overrides, available on iOS 17/macOS 14.
- [Apple: ProxyConfiguration](https://developer.apple.com/documentation/network/proxyconfiguration) and [allowFailover](https://developer.apple.com/documentation/network/proxyconfiguration/allowfailover) — CONNECT/SOCKSv5 support and failover behavior.
- [Apple: nonpersistent website store](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent()) and [snapshots](https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(with:completionhandler:)) — profile and image transport primitives.
- [Apple: media capture permission delegate](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:requestmediacapturepermissionfor:initiatedbyframe:type:decisionhandler:)) — explicit deny policy.
- [Apple: App Transport Security](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity), [local networking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) and [preventing insecure connections](https://developer.apple.com/documentation/security/preventing-insecure-network-connections) — policy is preserved, not disabled to make browser URLs work.
