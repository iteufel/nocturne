# Nocturne for Windows

The native .NET 10 Windows app can host this PC and connect to other Nocturne hosts
at the same time. It shares the Mac app’s authenticated desktop and app-window
protocol, including desktop audio, display selection, keyboard, mouse, resizing,
fullscreen, reconnect, and multiple app windows. Hosting also includes persistent
PowerShell tabs, shared files, microphone forwarding, headless display control,
and direct/relay remote access.

## Build and run

Use Windows 11 or Windows 10 version 2004 (build 19041) or later. The host runs as
the signed-in Windows user. Desktop capture needs a supported GPU/driver; app
windows also use Windows Graphics Capture and Media Foundation. Windows N editions
need the Media Feature Pack. x64 and ARM64 have separate native packages.

Install the .NET 10 SDK, PowerShell 7, CMake, Visual Studio's Desktop development
with C++ workload and Windows SDK, and Rust 1.99.1. Then run:

```powershell
pwsh -File scripts/build-windows.ps1 -Architecture x64
# Windows on ARM:
pwsh -File scripts/build-windows.ps1 -Architecture arm64
```

The script downloads the checksum-pinned Sunshine runtime, builds the native media
and Rust QUIC libraries, runs native and .NET tests, and packages:

```text
.build/WindowsRelease/Nocturne-Server-Windows-x64.zip
.build/WindowsRelease/Nocturne-Server-Windows-arm64.zip
.build/WindowsRelease/Nocturne-Windows-x64-Setup.exe
.build/WindowsRelease/Nocturne-Windows-arm64-Setup.exe
```

Choose the installer for the PC’s native architecture, or extract the portable ZIP.
These are unsigned development packages. Both native architectures are tested in
Windows CI and saved as download artifacts. The .NET runtime is included. Extract
the whole package and open **Nocturne Server.exe**; launching only the executable
without its libraries and `engine` folder is unsupported.

On macOS, .NET projects can be cross-compiled for build checks. Complete packaging
also requires native Windows libraries built for the selected architecture; pass
`-NativeDirectory` to use those prebuilt libraries.

## Sharing and startup

Enabled services start when Nocturne opens. Screen sharing and app windows are
enabled initially; PowerShell, files, microphone, remote access, and login startup
are optional. Use **Sharing** to change permissions and the shared local folder.
Changes remain a draft until **Apply changes**. Applying restarts enabled services;
reconnect clients afterward. **Discard** restores the saved settings. Disabling
all sharing services leaves the host stopped.

Enable **Settings → Open Nocturne at Windows login** to register the app for the
current Windows account. Login opens the app in the system tray. Closing the main
window keeps sharing running; use **Quit Nocturne** in the tray or Settings to stop
all services and remote windows. Nocturne does not install a system service.

Settings also offers System, Light, and Dark appearance. The welcome screens appear
on first launch and can be replayed without changing sharing settings or pairings.
The Windows secure desktop, UAC prompts, and signing into another Windows session
remain controlled by Windows. Native desktop/window capture ends when Windows
switches to its lock or security desktop; unlock locally and reconnect. The Mac
host’s signed-in lock-screen capture is platform-specific and is not available
through Windows Graphics Capture.

Allow the applications through Windows Firewall on the private home network. The
packaged `configure-windows-firewall.ps1` can add narrowly scoped rules from an
elevated PowerShell. Rules exclude engine administration on TCP 47990 and are
limited to the private profile/local subnet; use `-Remove` to undo them.

## Pairing and remote access

Choose **Pair a device**, select the PC's local address, then scan its QR code from
**Add host → Scan QR code** on iPhone/iPad. Each code enrolls one device and expires
after five minutes. **Copy pairing code** supports pairing from another computer.
The workspace advertises `_nocturne._tcp` with a public identity hash; it broadcasts
no pairing secret. Discovery only locates a candidate: TLS and device proof remain
mandatory. The bundled engine also advertises its streaming service.

In **Remote access**, enable the feature and choose an HTTPS broker. After
applying, wait for **Ready**, then scan a new pairing code to save remote routing
information on the client. The default broker is `https://nocturne.alkal.de`.
Existing local pairings continue to work. If the broker is unavailable, local
workspace services remain available while remote startup retries.

Remote access uses the same Rust/iroh implementation as the Mac host. It prefers
direct peer-to-peer connections and falls back to an encrypted relay. Only the
workspace TLS port is reachable until the host verifies a paired device's
certificate proof. Engine administration is never forwarded. Device removal also
revokes that identity's QUIC peers.

## Connecting to another computer

On the host choose **Pair a device → Copy pairing code**. On Windows choose
**Computers → Add host**, paste the code, and select **Add & connect**. Hosts are
saved only after successful authentication. Outgoing credentials and saved pairing
secrets use DPAPI and remain separate from this PC’s hosting keys.

Use **Connect** beside a saved host for its desktop, or **Apps** to browse and launch
applications and stream individual windows. One desktop and up to four app windows
per host can be open at once. Click the video to control it. **Ctrl+Alt+Esc** releases
the keyboard; losing focus also releases held keys and buttons. The toolbar offers
reconnect, fullscreen, paste text, display selection, and desktop audio mute.
Closing a stream releases its remote capture without stopping this PC’s host.

A saved address is tried first, followed by local discovery and then the paired
remote endpoint when available. Native desktop and app media use the authenticated
workspace connection, including over the encrypted remote tunnel. Desktop video
fits the selected monitor into the viewer; resizing this viewer does not change
the host’s physical display resolution. Desktop control has one exclusive lease.

Desktop audio is 48 kHz interleaved stereo Float32. Windows 11 process loopback
excludes Nocturne playback to prevent feedback when hosting and viewing together.
On systems that require endpoint loopback, outgoing desktop audio is suppressed
while incoming desktop audio plays. Missing audio devices leave video available;
reconnect after changing an endpoint. Individual app streams carry video and input,
matching the Mac app. Gamepad and microphone forwarding from iPhone/iPad continue
through their existing streaming controls.

## App windows

Enable **Screen sharing and app windows**, reconnect, and open **Apps** on iPad.
The catalog includes Start-menu apps, packaged Windows apps, and running desktop
apps. Launch an app or choose an existing window. Each stream captures that window
independently of the desktop and other overlapping windows.

Windows Graphics Capture frames are converted and encoded as H.264 using Media
Foundation. Video uses bounded fragments with one send in flight. Resizing changes
the real PC window and its encoded size. Keyboard shortcuts, text, pointer buttons,
dragging, and scrolling are forwarded to the selected window; Command shortcuts
map to Control on Windows. Windows may prevent control of an elevated application.

A window can be leased by one authenticated connection. Limits match the Mac host:
eight windows per host, four per device, and a 20-second heartbeat timeout. Closing
a scene, revoking access, disconnecting, or stopping Nocturne releases capture and
any injected held input. The streamed application remains open on the PC.

## Displays and headless mode

**Displays** chooses a connected monitor or a compatible virtual monitor. A fixed
client resolution works when that monitor supports the requested mode. **Match
device** follows the client's pixel size and therefore normally needs a virtual
monitor with matching modes.

For headless streaming:

1. Install a signed virtual display driver using the upstream
   [Virtual Driver Control](https://github.com/VirtualDrivers/Virtual-Driver-Control/releases).
   Use the driver for the PC's architecture; x64 kernel drivers do not work on ARM64.
2. Choose **Enable automatic virtual sizes…** in Nocturne's Displays settings.
   The packaged setup helper requests administrator approval, preserves the
   previous driver configuration path, and creates a Nocturne-managed configuration
   in `%PROGRAMDATA%\Nocturne\VirtualDisplay`. It grants the selected Windows user
   permission to maintain that configuration. Restart the virtual driver or PC.
3. Enable **Headless virtual monitor**, apply changes, and reconnect. Nocturne adds
   bounded resolution entries as the client rotates or resizes, then asks the driver
   to reload before preparing video. An existing manually configured virtual driver
   can also be used without automatic configuration.

**Turn off physical displays while streaming** requires headless mode. Nocturne
saves the previous display topology before changing it and restores it on release,
disconnect, timeout, or stop. Monitor identities are retained across virtual-driver
reloads. A separate helper watches the application process and attempts recovery
if it exits unexpectedly; startup also recovers any saved topology.

**Stop and restore displays** stops sharing and performs local recovery. Recovery
state is retained if Windows cannot restore it. Configuration helpers do not
install an unsigned driver or disable Windows driver-signature enforcement.

## Controllers

Pair Bluetooth accessories with the iPhone or iPad. Keyboard, mouse, and trackpad
input use the host’s Windows input path. Gamepad emulation uses Sunshine’s Windows
backend and needs a compatible virtual gamepad driver. **Controller setup…** opens
the upstream [Windows input setup guide](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html),
which covers Virtual HID Driver and the ViGEmBus fallback. Driver installation and
any machine license remain separate from Nocturne’s installer.

## Microphone

Install a compatible virtual audio driver, then choose its **playback** endpoint
under **Sharing → Virtual microphone playback endpoint**. Enable **Client
microphone**, apply, and reconnect. On the PC, select the driver's corresponding
**recording** endpoint in Discord or the target app. A normal speaker/headphone
endpoint does not create a microphone input. ARM64 requires an ARM64-compatible
virtual audio driver.

Open the stream's microphone control to unmute. The client starts muted on every
stream. Audio is 48 kHz, mono, signed 16-bit PCM in 20 ms frames; WASAPI converts it
for the selected endpoint. Only one authenticated socket owns the microphone,
replayed/out-of-order frames are rejected, and a two-second stall closes the output.
Disconnect, permission revocation, and stop also reset audio so it cannot linger.

## Security and lifetime

Workspace protocol 4 uses TLS 1.2 `TLS_PSK_WITH_AES_128_GCM_SHA256`. An RSA certificate
proof is bound to the handshake's TLS exporter and a fresh nonce. The host requires
a saved device or a valid single-use enrollment token; the QR key alone cannot
enroll another device. This protocol is verified against the real Swift client.

Private state lives in `%LOCALAPPDATA%\Nocturne`, restricted to the user,
Administrators, and SYSTEM. Workspace and remote identity keys are separate and
protected with Windows DPAPI. Pairing secrets are excluded from logs and discovery data. Pairing codes pasted
in the app stay within its process; opening an OS `nocturne://` link passes that
invitation through Windows’ registered protocol command.
Engine administration uses a random password, salted hash, pinned local certificate,
no proxy, and no redirects. Native libraries load from the app or system directory.

Windows Job Objects own the suspended engine/shell process before it resumes, so
an unexpected GUI exit terminates their process trees. Up to eight PowerShell tabs
per device retain 512 KiB of replayable history. Disconnect detaches tabs; reconnect
replays output by offset. Stop, permission revocation, and device removal close them.

Shared paths reject traversal, alternate data streams, reserved names, symlinks,
and junctions. In-flight directory guards prevent replacement races. Uploads are
bounded, staged privately, and published atomically without overwriting files.
Cancellation and disconnect discard unfinished uploads.

Removing a device blocks workspace access before closing its resources and revoking
every matching engine certificate. Saved certificates can also be removed while
stopped. Interrupted removals remain blocked and retry on the next start.
**Reset all pairings** stops connections, removes all streaming certificates and
workspace devices, rotates both hosting identities, and restarts enabled services.
Old QR codes become invalid. Outgoing computer pairings and shared files survive.

## Windows installer

The installer runs per user without elevation, installs to
`%LOCALAPPDATA%\Programs\Nocturne`, creates a Start-menu shortcut and optional
Desktop shortcut, and registers `nocturne://` pairing links. It includes the .NET
runtime, native libraries, embedded streaming engine, licenses, and setup helpers.
An upgrade requests a graceful shutdown before replacing application files and
retains login startup registration. Uninstall removes installed files, shortcuts,
URL registration, and that install’s login entry. It preserves
`%LOCALAPPDATA%\Nocturne` and all shared folders, including keys and saved hosts.
Optional driver and firewall changes remain explicit setup actions.

Inno Setup is pinned by version, SHA-256, and verified publisher in
`Windows/Installer/toolchain.lock.json`. `scripts/build-windows-installer.ps1`
can rebuild an installer from published files. CI installs version 0.9.0 of the same
payload as an upgrade fixture, opens the native app, upgrades to the current build,
and checks key/startup preservation, URL registration, and uninstall retaining data.
Run `scripts/test-windows-installer.ps1` only in a disposable Windows account with
no existing Nocturne profile or installation.

## Verification

```powershell
pwsh -File scripts/build-windows.ps1 -Architecture x64
pwsh -File scripts/build-windows.ps1 -Architecture arm64
# Portable host checks and compile-only UI check:
dotnet test Windows/Nocturne.Host.Tests -c Release -p:RestoreLockedMode=true
dotnet build Windows/Nocturne.Server.Tests -c Release -p:RestoreLockedMode=true
```

Native CI encodes and decodes a synthetic image through the real Media Foundation
pipeline, checks its H.264 output against the Swift packet format, and opens/renders
the WPF window on an STA thread using an isolated profile. Portable tests cover
TLS/authentication, permissions, connection-owned media leases, replay/timeouts,
settings application, terminal persistence, and file-path constraints. Native
ConPTY, filesystem/junction, and DPAPI tests run on both Windows architectures.

The fixture in `Windows/Nocturne.Interop` verifies authentication and reconnects
in both directions, including Windows receiver commands and fragmented video/audio
from a real Swift workspace server. The WPF smoke test connects the actual Windows
receiver over TLS and verifies a decoded native H.264 image on screen. Native CTest
checks sustained production decoding and occluded-window capture. It is excluded from the package. Native UI and codec tests do not prove
physical GPU capture, a driver's headless modes, audio routing into Discord, secure
desktop behavior, or visible iPhone-to-Windows playback; those require a Windows PC
and physical client/device checks.

Sunshine versions and architecture-specific hashes are pinned in
`Windows/engine.lock.json`; NuGet dependencies use lock files. See
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for source and redistribution
information. Virtual-device drivers are installed separately from their publisher.
