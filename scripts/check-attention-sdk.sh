#!/bin/bash
# Uses real production Shared sources and Apple SDKs, without fetching binary dependencies.
# The attention controller check substitutes only the ClientModel app boundary (see below).
set -euo pipefail
cd "$(dirname "$0")/.."
check="$PWD/.build/attention-sdk"
mkdir -p "$check/ios"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
# Standalone SDK checks do not run SwiftPM's resource accessor generator.
# This compile-only boundary is not part of the production module or executed.
cat > "$check/BundleModule.swift" <<'SWIFT'
import Foundation
extension Bundle { static let module = Bundle.main }
SWIFT
xcrun swiftc -emit-module -module-name NocturneKit -enable-testing \
  -module-cache-path "$check/MacModuleCache" -I remote/include \
  Sources/Shared/*.swift "$check/BundleModule.swift" -emit-module-path "$check/NocturneKit.swiftmodule"
xcrun swiftc -typecheck -swift-version 5 -module-name NocturneHostKit \
  -I remote/include -I "$check" -module-cache-path "$check/MacModuleCache" \
  Sources/HostKit/{ChatAgentSession,AgentRPC,ChatAgentConfiguration,ChatSupervisorService,CodexAttentionQuestions,DeveloperCommand,RepositoryService,ForgeService,ChatHostSession,SharedFolder}.swift
xcrun swiftc -emit-module -module-name NocturneKit -target arm64-apple-ios17.0-simulator \
  -sdk "$sdk" -module-cache-path "$check/iOSModuleCache" -I remote/include \
  Sources/Shared/*.swift "$check/BundleModule.swift" -emit-module-path "$check/ios/NocturneKit.swiftmodule"
xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-ios17.0-simulator -sdk "$sdk" \
  -I remote/include -I "$check/ios" -module-cache-path "$check/iOSModuleCache" \
  -D NOCTURNE_ATTENTION_WIDGET -application-extension \
  Sources/AttentionActivity/*.swift Sources/AttentionWidget/*.swift
cat > "$check/ClientModelBoundary.swift" <<'SWIFT'
import NocturneKit
// Boundary fixture only; all connection/chat protocol and controller code is production code.
@MainActor final class ClientModel {
    let server: WorkspaceConnection
    let chats: ChatWorkspaceModel
    enum Page { case chats }
    var page: Page = .chats
    init(server: WorkspaceConnection, chats: ChatWorkspaceModel) { self.server = server; self.chats = chats }
}
SWIFT
xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-ios17.0-simulator -sdk "$sdk" \
  -I remote/include -I "$check/ios" -module-cache-path "$check/iOSModuleCache" \
  Sources/Client/AgentAttentionCenter.swift Sources/AttentionActivity/*.swift "$check/ClientModelBoundary.swift"
ruby -c scripts/generate-project.rb
plutil -lint Resources/Client-Info.plist Resources/Attention-Info.plist
