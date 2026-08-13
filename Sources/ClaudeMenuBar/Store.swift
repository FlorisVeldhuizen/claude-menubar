import Foundation
import Observation

@MainActor
@Observable
final class Store {
    private(set) var sessions: [SessionInfo] = []
    private(set) var discovered: [SessionInfo] = []

    /// Hook-tracked sessions first, then any live process we have not heard from.
    var allSessions: [SessionInfo] { sessions + discovered }
    private(set) var pending: [PendingRequest] = []
    private(set) var autoAllow: Set<String> = []
    var hooksInstalled = false
    private(set) var focusedRequestId: String?

    /// The request shown in the slot: whichever session you picked, else the oldest.
    var activeRequest: PendingRequest? {
        if let id = focusedRequestId, let request = pending.first(where: { $0.id == id }) { return request }
        return pending.first
    }

    var activeIndex: Int {
        guard let active = activeRequest else { return 0 }
        return (pending.firstIndex { $0.id == active.id } ?? 0) + 1
    }

    func focus(requestId: String) {
        focusedRequestId = requestId
        onChange?()
    }

    func step(_ delta: Int) {
        guard pending.count > 1, let active = activeRequest,
              let index = pending.firstIndex(where: { $0.id == active.id })
        else { return }
        let next = (index + delta + pending.count) % pending.count
        focusedRequestId = pending[next].id
        onChange?()
    }

    func focus(sessionId: String) {
        guard let request = pending.first(where: { $0.sessionId == sessionId }) else { return }
        focusedRequestId = request.id
        onChange?()
    }

    func pendingCount(for sessionId: String) -> Int {
        pending.filter { $0.sessionId == sessionId }.count
    }

    var onChange: (() -> Void)?
    var onNewRequest: ((PendingRequest) -> Void)?

    private var panes: [String: String] = [:]
    private var queuedKeys: [String: (key: TerminalKey, cwd: String)] = [:]
    private var promptShowing: Set<String> = []
    private var answered: [String: PendingRequest] = [:]
    private var gateWaiters: [String: CheckedContinuation<DecisionResult, Never>] = [:]

    /// Read-only work is allowed straight through; gating every call would drown the panel.
    private static let alwaysSafe: Set<String> = [
        "Read", "Glob", "Grep", "LS", "NotebookRead", "TodoWrite", "TaskList", "TaskGet",
    ]

    /// A session that reports no pane cannot be answered by keystroke, so its decision is held here
    /// instead. Fires before the permission flow, and PreToolUse honours long timeouts.
    func gate(_ event: HookEvent) async -> DecisionResult {
        let tool = event.toolName ?? "Tool"
        let sessionId = event.sessionId ?? "unknown"
        let reachable = !(event.termSession ?? "").isEmpty
        let project = Transcript.projectPath(from: event.transcriptPath) ?? event.cwd

        if reachable || Self.alwaysSafe.contains(tool) { return DecisionResult(decision: .ask, message: nil) }
        if autoAllow.contains(Self.ruleKey(cwd: project ?? "", tool: tool)) {
            return DecisionResult(decision: .allow, message: nil)
        }

        touch(sessionId: sessionId, cwd: project, state: .waiting, agentType: event.agentType)
        var request = PendingRequest(
            id: event.toolUseId ?? UUID().uuidString,
            sessionId: sessionId,
            toolName: tool,
            cwd: sessions.first { $0.id == sessionId }?.cwd ?? project ?? "",
            detail: PendingRequest.detail(for: tool, input: event.toolInput),
            context: Transcript.lastAssistantText(path: event.transcriptPath),
            questions: PendingRequest.questions(from: event.toolInput),
            permissionLevel: event.permissionLevel,
            receivedAt: Date()
        )
        request.gated = true
        note(event, for: sessionId)
        pending.append(request)
        Log.write("GATE", "holding \(tool) for \(request.folder) (no pane)")
        onChange?()
        onNewRequest?(request)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(280))
            self?.releaseGate(request.id, decision: .ask)
        }
        return await withCheckedContinuation { continuation in
            gateWaiters[request.id] = continuation
        }
    }

    private func releaseGate(_ id: String, decision: Decision, message: String? = nil) {
        guard let continuation = gateWaiters.removeValue(forKey: id) else { return }
        Log.write("GATE", "released \(id) as \(decision.rawValue)")
        continuation.resume(returning: DecisionResult(decision: decision, message: message))
    }
    private(set) var notice: String?

    func pane(for sessionId: String) -> String? { panes[sessionId] }

    /// A prompt can be dismissed in ways that fire no hook at all — answering No, or interrupting.
    /// So each open card is checked against what is actually on screen.
    func verifyPending() {
        for request in pending where !request.gated {
            let id = request.id
            TerminalFocus.readOptions(pane: panes[request.sessionId], cwd: request.cwd) { [weak self] options in
                Task { @MainActor in
                    guard let self, options.isEmpty,
                          let index = self.pending.firstIndex(where: { $0.id == id }),
                          !self.pending[index].terminalOptions.isEmpty
                    else { return }
                    Log.write("CARD", "prompt gone from screen")
                    self.expire(id)
                }
            }
        }
    }

    /// Once the prompt is drawn, mirror its real options onto the card.
    private func readMenu(for sessionId: String) {
        guard let request = pending.first(where: { $0.sessionId == sessionId }), !request.gated else { return }
        TerminalFocus.readOptions(pane: panes[sessionId], cwd: request.cwd) { [weak self] options in
            Task { @MainActor in
                guard let self, !options.isEmpty,
                      let index = self.pending.firstIndex(where: { $0.id == request.id })
                else { return }
                self.pending[index].terminalOptions = options
                self.onChange?()
            }
        }
    }

    private func flushKey(_ session: String) {
        guard let queued = queuedKeys.removeValue(forKey: session) else { return }
        deliver(queued.key, session: session, cwd: queued.cwd)
    }

    init() {
        autoAllow = Self.loadAutoAllow()
        panes = Self.loadPanes()
    }

    private var clients: [String: SessionClient] = [:]

    func client(for sessionId: String) -> SessionClient { clients[sessionId] ?? .other }

    private func note(_ event: HookEvent, for sessionId: String) {
        let client = SessionClient.from(
            entrypoint: event.entrypoint,
            termProgram: event.termProgram,
            pane: event.termSession
        )
        guard client != .other, clients[sessionId] != client else { return }
        clients[sessionId] = client
        Log.write("CLIENT", "\(sessionId) is \(client.label)")
    }

    private func remember(pane: String, for sessionId: String) {
        guard panes[sessionId] != pane else { return }
        panes[sessionId] = pane
        Self.savePanes(panes)
        Log.write("PANE", "\(sessionId) -> \(pane)")
    }

    // MARK: - Permission flow

    /// Claude Code only waits ~6s for this hook, so a human decision can never be returned through it.
    /// We answer immediately and drive the terminal prompt by keystroke instead.
    func capture(_ event: HookEvent) -> DecisionResult {
        let tool = event.toolName ?? "Tool"
        let sessionId = event.sessionId ?? "unknown"
        if let pane = event.termSession, !pane.isEmpty { remember(pane: pane, for: sessionId) }
        note(event, for: sessionId)
        let project = Transcript.projectPath(from: event.transcriptPath) ?? event.cwd

        if autoAllow.contains(Self.ruleKey(cwd: project ?? "", tool: tool)) {
            return DecisionResult(decision: .allow, message: nil)
        }

        touch(sessionId: sessionId, cwd: project, state: .waiting, agentType: event.agentType)
        let homeCwd = sessions.first { $0.id == sessionId }?.cwd ?? event.cwd ?? ""

        let request = PendingRequest(
            id: event.toolUseId ?? UUID().uuidString,
            sessionId: sessionId,
            toolName: tool,
            cwd: homeCwd,
            detail: PendingRequest.detail(for: tool, input: event.toolInput),
            context: Transcript.lastAssistantText(path: event.transcriptPath),
            questions: PendingRequest.questions(from: event.toolInput),
            permissionLevel: event.permissionLevel,
            receivedAt: Date()
        )
        pending.removeAll { $0.sessionId == sessionId && $0.toolName == tool }
        pending.append(request)
        Log.write("CARD", "added \(tool) id=\(request.id) session=\(sessionId) pending=\(pending.count)")
        onChange?()
        onNewRequest?(request)

        return DecisionResult(decision: .ask, message: nil)
    }

    /// Answer the prompt in the terminal. Waits for it to be drawn if it isn't yet.
    func answer(_ request: PendingRequest, key: TerminalKey, remember: Bool = false) {
        if remember {
            autoAllow.insert(Self.ruleKey(cwd: request.cwd, tool: request.toolName))
            Self.saveAutoAllow(autoAllow)
        }
        notice = nil
        answered[request.sessionId] = request
        pending.removeAll { $0.id == request.id }
        if focusedRequestId == request.id { focusedRequestId = nil }
        onChange?()

        if request.gated {
            switch key {
            case .option: releaseGate(request.id, decision: .allow)
            case .cancel: releaseGate(request.id, decision: .deny, message: "Denied from the menu bar.")
            case .cancelThenSay(let text): releaseGate(request.id, decision: .deny, message: text)
            case .reply(let text): releaseGate(request.id, decision: .deny, message: text)
            }
            return
        }

        if case .reply = key { return }
        if promptShowing.contains(request.sessionId) {
            deliver(key, session: request.sessionId, cwd: request.cwd)
        } else {
            queuedKeys[request.sessionId] = (key, request.cwd)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.flushKey(request.sessionId)
            }
        }
    }

    private func deliver(_ key: TerminalKey, session: String, cwd: String) {
        let pane = panes[session]
        Log.write("KEY", "send \(key) session=\(session) pane=\(pane ?? "-")")
        promptShowing.remove(session)
        let request = answered[session]
        TerminalFocus.send(key: key, pane: pane, cwd: cwd) { [weak self] ok in
            Log.write("KEY", ok ? "delivered" : "FAILED to reach pane")
            guard !ok, let self, let request else { return }
            Task { @MainActor in self.deliveryFailed(request) }
        }
    }

    /// We could not identify the pane, so the prompt is still unanswered. Put the card back and say so.
    private func deliveryFailed(_ request: PendingRequest) {
        if !pending.contains(where: { $0.id == request.id }) { pending.append(request) }
        focusedRequestId = request.id
        notice = "Could not tell which pane \(request.folder) is in — answer it in the terminal."
        onChange?()
        TerminalFocus.reveal(pane: panes[request.sessionId], cwd: request.cwd, client: client(for: request.sessionId))
    }

    /// Drops a request whose session is gone or whose hook timed out, so a dead card can't sit there.
    private func expire(_ id: String) {
        guard pending.contains(where: { $0.id == id }) else { return }
        releaseGate(id, decision: .ask)
        Log.write("CARD", "removed id=\(id)")
        pending.removeAll { $0.id == id }
        if focusedRequestId == id { focusedRequestId = nil }
        onChange?()
    }

    /// The app is quitting; the terminal prompts are still live, so just clear our view of them.
    func releaseAll() {
        pending.removeAll()
        onChange?()
    }

    func clearAutoAllow() {
        autoAllow.removeAll()
        Self.saveAutoAllow(autoAllow)
        onChange?()
    }

    /// Keyed by project directory, not session: session ids are new every run, so a saved rule would never match.
    private static func ruleKey(cwd: String, tool: String) -> String { "\(cwd)|\(tool)" }

    private static var rulesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("always-allow.json")
    }

    private static func loadAutoAllow() -> Set<String> {
        guard let data = try? Data(contentsOf: rulesURL),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    private static var panesURL: URL {
        rulesURL.deletingLastPathComponent().appendingPathComponent("panes.json")
    }

    private static func loadPanes() -> [String: String] {
        guard let data = try? Data(contentsOf: panesURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private static func savePanes(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: panesURL, options: .atomic)
    }

    private static func saveAutoAllow(_ rules: Set<String>) {
        guard let data = try? JSONEncoder().encode(rules.sorted()) else { return }
        try? data.write(to: rulesURL, options: .atomic)
    }

    // MARK: - Keeping the list honest

    /// Claude Code only fires SessionEnd on a clean exit, so quiet sessions are dropped on a timer.
    func sweep(staleAfter: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        let before = sessions.count
        sessions.removeAll { session in
            session.lastActivity < cutoff && !hasPending(session.id)
        }
        if sessions.count != before { onChange?() }
    }

    func jump(toSessionOf request: PendingRequest) {
        notice = nil
        onChange?()
        TerminalFocus.reveal(pane: panes[request.sessionId], cwd: request.cwd, client: client(for: request.sessionId)) { [weak self] exact in
            guard !exact else { return }
            Task { @MainActor in
                self?.notice = "Don't know \(request.folder)'s pane yet — answer it in the terminal."
                self?.onChange?()
            }
        }
    }

    func jump(to session: SessionInfo) {
        notice = nil
        onChange?()
        TerminalFocus.reveal(pane: session.pane ?? panes[session.id], cwd: session.cwd, client: session.client) { [weak self] exact in
            guard !exact else { return }
            Task { @MainActor in
                self?.notice = "Don't know \(session.folder)'s pane yet — send it one prompt to register it."
                self?.onChange?()
            }
        }
    }

    func dismissRequest(_ request: PendingRequest) {
        expire(request.id)
    }

    func dismiss(_ sessionId: String) {
        sessions.removeAll { $0.id == sessionId }
        onChange?()
    }

    func clearIdle() {
        sessions.removeAll { session in
            session.state == .idle && !hasPending(session.id)
        }
        onChange?()
    }

    var idleCount: Int {
        sessions.filter { $0.state == .idle && !hasPending($0.id) }.count
    }

    private func setState(_ sessionId: String, to state: SessionState) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].state = state
        sessions[index].lastActivity = Date()
    }

    /// A scanned process is only listed if no tracked session already covers it.
    func merge(scan found: [SessionScan.Found]) {
        let knownPanes = Set(panes.values.compactMap { $0.split(separator: ":").last.map(String.init) })
        let knownPaths = Set(sessions.map(\.cwd))

        let fresh = found.compactMap { process -> SessionInfo? in
            let guid = process.pane?.split(separator: ":").last.map(String.init)
            if let guid, knownPanes.contains(guid) { return nil }
            if process.pane == nil, knownPaths.contains(process.cwd) { return nil }
            return SessionInfo(
                id: "pid:\(process.pid)",
                cwd: process.cwd,
                state: .running,
                lastActivity: Date(),
                agentType: nil,
                pane: process.pane
            )
        }
        guard fresh.map(\.id) != discovered.map(\.id) else { return }
        discovered = fresh
        onChange?()
    }

    static func isTemporary(_ path: String) -> Bool {
        path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/var/folders/")
            || path.hasPrefix("/var/folders/")
    }

    private func hasPending(_ sessionId: String) -> Bool {
        pending.contains { $0.sessionId == sessionId }
    }

    // MARK: - Session tracking

    func record(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        if let pane = event.termSession, !pane.isEmpty { remember(pane: pane, for: sessionId) }
        note(event, for: sessionId)
        let project = Transcript.projectPath(from: event.transcriptPath) ?? event.cwd
        // This fires the moment Claude Code draws its prompt, which is when a keystroke can land.
        if event.hookEventName == "Notification" {
            promptShowing.insert(sessionId)
            flushKey(sessionId)
            readMenu(for: sessionId)
        }
        settledElsewhere(event)
        switch event.hookEventName {
        case "SessionEnd":
            sessions.removeAll { $0.id == sessionId }
            pending.removeAll { $0.sessionId == sessionId }
        case "UserPromptSubmit", "SessionStart", "PostToolUse":
            touch(sessionId: sessionId, cwd: project, state: .working, agentType: event.agentType)
        case "Stop":
            // Claude only finishes a turn once nothing is blocking it, so any card here is stale.
            for stale in pending where stale.sessionId == sessionId { expire(stale.id) }
            touch(sessionId: sessionId, cwd: project, state: .idle, agentType: event.agentType)
        case "Notification":
            let waitingTypes: Set<String> = ["permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog"]
            let state: SessionState = waitingTypes.contains(event.notificationType ?? "") ? .waiting : .idle
            touch(sessionId: sessionId, cwd: project, state: state, agentType: event.agentType)
        default:
            touch(sessionId: sessionId, cwd: project, state: nil, agentType: event.agentType)
        }
        onChange?()
    }

    /// The tool ran, or was refused, in the terminal. Either way our card is stale.
    private func settledElsewhere(_ event: HookEvent) {
        guard event.hookEventName == "PostToolUse" || event.hookEventName == "PermissionDenied" else { return }
        if let session = event.sessionId { promptShowing.remove(session) }
        if let id = event.toolUseId, pending.contains(where: { $0.id == id }) {
            expire(id)
            return
        }
        guard let session = event.sessionId, let tool = event.toolName,
              let stale = pending.first(where: { $0.sessionId == session && $0.toolName == tool })
        else { return }
        Log.write("CARD", "settled in terminal via \(event.hookEventName ?? "?")")
        expire(stale.id)
    }

    private func touch(sessionId: String, cwd: String?, state: SessionState?, agentType: String?) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            // Claude Code reports its shell's cwd, which follows a cd into a scratchpad.
            // A temp directory is never a session's identity, so it only fills an empty slot.
            if let cwd, !cwd.isEmpty {
                let current = sessions[index].cwd
                if current.isEmpty || (Self.isTemporary(current) && !Self.isTemporary(cwd)) {
                    sessions[index].cwd = cwd
                }
            }
            if let state { sessions[index].state = state }
            if let agentType { sessions[index].agentType = agentType }
            sessions[index].lastActivity = Date()
        } else {
            sessions.append(SessionInfo(
                id: sessionId,
                cwd: cwd ?? "",
                state: state ?? .idle,
                lastActivity: Date(),
                agentType: agentType
            ))
        }
    }

}
