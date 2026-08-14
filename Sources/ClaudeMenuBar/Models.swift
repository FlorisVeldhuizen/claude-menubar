import Foundation

struct HookEvent: Decodable {
    let sessionId: String?
    let hookEventName: String?
    let cwd: String?
    let transcriptPath: String?
    let permissionMode: String?
    let toolName: String?
    let toolInput: [String: JSONValue]?
    let toolUseId: String?
    let permissionLevel: String?
    let notificationType: String?
    let agentType: String?
    let termSession: String?
    let termProgram: String?
    let entrypoint: String?

    static func decode(_ data: Data) throws -> HookEvent {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(HookEvent.self, from: data)
    }
}

enum Decision: String {
    case allow, deny, ask
}

/// What to type into the session's pane to answer its prompt.
enum TerminalKey: CustomStringConvertible {
    case option(Int)
    case cancel
    case cancelThenSay(String)
    /// Moves the cursor that many rows, then presses Return. Return acts on the row the cursor is on,
    /// so confirming a tick list means walking to its Submit row first.
    case confirm(steps: Int)
    /// Gated sessions only: block the call and hand Claude the answer as the reason.
    case reply(String)

    var description: String {
        switch self {
        case .option(let n): return "option \(n)"
        case .cancel: return "escape"
        case .confirm(let steps): return "confirm \(steps) rows down"
        case .cancelThenSay(let text): return "escape + \"\(text.prefix(40))\""
        case .reply(let text): return "reply \"\(text.prefix(40))\""
        }
    }
}

struct DecisionResult {
    let decision: Decision
    let message: String?

    /// PreToolUse uses a different field name, and "ask" there means "no decision from us".
    var preToolUseJSON: Data {
        guard decision != .ask else { return Data("{}".utf8) }
        var out: [String: Any] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": decision.rawValue,
        ]
        if let message, !message.isEmpty { out["permissionDecisionReason"] = message }
        return (try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": out])) ?? Data("{}".utf8)
    }

    var json: Data {
        var out: [String: Any] = [
            "hookEventName": "PermissionRequest",
            "decision": decision.rawValue,
        ]
        if let message, !message.isEmpty { out["message"] = message }
        let body: [String: Any] = ["hookSpecificOutput": out]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }
}

enum SessionState: String {
    case working, waiting, done, idle, running

    var label: String {
        switch self {
        case .working: return "working"
        case .waiting: return "needs you"
        case .done: return "finished its turn"
        case .idle: return "waiting for your prompt"
        case .running: return "not reporting yet"
        }
    }

    /// Spelled out on the row, because five short labels on their own don't say what to do about them.
    var meaning: String {
        switch self {
        case .working: return "Claude is running. Nothing to do."
        case .waiting: return "Claude is blocked on a decision. Answer it here."
        case .done: return "Claude finished its turn and is waiting for you. Goes quiet after 10 minutes."
        case .idle: return "Quiet. Claude is waiting for your next prompt."
        case .running: return "A claude process we found, but it has not reported through the hooks yet, so it can't be answered from here."
        }
    }
}

/// Where a session runs, which decides how it can be answered and focused.
enum SessionClient: String {
    case iTerm, vscode, terminal, other

    static func from(entrypoint: String?, termProgram: String?, pane: String?) -> SessionClient {
        if let entrypoint, entrypoint.contains("vscode") { return .vscode }
        switch termProgram {
        case "iTerm.app": return .iTerm
        case "vscode": return .vscode
        case "Apple_Terminal": return .terminal
        default: break
        }
        // Only reached for a hook installed before term_program was reported.
        return (pane?.isEmpty == false) ? .iTerm : .other
    }

    /// True where the app can type an answer into the session's own pane.
    var typeable: Bool { self == .iTerm || self == .terminal }

    var label: String {
        switch self {
        case .iTerm: return "iTerm2"
        case .vscode: return "VS Code"
        case .terminal: return "Terminal"
        case .other: return "session"
        }
    }
}

struct SessionInfo: Identifiable {
    let id: String
    var cwd: String
    var state: SessionState
    var lastActivity: Date
    var agentType: String?
    /// Set for sessions found by scanning processes rather than by a hook.
    var pane: String?
    var client: SessionClient = .other

    var folder: String {
        cwd.isEmpty ? "unknown" : (cwd as NSString).lastPathComponent
    }
}

/// One row of the menu Claude Code has on screen. A row with no number is the Submit row.
struct Row {
    let number: Int?
    var option: MenuOption
    let onCursor: Bool
    /// Where the label starts, so a deeper-indented line below is known to belong to it.
    let labelColumn: Int
}

struct TerminalMenu {
    let options: [MenuOption]
    let rows: [Row]
    let cursor: Int?

    var submitRow: Int? { rows.firstIndex { $0.number == nil } }
}

struct SessionGroup: Identifiable {
    let title: String
    let sessions: [SessionInfo]

    var id: String { title }
}

struct MenuOption: Equatable {
    var label: String
    /// nil where the option is a plain action rather than one of the boxes.
    var ticked: Bool?
}

struct AskOption: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
}

struct AskQuestion: Identifiable {
    let id = UUID()
    let text: String
    let options: [AskOption]
}

/// One look at the session's pane, and whether Claude's menu was on it.
struct MenuRead: Equatable {
    let at: Date
    let sawMenu: Bool
}

struct PendingRequest: Identifiable {
    let id: String
    let sessionId: String
    let toolName: String
    let cwd: String
    let detail: String
    let context: String
    let questions: [AskQuestion]
    let permissionLevel: String?
    let receivedAt: Date
    /// The numbered menu actually on screen, read from the pane once Claude draws it.
    var terminalOptions: [MenuOption] = []
    /// The last pane read to come back for this card.
    var lastRead: MenuRead?
    /// True when the session cannot be reached by keystroke, so the answer goes back through the hook.
    var gated = false
    /// What an always-allow rule from this card would cover. nil where none is offered.
    var scopes: [String]? = []

    /// Names the rule on the button, in the prompt's own terms.
    var scopeLabel: String {
        guard let scopes, let first = scopes.first else { return toolName }
        return scopes.count == 1 ? "\(first)" : "\(first) +\(scopes.count - 1)"
    }

    var folder: String {
        cwd.isEmpty ? "unknown" : (cwd as NSString).lastPathComponent
    }

    /// True once a read has looked for the menu later than it was due and found nothing there.
    /// A clock on its own cannot say this: a read in flight, or one that lands late, still finds it.
    func menuMissed(after wait: TimeInterval) -> Bool {
        guard let lastRead, !lastRead.sawMenu else { return false }
        return lastRead.at.timeIntervalSince(receivedAt) > wait
    }

    /// Claude Code draws a tick box on every option of a multiple-choice question, and nothing on a
    /// plain menu. So the box is how we know a digit ticks rather than answers.
    var isTickList: Bool { terminalOptions.contains { $0.ticked != nil } }

    /// Ticking goes through the terminal and back, which takes about a second. The box flips here
    /// first so the click feels immediate, and the next read replaces it with the real one.
    mutating func flipTick(option: Int) {
        let index = option - 1
        guard terminalOptions.indices.contains(index), let was = terminalOptions[index].ticked else { return }
        terminalOptions[index].ticked = !was
    }

    /// What an "always allow" here would cover, in the terms the prompt itself uses: the command,
    /// not the whole tool. Empty means the arguments say nothing useful, so only a tool-wide rule is
    /// on offer. nil means don't offer one at all.
    static func scopes(for tool: String, input: [String: JSONValue]?) -> [String]? {
        switch tool {
        case "Bash":
            guard let command = input?["command"]?.stringValue else { return [] }
            // A command that builds itself can hide anything inside, so it gets no rule.
            guard !command.contains("$("), !command.contains("`") else { return nil }
            let parts = command
                .replacingOccurrences(of: "&&", with: "\n")
                .replacingOccurrences(of: "||", with: "\n")
                .replacingOccurrences(of: ";", with: "\n")
                .replacingOccurrences(of: "|", with: "\n")
                .split(separator: "\n")
            let prefixes = parts.compactMap { commandPrefix(String($0)) }
            guard prefixes.count == parts.count else { return nil }
            return Array(Set(prefixes)).sorted()
        case "Read", "Write", "Edit", "NotebookEdit":
            guard let path = (input?["file_path"] ?? input?["filePath"])?.display, !path.isEmpty else { return [] }
            return [(path as NSString).deletingLastPathComponent]
        case "WebFetch":
            guard let url = input?["url"]?.stringValue, let host = URL(string: url)?.host else { return [] }
            return [host]
        default:
            return []
        }
    }

    /// Claude Code scopes its own rule to a command family, so ours matches: the program, plus its
    /// subcommand where the program is one that takes them.
    private static let subcommanded: Set<String> = [
        "git", "gh", "npm", "pnpm", "yarn", "cargo", "brew", "docker", "kubectl", "swift", "uv", "pip",
    ]

    private static func commandPrefix(_ segment: String) -> String? {
        let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first, !program.isEmpty, !program.contains("=") else { return nil }
        guard subcommanded.contains(program), words.count > 1, !words[1].hasPrefix("-") else { return program }
        return "\(program) \(words[1])"
    }

    /// The one field that matters per tool, so the card shows the decision-relevant text.
    static func detail(for tool: String, input: [String: JSONValue]?) -> String {
        guard let input, !input.isEmpty else { return "" }
        let preferred: [String]
        switch tool {
        case "Bash": preferred = ["command"]
        case "Write", "Edit", "NotebookEdit", "Read": preferred = ["file_path", "filePath"]
        case "WebFetch", "WebSearch": preferred = ["url", "query"]
        case "Agent", "Task": preferred = ["description", "prompt"]
        default: preferred = ["command", "file_path", "path", "url", "query", "description"]
        }
        for key in preferred {
            if let v = input[key]?.display, !v.isEmpty { return v }
        }
        return input.keys.sorted()
            .compactMap { k in input[k].map { "\(k): \($0.display)" } }
            .joined(separator: "\n")
    }

    static func questions(from input: [String: JSONValue]?) -> [AskQuestion] {
        guard let input, case .array(let items)? = input["questions"] else { return [] }
        return items.compactMap { item in
            guard case .object(let q) = item, let text = q["question"]?.stringValue else { return nil }
            var options: [AskOption] = []
            if case .array(let raw)? = q["options"] {
                options = raw.compactMap { option in
                    guard case .object(let o) = option, let label = o["label"]?.stringValue else { return nil }
                    return AskOption(label: label, detail: o["description"]?.stringValue ?? "")
                }
            }
            return AskQuestion(text: text, options: options)
        }
    }
}
