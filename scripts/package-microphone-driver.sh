#!/bin/bash
set -euo pipefail
driver="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/NocturneMicrophone.driver"
mkdir -p "$driver/Contents/MacOS"
cp "$SRCROOT/Resources/Microphone-Info.plist" "$driver/Contents/Info.plist"
architectures=()
for architecture in ${ARCHS:-arm64}; do architectures+=(-arch "$architecture"); done
xcrun --sdk macosx clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -Werror \
  -mmacosx-version-min=14.0 "${architectures[@]}" -bundle \
  "$SRCROOT/Sources/MicrophoneDriver/NocturneMicrophone.c" \
  -framework CoreAudio -framework CoreFoundation -o "$driver/Contents/MacOS/NocturneMicrophone"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -n "$identity" ] || identity=-
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp=none "$driver"
