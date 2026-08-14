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
            let script = """
            \(Shell.claudePIDs) | while read -r p; do
              c=$(lsof -a -d cwd -p "$p" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
              e=$(ps eww -p "$p" 2>/dev/null | tr ' ' '\\n')
              i=$(printf '%s' "$e" | sed -n 's/^ITERM_SESSION_ID=//p' | head -1)
              t=$(printf '%s' "$e" | sed -n 's/^TERM_SESSION_ID=//p' | head -1)
              echo "$p|$c|$i|$t"
            done
            """
            let output = Shell.sh(script) ?? ""
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
}
