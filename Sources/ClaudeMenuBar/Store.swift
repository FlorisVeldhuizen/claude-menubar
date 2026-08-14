import Foundation
import Observation

@MainActor
@Observable
final class Store {
    private(set) var sessions: [SessionInfo] = []
    private(set) var discovered: [SessionInfo] = []

    /// Hook-tracked sessions first, then any live process we have not heard from.
    var allSessions: [SessionInfo] { sessions + discovered }

    /// Grouped by state, so a session that needs you is never listed below three quiet ones.
    /// Order within a group is left alone; sorting live sessions by activity would shuffle them.
    var sessionGroups: [SessionGroup] {
        let all = allSessions
        let order: [(String, [SessionState])] = [
            ("Needs you", [.waiting]),
            ("Working", [.working]),
            ("Finished", [.done]),
            ("Quiet", [.idle, .running]),
        ]
        return order.compactMap { title, states in
            let members = all.filter { states.contains($0.state) }
            return members.isEmpty ? nil : SessionGroup(title: title, sessions: members)
        }
    }
    private(set) var pending: [PendingRequest] = []
    private(set) var autoAllow: Set<String> = []
    var hooksInstalled = false
    private(set) var focusedRequestId: String?
    private(set) var notice: String?

    /// The request shown in the slot: whichever session you picked, else the oldest.
    var activeRequest: PendingRequest? {
        if let id = focusedRequestId, let request = pending.first(where: { $0.id == id }) { return request }
        return pending.first
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
    private var wentQuiet: Set<String> = []
    private var reading: Set<String> = []
    private var lastKeyAt: [String: Date] = [:]
    private var lastMenu: [String: (menu: TerminalMenu, at: Date)] = [:]
    private var unannounced: [String: PendingRequest] = [:]
    private var pollTick = 0

    /// Set by the app: with the panel shut, nobody is watching a card's boxes.
    var panelOpen = false

    /// Read-only work is allowed straight through; gating every call would drown the panel.
    private static let alwaysSafe: Set<String> = [
        "Read", "Glob", "Grep", "LS", "NotebookRead", "TodoWrite", "TaskList", "TaskGet",
    ]

    /// A session that reports no pane cannot be answered by keystroke, so its decision is held here
    /// instead. Fires before the permission flow, and PreToolUse honours long timeouts.
    func gate(_ event: HookEvent) async -> DecisionResult {
        let tool = event.toolName ?? "Tool"
        let sessionId = event.sessionId ?? "unknown"
        let client = SessionClient.from(
            entrypoint: event.entrypoint,
            termProgram: event.termProgram,
            pane: event.termSession
        )
        let reachable = !(event.termSession ?? "").isEmpty && client.typeable
        let project = Transcript.projectPath(from: event.transcriptPath) ?? event.cwd

        if reachable || Self.alwaysSafe.contains(tool) { return DecisionResult(decision: .ask, message: nil) }
        if allowedAlready(tool: tool, project: project ?? "", input: event.toolInput) {
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
            receivedAt: Date(),
            scopes: PendingRequest.scopes(for: tool, input: event.toolInput)
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
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gateWaiters[request.id] = continuation
            }
        } onCancel: {
            // The session went away while we held its decision; drop the card with it.
            Task { @MainActor [weak self] in self?.expire(request.id) }
        }
    }

    private func releaseGate(_ id: String, decision: Decision, message: String? = nil) {
        guard let continuation = gateWaiters.removeValue(forKey: id) else { return }
        Log.write("GATE", "released \(id) as \(decision.rawValue)")
        continuation.resume(returning: DecisionResult(decision: decision, message: message))
    }

    func pane(for sessionId: String) -> String? { panes[sessionId] }

    /// One read per card does both jobs: mirror the menu Claude is showing, and notice when it has
    /// gone — a prompt can be dismissed in ways that fire no hook at all, such as answering No.
    func verifyPending() {
        for request in pending where !request.gated { read(request) }
    }

    /// Reading a pane costs about 0.4s of AppleScript, and every one of those queues behind the others,
    /// which is what a keystroke then waits for. So the timer only keeps the card you are looking at
    /// fresh; the rest, and everything while the panel is shut, go at a third of the rate.
    func pollPending() {
        pollTick += 1
        let watched = panelOpen ? activeRequest?.id : nil
        for request in pending where !request.gated {
            guard request.id == watched || pollTick % 3 == 0 else { continue }
            read(request)
        }
    }

    private func read(_ request: PendingRequest) {
        let id = request.id
        // One read at a time per card, and none that started before the last keystroke: two reads
        // in flight land in either order, and the older one puts the ticks back as they were.
        guard !reading.contains(id) else { return }
        reading.insert(id)
        let startedAt = Date()
        TerminalFocus.readMenu(pane: panes[request.sessionId], cwd: request.cwd, client: client(for: request.sessionId)) { [weak self] menu in
            Task { @MainActor in
                guard let self else { return }
                self.reading.remove(id)
                let options = menu.options
                if let typed = self.lastKeyAt[id], typed > startedAt { return }
                self.lastMenu[id] = (menu, Date())
                if !options.isEmpty { self.announce(id, drawn: true) }
                guard let index = self.pending.firstIndex(where: { $0.id == id }) else { return }
                if options.isEmpty {
                    guard !self.pending[index].terminalOptions.isEmpty else { return }
                    // A tool that asks several questions redraws between them, so one empty read
                    // is not proof the prompt has gone.
                    if self.pending[index].isTickList, self.wentQuiet.insert(id).inserted { return }
                    Log.write("CARD", "prompt gone from screen")
                    self.expire(id)
                } else if self.pending[index].terminalOptions != options {
                    self.wentQuiet.remove(id)
                    self.pending[index].terminalOptions = options
                    self.onChange?()
                }
            }
        }
    }

    /// Only ever called once Claude Code says its prompt is drawn, so the key lands on a menu.
    private func flushKey(_ session: String) {
        guard let queued = queuedKeys.removeValue(forKey: session) else { return }
        deliver(queued.key, session: session, cwd: queued.cwd)
    }

    /// The prompt never appeared. Typing now would put a digit in the composer, so the key is thrown
    /// away and the card comes back instead.
    private func dropQueuedKey(_ request: PendingRequest) {
        guard queuedKeys.removeValue(forKey: request.sessionId) != nil else { return }
        Log.write("KEY", "dropped: no prompt appeared for \(request.folder)")
        if !pending.contains(where: { $0.id == request.id }) { pending.append(request) }
        focusedRequestId = request.id
        notice = "\(request.folder) never drew its prompt — nothing was typed."
        onChange?()
    }

    init() {
        autoAllow = Persistence.loadRules()
        panes = Persistence.loadPanes()
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

    private func forget(_ sessionId: String) {
        clients.removeValue(forKey: sessionId)
        answered.removeValue(forKey: sessionId)
        guard let pane = panes.removeValue(forKey: sessionId) else { return }
        TerminalFocus.forget(pane: pane)
        Persistence.savePanes(panes)
    }

    private func remember(pane: String, for sessionId: String) {
        guard panes[sessionId] != pane else { return }
        panes[sessionId] = pane
        Persistence.savePanes(panes)
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

        if allowedAlready(tool: tool, project: project ?? "", input: event.toolInput) {
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
            receivedAt: Date(),
            scopes: PendingRequest.scopes(for: tool, input: event.toolInput)
        )
        pending.removeAll { $0.sessionId == sessionId && $0.toolName == tool }
        pending.append(request)
        Log.write("CARD", "added \(tool) id=\(request.id) session=\(sessionId) pending=\(pending.count)")
        onChange?()
        announceWhenReady(request)

        return DecisionResult(decision: .ask, message: nil)
    }

    // MARK: - Alerting

    /// The hook beats the prompt to the screen by a moment, and a card with no menu behind it cannot
    /// be answered yet. So the alert waits for Claude Code to draw it.
    private func announceWhenReady(_ request: PendingRequest) {
        guard !promptShowing.contains(request.sessionId) else {
            onNewRequest?(request)
            return
        }
        unannounced[request.id] = request
        Task { [weak self] in
            // Shorter than the 8s a queued key waits, so a late alert is still one you can act on.
            try? await Task.sleep(for: .seconds(6))
            self?.announce(request.id, drawn: false)
        }
    }

    private func announceReady(session: String) {
        for id in unannounced.filter({ $0.value.sessionId == session }).keys { announce(id, drawn: true) }
    }

    private func announce(_ id: String, drawn: Bool) {
        guard let request = unannounced.removeValue(forKey: id) else { return }
        guard pending.contains(where: { $0.id == id }) else { return }
        if !drawn { Log.write("ALERT", "no prompt seen for \(request.folder); alerting anyway") }
        onNewRequest?(request)
    }

    /// Answer the prompt in the terminal. Waits for it to be drawn if it isn't yet.
    func answer(_ request: PendingRequest, key: TerminalKey, remember: Bool = false) {
        if remember { rememberRule(for: request) }
        notice = nil
        answered[request.sessionId] = request
        pending.removeAll { $0.id == request.id }
        settle(request.sessionId)
        if focusedRequestId == request.id { focusedRequestId = nil }
        onChange?()

        if request.gated {
            switch key {
            case .option, .confirm: releaseGate(request.id, decision: .allow)
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
                self?.dropQueuedKey(request)
            }
        }
    }

    /// Ticks one box of a multiple-choice question, flipping it here first so the click lands at once.
    func tick(_ request: PendingRequest, option: Int) {
        if let index = pending.firstIndex(where: { $0.id == request.id }) {
            pending[index].flipTick(option: option)
            onChange?()
        }
        keepingCard(request, key: .option(option), what: "tick option \(option)")
    }

    /// Confirms a multiple-choice question. Return acts on whatever row the cursor is on, so the menu
    /// is read first to find out how far the Submit row is from there. The card stays: one tool call
    /// can ask several questions in turn, and the next one is drawn in the same place.
    func submit(_ request: PendingRequest) {
        notice = nil
        // Ticking does not move the cursor, so a read from a moment ago still says where it is.
        if let last = lastMenu[request.id], Date().timeIntervalSince(last.at) < 2,
           let submitRow = last.menu.submitRow, let cursor = last.menu.cursor {
            keepingCard(request, key: .confirm(steps: submitRow - cursor), what: "submit")
            return
        }
        TerminalFocus.readMenu(pane: panes[request.sessionId], cwd: request.cwd, client: client(for: request.sessionId)) { [weak self] menu in
            Task { @MainActor in
                guard let self else { return }
                guard let submitRow = menu.submitRow, let cursor = menu.cursor else {
                    self.notice = "Can't see where \(request.folder)'s Submit row is — send it in the terminal."
                    self.onChange?()
                    Log.write("KEY", "submit skipped: submit=\(menu.submitRow.map(String.init) ?? "-") cursor=\(menu.cursor.map(String.init) ?? "-")")
                    return
                }
                self.keepingCard(request, key: .confirm(steps: submitRow - cursor), what: "submit")
            }
        }
    }

    /// Unlike answering, these keys leave a prompt on screen, so the card lives until a read finds
    /// no menu left.
    private func keepingCard(_ request: PendingRequest, key: TerminalKey, what: String) {
        notice = nil
        Log.write("KEY", "\(what) session=\(request.sessionId)")
        TerminalFocus.send(key: key, pane: panes[request.sessionId], cwd: request.cwd, client: client(for: request.sessionId)) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                guard ok else {
                    self.notice = self.client(for: request.sessionId) == .terminal
                        ? "Terminal can't be sent an arrow key, so \(request.folder)'s tick list has to be submitted there."
                        : "Could not tell which pane \(request.folder) is in — answer it in the terminal."
                    self.onChange?()
                    return
                }
                self.lastKeyAt[request.id] = Date()
                try? await Task.sleep(for: .milliseconds(150))
                self.verifyPending()
            }
        }
    }

    private func deliver(_ key: TerminalKey, session: String, cwd: String) {
        let pane = panes[session]
        Log.write("KEY", "send \(key) session=\(session) pane=\(pane ?? "-")")
        promptShowing.remove(session)
        let request = answered[session]
        TerminalFocus.send(key: key, pane: pane, cwd: cwd, client: client(for: session)) { [weak self] ok in
            Log.write("KEY", ok ? "delivered" : "FAILED to reach pane")
            guard !ok, let self, let request else { return }
            Task { @MainActor in self.deliveryFailed(request) }
        }
    }

    /// We could not identify the pane, so the prompt is still unanswered. Put the card back and say so.
    private func deliveryFailed(_ request: PendingRequest) {
        if !pending.contains(where: { $0.id == request.id }) { pending.append(request) }
        focusedRequestId = request.id
        notice = request.isTickList && client(for: request.sessionId) == .terminal
            ? "Terminal can't be sent an arrow key, so \(request.folder)'s tick list has to be submitted there."
            : "Could not tell which pane \(request.folder) is in — answer it in the terminal."
        onChange?()
        TerminalFocus.reveal(pane: panes[request.sessionId], cwd: request.cwd, client: client(for: request.sessionId))
    }

    /// Drops a request whose session is gone or whose hook timed out, so a dead card can't sit there.
    private func expire(_ id: String) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        releaseGate(id, decision: .ask)
        Log.write("CARD", "removed id=\(id)")
        wentQuiet.remove(id)
        unannounced.removeValue(forKey: id)
        pending.removeAll { $0.id == id }
        settle(request.sessionId)
        if focusedRequestId == id { focusedRequestId = nil }
        onChange?()
    }

    /// The app is quitting; the terminal prompts are still live, so just clear our view of them.
    func releaseAll() {
        pending.removeAll()
        onChange?()
    }

    /// A rule covers the command, so every part of a chained one has to be covered before it passes.
    private func allowedAlready(tool: String, project: String, input: [String: JSONValue]?) -> Bool {
        if autoAllow.contains(Persistence.ruleKey(cwd: project, tool: tool, scope: "")) { return true }
        guard let scopes = PendingRequest.scopes(for: tool, input: input), !scopes.isEmpty else { return false }
        return scopes.allSatisfy {
            autoAllow.contains(Persistence.ruleKey(cwd: project, tool: tool, scope: $0))
        }
    }

    private func rememberRule(for request: PendingRequest) {
        let scopes = request.scopes ?? []
        for scope in scopes.isEmpty ? [""] : scopes {
            autoAllow.insert(Persistence.ruleKey(cwd: request.cwd, tool: request.toolName, scope: scope))
        }
        Persistence.saveRules(autoAllow)
        Log.write("RULE", "always allow \(request.toolName) \(scopes.joined(separator: ", ")) in \(request.folder)")
    }

    func clearAutoAllow() {
        autoAllow.removeAll()
        Persistence.saveRules(autoAllow)
        onChange?()
    }

    // MARK: - Keeping the list honest

    /// Claude Code only fires SessionEnd on a clean exit, so quiet sessions are dropped on a timer.
    func sweep(staleAfter: TimeInterval) {
        let settled = Date().addingTimeInterval(-10 * 60)
        for index in sessions.indices where sessions[index].lastActivity < settled {
            switch sessions[index].state {
            case .done: sessions[index].state = .idle
            // A notification claimed a prompt we never got a card for; ten minutes on, it is gone.
            case .waiting where !hasPending(sessions[index].id): sessions[index].state = .idle
            default: break
            }
        }
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

    // MARK: - Tab titles

    /// What Claude Code is calling the work in each tab. Held beside the sessions rather than on them:
    /// the process scan replaces `discovered` wholesale, which would drop a title written onto it.
    private(set) var titles: [String: String] = [:]

    func title(for sessionId: String) -> String? { titles[sessionId] }

    /// Only while the panel is open. A title nobody is looking at is not worth an AppleScript round
    /// trip, which queues ahead of the next keystroke.
    func refreshTitles() {
        guard panelOpen else { return }
        var handles = panes.filter { !$0.value.isEmpty }
        for session in discovered {
            if let pane = session.pane, !pane.isEmpty { handles[session.id] = pane }
        }
        guard !handles.isEmpty else { return }

        TerminalFocus.readTitles(panes: handles) { [weak self] found in
            Task { @MainActor in
                guard let self, let found, self.titles != found else { return }
                self.titles = found
                Log.write("TITLE", "named \(found.count) of \(handles.count) tabs")
            }
        }
    }

    // MARK: - Alert sound

    private(set) var alertSound = Sound.current

    var muted: Bool { alertSound == Sound.silent }

    /// Plays on the way in, so you can hear a sound before keeping it.
    func pickSound(_ name: String, preview: Bool = true) {
        if name != Sound.silent { Sound.lastAudible = name }
        Sound.current = name
        alertSound = name
        if preview { Sound.play(name) }
        onChange?()
    }

    func toggleMute() {
        let next = muted ? Sound.lastAudible : Sound.silent
        pickSound(next, preview: next != Sound.silent)
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
                pane: process.pane,
                client: process.client
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

    /// A row may only claim it needs you while a card backs it up. Once the last one goes, the
    /// prompt has been settled somewhere, so the session is between turns.
    private func settle(_ sessionId: String) {
        guard !hasPending(sessionId),
              let index = sessions.firstIndex(where: { $0.id == sessionId }),
              sessions[index].state == .waiting
        else { return }
        sessions[index].state = .done
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
            announceReady(session: sessionId)
            verifyPending()
        }
        settledElsewhere(event)
        switch event.hookEventName {
        case "SessionEnd":
            forget(sessionId)
            sessions.removeAll { $0.id == sessionId }
            pending.removeAll { $0.sessionId == sessionId }
        case "UserPromptSubmit", "SessionStart", "PostToolUse":
            touch(sessionId: sessionId, cwd: project, state: .working, agentType: event.agentType)
        case "Stop":
            // Claude only finishes a turn once nothing is blocking it, so any card here is stale.
            for stale in pending where stale.sessionId == sessionId { expire(stale.id) }
            touch(sessionId: sessionId, cwd: project, state: .done, agentType: event.agentType)
        case "Notification":
            touch(sessionId: sessionId, cwd: project, state: Self.state(for: event.notificationType), agentType: event.agentType)
        default:
            touch(sessionId: sessionId, cwd: project, state: nil, agentType: event.agentType)
        }
        onChange?()
    }

    /// Only a prompt on screen means Claude is blocked. idle_prompt is a timer saying Claude has
    /// nothing to do, and the rest say nothing about state, so they leave the row as it is.
    private static func state(for notificationType: String?) -> SessionState? {
        switch notificationType {
        case "permission_prompt", "agent_needs_input", "elicitation_dialog": return .waiting
        case "idle_prompt", "agent_completed": return .done
        case "elicitation_complete", "elicitation_response": return .working
        default: return nil
        }
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
