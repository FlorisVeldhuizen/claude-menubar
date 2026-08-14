import Foundation

/// Finds running `claude` processes so the list shows every live session, not only the ones
/// that have fired a hook since this app started.
enum SessionScan {
    struct Found {
        let pid: Int
        let cwd: String
        let pane: String?
        let client: SessionClient
    }

    static func run(completion: @escaping ([Found]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            // `ps -ax`, not pgrep: pgrep does not list the claude process that owns the calling shell.
            let script = """
            ps -ax -o pid=,comm= | awk '$2 ~ /(^|\\/)claude$/ { print $1 }' | while read -r p; do
              c=$(lsof -a -d cwd -p "$p" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
              e=$(ps eww -p "$p" 2>/dev/null | tr ' ' '\\n')
              i=$(printf '%s' "$e" | sed -n 's/^ITERM_SESSION_ID=//p' | head -1)
              t=$(printf '%s' "$e" | sed -n 's/^TERM_SESSION_ID=//p' | head -1)
              echo "$p|$c|$i|$t"
            done
            """
            let output = shell(script) ?? ""
            let found: [Found] = output.split(separator: "\n").compactMap { line in
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 4, let pid = Int(parts[0]), !parts[1].isEmpty else { return nil }
                // iTerm's id wins: a session there carries both, and only its pane can be addressed by id.
                if !parts[2].isEmpty {
                    return Found(pid: pid, cwd: parts[1], pane: parts[2], client: .iTerm)
                }
                guard !parts[3].isEmpty else { return Found(pid: pid, cwd: parts[1], pane: nil, client: .other) }
                return Found(pid: pid, cwd: parts[1], pane: parts[3], client: .terminal)
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    private static func shell(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
