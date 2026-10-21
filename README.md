# Nocturne

Stream your Mac to iPhone and iPad, with a native terminal and file transfer alongside your desktop.

- Stream your desktop or open individual Mac app windows on iPad.
- Use touch, a keyboard, a mouse, or a game controller.
- Keep terminal sessions running on your Mac and access shared files in Apple’s Files app.
- Connect locally or enable remote access for other networks.
- Pair several Macs and switch between them.

Requires iOS/iPadOS 17+ and an Apple Silicon Mac running macOS 14+. Nocturne Server includes its streaming engine; no separate Sunshine installation is needed.

## Get started

1. Download the signed and notarized **Nocturne Server** from [GitHub Releases](https://github.com/iteufel/nocturne/releases), unzip it, and move it to Applications. Quit any older server first.
2. Open the Mac app, select **Start server**, and allow screen/audio capture and Accessibility when prompted.
3. In Nocturne on iPhone or iPad, choose **Add host → Scan QR code** and scan the code shown by **Pair a device** on the Mac. Without a camera, choose **Copy pairing link** on the Mac, send it to your device, then open it or paste it in **Add host** and tap **Pair host**.
4. Choose **Desktop** to stream, or **Apps** to open a Mac app window. Enable optional terminal and file access in the Mac app’s **Sharing** settings.

For the iPhone/iPad app, see the [build and TestFlight guide](docs/RELEASING.md) or [build from source](docs/DEVELOPMENT.md).

## Documentation

- [Usage guide](docs/USAGE.md) — pairing one or more Macs, app windows, displays, input, microphone, terminal, and files.
- [Remote access](docs/REMOTE_ACCESS.md) — connecting across networks and hosting a broker.
- [Development](docs/DEVELOPMENT.md) — prerequisites, local builds, signing, and tests.
- [Releases and TestFlight](docs/RELEASING.md) — automated builds and distribution.
- [Implementation](docs/IMPLEMENTATION.md) — architecture, authentication, and protocols.
- [Verification](docs/VERIFICATION.md) — test evidence, limitations, and remaining device checks.

## License

GPL-3.0. Nocturne is an independent project built using the Moonlight iOS client, Sunshine, and SwiftTerm. See [third-party notices](THIRD_PARTY_NOTICES.md) and [LICENSE](LICENSE).
