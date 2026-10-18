#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${NOCTURNE_DEVELOPMENT_TEAM:?Set the Apple Developer team ID}"
: "${NOCTURNE_BUILD_NUMBER:?Set a unique numeric build number}"
if [[ ! "$NOCTURNE_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo 'The build number must have one to three numeric components.' >&2
  exit 1
fi

output="$PWD/.build/TestFlight"
mkdir -p "$output"
export NOCTURNE_EXPORT_OPTIONS="$output/ExportOptions.plist"
python3 - <<'PY'
import os, plistlib
with open(os.environ['NOCTURNE_EXPORT_OPTIONS'], 'wb') as output:
    plistlib.dump({
        'method': 'app-store-connect',
        'destination': 'export',
        'teamID': os.environ['NOCTURNE_DEVELOPMENT_TEAM'],
        'signingStyle': 'manual',
        'signingCertificate': 'Apple Distribution',
        'provisioningProfiles': {'app.nocturne.client': 'Nocturne App Store'},
        'manageAppVersionAndBuildNumber': False,
        'uploadSymbols': True,
    }, output)
PY

xcodebuild archive -workspace Nocturne.xcworkspace -scheme Nocturne \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/XcodeArchive -archivePath "$output/Nocturne.xcarchive" \
  NOCTURNE_DEVELOPMENT_TEAM="$NOCTURNE_DEVELOPMENT_TEAM" \
  CURRENT_PROJECT_VERSION="$NOCTURNE_BUILD_NUMBER" \
  NOCTURNE_CODE_SIGN_STYLE=Manual NOCTURNE_CODE_SIGN_IDENTITY='Apple Distribution' \
  NOCTURNE_PROVISIONING_PROFILE_SPECIFIER='Nocturne App Store'

xcodebuild -exportArchive -archivePath "$output/Nocturne.xcarchive" \
  -exportPath "$output/export" -exportOptionsPlist "$NOCTURNE_EXPORT_OPTIONS"
test -f "$output/export/Nocturne.ipa"
