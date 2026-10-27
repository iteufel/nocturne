#!/bin/bash
set -euo pipefail
runtime="$SRCROOT/Vendor/StreamingRuntime/Contents"
contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -n "$identity" ] || identity=-
[ -x "$runtime/Helpers/nocturne-stream-host" ] || { echo 'Run scripts/bootstrap.sh to prepare the server runtime.' >&2; exit 1; }
bash "$SRCROOT/scripts/build-streaming-engine.sh"
engine="$SRCROOT/.build/SunshinePerformanceBuild/Sunshine.app/Contents/MacOS/Sunshine"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources"
# Copy runtime components directly into the Nocturne bundle. There is no nested .app or GUI launcher.
# macOS resolves Bundle.main for auxiliary executables inside Contents/MacOS.
# The engine's native permission checks need that app identity even with its tray disabled.
ditto "$engine" "$contents/MacOS/nocturne-stream-host"
ditto "$runtime/Frameworks" "$contents/Frameworks"
ditto "$runtime/Resources/assets" "$contents/Resources/assets"
for component in "$contents/Frameworks/"*; do
  case "$component" in
    *.framework|*.dylib) /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp=none "$component" ;;
  esac
done
/usr/bin/codesign --force --sign "$identity" --identifier app.nocturne.stream-host --options runtime --timestamp=none --entitlements "$SRCROOT/Resources/Server.entitlements" "$contents/MacOS/nocturne-stream-host"
# Remove only the old generated executable location during an incremental build.
rm -f "$contents/Helpers/nocturne-stream-host"
# Migration cleanup is limited to the old generated resource from earlier development builds.
if [ -d "$contents/Resources/Sunshine.app" ]; then rm -rf "$contents/Resources/Sunshine.app"; fi
bash "$SRCROOT/scripts/package-microphone-driver.sh"
