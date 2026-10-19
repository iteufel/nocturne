# Using Nocturne

Setup and feature instructions for the iPhone/iPad client and Mac server. For downloads and a quick start, see the [README](../README.md).

## Connect

1. Open **Nocturne Server** and select **Start server**. Allow screen/system audio capture and Accessibility for input when macOS asks. These permissions belong to Nocturne Server.
2. In **Sharing**, enable terminal/file access if wanted and choose the shared folder. Both features start disabled. Configure displays in **Nocturne Server → Settings…** while the server is stopped.
3. Choose **Pair a device**. On iPhone/iPad, choose **Add computer → Scan QR code** and scan the Mac's screen. Pairing completes automatically, including video, through the authenticated connection. Each QR code enrolls one device and expires after five minutes.
4. Choose **Desktop** to stream. Swipe inward from the right edge of the stream to open its controls. The menu opens terminal/files alongside the video. On large windows they appear to the side; smaller windows use a bottom panel.

Nearby computers are discovered automatically. Selecting an unpaired computer opens QR pairing. New devices must scan a QR code from Nocturne Server; manual PIN entry, address-based pairing, pasted links, and external pairing links are not supported. Already paired computers remain available.

Paired Macs are rediscovered when their IP address changes, including after moving both devices to another local network. Update both apps for workspace discovery by a stable pairing identity; existing QR pairings continue to work without scanning again. The client retries workspace connections while foregrounded and saves the authenticated address for video, terminal, files, and microphone access. Remote access is disabled by default, with `https://nocturne.alkal.de` preconfigured as the broker. For access from other networks, enable **Remote access** in the Mac server settings, keep the default broker or enter your own, and scan a new QR code. Nocturne tries local connections first, then uses an encrypted Rust transport that attempts peer-to-peer NAT traversal with relay fallback. See [online broker setup](REMOTE_ACCESS.md). An interrupted video stream or file transfer must be started again.

Selecting a discovered computer requires explicit pairing approval before its library or desktop can open. Cached streaming certificates alone cannot grant access. A new video pairing is saved only after both QR workspace authorization and the streaming handshake succeed. **Forget computer** removes its streaming approval, and forgetting the paired Mac also removes its linked video connection.

## Mac apps in iPad windows

Choose **Apps** in the client's sidebar or tab bar to browse the paired Mac's installed applications, with their icons and open windows. Tap an app to launch it; when it has several windows, choose the one to share. Long-press an app to open a particular existing window directly. Refresh the list after opening or closing windows on the Mac.

On iPad, each selected Mac window opens in a separate native Nocturne window. Use iPad windowing or Stage Manager to arrange several side by side. Selecting an already open stream returns to its existing iPad window. Up to four app windows per device (eight across the host) can stream independently. iPhone opens one app window inside the client.

Only the selected window is captured, including when another app covers it on the Mac. Resizing the iPad window resizes that actual Mac window in points and updates Retina video without restarting the desktop engine or other streams. Mac apps may enforce a minimum window size; Nocturne preserves the resulting aspect ratio. Touch, dragging, right-click by holding, two-finger scrolling, hardware keyboards/mice, and the toolbar's software keyboard control the selected window. Closing the stream leaves the app running and restores its original window size unless it was manually resized on the Mac. Backgrounding releases that scene's capture; returning reconnects it.

Both apps must support app windows. The Mac server needs **Screen Recording** and **Accessibility** permission. Apps without an open, capturable, resizable window report an error. App streams currently carry H.264 video and input; audio, game controllers, other windows, app menus, and separate dialog windows are not included. Desktop streaming remains available for those uses. Individual window control uses a runtime-checked macOS window-ID bridge in the directly distributed server.

**Devices → Your devices** lists paired streaming devices and connected workspaces by name, with a separate **Remove…** action for each. Removing one device closes its terminal/file sessions, disables its active stream, and revokes its pairing without disconnecting the others. Saved devices remain visible while the server is stopped. “Connected” indicates an open workspace connection; streaming-only clients are shown as “Paired”.

One **Stop server** stops capture, streaming, terminal sessions, and transfers. Quitting the Mac app stops its child engine. **Reset all pairing** revokes video certificates and rotates the workspace key together.

## Adaptive and headless displays

On iOS, choose **Settings → Resolution → Match device** (the default for new installations). With the Mac server stopped, enable **Nocturne Server → Settings → Displays → Headless virtual monitor**, then start the server and pair using its QR code. Nocturne creates a Retina virtual display with the same pixel dimensions as the client's video area. Rotation, iPad window resizing, and opening the stream's tools panel update that size automatically. Video briefly reconnects to negotiate the new resolution; terminal tabs stay running. Dimensions are even and capped at 4096 pixels per side while preserving aspect ratio. Fixed resolution choices remain available. Match device reports missing display control instead of silently scaling video over an unchanged desktop.

Enable **Turn off connected Mac displays** before starting the server to move the Mac's windows onto the streamed desktop. The virtual display becomes the only active monitor. Disconnecting, backgrounding the client, removing its device, or stopping the server restores the saved display modes and arrangement. A missing client heartbeat releases the display after 20 seconds. **Restore Mac displays** is also available in the Mac menu bar. An internal recovery process restores monitors if the main server app exits unexpectedly.

The same virtual display supports a headless Mac without an HDMI dummy plug or separate display app. It stays available between streams until the server stops, including when physical screens are connected. Physical screens keep their layout unless the separate monitor-off option is enabled. The Mac must be awake with a logged-in desktop; Nocturne does not unlock FileVault or bypass the login screen. Turn off **Headless virtual monitor** to select a physical monitor instead; choose a fixed resolution on iOS in that mode. Existing physical-monitor selections remain unchanged after upgrading. Automatic Mac display control requires the authenticated Nocturne workspace connection, and only one stream can own it at a time.

Virtual display creation and monitor disabling use runtime-checked private macOS interfaces. These features are intended for the directly distributed Mac app, not a Mac App Store build. If unavailable on a macOS release, the app reports the failure and a connected display can be selected instead.

## Devices and input

- Native Apple Liquid Glass on iOS/iPadOS 26+ and macOS 26+: floating tabs, system sidebars/toolbars, glass action buttons, and stream controls. Earlier systems use native bordered controls and materials. Choose System, Light, or Dark in Nocturne → Settings → Appearance on iOS, or **Nocturne Server → Settings…** (⌘,) on macOS. Content surfaces honor Reduce Transparency; the terminal and video retain a dark canvas.
- iPhone and iPad: native tabs, sidebar navigation, rotation, Split View/window resizing, safe areas, and a persistent stream workspace with automatic resolution renegotiation. Stream controls stay hidden until you swipe inward from the right edge; there is no floating button or persistent bar. A brief hint explains the gesture when a stream starts, and VoiceOver offers an Open stream controls action.
- **Settings → Stream display → Fill entire screen**, also available in the live controls menu, switches between safe-area fit (the default) and the entire display. Safe-area fit keeps video clear of the camera, rounded corners, and home indicator. The choice is saved, applies immediately, and follows rotation and tools-panel resizing. Match device briefly reconnects when the video dimensions change; fixed resolutions retain their aspect ratio.
- iPhone Duo: responds to the actual scene size for compact/expanded layouts. There is no invented hinge API or second-phone controller mode. Dedicated Duo hardware verification is still required.
- Choose **Settings → Controls → Input mode → Touch or Trackpad**, or change it from the stream controls menu while connected. Touch clicks where you tap; hold for a right-click or move your finger to drag. Trackpad moves the pointer with one finger, taps to click, uses a two-finger tap for right-click, and scrolls with two fingers. Hold one finger before moving to drag. A three-finger tap opens the keyboard. The choice is saved and changes immediately without reconnecting the video.
- Bluetooth keyboards, mice, trackpads, and MFi/Xbox/PlayStation controllers use native input. Pair accessories in iOS Settings. Mouse/trackpad accessories work in either input mode, including UIKit input when pointer lock is unavailable in a window or Split View.
- The bundled engine uses VideoToolbox for H.264/HEVC, with client controls for resolution, bitrate, frame rate, HDR, pacing, touch input, and statistics. Hardware and network conditions determine supported combinations.
- macOS gamepad emulation requires a compatible **Virtual HID Broker** installation/driver. Nocturne includes controller forwarding; this Mac does not have that driver. Physical controller forwarding, latency, HDR, and system-audio playback require device testing.

## Microphone and voice chat

Forward the iPhone/iPad microphone (including its current wired, USB, or Bluetooth headset input) to Discord or a game **on the Mac**:

1. In **Nocturne Server → Sharing**, choose **Install microphone input…**, approve the macOS administrator prompt, and restart the Mac. The driver is bundled with Nocturne Server; no separate audio-routing app is needed.
2. Enable **Client microphone** in Sharing. Pair the client using the Nocturne Server QR code and reconnect it after enabling this feature.
3. In Discord or your game’s audio settings, choose **Nocturne Microphone** as the input. Keep the game’s output on its normal device so it continues through the video stream.
4. Start a stream, tap its microphone button, and allow iOS microphone access. **Mic on** indicates capture; tap again to mute.

Each stream starts muted. Backgrounding, disconnecting, changing audio devices, audio interruptions, or a video reconnect during resizing mutes it again. Unmute explicitly to resume. One client can own the Mac input at a time. Disabling Client microphone, removing the device, or stopping the server flushes its audio. Use headphones to reduce game-audio feedback; Bluetooth hands-free microphone use may lower playback quality.

This feature requires both Nocturne apps and an authenticated workspace connection; standard Sunshine/GameStream-only hosts do not expose it. Traffic is encrypted, uses a separate socket from terminal/files, and is not recorded. The input driver stays available to Mac apps and produces silence while muted. It does not change the Mac’s default input or output.

The installation is `/Library/Audio/Plug-Ins/HAL/NocturneMicrophone.driver`. To uninstall, move only that bundle to Trash using Finder with administrator approval, then restart the Mac. Driver installation/restart is a user action; building or running tests does not install it.

## Terminal and files

The terminal is SwiftTerm connected to a real `/bin/zsh -l` PTY on the Mac. Open up to eight independent tabs with **+**, switch between them, and close a single shell with its tab’s **×**. Tabs are available in both the Terminal workspace and the stream tools panel. Escape, Tab, Control, and arrows come from the terminal keyboard’s built-in accessory; there is no duplicate shortcut strip.

Shells and running commands stay on the Mac when the mobile app backgrounds, disconnects, or quits. Reconnecting restores the same tabs, working directories, shell variables, and buffered output (the latest 512 KiB per tab). Finished shells remain readable until you close their tabs. The Mac server must stay running: closing a tab, disabling Terminal, removing its device, stopping the server, or quitting the Mac app ends the affected shells. Sessions do not survive a Mac/server restart.

File transfer is bidirectional, chunked, cancellable, and restricted to the selected shared folder. Uploads remain invisible until committed and cannot overwrite an existing file. Symlinks, path traversal, and non-regular files are rejected with descriptor-based filesystem operations. Downloads use the native iOS share sheet, including Save to Files; uploads use the native document picker and file URL drop support.

The paired Mac also appears in Apple’s **Files** app. Enable **File sharing** on the Mac and pair or reconnect Nocturne, then open **Files → Browse → Locations → Nocturne**. Enable the location when asked. If it is hidden, use **More (…) → Edit** to enable Nocturne. Browse subfolders, preview documents, and copy files to your device or another app. The Mac must be reachable and Nocturne Server running; the extension connects independently while Nocturne is in the background. **Settings → Apple Files → Refresh Files location** retries registration after reconnecting.

The Files location provides browsing and downloads; send new files through Nocturne’s Files tab. Access stays inside the Mac’s chosen shared folder. Forgetting the paired Mac removes the location and its extension credentials; disabling File sharing blocks new reads immediately and removes the location when Nocturne reconnects. Copies already saved to your device remain available.

## Pairing and security

Pairing QR codes contain a private 256-bit transport key and a single-use enrollment token that expires after five minutes. Each device also proves possession of its own streaming certificate on every workspace connection; the proof is bound to that TLS session. A certificate alone cannot register a new workspace device, and a removed device cannot reuse the old shared key or invitation to regain access. Update both apps for workspace protocol version 4; an existing workspace-only pairing may need a fresh QR code. Keys are stored in Keychain, never in Bonjour or UserDefaults. Workspace traffic uses authenticated TLS-PSK; video uses the upstream pairing and encrypted transport implementation. Terminal access runs as the Mac user and is explicitly opt-in.

Streaming approval is stored separately in Keychain and bound to the computer ID and both certificates. Discovery and cached transport credentials cannot grant it. The direct server runtime is pinned to Sunshine `v2026.1018.5342`, an official prerelease containing the fix for duplicate certificate records when re-pairing; its download checksum is verified by bootstrap.
