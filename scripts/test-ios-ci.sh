#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${GITHUB_ACTIONS:-}" != true ]; then
  echo 'This script manages disposable GitHub CI simulators. Use xcodebuild test with your local simulator for development.' >&2
  exit 1
fi

simulator=''
cleanup() {
  if [ -n "$simulator" ]; then
    xcrun simctl shutdown "$simulator" || true
    xcrun simctl delete "$simulator" || true
  fi
}
trap cleanup EXIT

runtime="$(xcrun simctl list runtimes --json | python3 -c '
import json,sys
matches=[r["identifier"] for r in json.load(sys.stdin)["runtimes"]
         if r["isAvailable"] and r["identifier"].endswith(".iOS-27-0")]
if len(matches)!=1: raise SystemExit("Expected the installed iOS 27.0 runtime")
print(matches[0])')"

mkdir -p .build/ClientTests
for device in 'iPhone 18 Pro' 'iPad Pro 13-inch (M5)'; do
  device_type="$(xcrun simctl list devicetypes --json | python3 -c '
import json,sys
matches=[d["identifier"] for d in json.load(sys.stdin)["devicetypes"] if d["name"]==sys.argv[1]]
if len(matches)!=1: raise SystemExit("Simulator device type not found: "+sys.argv[1])
print(matches[0])' "$device")"
  simulator="$(xcrun simctl create "Nocturne CI $device" "$device_type" "$runtime")"
  echo "Booting $device for client tests"
  xcrun simctl boot "$simulator"
  python3 - "$simulator" <<'PY'
import subprocess, sys
try:
    subprocess.run(['xcrun', 'simctl', 'bootstatus', sys.argv[1], '-b'], check=True, timeout=300)
except subprocess.TimeoutExpired:
    raise SystemExit('Simulator did not finish booting within five minutes')
PY
  # Xcode 27 gathers simulator diagnostics even after passing runs, which can stall for its 10-minute timeout.
  xcodebuild test -workspace Nocturne.xcworkspace -scheme Nocturne \
    -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath .build/Xcode -resultBundlePath ".build/ClientTests/$device.xcresult" \
    -collect-test-diagnostics never \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:NocturneClientTests CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
  cleanup
  simulator=''
done
