#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Opt-in native hardware test, run on an Apple Silicon Mac. FFmpeg development
# libraries can come from Homebrew or PKG_CONFIG_PATH for the pinned engine.
mkdir -p .build/StreamEncoderTests
c++ -std=c++17 -O2 -Wall -Wextra -Werror \
  -I Sources/StreamingEngine $(pkg-config --cflags libavcodec libavutil) \
  scripts/tests/stream-encoder.cpp $(pkg-config --libs libavcodec libavutil) \
  -o .build/StreamEncoderTests/stream-encoder
.build/StreamEncoderTests/stream-encoder "$@"
