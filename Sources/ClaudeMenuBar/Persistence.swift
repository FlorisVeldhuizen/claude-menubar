import Foundation

/// The two things worth surviving a restart: which tools you have always-allowed, and which pane
/// each session runs in.
enum Persistence {
    /// Keyed by project directory, not session: session ids are new every run, so a session-keyed
    /// rule could never match again.
    /// An empty scope is the tool-wide rule, kept for tools whose arguments say nothing useful.
    static func ruleKey(cwd: String, tool: String, scope: String) -> String { "\(cwd)|\(tool)|\(scope)" }

    static func loadRules() -> Set<String> {
        guard let list: [String] = read(from: rulesURL) else { return [] }
        return Set(list)
    }

    static func saveRules(_ rules: Set<String>) { write(rules.sorted(), to: rulesURL) }

    static func loadPanes() -> [String: String] { read(from: panesURL) ?? [:] }

    static func savePanes(_ map: [String: String]) { write(map, to: panesURL) }

    // MARK: - Plumbing

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var rulesURL: URL { directory.appendingPathComponent("always-allow.json") }
    private static var panesURL: URL { directory.appendingPathComponent("panes.json") }

    private static func read<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
