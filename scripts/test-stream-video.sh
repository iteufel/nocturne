#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/StreamVideoTests
c++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -fno-omit-frame-pointer -I Sources/Client/Bridge \
  scripts/tests/stream-video-pacing.cpp -o .build/StreamVideoTests/replay
.build/StreamVideoTests/replay "$@"
