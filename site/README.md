# Nocturne website

The product page at <https://iteufel.github.io/nocturne/> is a static site. It has no package dependencies, analytics, external fonts, or build step.

## Preview locally

From the repository root:

```sh
python3 -m http.server 8765 --directory site
```

Open <http://localhost:8765>. Check the desktop layout and a narrow phone viewport. The workspace tabs support clicks, arrow keys, Home, and End. The compatibility link opens its answer, and motion follows the visitor's reduced-motion preference.

## Publish

Changes to `site/` on `main` deploy through `.github/workflows/pages.yml`. The workflow can also be started manually in GitHub Actions. GitHub Pages must use **GitHub Actions** as its publishing source. Only `site/` is included in the deployment artifact.

The app icon is copied from the client asset catalog. The wallpaper and interface illustrations are original website assets; no personal desktop captures are published. Update release availability and source links in `index.html` when a downloadable release or TestFlight invitation is actually available.
