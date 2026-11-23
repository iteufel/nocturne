#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
platform="${1:-all}"
case "$platform" in
  all|mac|ios-device|ios-simulator) ;;
  *) echo 'Usage: scripts/bootstrap.sh [all|mac|ios-device|ios-simulator]' >&2; exit 1 ;;
esac
mkdir -p Vendor
scripts/build-remote.sh "$platform"
fetch() {
  local directory="$1" url="$2" revision="$3"
  if [ ! -d "$directory/.git" ]; then
    git clone --no-checkout "$url" "$directory"
    git -C "$directory" checkout --detach "$revision"
  fi
  if [ "$(git -C "$directory" rev-parse HEAD)" != "$revision" ]; then
    echo "Unexpected dependency revision in $directory. Move that directory aside and rerun bootstrap." >&2
    exit 1
  fi
  git -C "$directory" submodule update --init --recursive
}
fetch Vendor/moonlight-ios https://github.com/moonlight-stream/moonlight-ios.git 02dc9780496eeeac6d01c8bbdccb8b6fe71ef28a
fetch Vendor/SwiftTerm https://github.com/migueldeicaza/SwiftTerm.git 282c3c3a932b55c129628876b70f37d993af1615
ruby -e 'require "xcodeproj"' 2>/dev/null || { echo 'Install the project generator: gem install xcodeproj -v 1.28.1'; exit 1; }
if [ "$platform" = all ] || [ "$platform" = mac ]; then
  scripts/fetch-sunshine.sh
fi
swift scripts/make-icon.swift
ruby scripts/generate-project.rb
echo 'Ready. Open Nocturne.xcworkspace in Xcode.'
