# Using Nocturne

Setup and feature instructions for the iPhone/iPad client and the Mac app's host and client. For downloads and a quick start, see the [README](../README.md).

## Connect

1. Open **Nocturne**. The saved Sharing toggles determine which services start. Allow screen/system audio capture and Accessibility for input when macOS asks. These permissions belong to Nocturne.
2. In **Sharing**, enable terminal/file access if wanted and choose the shared folder, then select **Apply & restart**. Both features start disabled. Screen sharing starts enabled and can be turned off independently. Configure displays in **Nocturne → Settings…**; settings stay editable while the server runs and take effect when you apply them.
3. Choose **Pair a device**. On iPhone/iPad, choose **Add host → Scan QR code** and scan the Mac's screen. Pairing completes automatically, including video, through the authenticated connection. Each QR code enrolls one device and expires after five minutes.
4. Tap a saved host in **Computers → Paired hosts** to open its desktop. After first-time pairing, choose **Desktop** from its library. Swipe inward from the right edge of the stream to open its controls. The menu opens terminal/files alongside the video. On large windows they appear to the side; smaller windows use a bottom panel.

Nearby hosts are discovered automatically on iPhone and iPad. Select **Pair a device** on the Mac and scan its QR code using **Add host** on the iOS client. No address selection or entry is needed: the QR code uses the Mac’s local network name, and authenticated discovery finds its current connection address. Selecting an unpaired nearby host also opens QR pairing. The iOS client accepts pairing through its scanner; manual PIN entry, pasted links, and external pairing links are not supported there. Already paired hosts remain available.

Paired Macs are rediscovered when their IP address changes, including after moving both devices to another local network. Update both apps for workspace discovery by a stable pairing identity; existing QR pairings continue to work without scanning again. The client retries workspace connections while foregrounded and saves the authenticated address for video, terminal, files, and microphone access. Remote access is disabled by default, with `https://nocturne.alkal.de` preconfigured as the broker. For access from other networks, enable **Remote access** in the Mac server settings, keep the default broker or enter your own, and scan a new QR code. Nocturne tries local connections first, then uses an encrypted Rust transport that attempts peer-to-peer NAT traversal with relay fallback. See [online broker setup](REMOTE_ACCESS.md). An interrupted video stream or file transfer must be started again.

Selecting a discovered computer requires explicit pairing approval before its library or desktop can open. Cached streaming certificates alone cannot grant access. A new video pairing is saved only after both QR workspace authorization and the streaming handshake succeed. **Forget host** in a host’s details removes its workspace pairing and linked video approval.

### Mac to Mac

Install the updated **Nocturne** app on both Macs. On the host, enable **Screen sharing**, allow Screen & System Audio Recording and Accessibility, and choose **Pair a device → Copy pairing code**. On the viewing Mac, open **Computers → Add host**, paste that code, and choose **Add & connect**. The same one-device, five-minute invitation used by QR pairing authorizes this connection. Pairings and the outgoing device identity are saved in Keychain separately from the local host's credentials.

The remote desktop opens in its own Mac window. Click inside to send keyboard shortcuts, mouse movement, clicks, dragging, and scrolling to the host. Press **Control–Option–Escape** to release the keyboard locally. The toolbar selects a host display, mutes system audio, reconnects, and toggles full screen. Losing keyboard focus releases held keys and buttons. Closing the desktop window disconnects it; your local host and other connected devices keep running. Saved hosts remain under Computers and can be forgotten individually.

Choose **Apps** next to a paired host, or in the desktop toolbar, to browse its installed applications and open windows. Search by app or window name. Click an app to launch it, then choose its window if it has several. Each selected window opens with its original host title bar and a small drag handle above it, without an additional local title bar or toolbar. Drag the handle to move the viewer; right-click it for **Fit window to app**, **Reconnect**, **Toggle full screen**, and **Close stream**. The handle also exposes these actions to VoiceOver. Reopening the same window focuses its existing viewer. Up to four app windows per device can stream independently.

Resizable apps follow the viewer's size. Non-resizable apps and apps that reject a resize keep their actual dimensions; their viewer scales the image while preserving its shape and input coordinates. Closing a viewer leaves its app running; closing the Apps browser or desktop leaves other app viewers connected. The menu bar can reopen each viewer. App streams carry video and keyboard/mouse input; use Desktop for system audio, app menus, and separate dialogs.

Mac desktop streams default to **Displays → Match window**. Enable **Headless virtual monitor** on the host and update both Macs. Nocturne creates a desktop matching the viewer's content size and Retina scale, then adjusts it when the viewer resizes or moves to another screen. This keeps ultrawide host monitors from being squeezed onto a laptop screen. Resolution is capped at 4096 pixels per side. Display and capture leases are released on disconnect. The host's existing **Turn off connected Mac displays** setting controls whether physical monitors stay on, as for iPad streams.

Choose an existing monitor in **Displays** to stream its original resolution and arrangement; **Match window** returns to the adaptive desktop. If matching is unavailable, Nocturne reports how to enable it and lets you choose a physical display explicitly. One Mac client controls a host desktop at a time. Desktop also shows an already signed-in host's lock screen and accepts its normal password; capture follows the main display while locked, then returns to the requested display after unlock. System audio resumes after unlocking. See [Unlock a locked Mac](#unlock-a-locked-mac) for prerequisites and startup limitations.

The Mac client provides desktop video, stereo audio, app windows, adaptive virtual-display control, and keyboard/mouse input. Terminal, Files integration, game controllers, and microphone forwarding remain in the iPhone/iPad client. Both Mac apps must support the optional desktop/app-window capabilities. Older hosts show an update instruction. LAN discovery and authenticated remote-access tunnels use the same saved host identity as other Nocturne connections.

### Automatic startup and settings

In **Nocturne → Settings… → Startup**, enable **Open Nocturne at login** to launch the host app when you sign in. Select **Apply** to save. The saved toggles in **Sharing** start the enabled services whenever Nocturne opens. If macOS requires approval, use **Open Login Items…** to allow Nocturne. Closing the window leaves enabled services running in the menu bar. To stop them, turn their Sharing toggles off and apply, or choose **Quit Nocturne**.

Changes in Sharing and Settings remain pending until **Apply**. Applying while the server is running restarts it and disconnects current sessions, including background shells and file transfers. **Apply & start** starts the enabled services when sharing is off; **Apply & stop** stops the server when every Sharing toggle is off. **Discard** restores the last applied settings. Appearance changes take effect immediately.

When **Screen sharing** is enabled, its engine starts and stays ready while Nocturne is open and restarts automatically after a failure. Files and terminal remain available during screen-sharing startup or recovery, and also work with screen sharing turned off. Disabling screen sharing also disables individual app-window sharing. A temporary headless startup display is still removed when the engine is ready.

### Paired hosts

Use **Add host** to scan another host’s QR code. Earlier pairings stay saved. **Settings → Paired hosts** opens the saved-host list; select a host for **Open desktop**, **Open library**, **Reconnect**, and **Forget host**. Saved hosts also appear first on Computers, including when they are offline.

One host is selected for Apps, Terminal, Files, display control, and the microphone. Switch it from **Your workspace**, from the toolbar on Apps, Terminal, and Files, or from a host’s details. Opening a host’s desktop or library selects and authenticates that host before requesting video approval. Shells keep running on each host; app windows already open keep using their own host, and each host has its own Apple Files location.

Workspace availability and screen sharing are shown separately. An interrupted video setup resumes through the saved authenticated connection without another QR scan. If it fails, **Retry screen sharing** retries that step while keeping the pairing. Setup can be cancelled and times out with a retry action rather than staying busy indefinitely.

**Forget host** removes only that host’s pairing, Files location, app windows, and video approval after confirmation. If a host resets its pairing and you scan a new QR code, the new pairing replaces the old one. Existing single-host pairings carry over automatically.

## Mac apps in iPad windows

Choose **Apps** in the client's sidebar or tab bar to browse the paired Mac's installed applications, with their icons and open windows. Tap an app to launch it; when it has several windows, choose the one to share. Long-press an app to open a particular existing window directly. Refresh the list after opening or closing windows on the Mac.

Shared windows adapt to the video area's proportions, including rotation. When a Mac app enforces a minimum width or height, Nocturne grows the other dimension proportionally and moves the window within its existing monitor so macOS can resize it. The window's original size and position are restored on close if they still match the stream's applied geometry. **Fill entire screen** also applies to app windows and is available in their controls menu. It uses the camera-side and home-indicator areas while keeping Close and Keyboard controls accessible; if an app's hard size limits still prevent a matching shape, Fill crops excess edges and maps input through that crop.

On iPad, each selected Mac window opens in a separate native Nocturne window. Use iPad windowing or Stage Manager to arrange several side by side. Selecting an already open stream returns to its existing iPad window. Up to four app windows per device (eight across the host) can stream independently. iPhone opens one app window inside the client.

Only the selected window is captured, including when another app covers it on the Mac. Resizing the iPad window resizes that actual Mac window in points and updates Retina video without restarting the desktop engine or other streams. Mac apps may enforce a minimum window size; Nocturne preserves the resulting aspect ratio. Touch, dragging, right-click by holding, two-finger scrolling, hardware keyboards/mice, and the toolbar's software keyboard control the selected window. Closing the stream leaves the app running and restores its original window size unless it was manually resized on the Mac. Backgrounding releases that scene's capture; returning reconnects it.

Both apps must support app windows. The Mac server needs **Screen Recording** and **Accessibility** permission. Apps without an open, capturable window report an error. App streams currently carry H.264 video and input; audio, game controllers, other windows, app menus, and separate dialog windows are not included. Desktop streaming remains available for those uses. Individual window control uses a runtime-checked macOS window-ID bridge in the directly distributed server. Touch or type to activate the shared app on your Mac. Pointer events use the normal macOS input route, so the Mac pointer moves as you control the window.

**Devices → Your devices** lists paired streaming devices and connected workspaces by name, with a separate **Remove…** action for each. Removing one device closes its terminal/file sessions, disables its active stream, and revokes its pairing without disconnecting the others. Saved devices remain visible while the server is stopped. “Connected” indicates an open workspace connection; streaming-only clients are shown as “Paired”.

Turn off all features in **Sharing** and apply to stop capture, streaming, terminal sessions, and transfers. Quitting the Mac app stops its child engine. **Reset all pairing** revokes video certificates and rotates the workspace key together.

## Adaptive and headless displays

On iOS, choose **Settings → Resolution → Match device** (the default for new installations). Enable **Nocturne → Settings → Displays → Headless virtual monitor**, apply your changes, then pair using its QR code. Nocturne creates a Retina virtual display with the same pixel dimensions as the client's video area. Rotation, iPad window resizing, and opening the stream's tools panel update that size automatically. Video briefly reconnects to negotiate the new resolution; terminal tabs stay running. Dimensions are even and capped at 4096 pixels per side while preserving aspect ratio. Fixed resolution choices remain available. Match device reports missing display control instead of silently scaling video over an unchanged desktop.

Enable **Turn off connected Mac displays** and apply your changes to move the Mac's windows onto the streamed desktop. The virtual display becomes the only active monitor. Disconnecting, backgrounding the client, removing its device, or stopping the server restores the saved display modes and arrangement. A missing client heartbeat releases the display after 20 seconds. **Restore Mac displays** is also available in the Mac menu bar. An internal recovery process restores monitors if the main server app exits unexpectedly.

The same virtual display supports a headless Mac without an HDMI dummy plug or separate display app. It is removed when the stream disconnects and recreated when the next stream connects. The temporary display used to start the video engine is also removed once the server is ready. Physical screens keep their layout unless the separate monitor-off option is enabled; when enabled, Nocturne restores them before removing its virtual display. The Mac must be awake with a signed-in user session; that session can be locked. Turn off **Headless virtual monitor** to select a physical monitor instead; choose a fixed resolution on iOS in that mode. Existing physical-monitor selections remain unchanged after upgrading. Automatic Mac display control requires the authenticated Nocturne workspace connection, and only one stream can own it at a time.

Virtual display creation and monitor disabling use runtime-checked private macOS interfaces. These features are intended for the directly distributed Mac app, not a Mac App Store build. If unavailable on a macOS release, the app reports the failure and a connected display can be selected instead.

## Unlock a locked Mac

Leave **Nocturne** running, then open **Desktop** from an already paired iPhone, iPad, or Mac. The stream shows the Mac's lock screen. On iPhone/iPad, open **Keyboard** from the stream controls or use a connected keyboard. On Mac, click inside the desktop viewer and type your normal Mac password. Individual app windows require unlocking through Desktop first.

While locked, video follows the Mac's main display, where macOS shows the password field. After you unlock, it returns to the selected physical or virtual display automatically. The lock screen may have a different aspect ratio from your virtual desktop. Pairing, Screen Recording and Accessibility permissions must already be set up.

When connecting to a locked Mac, connected monitors stay on for login. If **Turn off connected Mac displays** is enabled, reconnect after unlocking to apply it. Nocturne avoids changing the physical monitor layout while macOS is locked.

This works for locking an existing user session. Logging out or restarting ends the server; sign in locally before connecting. Enable **Open Nocturne at login** and leave the desired Sharing toggles enabled to make Nocturne available after signing in. FileVault's startup unlock screen is not accessible through Nocturne.

## Devices and input

- Native Apple Liquid Glass on iOS/iPadOS 26+ and macOS 26+: floating tabs, system sidebars/toolbars, glass action buttons, and stream controls. Earlier systems use native bordered controls and materials. Choose System, Light, or Dark in Nocturne → Settings → Appearance on iOS, or **Nocturne → Settings…** (⌘,) on macOS. Content surfaces honor Reduce Transparency; the terminal and video retain a dark canvas.
- iPhone and iPad: native tabs, sidebar navigation, rotation, Split View/window resizing, safe areas, and a persistent stream workspace with automatic resolution renegotiation. Stream controls stay hidden until you swipe inward from the right edge; there is no floating button or persistent bar. A brief hint explains the gesture when a stream starts, and VoiceOver offers an Open stream controls action.
- **Settings → Stream display → Fill entire screen**, also available in the live controls menu, switches between safe-area fit (the default) and filling the entire display. Fill scales the video to cover the display, cropping excess edges when its aspect ratio differs; touch coordinates follow that crop. Safe-area fit keeps the full video clear of the camera, rounded corners, and home indicator. The choice is saved, applies immediately, and follows rotation and tools-panel resizing. Match device briefly reconnects when the video dimensions change. Black borders already included by the host in the encoded video remain part of the picture.
- iPhone Duo: responds to the actual scene size for compact/expanded layouts. There is no invented hinge API or second-phone controller mode. Dedicated Duo hardware verification is still required.
- Choose **Settings → Controls → Input mode → Touch or Trackpad**, or change it from the stream controls menu while connected. Touch clicks where you tap; hold for a right-click or move your finger to drag. Trackpad moves the pointer with one finger, taps to click, uses a two-finger tap for right-click, and scrolls with two fingers. Hold one finger before moving to drag. A three-finger tap opens the keyboard. The choice is saved and changes immediately without reconnecting the video.
- Bluetooth keyboards, mice, trackpads, and MFi/Xbox/PlayStation controllers use native input. Pair accessories in iOS Settings. Mouse/trackpad accessories work in either input mode, including UIKit input when pointer lock is unavailable in a window or Split View.
- **Lock pointer** is on by default for each desktop stream. In full screen, a connected mouse or trackpad controls the Mac with relative movement and the iPad pointer stays hidden. Press **⌘⇧M** (Command–Shift–M), or swipe inward from the right edge with a finger, to release the pointer and open stream controls. Turn off **Lock pointer** there to keep the local pointer available. Controls, Terminal, and Files release the lock automatically; closing them restores it. iPadOS decides when capture is available, so windowed/Split View sessions keep ordinary pointer input.
- The bundled engine uses VideoToolbox for H.264/HEVC, with client controls for resolution, bitrate, frame rate, HDR, pacing, touch input, and statistics. Hardware and network conditions determine supported combinations.
- macOS gamepad emulation requires a compatible **Virtual HID Broker** installation/driver. Nocturne includes controller forwarding; this Mac does not have that driver. Physical controller forwarding, latency, HDR, and system-audio playback require device testing.

## Microphone and voice chat

Forward the iPhone/iPad microphone (including its current wired, USB, or Bluetooth headset input) to Discord or a game **on the Mac**:

1. In **Nocturne → Sharing**, choose **Install microphone input…**, approve the macOS administrator prompt, and restart the Mac. The driver is bundled with Nocturne; no separate audio-routing app is needed.
2. Enable **Client microphone** in Sharing. Pair the client using the Nocturne QR code and reconnect it after enabling this feature.
3. In Discord or your game’s audio settings, choose **Nocturne Microphone** as the input. Keep the game’s output on its normal device so it continues through the video stream.
4. Start a stream, tap its microphone button, and allow iOS microphone access. **Mic on** indicates capture; tap again to mute.

Each stream starts muted. Backgrounding, disconnecting, changing audio devices, audio interruptions, or a video reconnect during resizing mutes it again. Unmute explicitly to resume. One client can own the Mac input at a time. Disabling Client microphone, removing the device, or stopping the server flushes its audio. Use headphones to reduce game-audio feedback; Bluetooth hands-free microphone use may lower playback quality.

This feature requires both Nocturne apps and an authenticated workspace connection; standard Sunshine/GameStream-only hosts do not expose it. Traffic is encrypted, uses a separate socket from terminal/files, and is not recorded. The input driver stays available to Mac apps and produces silence while muted. It does not change the Mac’s default input or output.

The installation is `/Library/Audio/Plug-Ins/HAL/NocturneMicrophone.driver`. To uninstall, move only that bundle to Trash using Finder with administrator approval, then restart the Mac. Driver installation/restart is a user action; building or running tests does not install it.

## Terminal and files

The terminal is SwiftTerm connected to a real `/bin/zsh -l` PTY on the Mac. Open up to eight independent tabs with **+**, switch between them, and close a single shell with its tab’s **×**. Tabs are available in both the Terminal workspace and the stream tools panel. Escape, Tab, Control, and arrows come from the terminal keyboard’s built-in accessory; there is no duplicate shortcut strip.

Shells and running commands stay on the Mac when the mobile app backgrounds, disconnects, or quits. Reconnecting restores the same tabs, working directories, shell variables, and buffered output (the latest 512 KiB per tab). Finished shells remain readable until you close their tabs. The Mac server must stay running: closing a tab, disabling Terminal, removing its device, stopping the server, or quitting the Mac app ends the affected shells. Sessions do not survive a Mac/server restart.

File transfer is bidirectional, chunked, cancellable, and restricted to the selected shared folder. Uploads remain invisible until committed and cannot overwrite an existing file. Symlinks, path traversal, and non-regular files are rejected with descriptor-based filesystem operations. Downloads use the native iOS share sheet, including Save to Files; uploads use the native document picker and file URL drop support.

Each paired Mac also appears as its own location in Apple’s **Files** app. Enable **File sharing** on the Mac and pair or reconnect Nocturne, then open **Files → Browse → Locations → Nocturne**. Enable the location when asked. If it is hidden, use **More (…) → Edit** to enable Nocturne. Browse subfolders, preview documents, and copy files to your device or another app. The Mac must be reachable and Nocturne running; the extension connects independently while Nocturne is in the background. **Settings → Apple Files → Refresh Files location** retries registration after reconnecting.

The Files location provides browsing and downloads; send new files through Nocturne’s Files tab. Access stays inside the Mac’s chosen shared folder. Forgetting a paired Mac removes its location and extension credentials; disabling File sharing blocks new reads immediately and removes the location when Nocturne reconnects. Copies already saved to your device remain available.

## Pairing and security

Pairing QR codes contain a private 256-bit transport key and a single-use enrollment token that expires after five minutes. Each device also proves possession of its own streaming certificate on every workspace connection; the proof is bound to that TLS session. A certificate alone cannot register a new workspace device, and a removed device cannot reuse the old shared key or invitation to regain access. Update both apps for workspace protocol version 4; an existing workspace-only pairing may need a fresh QR code. Keys are stored in Keychain, never in Bonjour or UserDefaults. Workspace traffic uses authenticated TLS-PSK; video uses the upstream pairing and encrypted transport implementation. Terminal access runs as the Mac user and is explicitly opt-in.

Streaming approval is stored separately in Keychain and bound to the computer ID and both certificates. Discovery and cached transport credentials cannot grant it. The direct server runtime is pinned to Sunshine `v2026.1018.5342`, an official prerelease containing the fix for duplicate certificate records when re-pairing; its download checksum is verified by bootstrap.
