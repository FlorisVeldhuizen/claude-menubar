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

    var description: String {
        switch self {
        case .option(let n): return "option \(n)"
        case .cancel: return "escape"
        case .cancelThenSay(let text): return "escape + \"\(text.prefix(40))\""
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
    case working, waiting, idle, running

    var label: String {
        switch self {
        case .working: return "working"
        case .waiting: return "needs you"
        case .idle: return "idle"
        case .running: return "running"
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

    var folder: String {
        cwd.isEmpty ? "unknown" : (cwd as NSString).lastPathComponent
    }
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
    var terminalOptions: [String] = []
    /// True when the session cannot be reached by keystroke, so the answer goes back through the hook.
    var gated = false

    var folder: String {
        cwd.isEmpty ? "unknown" : (cwd as NSString).lastPathComponent
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
