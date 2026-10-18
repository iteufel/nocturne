#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-all}" in
  ios) xcodebuild -workspace Nocturne.xcworkspace -scheme 'Nocturne' -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/Xcode CODE_SIGN_IDENTITY="${NOCTURNE_SIGNING_IDENTITY:--}" DEVELOPMENT_TEAM="${NOCTURNE_DEVELOPMENT_TEAM:-}" build ;;
  mac) xcodebuild -project Nocturne.xcodeproj -scheme 'Nocturne Server' -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/XcodeMac CODE_SIGN_IDENTITY="${NOCTURNE_SIGNING_IDENTITY:--}" DEVELOPMENT_TEAM="${NOCTURNE_DEVELOPMENT_TEAM:-}" build ;;
  all) "$0" ios; "$0" mac ;;
  *) echo 'Usage: scripts/build.sh [ios|mac|all]' >&2; exit 1 ;;
esac
