import Foundation

/// Pulls the last thing Claude said before it asked, so a request has some context.
enum Transcript {
    private static let tailBytes = 512 * 1024

    static func lastAssistantText(path: String?) -> String {
        guard let path, let text = tail(of: path) else { return "" }
        for line in text.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }

            let blocks = content.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            if let found = blocks.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return condense(found)
            }
        }
        return ""
    }

    /// The project a session belongs to, from its transcript path. Claude Code names that folder by
    /// replacing both "/" and "." with "-", so it is decoded against real directory entries —
    /// A name like "claude-menubar" is otherwise indistinguishable from a separator.
    /// Unlike `cwd`, this never follows the shell into a scratchpad.
    static func projectPath(from transcriptPath: String?) -> String? {
        guard let transcriptPath else { return nil }
        let folder = ((transcriptPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard folder.hasPrefix("-") else { return nil }

        let tokens = folder.dropFirst().components(separatedBy: "-")
        var path = ""
        var index = 0
        while index < tokens.count {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path.isEmpty ? "/" : path)
            else { return nil }

            var best: (name: String, parts: Int)?
            for entry in entries {
                let parts = entry.replacingOccurrences(of: ".", with: "-").components(separatedBy: "-")
                guard index + parts.count <= tokens.count,
                      Array(tokens[index..<(index + parts.count)]) == parts,
                      best == nil || parts.count > best!.parts
                else { continue }
                best = (entry, parts.count)
            }
            guard let best else { return nil }
            path += "/" + best.name
            index += best.parts
        }
        return path.isEmpty ? nil : path
    }

    private static func tail(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func condense(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 500 ? String(flat.prefix(500)) + "…" : flat
    }
}
