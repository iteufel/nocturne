# Nocturne Server for Windows

The Windows host is a native .NET 10 WPF application. It bundles and manages the
Windows Sunshine executable, uses the existing Nocturne iOS client, and provides
QR pairing, desktop streaming, persistent PowerShell terminals, file transfers,
and individual device removal. No separate Sunshine installation or web setup
is required.

## Build and run

Use Windows 11 or Windows 10 version 2004 (build 19041) or later, with an active,
unlocked desktop, a connected monitor, and a GPU/driver supported by Sunshine.
Windows on ARM has a separate ARM64 package. Build with the **.NET 10 SDK** and
PowerShell 7:

```powershell
pwsh -File scripts/build-windows.ps1
# Windows on ARM:
pwsh -File scripts/build-windows.ps1 -Architecture arm64
```

The script verifies the pinned upstream download, runs the host tests, publishes
a self-contained application, and produces the requested architecture:

```text
.build/WindowsRelease/Nocturne-Server-Windows-x64.zip
.build/WindowsRelease/Nocturne-Server-Windows-arm64.zip
```

These are unsigned development packages; no Windows release is uploaded
automatically. Windows CI saves both architectures as build artifacts. The .NET
runtime is included, so the destination PC needs no SDK or runtime installation.
Extract the entire ZIP into a local folder before opening **Nocturne Server.exe**.
Keep the `engine` folder next to the executable. `dotnet run` alone does not stage
the bundled engine; use the packaging script for a runnable application.

1. Open the Windows app and select **Start server**. Stop another Sunshine or
   GameStream host first if one is running.
2. Allow the applications through Windows Firewall on your **private** home
   network. If needed, explicitly run the packaged
   `configure-windows-firewall.ps1` from an elevated PowerShell. Its rules are
   limited to the private profile and local subnet; local administration on TCP
   47990 is excluded. Pass `-Remove` to remove those rules.
3. Choose **Pair a device**. Select the PC address on the same network as your
   iPhone/iPad, then scan its QR code from **Add computer → Scan QR code** in
   Nocturne. Each code enrolls one device and expires after five minutes.
4. On iOS, choose **Settings → Resolution → 1080p** (or another fixed resolution),
   then open **Desktop**. Windows streams an existing monitor. The default
   **Match device** setting requires the Mac host's virtual display feature.
5. To enable PowerShell or files, stop the server, open **Sharing**, enable the
   feature, select **Save settings**, start the server, and reconnect the client.
   Both features are disabled by default.

Closing the app stops streaming, terminal processes, and transfers. The host runs
as the signed-in desktop user; it installs no Windows service and does not run at
the lock screen, bypass UAC, or log in automatically. Windows keyboard/mouse and
controller behavior depends on the bundled engine and installed input drivers;
this app does not install drivers or activate a driver license. See the
[pinned Sunshine release](https://github.com/LizardByte/Sunshine/releases/tag/v2026.1018.5342)
for driver requirements. Headless/virtual monitors, monitor power control,
and client microphone forwarding are not implemented by the Windows host.

## Security and lifetime

Workspace protocol 4 uses the same TLS 1.2
`TLS_PSK_WITH_AES_128_GCM_SHA256` suite as the Swift client. Bouncy Castle retains
the session exporter during `NotifyHandshakeComplete`, with Apple's empty-context
semantics. Certificate-status extensions are omitted for this certificate-free
PSK handshake. The client signs a fresh
nonce bound to that exporter with its streaming RSA certificate. The host verifies
the proof and requires either a saved device or a valid, single-use enrollment
token. The QR key alone cannot enroll a device.

Private state lives in `%LOCALAPPDATA%\Nocturne`. Directory ACLs grant access to
the current user, Administrators, and SYSTEM. The transport secret is protected
with Windows DPAPI for the current user. It is not passed as a process argument,
advertised through discovery, or logged. Engine administration uses a random
password on each start, a salted password hash on disk, an exactly pinned local
certificate, and no redirects or proxy. The app uses the standard streaming ports
and TCP 48555 for the workspace. Pairing uses the address in the QR code; nearby
streaming discovery is provided by the bundled engine.

Windows Job Objects are assigned before the suspended engine/shell process is
resumed. Closing the job kills its process tree, including when the GUI exits
unexpectedly. Terminal input/output use separate ConPTY workers. Up to eight tabs
are retained per device, with 512 KiB of scrollback per tab. Losing a workspace
connection detaches its subscriptions; reconnecting replays output by byte offset
without launching replacement shells. Stop, device removal, and terminal
permission revocation close the affected shells.

Shared paths reject traversal, alternate data streams, DOS device names,
symlinks, and junctions. Directory handles deny write/delete sharing while
operations are in flight; each component is opened with
`FILE_FLAG_OPEN_REPARSE_POINT` and checked through its handle. Reads never follow
a replacement reparse point. Uploads are bounded, staged under a reserved
hidden-from-client name, and moved atomically without replacement. Disconnect,
permission revocation, and cancellation discard unfinished uploads. The folder
must be on a local drive and its path must not traverse a junction.

Removing a device persists a block before closing its connections, terminals,
and transfers. It then disables and removes every matching engine certificate.
Interrupted removals remain blocked and are retried at the next server start.
Other devices retain their connections and certificates.

## Verification

```powershell
dotnet test Windows/Nocturne.Host.Tests -c Release -p:RestoreLockedMode=true
dotnet test Windows/Nocturne.Server.Tests -c Release -p:RestoreLockedMode=true
dotnet build Windows/Nocturne.Server -c Release -p:RestoreLockedMode=true
```

Portable tests exercise real TLS sockets, exporter-bound proof, wrong keys,
single-use/expired invitations, reconnects, terminal ownership, retained replay,
history limits, revocation isolation, bounded frames, and Windows path syntax.
Five Windows-only tests exercise real ConPTY/PowerShell, filesystem transfers
and junctions, and DPAPI. Those tests are explicitly skipped on Mac/Linux.
Native x64 and ARM64 Windows CI also opens and renders the WPF main window on an
STA thread using a temporary profile, checking the application's XAML and resources.

On macOS, verify the actual Swift client against the .NET protocol listener:

```sh
dotnet build Windows/Nocturne.Interop
NOCTURNE_DOTNET="$(command -v dotnet)" \
NOCTURNE_WINDOWS_TEST_HOST="$PWD/Windows/Nocturne.Interop/bin/Debug/net10.0/Nocturne.Interop.dll" \
swift test --filter WindowsHostInteropTests
```

The fixture is test-only and excluded from the Windows package. It does not
exercise Windows capture or native Windows APIs. Native UI, GPU capture/encoding,
audio playback, physical input, firewall behavior, and a complete iPhone-to-Windows
stream require a Windows PC and physical device. The Windows app can be
cross-compiled and packaged on macOS with the .NET 10 SDK and PowerShell 7; that
does not establish those runtime results.

Sunshine's version and architecture-specific SHA-256 digests are pinned in
`Windows/engine.lock.json`. NuGet dependencies are locked in each project's
`packages.lock.json`. See `THIRD_PARTY_NOTICES.md` for source and distribution
obligations.
