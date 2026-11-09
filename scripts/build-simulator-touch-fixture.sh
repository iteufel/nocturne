#!/bin/bash
# Build only. Install/open the fixture on an explicitly selected test simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/.build/SimulatorTouchFixture.app"
mkdir -p "$app" .build/fixture-module-cache
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator -sdk "$sdk" \
  -module-cache-path "$PWD/.build/fixture-module-cache" \
  scripts/fixtures/SimulatorTouchFixture.swift -o "$app/SimulatorTouchFixture"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.nocturne.simulator-touch-fixture</string>
<key>CFBundleExecutable</key><string>SimulatorTouchFixture</string>
<key>CFBundleName</key><string>Nocturne Touch Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string><string>UIInterfaceOrientationPortraitUpsideDown</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
