#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_file="${1:-.build/EngineOverrides/Connection.m}"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/nocturne-stream-audio.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
# Compile the actual decoder callback, with deterministic codec/device boundaries.
# Pass the pinned upstream Connection.m to measure the unfixed baseline.
ruby - "$source_file" "$test_directory/audio-under-test.inc" <<'RUBY'
source = File.read(ARGV[0])
state = source[/static SDL_AudioDeviceID audioDevice;.*?(?=static VideoDecoderRenderer\*)/m]
callback = source[/void ArDecodeAndPlaySample\(.*?(?=void ClStageStarting)/m]
abort 'Audio callback changed; review the test seam.' unless state && callback
File.write(ARGV[1], "static OpusMSDecoder *opusDecoder;\n" + state + callback)
RUBY
clang -x objective-c -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$test_directory" -I Vendor/moonlight-ios/libs/SDL2/include \
  -I Vendor/moonlight-ios/libs/opus/include/opus \
  -I Vendor/moonlight-ios/moonlight-common/moonlight-common-c/src \
  scripts/tests/stream-audio.m -o "$test_directory/stream-audio"
"$test_directory/stream-audio"
