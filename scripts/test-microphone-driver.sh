#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
temporary="$(mktemp -d .build/MicrophoneDriver.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT
flags=(-std=c11 -g -O1 -Wall -Wextra -Wno-unused-parameter -Werror -fsanitize=address,undefined -framework CoreAudio -framework CoreFoundation)
xcrun clang "${flags[@]}" -bundle Sources/MicrophoneDriver/NocturneMicrophone.c -o "$temporary/NocturneMicrophone"
xcrun clang "${flags[@]}" scripts/tests/microphone-driver.c -o "$temporary/test"
"$temporary/test" "$temporary/NocturneMicrophone"
