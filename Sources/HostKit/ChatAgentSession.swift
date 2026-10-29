import Foundation
import NocturneKit

@MainActor
final class ChatAgentSession {
    let configuration: ChatAgentConfiguration
    private let rpc: AgentRPC
    private let directory: URL
    private let chatGPTOnly: Bool
    var emit: ((ChatEvent) -> Void)?
    var emitVoice: ((ChatVoiceEvent) -> Void)?
    var supervisorSession: ((String) -> Bool)?
    var supervisorTool: ((String, [String: Any]) async throws -> String)?
    private var toolTasks: [UUID: Task<Void, Never>] = [:]
    private var voiceID: String?
    private var voiceSession: String?
    private var voiceStarted = false
    private var voiceAnswerReceived = false
    private var voiceFailure: String?
    private var voiceReady: CheckedContinuation<Void, Error>?
    private var voiceDeadline: Task<Void, Never>?
    private var canonicalVoiceTranscripts = false
    private var voiceTranscriptRoles: [String: ChatRole] = [:]
    private var legacyVoiceTranscripts: [String: String] = [:]
    private var capabilities: [String: Any] = [:]
    private var opened: Set<String> = []
    private var preparedVoiceSessions: Set<String> = []
    private var created: Set<String> = []
    private var known: [String: ChatSessionInfo] = [:]
    private var activeSession: String?
    private var activeTurn: String?
    private var cancelRequested = false
    private var replaying = false
    private var transcript: [ChatMessage] = []
    private var transcriptSession: String?
    private var savedTranscripts: [String: [ChatMessage]] = [:]
    private var toolTitles: [String: String] = [:]
    private var replayBytes = 0
    private var chunkID: String?
    private var chunkRole: ChatRole?
    private var history: [ChatMessage] = []
    private var historySession: ChatSessionInfo?
    private var historyRemoteCursor: String?
    private var historyToken: String?
    private var historyCanPrompt = true
    private var listRemainder: [ChatSessionInfo] = []
    private var listRemoteCursor: String?
    private var listToken: String?
    private var listArchived = false
    private var didReadApprovalRequirements = false
    private var allowedApprovalPolicies: Set<String>?
    private var modelCatalog: [[String: Any]]?
    private var lastActivities: [String: ChatActivity] = [:]
    private var approvalPolicies: [String: String] = [:]
    private var sessionOptions: [String: [ChatConfigOption]] = [:]
    private final class InputAnswers {
        let expected: Int
        var answers: [String: [String: [String]]] = [:]
        var responded = false
        init(expected: Int) { self.expected = expected }
    }
    private struct Approval {
        let rpcID: Any
        let method: String
        let sessionID: String
        let options: Set<String>
        let permissions: [String: Any]
        var decisions: [String: Any] = [:]
        let expiresAt: Date
        var inputAnswers: InputAnswers? = nil
        var questionID: String? = nil
        var answerLabels: [String: String] = [:]
    }
    private var approvals: [String: Approval] = [:]
    private let approvalLifetime: TimeInterval

    init(configuration: ChatAgentConfiguration, directory: URL, chatGPTOnly: Bool = false, approvalLifetime: TimeInterval = 300) throws {
        self.configuration = configuration; self.directory = directory
        self.approvalLifetime = min(300, max(0, approvalLifetime))
        self.chatGPTOnly = chatGPTOnly
        rpc = try AgentRPC(configuration: configuration, directory: directory, chatGPTOnly: chatGPTOnly)
        rpc.onNotification = { [weak self] in self?.notification($0, $1) }
        rpc.onRequest = { [weak self] in self?.request($0, $1, $2) }
        rpc.onExit = { [weak self] error in
            guard let self else { return }
            self.endVoiceLocally(error: error.localizedDescription)
            if let id = self.activeSession { self.finish(id, error: error.localizedDescription) }
        }
    }
    func initialize() async throws {
        if configuration.transport == .codex {
            _ = try await rpc.call("initialize", ["clientInfo": ["name": "nocturne", "title": "Nocturne", "version": "1.0"],
                "capabilities": ["experimentalApi": true]])
            rpc.notify("initialized")
        } else {
            let result = try await rpc.call("initialize", ["protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "nocturne", "title": "Nocturne", "version": "1.0"]])
            guard result["protocolVersion"] as? Int == 1 else { throw NocturneError.remote("This provider requires an unsupported ACP version. Use an ACP v1 agent.") }
            capabilities = result["agentCapabilities"] as? [String: Any] ?? [:]
        }
    }
    var isClosed: Bool { rpc.closed }
    var isResponding: Bool { activeSession != nil }
    func close() { toolTasks.values.forEach { $0.cancel() }; toolTasks = [:]; cancelApprovals(); endVoiceLocally(); rpc.close(); emit = nil; emitVoice = nil }

    func list(cursor: String?, archived: Bool) async throws -> ChatSessionPage {
        if let cursor {
            guard cursor == listToken, archived == listArchived else { throw NocturneError.invalidFrame }
        } else { listRemainder = []; listRemoteCursor = nil; listToken = nil; listArchived = archived }
        var notice: String?
        if listRemainder.isEmpty {
            var params: [String: Any] = [:]
            if let next = listRemoteCursor { params["cursor"] = next }
            if configuration.transport == .codex {
                params["limit"] = ChatProtocol.pageSize; params["archived"] = archived
                params["sortKey"] = "updated_at"; params["modelProviders"] = [String]()
                // Interactive and noninteractive sources are explicit: Codex otherwise hides exec/subagent sessions.
                params["sourceKinds"] = ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]
                let result = try await rpc.call("thread/list", params)
                listRemainder = (result["data"] as? [[String: Any]] ?? []).compactMap(Self.codexSession)
                listRemoteCursor = result["nextCursor"] as? String
            } else if (capabilities["sessionCapabilities"] as? [String: Any])?["list"] != nil {
                let result = try await rpc.call("session/list", params)
                listRemainder = (result["sessions"] as? [[String: Any]] ?? []).compactMap(Self.acpSession)
                listRemoteCursor = result["nextCursor"] as? String
            } else {
                listRemainder = Array(known.values).sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                listRemoteCursor = nil
                notice = "This provider does not expose conversation history. Only chats opened in this connection appear here."
            }
        }
        let page = Array(listRemainder.prefix(ChatProtocol.pageSize)); listRemainder.removeFirst(page.count)
        for session in page { known[session.id] = session }
        listToken = listRemainder.isEmpty && listRemoteCursor == nil ? nil : UUID().uuidString
        return ChatSessionPage(sessions: page, nextCursor: listToken, notice: notice)
    }

    func load(_ id: String, cursor: String?, archived: Bool) async throws -> ChatHistoryPage {
        guard activeSession == nil else { throw NocturneError.remote("Stop the current reply before opening another conversation.") }
        if let cursor {
            guard cursor == historyToken, historySession?.id == id else { throw NocturneError.invalidFrame }
            if history.isEmpty, let remote = historyRemoteCursor { try await codexItems(id, cursor: remote) }
        } else {
            history = []; historyRemoteCursor = nil; historyToken = nil; historyCanPrompt = !archived
            if configuration.transport == .codex {
                let result = try await rpc.call("thread/read", ["threadId": id, "includeTurns": false])
                guard let thread = result["thread"] as? [String: Any], let info = Self.codexSession(thread) else { throw NocturneError.invalidFrame }
                historySession = info; known[id] = info
                if thread["historyMode"] as? String == "paginated" { try await codexItems(id, cursor: nil) }
                else {
                    do {
                        let full = try await rpc.call("thread/read", ["threadId": id, "includeTurns": true])
                        let turns = (full["thread"] as? [String: Any])?["turns"] as? [[String: Any]] ?? []
                        history = turns.flatMap { $0["items"] as? [[String: Any]] ?? [] }.compactMap(Self.codexMessage).flatMap(\.parts)
                    } catch let error as AgentRPCError where error.code == -32600 &&
                        (error.message.contains("not materialized yet") || error.message.contains("ephemeral threads do not support includeTurns")) {
                        // Metadata exists before the first turn is written. This is a valid empty conversation.
                        history = []
                    }
                }
            } else {
                guard let info = known[id] else { throw NocturneError.remote("Refresh the conversations list before opening this chat.") }
                guard capabilities["loadSession"] as? Bool == true || opened.contains(id) else {
                    throw NocturneError.remote("This provider cannot reopen saved conversations. Start a new chat or use a provider with session loading.")
                }
                historySession = info
                if capabilities["loadSession"] as? Bool != true, let previous = transcriptSession, previous != id { savedTranscripts[previous] = transcript }
                transcriptSession = id
                if capabilities["loadSession"] as? Bool == true {
                    transcript = []; toolTitles = [:]; replayBytes = 0; replaying = true; chunkID = nil; chunkRole = nil
                    defer { replaying = false }
                    let result = try await rpc.call("session/load", ["sessionId": id, "cwd": info.directory, "mcpServers": [Any]()], timeout: 90)
                    sessionOptions[id] = Self.acpOptions(result)
                    opened.insert(id)
                } else if let saved = savedTranscripts[id] { transcript = saved }
                history = transcript.flatMap(\.parts)
            }
        }
        guard let session = historySession else { throw NocturneError.invalidFrame }
        var start = history.count, bytes = 0
        while start > 0, history.count - start < ChatProtocol.pageSize {
            let count = history[start - 1].text.utf8.count
            if bytes + count > 120_000 && start < history.count { break }
            bytes += count; start -= 1
        }
        let page = Array(history[start...]); history.removeSubrange(start...)
        historyToken = history.isEmpty && historyRemoteCursor == nil ? nil : UUID().uuidString
        return ChatHistoryPage(session: session, messages: page, nextCursor: historyToken, canPrompt: historyCanPrompt)
    }
    private func codexItems(_ id: String, cursor: String?) async throws {
        var params: [String: Any] = ["threadId": id, "limit": 20, "sortDirection": "desc"]
        if let cursor { params["cursor"] = cursor }
        let result = try await rpc.call("thread/items/list", params)
        history = (result["data"] as? [[String: Any]] ?? []).reversed()
            .compactMap { $0["item"] as? [String: Any] }.compactMap(Self.codexMessage).flatMap(\.parts)
        historyRemoteCursor = result["nextCursor"] as? String
    }
    func create(ephemeral: Bool = false, in workingDirectory: URL? = nil, supervisor: Bool = false) async throws -> ChatSessionInfo {
        guard activeSession == nil else { throw NocturneError.remote("Stop the current reply before starting a new conversation.") }
        guard configuration.transport == .codex || capabilities["loadSession"] as? Bool == true || opened.count < 32 else {
            throw NocturneError.remote("This provider cannot save history. Reconnect before starting more than 32 temporary chats.")
        }
        let info: ChatSessionInfo
        let workingDirectory = workingDirectory ?? directory
        if configuration.transport == .codex {
            var params: [String: Any] = ["cwd": workingDirectory.path, "approvalPolicy": "on-request", "sandbox": "workspace-write", "ephemeral": ephemeral]
            if chatGPTOnly { params["modelProvider"] = "openai" }
            if supervisor {
                params["developerInstructions"] = ChatSupervisorService.instructions
                params["dynamicTools"] = ChatSupervisorService.tools
                // Codex 0.164 advertises paginated threads before implementing thread/items/list.
                params["historyMode"] = "legacy"
            }
            let result = try await rpc.call("thread/start", params)
            guard let thread = result["thread"] as? [String: Any], let session = Self.codexSession(thread) else { throw NocturneError.invalidFrame }
            if supervisor, !ephemeral {
                // Naming materializes an otherwise empty thread so a dedicated voice process can resume it.
                _ = try await rpc.call("thread/name/set", ["threadId": session.id, "name": ChatSupervisor.title])
            }
            info = session
        } else {
            let result = try await rpc.call("session/new", ["cwd": workingDirectory.path, "mcpServers": [Any]()])
            guard let id = result["sessionId"] as? String else { throw NocturneError.invalidFrame }
            info = ChatSessionInfo(id: id, title: "New conversation", directory: workingDirectory.path, updatedAt: Date())
            sessionOptions[id] = Self.acpOptions(result)
        }
        if configuration.transport == .acp, capabilities["loadSession"] as? Bool != true, let previous = transcriptSession { savedTranscripts[previous] = transcript }
        known[info.id] = info; opened.insert(info.id); created.insert(info.id); transcript = []; transcriptSession = info.id; toolTitles = [:]; chunkID = nil; chunkRole = nil
        return info
    }
    func prompt(_ id: String, text: String) async throws {
        guard activeSession == nil, voiceID == nil else { throw NocturneError.remote("Open a conversation and end voice chat before sending a message.") }
        if known[id] == nil, configuration.transport == .codex { _ = try await workingDirectory(for: id) }
        guard known[id] != nil else { throw NocturneError.remote("Open this conversation before sending a message.") }
        activeSession = id; activeTurn = nil; cancelRequested = false; chunkID = nil; chunkRole = nil
        do {
            if configuration.transport == .codex {
                if !opened.contains(id) {
                    var params: [String: Any] = ["threadId": id, "excludeTurns": true, "approvalPolicy": "on-request", "sandbox": "workspace-write"]
                    if supervisorSession?(id) == true { params["developerInstructions"] = ChatSupervisorService.instructions }
                    _ = try await rpc.call("thread/resume", params)
                    opened.insert(id)
                }
                var params: [String: Any] = ["threadId": id,
                    "input": [["type": "text", "text": text, "text_elements": [Any]()]]]
                if let policy = approvalPolicies[id] { params["approvalPolicy"] = policy }
                let result = try await rpc.call("turn/start", params)
                activeTurn = (result["turn"] as? [String: Any])?["id"] as? String
                if cancelRequested { try await cancel(id) }
            } else {
                guard opened.contains(id) else { throw NocturneError.remote("Reopen this conversation before sending a message.") }
                transcript.append(ChatMessage(id: UUID().uuidString, role: .user, text: text))
                let result = try await rpc.call("session/prompt", ["sessionId": id, "prompt": [["type": "text", "text": text]]], timeout: 86_400)
                let reason = result["stopReason"] as? String ?? "end_turn"
                finish(id, detail: reason == "cancelled" ? "Stopped" : reason == "max_tokens" ? "The provider reached its response limit." : nil)
            }
        } catch { finish(id, error: error.localizedDescription); throw error }
    }
    func cancel(_ id: String) async throws {
        guard activeSession == id else { return }
        cancelRequested = true; cancelApprovals()
        if configuration.transport == .codex {
            if let turn = activeTurn { _ = try await rpc.call("turn/interrupt", ["threadId": id, "turnId": turn]) }
        } else { rpc.notify("session/cancel", ["sessionId": id]) }
    }
    func releaseForVoice(_ id: String) async throws {
        guard configuration.transport == .codex, activeSession == nil, voiceID == nil else { throw NocturneError.remote("Finish the current reply before starting voice.") }
        if created.contains(id), let info = known[id] {
            _ = try await rpc.call("thread/name/set", ["threadId": id, "name": supervisorSession?(id) == true ? ChatSupervisor.title : info.title])
        }
        close()
        try await rpc.waitUntilExit()
    }
    func requireIdle(_ id: String) async throws {
        guard configuration.transport == .codex else { return }
        let result = try await rpc.call("thread/read", ["threadId": id, "includeTurns": false])
        let status = ((result["thread"] as? [String: Any])?["status"] as? [String: Any])?["type"] as? String
        guard status != "active" else { throw NocturneError.remote("This conversation is active in another client. Let it finish or stop it there before sending another task.") }
    }
    func workingDirectory(for id: String) async throws -> URL {
        if configuration.transport == .codex {
            let result = try await rpc.call("thread/read", ["threadId": id, "includeTurns": false])
            guard let thread = result["thread"] as? [String: Any], let info = Self.codexSession(thread) else { throw NocturneError.invalidFrame }
            known[id] = info
        }
        guard let info = known[id], !info.directory.isEmpty else { throw NocturneError.remote("Open this conversation before using its project tools.") }
        return URL(fileURLWithPath: info.directory)
    }
    func options(for id: String) async throws -> [ChatConfigOption] {
        if configuration.transport == .acp { return sessionOptions[id] ?? [] }
        if !didReadApprovalRequirements {
            do {
                let result = try await rpc.call("configRequirements/read")
                if let raw = (result["requirements"] as? [String: Any])?["allowedApprovalPolicies"], !(raw is NSNull) {
                    allowedApprovalPolicies = Set((raw as? [Any] ?? []).compactMap { $0 as? String })
                }
            } catch let error as AgentRPCError where error.unsupported {
                // Legacy providers enforce policy support when turn/start is submitted.
            }
            didReadApprovalRequirements = true
        }
        if modelCatalog == nil {
            var catalog: [[String: Any]] = [], cursor: String?, seen = Set<String>()
            repeat {
                var params: [String: Any] = ["limit": 100, "includeHidden": false]
                if let cursor { params["cursor"] = cursor }
                let result = try await rpc.call("model/list", params)
                catalog += result["data"] as? [[String: Any]] ?? []
                cursor = result["nextCursor"] as? String
                if let cursor, !seen.insert(cursor).inserted { throw NocturneError.invalidFrame }
                guard catalog.count <= 500 else { throw NocturneError.invalidFrame }
            } while cursor != nil
            modelCatalog = catalog
        }
        let result = try await rpc.call("thread/read", ["threadId": id, "includeTurns": false])
        let thread = result["thread"] as? [String: Any] ?? [:]
        let catalog = modelCatalog ?? []
        guard let fallback = catalog.first(where: { $0["isDefault"] as? Bool == true }) ?? catalog.first else { return [Self.approvalPolicyOption(value: approvalPolicies[id] ?? "on-request", allowed: allowedApprovalPolicies)] }
        let model = thread["model"] as? String ?? fallback["model"] as? String ?? ""
        let current = catalog.first { $0["model"] as? String == model } ?? [:]
        let effort = thread["reasoningEffort"] as? String ?? current["defaultReasoningEffort"] as? String ?? ""
        var choices = catalog.compactMap { row -> ChatConfigChoice? in
            guard let value = row["model"] as? String, let name = row["displayName"] as? String else { return nil }
            return ChatConfigChoice(value, name: name)
        }
        if !choices.contains(where: { $0.value == model }), !model.isEmpty { choices.append(ChatConfigChoice(model, name: model)) }
        var options = [ChatConfigOption(id: "model", name: "Model", category: "model", value: model, choices: choices)]
        let efforts = (current["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { row -> ChatConfigChoice? in
            guard let value = row["reasoningEffort"] as? String else { return nil }; return ChatConfigChoice(value, name: value.capitalized)
        }
        if !efforts.isEmpty { options.append(ChatConfigOption(id: "effort", name: "Reasoning", category: "thought_level", value: effort, choices: efforts)) }
        options.append(Self.approvalPolicyOption(value: approvalPolicies[id] ?? "on-request", allowed: allowedApprovalPolicies))
        return options
    }
    func configure(_ session: String, id: String, value: String) async throws -> [ChatConfigOption] {
        guard activeSession == nil, voiceID == nil else { throw NocturneError.remote("Finish the current reply or voice call before changing chat settings.") }
        // A chat-local override is applied only to subsequent text turns. No config file,
        // sandbox, pending approval or other conversation is changed.
        if configuration.transport == .codex, id == "nocturne.approvalPolicy" {
            guard known[session] != nil else { throw NocturneError.invalidFrame }
            var updated = try await self.options(for: session)
            guard updated.first(where: { $0.id == id })?.choices.contains(where: { $0.value == value }) == true else { throw NocturneError.invalidFrame }
            approvalPolicies[session] = value
            if let index = updated.firstIndex(where: { $0.id == id }) { updated[index].value = value }
            return updated
        }
        let options = try await options(for: session)
        guard let option = options.first(where: { $0.id == id }), option.choices.contains(where: { $0.value == value }) else { throw NocturneError.invalidFrame }
        if configuration.transport == .codex {
            if !opened.contains(session) {
                _ = try await rpc.call("thread/resume", ["threadId": session, "excludeTurns": true, "approvalPolicy": "on-request", "sandbox": "workspace-write"])
                opened.insert(session)
            }
            var params: [String: Any] = ["threadId": session, id == "model" ? "model" : "effort": value]
            if id == "model", let model = modelCatalog?.first(where: { $0["model"] as? String == value }), let effort = model["defaultReasoningEffort"] as? String { params["effort"] = effort }
            _ = try await rpc.call("thread/settings/update", params)
            return try await self.options(for: session)
        }
        if id == "nocturne.acpMode" {
            _ = try await rpc.call("session/set_mode", ["sessionId": session, "modeId": value])
            var updated = sessionOptions[session] ?? []
            if let index = updated.firstIndex(where: { $0.id == id }) { updated[index].value = value }
            sessionOptions[session] = updated; return updated
        }
        let response = try await rpc.call("session/set_config_option", ["sessionId": session, "configId": id, "value": value])
        sessionOptions[session] = Self.acpOptions(response)
        return sessionOptions[session] ?? []
    }
    static func acpOptions(_ result: [String: Any]) -> [ChatConfigOption] {
        func flatten(_ choices: [[String: Any]]) -> [ChatConfigChoice] {
            choices.flatMap { row -> [ChatConfigChoice] in
                if let group = row["options"] as? [[String: Any]] { return flatten(group) }
                guard let value = row["value"] as? String, let name = row["name"] as? String else { return [] }
                return [ChatConfigChoice(value, name: name, detail: row["description"] as? String)]
            }
        }
        var options: [ChatConfigOption] = (result["configOptions"] as? [[String: Any]] ?? []).prefix(24).compactMap { row in
            guard row["type"] as? String == "select", let id = row["id"] as? String,
                  let name = row["name"] as? String, let current = row["currentValue"] as? String else { return nil }
            let choices = Array(flatten(row["options"] as? [[String: Any]] ?? []).prefix(500))
            guard !choices.isEmpty else { return nil }
            return ChatConfigOption(id: id, name: name, category: row["category"] as? String, value: current, choices: choices, detail: row["description"] as? String)
        }
        if !options.contains(where: { $0.category == "mode" }), let modes = result["modes"] as? [String: Any], let current = modes["currentModeId"] as? String {
            let choices = (modes["availableModes"] as? [[String: Any]] ?? []).compactMap { row -> ChatConfigChoice? in
                guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                return .init(id, name: name, detail: row["description"] as? String)
            }
            if !choices.isEmpty { options.append(.init(id: "nocturne.acpMode", name: "Approval mode", category: "mode", value: current, choices: choices)) }
        }
        return options
    }
    func approve(_ id: String, option: String, session: String) throws {
        guard let approval = approvals[id], approval.sessionID == session,
              approval.expiresAt > Date(), approval.options.contains(option) else { throw NocturneError.invalidFrame }
        approvals.removeValue(forKey: id)
        if let input = approval.inputAnswers, let questionID = approval.questionID, let label = approval.answerLabels[option] {
            guard !input.responded else { throw NocturneError.invalidFrame }
            input.answers[questionID] = ["answers": [label]]
            if input.answers.count == input.expected {
                input.responded = true
                rpc.respond(approval.rpcID, result: ["answers": input.answers])
            }
        }
        else if configuration.transport == .acp { rpc.respond(approval.rpcID, result: ["outcome": ["outcome": "selected", "optionId": option]]) }
        else if approval.method == "item/permissions/requestApproval" {
            rpc.respond(approval.rpcID, result: ["permissions": ["accept", "acceptForSession"].contains(option) ? approval.permissions : [:], "scope": option == "acceptForSession" ? "session" : "turn"])
        } else { rpc.respond(approval.rpcID, result: ["decision": approval.decisions[option] ?? option]) }
        emit?(ChatEvent(providerID: configuration.id, sessionID: approval.sessionID, kind: .permissionResolved, detail: id))
    }
    private func expireApproval(_ id: String) {
        // The scheduled timeout is monotonic; a backwards wall-clock change must not extend a grant.
        guard let approval = approvals.removeValue(forKey: id) else { return }
        cancelApprovalResponse(approval)
        emit?(ChatEvent(providerID: configuration.id, sessionID: approval.sessionID, kind: .permissionResolved, detail: id))
    }
    private func cancelApprovalResponse(_ approval: Approval) {
        if let input = approval.inputAnswers {
            guard !input.responded else { return }; input.responded = true
            // An incomplete question group never chooses an answer automatically.
            rpc.respond(approval.rpcID, result: ["answers": [String: String]()])
        }
        else if configuration.transport == .acp { rpc.respond(approval.rpcID, result: ["outcome": ["outcome": "cancelled"]]) }
        else if approval.method == "item/permissions/requestApproval" { rpc.respond(approval.rpcID, result: ["permissions": [:], "scope": "turn"]) }
        else { rpc.respond(approval.rpcID, result: ["decision": "cancel"]) }
    }
    private func cancelApprovals() {
        for (id, approval) in approvals {
            cancelApprovalResponse(approval)
            emit?(ChatEvent(providerID: configuration.id, sessionID: approval.sessionID, kind: .permissionResolved, detail: id))
        }
        approvals.removeAll()
    }
    private func activity(_ session: String, _ phase: ChatActivity.Phase, _ detail: String) {
        guard !replaying else { return }
        let value = ChatActivity(phase, detail)
        guard lastActivities[session] != value else { return }
        lastActivities[session] = value
        var event = ChatEvent(providerID: configuration.id, sessionID: session, kind: .configured)
        event.activity = value; emit?(event)
    }
    private func finish(_ id: String, error: String? = nil, detail: String? = nil) {
        guard activeSession == id || voiceSession == id else { return }
        cancelApprovals(); activeSession = nil; activeTurn = nil; lastActivities.removeValue(forKey: id)
        emit?(ChatEvent(providerID: configuration.id, sessionID: id, kind: error == nil ? .completed : .failed, detail: error ?? detail))
    }
    private static func sameRequestID(_ lhs: Any, _ rhs: Any) -> Bool {
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        if lhs is String || rhs is String { return false }
        if let left = lhs as? NSNumber, let right = rhs as? NSNumber { return left == right }
        return false
    }
    private func notification(_ method: String, _ params: [String: Any]) {
        if method.hasPrefix("thread/realtime/") { voiceNotification(method, params); return }
        if configuration.transport == .acp {
            guard method == "session/update", let session = params["sessionId"] as? String,
                  let update = params["update"] as? [String: Any] else { return }
            acpUpdate(session, update); return
        }
        guard let session = params["threadId"] as? String, session == (activeSession ?? voiceSession) else { return }
        switch method {
        case "serverRequest/resolved":
            guard let requestID = params["requestId"] else { return }
            // Provider cleanup wins even if an old notification still offers an action.
            for (id, approval) in approvals where approval.sessionID == session && Self.sameRequestID(approval.rpcID, requestID) {
                approvals.removeValue(forKey: id)
                emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .permissionResolved, detail: id))
            }
        case "turn/diff/updated":
            guard let diff = params["diff"] as? String else { return }
            let text = RepositoryService.text("Latest agent turn", DeveloperCommandResult(data: Data(diff.utf8), error: "", code: 0, truncated: false))
            var event = ChatEvent(providerID: configuration.id, sessionID: session, kind: .diffUpdated)
            event.diff = text; emit?(event)
        case "turn/started":
            activity(session, .working, "Working")
            activeTurn = (params["turn"] as? [String: Any])?["id"] as? String
            emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .diffUpdated))
        case "item/started":
            if let item = params["item"] as? [String: Any] {
                let type = item["type"] as? String ?? ""
                activity(session, type == "reasoning" ? .thinking : type == "agentMessage" ? .working : .tool,
                    type == "reasoning" ? "Thinking" : type == "commandExecution" ? "Running command" : type == "fileChange" ? "Editing files" : type == "agentMessage" ? "Writing reply" : "Using tool")
            }
        case "item/agentMessage/delta":
            activity(session, .working, "Writing reply")
            if let text = params["delta"] as? String, let id = params["itemId"] as? String {
                emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .delta, message: ChatMessage(id: id, role: .assistant, text: text)))
            }
        case "item/completed":
            activity(session, .working, "Working")
            if let item = params["item"] as? [String: Any], let message = Self.codexMessage(item) {
                emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .message, message: message))
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            finish(session, error: status == "failed" ? error ?? "Codex could not finish this reply." : nil, detail: status == "interrupted" ? "Stopped" : nil)
        case "error":
            if params["willRetry"] as? Bool != true {
                let error = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex returned an error."
                finish(session, error: error)
            }
        default: break
        }
    }
    private func acpUpdate(_ session: String, _ update: [String: Any]) {
        guard session == transcriptSession else { return }
        let kind = update["sessionUpdate"] as? String ?? ""
        if kind == "current_mode_update", let mode = update["currentModeId"] as? String,
           var options = sessionOptions[session], let index = options.firstIndex(where: { $0.id == "nocturne.acpMode" }) {
            options[index].value = mode; sessionOptions[session] = options
            var event = ChatEvent(providerID: configuration.id, sessionID: session, kind: .configured)
            event.options = options; emit?(event); return
        }
        if kind == "config_option_update" {
            sessionOptions[session] = Self.acpOptions(update)
            var event = ChatEvent(providerID: configuration.id, sessionID: session, kind: .configured)
            event.options = sessionOptions[session]; emit?(event); return
        }
        if kind == "agent_thought_chunk", session == activeSession, !replaying {
            activity(session, .thinking, "Thinking"); return
        }
        if kind == "agent_message_chunk" || kind == "user_message_chunk" {
            let role: ChatRole = kind == "user_message_chunk" ? .user : .assistant
            let content = update["content"] as? [String: Any] ?? [:]
            let text = Self.contentText(content)
            let explicitID = update["messageId"] as? String
            if chunkRole != role || chunkID == nil || (explicitID != nil && explicitID != chunkID) { chunkID = explicitID ?? UUID().uuidString; chunkRole = role }
            let id = chunkID!
            if let index = transcript.indices.last, transcript[index].id == id { transcript[index].text += text }
            else { transcript.append(ChatMessage(id: id, role: role, text: text)) }
            if replaying {
                replayBytes += text.utf8.count
                if replayBytes > 32 * 1_048_576 { rpc.close(error: NocturneError.remote("This conversation is too large to load from this ACP provider.")) }
            } else if session == activeSession, role == .assistant {
                activity(session, .working, "Writing reply")
                emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .delta, message: ChatMessage(id: id, role: role, text: text)))
            }
        } else if kind == "tool_call" || kind == "tool_call_update" {
            chunkID = nil; chunkRole = nil
            guard let id = update["toolCallId"] as? String else { return }
            if let title = update["title"] as? String { toolTitles[id] = title }
            let text = [toolTitles[id] ?? "Tool activity", update["status"] as? String].compactMap { $0 }.joined(separator: " · ")
            guard !text.isEmpty else { return }
            let message = ChatMessage(id: "tool:" + id, role: .tool, text: text)
            if let index = transcript.firstIndex(where: { $0.id == message.id }) { transcript[index] = message } else { transcript.append(message) }
            if !replaying {
                let status = update["status"] as? String
                activity(session, status == "completed" || status == "failed" ? .working : .tool,
                    status == "failed" ? "Tool failed; agent continuing" : status == "completed" ? "Working" : toolTitles[id] ?? "Using tool")
                emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .message, message: message))
            }
        }
    }
    private func request(_ rpcID: Any, _ method: String, _ params: [String: Any]) {
        let session = (params[configuration.transport == .acp ? "sessionId" : "threadId"] as? String) ?? activeSession ?? voiceSession
        guard let session, session == (activeSession ?? voiceSession), approvals.count < 8 else { rpc.reject(rpcID, message: "No active conversation for this request."); return }
        if configuration.transport == .codex, method == "item/tool/call", params["tool"] as? String == "nocturne_agents",
           supervisorSession?(session) == true, let handler = supervisorTool, let arguments = params["arguments"] as? [String: Any] {
            guard toolTasks.count < 8 else { rpc.reject(rpcID, message: "Too many supervisor actions."); return }
            let token = UUID()
            toolTasks[token] = Task { [weak self] in
                let result: String, success: Bool
                do { result = try await handler(session, arguments); success = true }
                catch { result = error.localizedDescription; success = false }
                guard let self, !self.rpc.closed, !Task.isCancelled else { return }
                self.rpc.respond(rpcID, result: ["success": success, "contentItems": [["type": "inputText", "text": result]]])
                self.toolTasks.removeValue(forKey: token)
            }
            return
        }
        if configuration.transport == .codex, ["item/tool/requestUserInput", "tool/requestUserInput"].contains(method) {
            do {
                let questions = try CodexAttentionQuestions.parse(params)
                guard approvals.count + questions.count <= 8 else { throw NocturneError.invalidFrame }
                let group = InputAnswers(expected: questions.count)
                let timeout = min(approvalLifetime, max(0, (params["autoResolutionMs"] as? Double ?? 300_000) / 1000))
                let expires = Date().addingTimeInterval(timeout)
                for question in questions {
                    let id = UUID().uuidString
                    approvals[id] = Approval(rpcID: rpcID, method: method, sessionID: session,
                        options: Set(question.options.map(\.id)), permissions: [:], expiresAt: expires,
                        inputAnswers: group, questionID: question.id, answerLabels: question.labels)
                    emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .permission,
                        permission: ChatPermission(id: id, title: question.title, detail: question.detail,
                            options: question.options, expiresAt: expires, attentionKind: .question)))
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        self?.expireApproval(id)
                    }
                }
            } catch {
                rpc.reject(rpcID, message: "This input form requires the provider's Mac client. No answer was selected.")
            }
            return
        }
        let options: [ChatPermissionOption]
        var decisions: [String: Any] = [:]
        let title: String, detail: String
        if configuration.transport == .acp, method == "session/request_permission" {
            options = (params["options"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["optionId"] as? String, let name = $0["name"] as? String else { return nil }
                let kind = $0["kind"] as? String
                return ChatPermissionOption(id: id, title: name, destructive: kind?.hasPrefix("reject") == true,
                    action: kind == "allow_once" ? .allowOnce : kind == "reject_once" ? .denyOnce : nil,
                    scope: kind == "allow_always" || kind == "reject_always" ? "Provider remembers this choice. Scope and revocation are managed by the provider on your Mac." : "This request only.")
            }
            let tool = params["toolCall"] as? [String: Any] ?? [:]
            title = tool["title"] as? String ?? "Allow this action?"
            detail = (tool["rawInput"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .fragmentsAllowed]) })
                .flatMap { String(data: $0, encoding: .utf8) } ?? "The agent is waiting for your decision."
        } else if configuration.transport == .codex, ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"].contains(method) {
            let offered = Self.codexApprovalOptions(method: method, params: params)
            options = offered.options; decisions = offered.decisions
            let network = params["networkApprovalContext"] as? [String: Any]
            title = network != nil ? "Allow network access?" : method == "item/fileChange/requestApproval" ? "Allow file changes?" : method == "item/permissions/requestApproval" ? "Allow additional access?" : "Allow this command?"
            detail = [network?["host"] as? String, network?["protocol"] as? String, params["command"] as? String, params["reason"] as? String, params["cwd"] as? String,
                (params["permissions"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted]) }).flatMap { String(data: $0, encoding: .utf8) }]
                .compactMap { $0 }.joined(separator: "\n\n")
        } else {
            rpc.reject(rpcID, message: "This request is not supported by Nocturne. Use the agent on your Mac for this action.")
            emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .message,
                message: ChatMessage(id: UUID().uuidString, role: .system, text: "The provider requested an action that needs its Mac client (\(method)).")))
            return
        }
        guard !options.isEmpty else { rpc.reject(rpcID, message: "The provider supplied no permission options."); return }
        let lifetime = approvalLifetime
        let id = UUID().uuidString, expiresAt = Date().addingTimeInterval(lifetime)
        approvals[id] = Approval(rpcID: rpcID, method: method, sessionID: session, options: Set(options.map(\.id)), permissions: params["permissions"] as? [String: Any] ?? [:], decisions: decisions, expiresAt: expiresAt)
        emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .permission,
            permission: ChatPermission(id: id, title: title, detail: String(detail.prefix(16_384)), options: options, expiresAt: expiresAt)))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            self?.expireApproval(id)
        }
    }

    static func approvalPolicyOption(value: String, allowed: Set<String>? = nil) -> ChatConfigOption {
        ChatConfigOption(id: "nocturne.approvalPolicy", name: "Approval policy", category: "mode", value: value, choices: [
            .init("on-request", name: "Ask when needed (default)", detail: "Codex decides when to request approval."),
            .init("untrusted", name: "Ask for untrusted commands", detail: "Codex may run trusted commands without asking."),
            .init("never", name: "Automatic within sandbox", detail: "Codex never asks for escalation. Actions requiring approval fail; this grants no extra access.")
        ].filter { allowed?.contains($0.value) ?? true }, detail: "This chat’s next text turns, during this connection only. Workspace sandbox stays enabled. Voice uses its own default. Return to Ask when needed to undo. Provider and managed restrictions still apply.")
    }

    /// Keep actual response payloads on the host; the client can only select an offered id.
    static func codexApprovalOptions(method: String, params: [String: Any]) -> (options: [ChatPermissionOption], decisions: [String: Any]) {
        let permissions = method == "item/permissions/requestApproval"
        let command = method == "item/commandExecution/requestApproval"
        // Older App Servers omit availableDecisions. These are their documented native choices.
        let explicit = params["availableDecisions"].map { !($0 is NSNull) } ?? false
        var raw: [Any] = explicit ? (params["availableDecisions"] as? [Any] ?? []) : ["accept", "acceptForSession", "decline", "cancel"]
        if command, !explicit, let prefix = params["proposedExecpolicyAmendment"] as? [String], !prefix.isEmpty {
            raw.append(["acceptWithExecpolicyAmendment": ["execpolicy_amendment": prefix]])
        }
        if permissions, !explicit { raw = ["accept", "acceptForSession", "decline"] }
        var options: [ChatPermissionOption] = [], decisions: [String: Any] = [:]
        for row in raw {
            if let value = row as? String, ["accept", "acceptForSession", "decline", "cancel"].contains(value), !permissions || value != "cancel" {
                guard decisions[value] == nil else { continue }
                let title = value == "accept" ? (permissions ? "Allow for this turn" : "Allow once") : value == "acceptForSession" ? "Allow for session" : value == "cancel" ? "Stop turn" : "Deny"
                let scope = value == "acceptForSession" ? "Provider session cache for this request’s command, files or access. Ends with the provider session; not a global setting." : "This request only."
                options.append(.init(id: value, title: title, destructive: value == "decline" || value == "cancel",
                    action: value == "accept" ? .allowOnce : value == "decline" ? .denyOnce : nil, scope: scope)); decisions[value] = value
            } else if command, let object = row as? [String: Any], object.count == 1,
                      let amendment = object["acceptWithExecpolicyAmendment"] as? [String: Any], amendment.count == 1,
                      let prefix = amendment["execpolicy_amendment"] as? [String], !prefix.isEmpty,
                      prefix == params["proposedExecpolicyAmendment"] as? [String] {
                let id = "execpolicy"
                guard decisions[id] == nil else { continue }
                options.append(.init(id: id, title: "Always allow matching prefix", scope: "Codex saves this rule on your Mac: " + prefix.joined(separator: " ") + ". May affect other chats. Revoke in Codex rules on your Mac."))
                decisions[id] = object
            }
        }
        return (options, decisions)
    }

    static func codexSession(_ value: [String: Any]) -> ChatSessionInfo? {
        guard let id = value["id"] as? String else { return nil }
        let title = (value["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (value["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "New conversation"
        return ChatSessionInfo(id: id, title: String(title.prefix(256)), directory: value["cwd"] as? String ?? "", updatedAt: (value["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
    }
    static func acpSession(_ value: [String: Any]) -> ChatSessionInfo? {
        guard let id = value["sessionId"] as? String, let cwd = value["cwd"] as? String else { return nil }
        let date = (value["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ChatSessionInfo(id: id, title: String((value["title"] as? String ?? "Conversation").prefix(256)), directory: cwd, updatedAt: date)
    }
    static func codexMessage(_ value: [String: Any]) -> ChatMessage? {
        guard let id = value["id"] as? String, let type = value["type"] as? String else { return nil }
        switch type {
        case "userMessage": return ChatMessage(id: id, role: .user, text: (value["content"] as? [[String: Any]] ?? []).map(contentText).joined(separator: "\n"))
        case "agentMessage", "plan": return ChatMessage(id: id, role: .assistant, text: value["text"] as? String ?? "")
        case "commandExecution": return ChatMessage(id: id, role: .tool, text: (value["command"] as? String ?? "Command") + "\n" + (value["aggregatedOutput"] as? String ?? value["status"] as? String ?? ""))
        case "fileChange":
            let paths = (value["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return ChatMessage(id: id, role: .tool, text: "File changes\n" + paths.joined(separator: "\n"))
        case "mcpToolCall", "dynamicToolCall": return ChatMessage(id: id, role: .tool, text: (value["tool"] as? String ?? "Tool") + " · " + (value["status"] as? String ?? ""))
        // Raw reasoning is intentionally not part of the conversation transcript.
        case "reasoning": return nil
        default: return ChatMessage(id: id, role: .system, text: "[\(type)]")
        }
    }
    private static func contentText(_ value: [String: Any]) -> String {
        if let text = value["text"] as? String { return text }
        if let resource = value["resource"] as? [String: Any], let text = resource["text"] as? String { return text }
        let type = value["type"] as? String ?? "attachment"
        return "[\(type): \(value["path"] as? String ?? value["uri"] as? String ?? "attachment")]"
    }
}

extension ChatAgentSession {
    var isVoiceProvider: Bool { chatGPTOnly }

    /// Claim the backing thread before opening the microphone. A writer owned by another
    /// app cannot be transferred; fork its persisted history without interrupting that app.
    func prepareVoiceSession(_ session: String, allowContinuation: Bool = false) async throws -> ChatSessionInfo {
        guard chatGPTOnly, configuration.transport == .codex, activeSession == nil, voiceID == nil else {
            throw NocturneError.remote("Live voice is available for Codex. End the current reply or voice chat first.")
        }
        if preparedVoiceSessions.contains(session), let info = known[session] { return info }
        let account = try await rpc.call("account/read", ["refreshToken": false])
        guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
            throw NocturneError.remote("Sign in with ChatGPT in Nocturne Server → Sharing → Codex live voice on your Mac. Voice requires a Codex-managed ChatGPT login.")
        }
        let voiceDirectory = try await workingDirectory(for: session).path
        let settings = try await rpc.call("config/read", ["includeLayers": false, "cwd": voiceDirectory])
        let config = settings["config"] as? [String: Any] ?? [:]
        let openAI = (config["model_providers"] as? [String: [String: Any]])?["openai"] ?? [:]
        let overridesAuth = ["env_key", "experimental_bearer_token", "auth", "aws"].contains {
            openAI[$0] != nil && !(openAI[$0] is NSNull)
        }
        let headers = ["http_headers", "env_http_headers"].flatMap { (openAI[$0] as? [String: Any])?.keys.map { $0.lowercased() } ?? [] }
        guard !overridesAuth, !headers.contains(where: { ["authorization", "api-key", "x-api-key"].contains($0) }) else {
            throw NocturneError.remote("Voice requires ChatGPT authentication. Remove custom API-key authentication from Codex's OpenAI provider configuration on your Mac.")
        }
        var params: [String: Any] = ["threadId": session, "excludeTurns": true, "modelProvider": "openai",
            "approvalPolicy": "on-request", "sandbox": "workspace-write"]
        if supervisorSession?(session) == true { params["developerInstructions"] = ChatSupervisorService.instructions }
        let result: [String: Any]
        var continued = false
        do { result = try await rpc.call("thread/resume", params) }
        catch let error as AgentRPCError where error.code == -32600 && error.message == "thread \(session) already has an active writer" {
            guard supervisorSession?(session) != true else {
                throw NocturneError.remote("The supervisor is open in another client. End its voice session or close it there, then try again.")
            }
            guard allowContinuation else {
                throw NocturneError.remote("This conversation is open in another client. Update Nocturne on both devices to continue it in voice, or close it there and try again.")
            }
            // A carried goal must not launch work before the user has spoken.
            params["deferGoalContinuation"] = true
            result = try await rpc.call("thread/fork", params)
            continued = true
        }
        guard let thread = result["thread"] as? [String: Any], var info = Self.codexSession(thread),
              continued ? info.id != session : info.id == session else { throw NocturneError.invalidFrame }
        if continued {
            let title = "Voice · " + String((known[session]?.title ?? info.title).prefix(220))
            do { _ = try await rpc.call("thread/name/set", ["threadId": info.id, "name": title]) }
            catch { _ = try? await rpc.call("thread/archive", ["threadId": info.id]); throw error }
            info = ChatSessionInfo(id: info.id, title: title, directory: info.directory, updatedAt: Date())
        }
        opened.insert(info.id); preparedVoiceSessions.insert(info.id); known[info.id] = info
        return info
    }
    func startVoice(_ session: String, lease: String, sdp: String) async throws {
        try ChatVoice.validateSDP(sdp)
        _ = try await prepareVoiceSession(session)
        voiceID = lease; voiceSession = session; voiceStarted = false; voiceAnswerReceived = false; voiceFailure = nil
        canonicalVoiceTranscripts = false; voiceTranscriptRoles = [:]; legacyVoiceTranscripts = [:]
        do {
            var realtime: [String: Any] = ["threadId": session, "outputModality": "audio",
                // 0.164.0 defaults WebRTC to v1, whose quicksilver=v1 header AVAS rejects.
                // v3 selects Codex's Frameless Bidi parser and quicksilver=v2 header.
                "version": "v3", "transport": ["type": "webrtc", "sdp": sdp],
                "realtimeSessionId": lease, "voiceSessionId": lease]
            if supervisorSession?(session) == true {
                realtime["realtimeStartInstructions"] = "You are the Nocturne supervisor. Delegate requests to inspect or manage agents to your backing coding agent, which has the nocturne_agents tool. Report actual results; do not claim a task finished just because it started."
            }
            _ = try await rpc.call("thread/realtime/start", realtime, timeout: 30)
            guard voiceID == lease else { throw NocturneError.remote(voiceFailure ?? "Codex closed the voice session while connecting.") }
            if !voiceStarted || !voiceAnswerReceived {
                try await withCheckedThrowingContinuation { continuation in
                    voiceReady = continuation
                    voiceDeadline = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                        guard let self, self.voiceID == lease else { return }
                        self.endVoiceLocally(error: "Codex voice did not connect. Check voice availability and sign-in on your Mac.")
                    }
                }
            }
        } catch {
            let message = voiceFailure ?? ChatVoice.failure(error.localizedDescription)
            endVoiceLocally(error: message)
            if let rpcError = error as? AgentRPCError, rpcError.unsupported {
                throw NocturneError.remote("Update Codex on your Mac to a version with realtime voice support, then reconnect.")
            }
            throw NocturneError.remote(message)
        }
    }
    func stopVoice(lease: String) async throws {
        guard voiceID == lease, let session = voiceSession else { return }
        _ = try await rpc.call("thread/realtime/stop", ["threadId": session], timeout: 3)
        endVoiceLocally()
    }
    private func endVoiceLocally(error: String? = nil, detail: String? = nil) {
        guard let lease = voiceID, let session = voiceSession else { return }
        if let error { voiceFailure = error }
        voiceID = nil; voiceSession = nil; voiceStarted = false; voiceAnswerReceived = false
        voiceDeadline?.cancel(); voiceDeadline = nil
        voiceReady?.resume(throwing: NocturneError.remote(error ?? "Voice chat ended.")); voiceReady = nil
        emitVoice?(ChatVoiceEvent(voiceID: lease, providerID: configuration.id, sessionID: session,
            kind: error == nil ? .closed : .failed, detail: error ?? detail))
    }
    private func voiceNotification(_ method: String, _ params: [String: Any]) {
        guard let lease = voiceID, let session = voiceSession, params["threadId"] as? String == session else { return }
        func event(_ kind: ChatVoiceEvent.Kind, sdp: String? = nil, detail: String? = nil) {
            emitVoice?(ChatVoiceEvent(voiceID: lease, providerID: configuration.id, sessionID: session, kind: kind, sdp: sdp, detail: detail))
        }
        switch method {
        case "thread/realtime/started":
            guard params["version"] as? String == "v3" else { endVoiceLocally(error: "Codex negotiated an unsupported voice protocol. Update Codex and reconnect."); return }
            voiceStarted = true; event(.started); finishVoiceStartup()
        case "thread/realtime/sdp":
            guard !voiceAnswerReceived, let sdp = params["sdp"] as? String else { endVoiceLocally(error: "Codex returned an invalid WebRTC answer."); return }
            do { try ChatVoice.validateSDP(sdp) }
            catch { endVoiceLocally(error: "Codex returned an invalid WebRTC answer."); return }
            voiceAnswerReceived = true; event(.answer, sdp: sdp); finishVoiceStartup()
        case "thread/realtime/itemAdded":
            let item = params["item"] as? [String: Any] ?? [:]
            if ["input_audio_buffer.speech_started", "response.cancelled", "response.interrupted"].contains(item["type"] as? String ?? "") { event(.speechStarted) }
        case "thread/realtime/item/started", "thread/realtime/item/completed":
            guard let item = params["item"] as? [String: Any], item["type"] as? String == "transcriptSegment",
                  let id = item["id"] as? String, let role = Self.voiceRole(item["role"] as? String) else { return }
            canonicalVoiceTranscripts = true
            if voiceTranscriptRoles.count > 256 { voiceTranscriptRoles.removeAll() }
            voiceTranscriptRoles[id] = role
            if method.hasSuffix("/started"), role == .user { event(.speechStarted) }
            if let text = item["text"] as? String {
                emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .message,
                    message: ChatMessage(id: "voice:" + id, role: role, text: text)))
            }
        case "thread/realtime/item/transcript/delta":
            guard let id = params["itemId"] as? String, let role = voiceTranscriptRoles[id], let delta = params["delta"] as? String else { return }
            emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: .delta,
                message: ChatMessage(id: "voice:" + id, role: role, text: delta)))
        case "thread/realtime/transcript/delta", "thread/realtime/transcript/done":
            guard !canonicalVoiceTranscripts, let roleName = params["role"] as? String,
                  let role = Self.voiceRole(roleName), let text = (params["delta"] ?? params["text"]) as? String else { return }
            let isNew = legacyVoiceTranscripts[roleName] == nil
            let id = legacyVoiceTranscripts[roleName] ?? "voice:" + UUID().uuidString
            legacyVoiceTranscripts[roleName] = id
            if role == .user, isNew { event(.speechStarted) }
            let done = method.hasSuffix("/done")
            emit?(ChatEvent(providerID: configuration.id, sessionID: session, kind: done ? .message : .delta,
                message: ChatMessage(id: id, role: role, text: text)))
            if done { legacyVoiceTranscripts.removeValue(forKey: roleName) }
        case "thread/realtime/error": endVoiceLocally(error: ChatVoice.failure(params["message"] as? String ?? "Codex voice disconnected."))
        case "thread/realtime/closed": endVoiceLocally(detail: params["reason"] as? String)
        default: break
        }
    }
    private func finishVoiceStartup() {
        guard voiceStarted, voiceAnswerReceived else { return }
        voiceDeadline?.cancel(); voiceDeadline = nil
        voiceReady?.resume(); voiceReady = nil
    }
    private static func voiceRole(_ value: String?) -> ChatRole? {
        switch value { case "user": return .user; case "assistant": return .assistant; default: return nil }
    }
}
