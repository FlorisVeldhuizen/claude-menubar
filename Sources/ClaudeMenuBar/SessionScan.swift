import Foundation

/// Finds running `claude` processes so the list shows every live session, not only the ones
/// that have fired a hook since this app started.
enum SessionScan {
    struct Found {
        let pid: Int
        let cwd: String
        let pane: String?
    }

    static func run(completion: @escaping ([Found]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let script = """
            for p in $(pgrep -x claude); do
              c=$(lsof -a -d cwd -p "$p" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
              i=$(ps eww -p "$p" 2>/dev/null | tr ' ' '\\n' | sed -n 's/^ITERM_SESSION_ID=//p' | head -1)
              echo "$p|$c|$i"
            done
            """
            let output = shell(script) ?? ""
            let found: [Found] = output.split(separator: "\n").compactMap { line in
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 3, let pid = Int(parts[0]), !parts[1].isEmpty else { return nil }
                return Found(pid: pid, cwd: parts[1], pane: parts[2].isEmpty ? nil : parts[2])
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
