#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_root="${NOCTURNE_ENGINE_SOURCE:-$PWD/.build/SunshinePerformanceSource}"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/nocturne-lock-screen.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
source_file="$source_root/src/platform/macos/display.mm"
if [ "${1:-}" != --baseline ]; then
  cat > "$test_directory/generate.cmake" <<'CMAKE'
include("${OVERLAY_FILE}")
nocturne_macos_capture("${SOURCE_ROOT}" "${OUTPUT}")
CMAKE
  cmake -DOVERLAY_FILE="$PWD/scripts/cmake/NocturneMacOSCapture.cmake" \
    -DSOURCE_ROOT="$source_root" -DOUTPUT="$test_directory/display.mm" \
    -P "$test_directory/generate.cmake"
  source_file="$test_directory/display.mm"
fi
# Exercise the actual display selection and capture callback, replacing only the
# clock, frame buffers and OS capture boundary. --baseline runs the pinned engine.
ruby - "$source_file" "$test_directory" <<'RUBY'
source = File.read(ARGV[0])
parser = source[/    std::optional<CGDirectDisplayID> parse_display_id.*?(?=\n    \/\*\*)/m]
selection = source[/    \/\/ Default to main display.*?(?=    \/\/ Print all displays)/m]
capture = source[/    capture_e capture\(.*?(?=    \/\*\*\n     \* @brief Allocate an image)/m]
abort 'macOS capture test seam changed; review the pinned source.' unless parser && selection && capture
File.write("#{ARGV[1]}/parser.inc", parser)
File.write("#{ARGV[1]}/selection.inc", selection)
File.write("#{ARGV[1]}/capture.inc", capture.gsub('std::chrono::steady_clock::now()', 'testNow'))
RUBY
clang++ -x objective-c++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$test_directory" -I Sources/StreamingEngine -I Sources/DisplayBridge/include \
  -framework Foundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo \
  scripts/tests/stream-lock-screen.mm -o "$test_directory/stream-lock-screen"
"$test_directory/stream-lock-screen"
