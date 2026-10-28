# Nocturne

Stream your Mac to iPhone, iPad, or another Mac. The Mac app can host your desktop and connect to other Nocturne hosts at the same time.

- Stream your desktop or open individual Mac app windows on iPad or another Mac.
- Use touch, a keyboard, a mouse, or a game controller.
- Keep terminal sessions running on your Mac and access shared files in Apple’s Files app.
- Read and continue Codex conversations, or switch to Claude Code and other ACP agents on your Mac.
- Choose models/reasoning, open worktree chats, review agent/Git diffs, edit changed files, and view/edit GitHub or Azure DevOps pull requests.
- Talk with Codex over WebRTC using your ChatGPT sign-in, with spoken replies, transcripts, microphone controls, and background audio.
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

The Mac desktop matches its viewer window by default, including Retina resolution. Enable **Headless virtual monitor** in the host's Displays settings. Choose a physical monitor from **Displays** when wanted. **Apps** opens individual windows with a small local drag handle; fixed-size apps stream without needing to resize. To unlock a locked host, open its **Desktop** and enter the Mac password; Nocturne must already be running in that signed-in session.

## Documentation

- [Usage guide](docs/USAGE.md) — pairing one or more Macs, app windows, displays, input, microphone, terminal, and files.
- [Remote access](docs/REMOTE_ACCESS.md) — connecting across networks and hosting a broker.
- [Development](docs/DEVELOPMENT.md) — prerequisites, local builds, signing, and tests.
- [Releases and TestFlight](docs/RELEASING.md) — automated builds and distribution.
- [Implementation](docs/IMPLEMENTATION.md) — architecture, authentication, and protocols.
- [Verification](docs/VERIFICATION.md) — test evidence, limitations, and remaining device checks.

## License

GPL-3.0. Nocturne is an independent project built using the Moonlight iOS client, Sunshine, and SwiftTerm. See [third-party notices](THIRD_PARTY_NOTICES.md) and [LICENSE](LICENSE).

Simulator framebuffer preview (experimental, view only; remote touch remains blocked): see [support and verification](docs/SIMULATOR.md).
