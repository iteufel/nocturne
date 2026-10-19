# Nocturne website

The product page at <https://iteufel.github.io/nocturne/> is a static site. It has no package dependencies, analytics, external fonts, or build step. Mac download links point directly to a published ZIP and refresh from the public GitHub Releases API to the most recently published Mac asset, including previews. If JavaScript or the API is unavailable, the pinned HTML download still works; update that fallback when publishing a new Mac release.

## Preview locally

From the repository root:

```sh
python3 -m http.server 8765 --directory site
```

Open <http://localhost:8765>. Check the desktop layout and a narrow phone viewport. The compatibility link opens its answer, and motion follows the visitor's reduced-motion preference.

## Publish

Changes to `site/` on `main` deploy through `.github/workflows/pages.yml`. The workflow can also be started manually in GitHub Actions. GitHub Pages must use **GitHub Actions** as its publishing source. Only `site/` is included in the deployment artifact. The CSS and JavaScript URLs in `index.html` carry the first 12 characters of their SHA-256 content hashes; update those query values when either file changes so returning visitors receive matching assets.

The app icon is copied unchanged from the client asset catalog. The hero and Mac section use real app captures. The terminal drawing and folder artwork are decorative illustrations; the terminal is explicitly labeled as an illustration. Do not substitute drawn or generated interfaces for app screenshots.

### Screenshot provenance

The website PNGs are lossless captures taken on October 19, 2026 from the actual running apps. They replace the earlier 1× captures; those historical originals remain under `artifacts/` and are described in the **Liquid Glass design pass** in [`docs/VERIFICATION.md`](../docs/VERIFICATION.md).

The iPhone image comes from an iPhone 18 Pro simulator at its native 3× resolution, in dark appearance. The iPad image comes from an iPad Pro 13-inch (M5) simulator at its native 2× resolution, in light appearance and landscape orientation. Both run iOS 27 and the local Nocturne 1.0 (1) simulator build from `.build/Xcode/Build/Products/Debug-iphonesimulator/Nocturne.app`. They show the genuine unpaired Computers screen. The simulators' status bars were set to 09:41 and full battery before capture with `simctl status_bar`; the PNGs were saved directly with `simctl io … screenshot`, without resampling or retouching.

The Mac image shows the installed Nocturne Server 1.0 (8.1) on macOS 27.0.1. ScreenCaptureKit captured only its 1040 × 760-point Overview window at 2× resolution, with `captureResolution = .best`, cursor and window shadow excluded. The capture does not include unrelated desktop windows. The existing server was not started, stopped, or reconfigured for this capture.

- `ipad-computers.png`: 2752 × 2064 pixels. SHA-256: `aca770431e50392c511f330fa85c337200cee664d147e173e29f216f17e0b275`.
- `iphone-computers.png`: 1206 × 2622 pixels. SHA-256: `58deb59ae5596851ba22a67a0c877b635d1009c3386f7287cd89e012ae5313de`.
- `mac-overview.png`: 2080 × 1520 pixels. SHA-256: `debfd582e35e59cc395b5d04daeb8efd5e29fc274cb3a7648ce0fe5ae27886d2`.

Build fingerprints (SHA-256): iOS `Nocturne.debug.dylib` = `03c1c7cd70b361757e13c49590fd50dfadc90f3868d9c66d543abe5a745aeb27`; Mac `Nocturne Server` executable = `03b1887754cd36950985c288b3abe75b860590d1f3abf4ecb4210332ba06a368`. The exact source revision of these pre-existing builds was not established; these captures document their UI, not a new runtime verification.

All three captures were inspected for passwords, pairing QR codes, tokens, private documents, and unrelated desktop content. App pixels and content were not edited. Images scale proportionally on the page and open at full resolution when selected. Their URLs carry the first 12 characters of the PNG content hashes, so replacing a capture also refreshes browser caches. Keep at least 2 source pixels per displayed CSS pixel for the iPad and Mac captures; never upscale a smaller source to make a Retina asset.

Future app screenshots must come from the actual running app. Check them for private data and record their build version, capture environment, and source. Update release availability and source links in `index.html` when a downloadable release or TestFlight invitation is actually available.
