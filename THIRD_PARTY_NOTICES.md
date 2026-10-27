# Third-party notices

Nocturne's original application and integration code is provided under GPL-3.0; see LICENSE. This project is not affiliated with Apple, Moonlight, or LizardByte.

- **Moonlight iOS** — GPL-3.0, https://github.com/moonlight-stream/moonlight-ios, pinned commit `02dc9780496eeeac6d01c8bbdccb8b6fe71ef28a`. Its notices and recursive submodule licenses remain in `Vendor/moonlight-ios`, including moonlight-common-c, ENet, nanors, and X1Kit. The generated client links this implementation and its pinned OpenSSL package.
- **Sunshine** — GPL-3.0, https://github.com/LizardByte/Sunshine/tree/v2026.1018.5342, macOS arm64 prerelease `v2026.1018.5342` (fixes duplicate identities after re-pairing), source commit `3d6e1d6008bd4a24906283ab25fcd0becc0a1c07`. The verified release is used only as an extraction source. Its server executable, required libraries, and runtime assets are copied directly into Nocturne; the application wrapper, Info.plist, icons, launcher, and tray plugins are excluded. The executable and libraries are signed as part of Nocturne. Download: https://github.com/LizardByte/Sunshine/releases/download/v2026.1018.5342/Sunshine-macOS-arm64.dmg. SHA-256: `3987348251060f84b1af147fa9cbe933c3b41872ffbb499586443abb85637bfb`. Its required frameworks and runtime assets are retained in Nocturne’s own bundle. The server uses the documented/local configuration API; upstream attribution is preserved in diagnostic logs.
- **SwiftTerm** — MIT, https://github.com/migueldeicaza/SwiftTerm, v1.20.0 commit `5d14406844143538cd8f8851d2d8a67c1fe443e5`. Its license remains at `Vendor/SwiftTerm/LICENSE`.
- **WebRTC** — native framework distributed by https://github.com/stasel/WebRTC at **155.0.0**, commit `44f36788497f701bc8c0306de3a1c2511d56019d`; the package verifies archive SHA-256 `cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe`. Build scripts use BSD-3-Clause; the framework and its dependencies retain the [WebRTC licenses](https://webrtc.org/support/license). Preserve the package/framework notices when distributing.
- **OpenSSL package** and **swift-argument-parser** — versions/commits recorded in `Nocturne.xcworkspace/xcshareddata/swiftpm/Package.resolved`; retain their source/package notices when distributing.

No proprietary Apple artwork or marketing assets are bundled. The icons and orbit illustration are generated with native drawing code. SF Symbols are rendered through the platform APIs.

For redistribution, provide this repository plus all corresponding pinned upstream source (including recursive submodules and source for the embedded engine's bundled dependencies) and preserve the applicable notices. The development bootstrap downloads binaries for local builds; it is not a completed source-distribution or App Store release process.

## Remote transport

The Rust broker and native tunnel use [iroh](https://github.com/n0-computer/iroh) and iroh-relay (MIT OR Apache-2.0), with netwatch, Tokio, rustls, and their dependencies. Exact versions and checksums are recorded in `remote/Cargo.lock`. The transport is statically linked into the apps; the broker is a separate self-hosted executable.
