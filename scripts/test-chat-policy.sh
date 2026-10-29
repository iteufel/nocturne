#!/bin/bash
# Run the chat protocol/stdio fixtures without downloading streaming, WebRTC or Rust assets.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="$PWD/.build/chat-policy-check"
mkdir -p "$fixture/kit" "$fixture/host" "$fixture/ChatPolicyTests.xctest/Contents/MacOS"
python3 - "$fixture" <<'PY'
from pathlib import Path
import shutil, sys
fixture = Path(sys.argv[1])
for target, source, names in [
    ('kit', 'Shared', ['ChatProtocol', 'ChatPermission', 'AgentAttention', 'NocturneError', 'DeveloperProtocol', 'ChatVoice', 'ChatSupervisor']),
    ('host', 'HostKit', ['ChatAgentSession', 'ChatAgentConfiguration', 'AgentRPC', 'ChatSupervisorService', 'CodexAttentionQuestions', 'RepositoryService', 'DeveloperCommand', 'ForgeService'])
]:
    for name in names:
        shutil.copy(Path('Sources') / source / (name + '.swift'), fixture / target)

PY
platform="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
common=(-swift-version 5 -module-cache-path "$fixture/cache" -I "$fixture" -L "$fixture")
xcrun swiftc "${common[@]}" -parse-as-library -emit-module -emit-library -enable-testing -module-name NocturneKit \
    "$fixture"/kit/*.swift -emit-module-path "$fixture/NocturneKit.swiftmodule" -o "$fixture/libNocturneKit.dylib"
xcrun swiftc "${common[@]}" -parse-as-library -emit-module -emit-library -enable-testing -module-name NocturneHostKit \
    -lNocturneKit "$fixture"/host/*.swift -emit-module-path "$fixture/NocturneHostKit.swiftmodule" -o "$fixture/libNocturneHostKit.dylib"
xcrun swiftc "${common[@]}" -parse-as-library -emit-library -module-name ChatPolicyTests \
    -F "$platform/Library/Frameworks" -I "$platform/usr/lib" -L "$platform/usr/lib" \
    -lNocturneKit -lNocturneHostKit \
    -Xlinker -rpath -Xlinker "$platform/Library/Frameworks" -Xlinker -rpath -Xlinker "$platform/usr/lib" \
    Tests/ChatStatusApprovalTests.swift -o "$fixture/ChatPolicyTests.xctest/Contents/MacOS/ChatPolicyTests"
xcrun xctest "$fixture/ChatPolicyTests.xctest"
