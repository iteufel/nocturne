#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cargo >/dev/null || { echo 'Install Rust 1.91+ with rustup before building the remote transport: https://rustup.rs' >&2; exit 1; }
command -v rustup >/dev/null || { echo 'rustup is required for the Apple cross-compilation targets.' >&2; exit 1; }
targets=(aarch64-apple-darwin)
if [ "${1:-all}" != mac ]; then targets+=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios); fi
args=()
for target in "${targets[@]}"; do
  rustup target add "$target"
  MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --manifest-path remote/Cargo.toml --locked --release -p nocturne-remote --target "$target"
  if [ "$target" = aarch64-apple-darwin ] || [ "$target" = aarch64-apple-ios ]; then
    args+=(-library "$PWD/remote/target/$target/release/libnocturne_remote.a" -headers "$PWD/remote/include")
  fi
done
mkdir -p Vendor .build
if [ "${1:-all}" != mac ]; then
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
