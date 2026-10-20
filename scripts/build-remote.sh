#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-all}" in
  all) targets=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios) ;;
  mac) targets=(aarch64-apple-darwin) ;;
  ios-device) targets=(aarch64-apple-ios) ;;
  ios-simulator) targets=(aarch64-apple-ios-sim) ;;
  *) echo 'Usage: scripts/build-remote.sh [all|mac|ios-device|ios-simulator]' >&2; exit 1 ;;
esac
command -v cargo >/dev/null || { echo 'Install Rust 1.91+ with rustup before building the remote transport: https://rustup.rs' >&2; exit 1; }
command -v rustup >/dev/null || { echo 'rustup is required for the Apple cross-compilation targets.' >&2; exit 1; }
args=()
for target in "${targets[@]}"; do
  rustup target add "$target"
  MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --manifest-path remote/Cargo.toml --locked --release -p nocturne-remote --target "$target"
  if [ "$target" != x86_64-apple-ios ] && { [ "$target" != aarch64-apple-ios-sim ] || [ "${1:-all}" = ios-simulator ]; }; then
    args+=(-library "$PWD/remote/target/$target/release/libnocturne_remote.a" -headers "$PWD/remote/include")
  fi
done
mkdir -p Vendor .build
if [ "${1:-all}" = all ]; then
  mkdir -p .build/remote-simulator
  xcrun lipo -create remote/target/aarch64-apple-ios-sim/release/libnocturne_remote.a \
    remote/target/x86_64-apple-ios/release/libnocturne_remote.a -output .build/remote-simulator/libnocturne_remote.a
  args+=(-library "$PWD/.build/remote-simulator/libnocturne_remote.a" -headers "$PWD/remote/include")
fi
output=$(mktemp -d "$PWD/.build/remote-framework.XXXXXX")
trap 'rm -rf "$output"' EXIT
xcodebuild -create-xcframework "${args[@]}" -output "$output/NocturneRemote.xcframework"
rm -rf Vendor/NocturneRemote.xcframework
mv "$output/NocturneRemote.xcframework" Vendor/NocturneRemote.xcframework
