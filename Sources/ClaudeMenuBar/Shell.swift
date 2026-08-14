import Foundation

/// Running a short script and reading what it printed.
enum Shell {
    /// `ps -ax`, not pgrep: pgrep does not list the claude process that owns the calling shell.
    static let claudePIDs = #"ps -ax -o pid=,comm= | awk '$2 ~ /(^|\/)claude$/ { print $1 }'"#

    static func sh(_ script: String) -> String? { run("/bin/sh", ["-c", script]) }

    static func osascript(_ script: String) -> String? { run("/usr/bin/osascript", ["-e", script]) }

    private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
