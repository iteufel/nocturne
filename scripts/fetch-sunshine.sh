#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -m)" != arm64 ]; then
  echo 'This release bundles the Apple Silicon streaming engine. An Intel build requires a separately verified x86_64 engine bundle at build time.' >&2
  exit 1
fi
mkdir -p .build/downloads Vendor
# This pinned prerelease fixes duplicate certificate records on re-pairing.
# v2026.914.233613 rejects a device after a second successful PIN exchange.
archive="$PWD/.build/downloads/Sunshine-v2026.1018.5342-arm64.dmg"
if [ ! -f "$archive" ]; then
  curl --fail --location --output "$archive" https://github.com/LizardByte/Sunshine/releases/download/v2026.1018.5342/Sunshine-macOS-arm64.dmg
fi
actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
if [ "$actual" != 3987348251060f84b1af147fa9cbe933c3b41872ffbb499586443abb85637bfb ]; then
  echo 'Sunshine checksum mismatch. Refusing to use this download.' >&2
  exit 1
fi
mount_point="$(mktemp -d "$PWD/.build/downloads/sunshine-mount.XXXXXX")"
cleanup() { hdiutil detach "$mount_point" -quiet 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach "$archive" -readonly -nobrowse -mountpoint "$mount_point" -quiet
runtime="$PWD/Vendor/StreamingRuntime/Contents"
mkdir -p "$runtime/Helpers" "$runtime/Frameworks" "$runtime/Resources"
# The official release archive is only an input to extraction. Do not copy its app bundle.
ditto "$mount_point/Sunshine.app/Contents/MacOS/Sunshine" "$runtime/Helpers/nocturne-stream-host"
ditto "$mount_point/Sunshine.app/Contents/Frameworks" "$runtime/Frameworks"
ditto "$mount_point/Sunshine.app/Contents/Resources/assets" "$runtime/Resources/assets"
echo 'Verified server executable and runtime files are ready for Nocturne.'
