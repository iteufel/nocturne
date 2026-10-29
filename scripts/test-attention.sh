#!/bin/bash
# Dependency-free tests of the production attention protocol and stdio host adapter.
# No APNs, notification center, model provider, network, simulator, or signing is used.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import shutil
root = Path('.build/attention-harness')
kit = root / 'Sources/NocturneKit'
host = root / 'Sources/NocturneHostKit'
tests = root / 'Tests/AttentionTests'
for folder in [kit, host, tests]: folder.mkdir(parents=True, exist_ok=True)
for name in ['AgentAttention', 'ChatPermission', 'ChatProtocol', 'DeveloperProtocol', 'NocturneError', 'ChatVoice', 'ChatSupervisor']:
    shutil.copy2(Path('Sources/Shared') / (name + '.swift'), kit)
for name in ['ChatAgentSession', 'AgentRPC', 'ChatAgentConfiguration', 'ChatSupervisorService', 'CodexAttentionQuestions', 'DeveloperCommand', 'RepositoryService', 'ForgeService']:
    shutil.copy2(Path('Sources/HostKit') / (name + '.swift'), host)
for name in ['AttentionTests', 'AttentionHostTests']:
    shutil.copy2(Path('Tests') / (name + '.swift'), tests)
(root / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AttentionHarness", platforms: [.macOS(.v14)], targets: [
    .target(name: "NocturneKit"),
    .target(name: "NocturneHostKit", dependencies: ["NocturneKit"]),
    .testTarget(name: "AttentionTests", dependencies: ["NocturneKit", "NocturneHostKit"])
])
''')
PY
swift test --package-path .build/attention-harness --disable-sandbox \
  --cache-path "$PWD/.build/attention-harness/cache" \
  --config-path "$PWD/.build/attention-harness/config" \
  --security-path "$PWD/.build/attention-harness/security"
