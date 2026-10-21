# Nocturne

Stream your Mac to iPhone, iPad, or another Mac. The Mac app can host your desktop and connect to other Nocturne hosts at the same time.

- Stream your desktop or open individual Mac app windows on iPad or another Mac.
- Use touch, a keyboard, a mouse, or a game controller.
- Keep terminal sessions running on your Mac and access shared files in Apple’s Files app.
- Connect locally or enable remote access for other networks.
- Pair several Macs and switch between them.
- Connect Mac to Mac from **Computers**, with desktop video, audio, keyboard, and mouse in a separate window.

Requires iOS/iPadOS 17+ and an Apple Silicon Mac running macOS 14+. Nocturne includes its streaming engine; no separate Sunshine installation is needed.

## Get started

1. Download the signed and notarized **Nocturne** from [GitHub Releases](https://github.com/iteufel/nocturne/releases), unzip it, and move it to Applications. Quit any older server first.
2. Open the Mac app, select **Start server**, and allow screen/audio capture and Accessibility when prompted.
3. In Nocturne on iPhone or iPad, choose **Add host → Scan QR code** and scan the code shown by **Pair a device** on the Mac.
4. Choose **Desktop** to stream, or **Apps** to open a Mac app window. Enable optional terminal and file access in the Mac app’s **Sharing** settings.

For the iPhone/iPad app, see the [build and TestFlight guide](docs/RELEASING.md) or [build from source](docs/DEVELOPMENT.md).

To connect from a Mac, install the updated Mac app on both computers. On the host choose **Pair a device → Copy pairing code**. On the viewing Mac choose **Computers → Add host**, paste the code, and select **Add & connect**. Saved hosts reconnect from Computers.

Choose **Apps** next to a saved Mac to browse applications and open individual windows. To unlock a locked host, open its **Desktop** and enter the Mac password; Nocturne must already be running in that signed-in session.

## Documentation

- [Usage guide](docs/USAGE.md) — pairing one or more Macs, app windows, displays, input, microphone, terminal, and files.
- [Remote access](docs/REMOTE_ACCESS.md) — connecting across networks and hosting a broker.
- [Development](docs/DEVELOPMENT.md) — prerequisites, local builds, signing, and tests.
- [Releases and TestFlight](docs/RELEASING.md) — automated builds and distribution.
- [Implementation](docs/IMPLEMENTATION.md) — architecture, authentication, and protocols.
- [Verification](docs/VERIFICATION.md) — test evidence, limitations, and remaining device checks.

## License

GPL-3.0. Nocturne is an independent project built using the Moonlight iOS client, Sunshine, and SwiftTerm. See [third-party notices](THIRD_PARTY_NOTICES.md) and [LICENSE](LICENSE).
