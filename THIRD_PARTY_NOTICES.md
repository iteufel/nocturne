# Third-party notices

Nocturne's original application and integration code is provided under GPL-3.0; see LICENSE. This project is not affiliated with Apple, Moonlight, or LizardByte.

- **Moonlight iOS** — GPL-3.0, https://github.com/moonlight-stream/moonlight-ios, pinned commit `02dc9780496eeeac6d01c8bbdccb8b6fe71ef28a`. Its notices and recursive submodule licenses remain in `Vendor/moonlight-ios`, including moonlight-common-c, ENet, nanors, and X1Kit. The generated client links this implementation and its pinned OpenSSL package.
- **Sunshine** — GPL-3.0, https://github.com/LizardByte/Sunshine/tree/v2026.1018.5342, macOS arm64 prerelease `v2026.1018.5342` (fixes duplicate identities after re-pairing), source commit `3d6e1d6008bd4a24906283ab25fcd0becc0a1c07`. Nocturne rebuilds this source with the repository's CMake/VideoToolbox overlay and disabled tray. Required libraries and runtime assets are extracted from the verified release; the upstream application wrapper, Info.plist, icons, launcher, and tray plugins are excluded. The executable and libraries are signed as part of Nocturne. Download: https://github.com/LizardByte/Sunshine/releases/download/v2026.1018.5342/Sunshine-macOS-arm64.dmg. SHA-256: `3987348251060f84b1af147fa9cbe933c3b41872ffbb499586443abb85637bfb`. The server uses the documented/local configuration API; upstream attribution is preserved in diagnostic logs. The pinned source and its dependency notices remain in `.build/SunshinePerformanceSource`; distribution must include the corresponding source and this overlay.
- **SwiftTerm** — MIT, https://github.com/migueldeicaza/SwiftTerm, v1.20.0 commit `5d14406844143538cd8f8851d2d8a67c1fe443e5`. Its license remains at `Vendor/SwiftTerm/LICENSE`.
- **OpenSSL package** and **swift-argument-parser** — versions/commits recorded in `Nocturne.xcworkspace/xcshareddata/swiftpm/Package.resolved`; retain their source/package notices when distributing.

No proprietary Apple artwork or marketing assets are bundled. The icons and orbit illustration are generated with native drawing code. SF Symbols are rendered through the platform APIs.

The Windows application also uses:

- **Sunshine Windows** — the same GPL-3.0 source tag and commit listed above. Both Windows lite archives are checksum-pinned in `Windows/engine.lock.json`. The Windows app bundles the executable, runtime DLLs, and assets, excluding upstream service/setup launchers. It retains Sunshine's attribution in the logs and supplies this source reference.
- **Bouncy Castle C#** — BouncyCastle.Cryptography 2.7.0, MIT, https://github.com/bcgit/bc-csharp/tree/release-2.7.0. Implements the existing TLS-PSK workspace transport on Windows.
- **QRCoder** — 1.8.1, MIT, https://github.com/codebude/QRCoder. Generates pairing QR codes locally.
- **.NET 10 / WPF** — MIT and associated third-party notices, https://github.com/dotnet/runtime and https://github.com/dotnet/wpf. Self-contained Windows packages include the runtime. System.Security.Cryptography.ProtectedData 10.0.13 provides Windows DPAPI integration. Exact NuGet dependency graphs are recorded in `Windows/**/packages.lock.json`.

Windows packages include this notice, the project license, the pinned engine manifest, and setup documentation. Binary packaging does not remove the corresponding-source requirements below.

For redistribution, provide this repository plus all corresponding pinned upstream source (including recursive submodules and source for the embedded engine's bundled dependencies) and preserve the applicable notices. The development bootstrap downloads binaries for local builds; it is not a completed source-distribution or App Store release process.

## Remote transport

The Rust broker and native tunnel use [iroh](https://github.com/n0-computer/iroh) and iroh-relay (MIT OR Apache-2.0), with netwatch, Tokio, rustls, and their dependencies. Exact versions and checksums are recorded in `remote/Cargo.lock`. Apple apps statically link the transport; Windows packages include `nocturne_remote.dll`, built from the same source and lock file. The broker is a separate self-hosted executable. Windows capture, codec, and audio modules use operating-system APIs rather than redistributing a separate video codec. Virtual display and audio drivers are installed separately from their publishers and are not bundled by Nocturne.
