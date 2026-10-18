# Nocturne website

The product page at <https://iteufel.github.io/nocturne/> is a static site. It has no package dependencies, analytics, external fonts, or build step.

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

The following PNGs are byte-for-byte copies of the captures recorded in the **Liquid Glass design pass** in [`docs/VERIFICATION.md`](../docs/VERIFICATION.md). They show the running development apps on October 18, 2026: iPhone 18 Pro and iPad Pro simulators on iOS 27, and the native Mac app on macOS 27. They are historical captures of that verified build, not new captures or proof of current server availability. The exact build revision was not recorded with the originals. Appearance and controls may differ in later builds, including the subsequent move of Mac appearance controls into Settings.

| Website image | Original capture | SHA-256 |
| --- | --- | --- |
| `assets/screenshots/ipad-computers.png` | `artifacts/nocturne-glass-ipad-light.png` | `d1924e4782852c89fc8898e9772cc589ab47a9c635aeb516f0cbc9305a1a494c` |
| `assets/screenshots/iphone-computers.png` | `artifacts/nocturne-glass-iphone-dark.png` | `327215842c5442059e334936c6fa917e6804e50f092d9aa535aa6b4db526c2e5` |
| `assets/screenshots/mac-overview.png` | `artifacts/nocturne-glass-mac-dark.png` | `5768a685035d889a91220a7a60396c7c1e748162271ed255125c80ec6c9d225c` |

The originals were inspected before publication. They show app UI and local test-host details, with no passwords, pairing QR codes, tokens, private documents, or unrelated desktop windows. No pixels, labels, status, or app content were changed. The images scale proportionally on the page and open at full size when selected.

Future app screenshots must come from the actual running app. Check them for private data and record their build version, capture environment, and source. Update release availability and source links in `index.html` when a downloadable release or TestFlight invitation is actually available.
