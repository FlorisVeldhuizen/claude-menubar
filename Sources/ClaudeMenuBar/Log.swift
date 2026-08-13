import Foundation

/// Append-only trace of what arrives and what we send back, for diagnosing the decision path.
enum Log {
    static var url: URL { Persistence.directory.appendingPathComponent("trace.log") }

    private static let queue = DispatchQueue(label: "claude-menubar.log")

    private static let maxBytes = 2 * 1024 * 1024
    private static var writesSinceCheck = 0

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ tag: String, _ message: String) {
        let line = "\(stamp()) \(tag) \(message)\n"
        queue.async {
            writesSinceCheck += 1
            if writesSinceCheck >= 200 {
                writesSinceCheck = 0
                rotateIfLarge()
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Keep the newest half rather than growing without bound.
    private static func rotateIfLarge() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func stamp() -> String { formatter.string(from: Date()) }
}
