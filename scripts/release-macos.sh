#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The caller writes credentials with umask 077. Distributed app files must also
# be readable by other users when the app is installed in shared Applications.
umask 022

: "${NOCTURNE_DEVELOPER_ID:?Set the Developer ID Application signing identity}"
: "${NOCTURNE_DEVELOPMENT_TEAM:?Set the Apple Developer team ID}"
: "${NOCTURNE_BUILD_NUMBER:?Set a unique numeric build number}"
: "${NOCTURNE_NOTARY_KEY_PATH:?Set the path to the App Store Connect API private key}"
: "${NOCTURNE_NOTARY_KEY_ID:?Set the App Store Connect API key ID}"
: "${NOCTURNE_NOTARY_ISSUER_ID:?Set the App Store Connect API issuer ID}"
if [[ ! "$NOCTURNE_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo 'The build number must have one to three numeric components.' >&2
  exit 1
fi

output="$PWD/.build/MacRelease"
app="$output/Nocturne.app"
mkdir -p "$output"

# Compile without a distribution identity in Xcode, then sign inside out below.
# This keeps application signing settings away from SwiftPM build products.
xcodebuild -project Nocturne.xcodeproj -scheme 'Nocturne Mac' \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build/XcodeMacRelease ARCHS=arm64 \
  CURRENT_PROJECT_VERSION="$NOCTURNE_BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build

rm -rf "$app"
ditto '.build/XcodeMacRelease/Build/Products/Release/Nocturne.app' "$app"
actual_build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
if [ "$actual_build" != "$NOCTURNE_BUILD_NUMBER" ]; then
  echo "Mac bundle build number $actual_build does not match requested build $NOCTURNE_BUILD_NUMBER." >&2
  exit 1
fi
sign=(/usr/bin/codesign --force --sign "$NOCTURNE_DEVELOPER_ID" --options runtime --timestamp)
if [ -n "${NOCTURNE_SIGNING_KEYCHAIN:-}" ]; then
  sign+=(--keychain "$NOCTURNE_SIGNING_KEYCHAIN")
fi
for component in "$app/Contents/Frameworks/"*; do
  case "$component" in
    *.framework|*.dylib) "${sign[@]}" "$component" ;;
  esac
done
"${sign[@]}" --identifier app.nocturne.stream-host \
  --entitlements Resources/Server.entitlements "$app/Contents/MacOS/nocturne-stream-host"
"${sign[@]}" "$app/Contents/Resources/NocturneMicrophone.driver"
"${sign[@]}" --entitlements Resources/Server.entitlements "$app"
python3 scripts/verify-macos-release.py "$app" "$NOCTURNE_DEVELOPMENT_TEAM"
codesign -dv --verbose=4 "$app" 2> "$output/signature.txt"

ditto -c -k --sequesterRsrc --keepParent "$app" "$output/notarization-upload.zip"
notary=(--key "$NOCTURNE_NOTARY_KEY_PATH" --key-id "$NOCTURNE_NOTARY_KEY_ID" --issuer "$NOCTURNE_NOTARY_ISSUER_ID")
xcrun notarytool submit "$output/notarization-upload.zip" "${notary[@]}" \
  --output-format json > "$output/submission.json"
submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$output/submission.json")"
echo "Waiting for Apple notarization: $submission_id"
xcrun notarytool wait "$submission_id" "${notary[@]}" --timeout 45m \
  --output-format json > "$output/notarization.json"
xcrun notarytool log "$submission_id" "${notary[@]}" "$output/notarization-log.json"
python3 - "$output/notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result['status'] != 'Accepted':
    raise SystemExit('Apple did not accept this build: ' + result['status'])
print('Apple accepted the notarized Mac build.')
PY

xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=4 "$app"

# Staple the app before creating the archive users actually download.
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/Nocturne-macOS-arm64.zip"
(cd "$output" && shasum -a 256 Nocturne-macOS-arm64.zip > SHA256SUMS.txt)
echo "Signed, notarized release: $output/Nocturne-macOS-arm64.zip"
