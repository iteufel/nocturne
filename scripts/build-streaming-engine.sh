#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Xcode's GUI build environment does not include Homebrew by default.
export PATH="/opt/homebrew/bin:$PATH"
if [ "$(uname -m)" != arm64 ]; then
  echo 'The streaming engine build currently targets Apple Silicon.' >&2
  exit 1
fi
for command in cmake pkg-config git brew; do
  command -v "$command" >/dev/null || { echo 'Install build tools: brew install cmake pkgconf miniupnpc openssl@3' >&2; exit 1; }
done
pkg-config --exists miniupnpc || { echo 'Install miniupnpc: brew install miniupnpc' >&2; exit 1; }

revision=3d6e1d6008bd4a24906283ab25fcd0becc0a1c07
source_dir="$PWD/.build/SunshinePerformanceSource"
build_dir="$PWD/.build/SunshinePerformanceBuild"
if [ ! -d "$source_dir/.git" ]; then
  git clone --depth 1 --branch v2026.1018.5342 https://github.com/LizardByte/Sunshine.git "$source_dir"
fi
if [ "$(git -C "$source_dir" rev-parse HEAD)" != "$revision" ]; then
  echo 'Unexpected streaming engine source revision; refusing to build.' >&2
  exit 1
fi
# The build-deps checkout supplies the pinned prebuilt FFmpeg release. Its own
# encoder source submodules are unnecessary; avoid downloading/building them.
git -C "$source_dir" submodule update --init --depth 1 -- third-party/build-deps
git -C "$source_dir" submodule update --init --recursive --depth 1 -- \
  third-party/Simple-Web-Server third-party/TPCircularBuffer \
  third-party/libdisplaydevice third-party/libvirtualhid \
  third-party/lizardbyte-common third-party/moonlight-common-c

openssl_root="$(brew --prefix openssl@3)"
runtime="$PWD/Vendor/StreamingRuntime/Contents"
cmake -E env BRANCH=nocturne/stream-timing BUILD_VERSION=2026.1018.5342 COMMIT="$revision" \
  cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 \
  -DBUILD_TESTS=OFF -DBUILD_DOCS=OFF -DSUNSHINE_ENABLE_TRAY=OFF \
  -DOPENSSL_USE_STATIC_LIBS=FALSE -DOPENSSL_ROOT_DIR="$openssl_root" \
  -DOPENSSL_SSL_LIBRARY="$runtime/Frameworks/libssl.3.dylib" \
  -DOPENSSL_CRYPTO_LIBRARY="$runtime/Frameworks/libcrypto.3.dylib" \
  -DBOOST_LOCALE_ENABLE_ICU=OFF -DSUNSHINE_PUBLISHER_NAME=Nocturne \
  -DSUNSHINE_PUBLISHER_ISSUE_URL=https://github.com/iteufel/nocturne/issues \
  -DCMAKE_PROJECT_INCLUDE="$PWD/scripts/cmake/NocturneStreamingEngine.cmake"
# Use the checksum-verified assets from the same release. Only the embedded
# executable needs rebuilding; its web UI and images are unchanged.
mkdir -p "$build_dir/assets"
ditto Vendor/StreamingRuntime/Contents/Resources/assets "$build_dir/assets"
cmake --build "$build_dir" --target sunshine --parallel "${NOCTURNE_ENGINE_BUILD_JOBS:-6}"
binary="$build_dir/Sunshine.app/Contents/MacOS/Sunshine"
while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*) ;;
    @executable_path/../Frameworks/*)
      [ -f "$runtime/Frameworks/${dependency##*/}" ] || { echo "Missing bundled library: $dependency" >&2; exit 1; } ;;
    *) echo "Unpackaged engine dependency: $dependency" >&2; exit 1 ;;
  esac
done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
echo "Built Nocturne streaming engine: $binary"
