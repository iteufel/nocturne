#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${GITHUB_ACTIONS:-}" != true ]; then
  echo 'This script manages disposable GitHub CI simulators. Use xcodebuild test with your local simulator for development.' >&2
  exit 1
fi

simulators=()
boot_pids=()
cleanup() {
  for pid in "${boot_pids[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  for simulator in "${simulators[@]:-}"; do
    [ -n "$simulator" ] || continue
    xcrun simctl shutdown "$simulator" || true
    xcrun simctl delete "$simulator" || true
  done
}
trap cleanup EXIT

runtime="$(xcrun simctl list runtimes --json | python3 -c '
import json,sys
matches=[r["identifier"] for r in json.load(sys.stdin)["runtimes"]
         if r["isAvailable"] and r["identifier"].endswith(".iOS-27-0")]
if len(matches)!=1: raise SystemExit("Expected the installed iOS 27.0 runtime")
print(matches[0])')"

mkdir -p .build/ClientTests
devices=('iPhone 18 Pro' 'iPad Pro 13-inch (M5)')
# Start both cold boots before compilation so their first-run setup overlaps
# the build, rather than adding a separate boot wait for each device.
for device in "${devices[@]}"; do
  device_type="$(xcrun simctl list devicetypes --json | python3 -c '
import json,sys
matches=[d["identifier"] for d in json.load(sys.stdin)["devicetypes"] if d["name"]==sys.argv[1]]
if len(matches)!=1: raise SystemExit("Simulator device type not found: "+sys.argv[1])
print(matches[0])' "$device")"
  simulator="$(xcrun simctl create "Nocturne CI $device" "$device_type" "$runtime")"
  simulators+=("$simulator")
done
for index in "${!devices[@]}"; do
  echo "Booting ${devices[$index]} for client tests"
  xcrun simctl boot "${simulators[$index]}" &
  boot_pids+=("$!")
done

# The same arm64 simulator test products run on both device families.
xcodebuild build-for-testing -workspace Nocturne.xcworkspace -scheme Nocturne \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/Xcode \
  -only-testing:NocturneClientTests ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=

for index in "${!devices[@]}"; do
  device="${devices[$index]}"
  simulator="${simulators[$index]}"
  wait "${boot_pids[$index]}"
  boot_pids[index]=''
  python3 - "$simulator" <<'PY'
import subprocess, sys
try:
    subprocess.run(['xcrun', 'simctl', 'bootstatus', sys.argv[1], '-b'], check=True, timeout=300)
except subprocess.TimeoutExpired:
    raise SystemExit('Simulator did not finish booting within five minutes')
PY
  # Xcode 27 gathers simulator diagnostics even after passing runs, which can stall for its 10-minute timeout.
  xcodebuild test-without-building -workspace Nocturne.xcworkspace -scheme Nocturne \
    -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath .build/Xcode -resultBundlePath ".build/ClientTests/$device.xcresult" \
    -collect-test-diagnostics never \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:NocturneClientTests CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
done
