import AppKit

/// Brings the terminal tab running a given session to the front.
/// Claude Code's hooks carry no PID, so the session is matched by working directory.
enum TerminalFocus {
    static func reveal(
        pane: String?,
        cwd: String,
        client: SessionClient = .other,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        // VS Code has no addressable pane, but its URL handler focuses the window for a folder.
        if client == .vscode, !cwd.isEmpty {
            let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd
            if let url = URL(string: "vscode://file\(encoded)") {
                NSWorkspace.shared.open(url)
                Log.write("JUMP", "opened VS Code at \(cwd)")
                completion(true)
                return
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if let guid = resolve(pane: pane, cwd: cwd), focusITerm(guid: guid) {
                Log.write("JUMP", "focused pane for \(cwd)")
                DispatchQueue.main.async { completion(true) }
                return
            }
            Log.write("JUMP", "no exact pane for \(cwd); activating iTerm2 only")
            DispatchQueue.main.async {
                activateAnyTerminal()
                completion(false)
            }
        }
    }

    /// The pane id comes from the session's own hook, so it is exact. The cwd scan is only a fallback.
    private static func resolve(pane: String?, cwd: String) -> String? {
        if let pane, !pane.isEmpty {
            return pane.split(separator: ":").last.map(String.init)
        }
        return cwd.isEmpty ? nil : sessionGUID(forCwd: cwd)
    }

    /// Types a key into the pane running this session. Used to pick a numbered option.
    /// Returns false when the pane can't be identified, so the caller never types blindly.
    static func send(key: TerminalKey, pane: String?, cwd: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let guid = resolve(pane: pane, cwd: cwd) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let keystrokes: String
            switch key {
            case .option(let number):
                keystrokes = #"tell s to write text "\#(number)" newline NO"#
            case .cancel:
                keystrokes = "tell s to write text (character id 27) newline NO"
            case .reply:
                // Only meaningful for gated sessions, which never reach this path.
                DispatchQueue.main.async { completion(false) }
                return
            case .cancelThenSay(let text):
                // Escape returns focus to the composer, then the note goes in as an ordinary message.
                keystrokes = """
                tell s to write text (character id 27) newline NO
                delay 0.4
                tell s to write text "\(escaped(text))"
                """
            }

            // Deliberately no select or activate: answering must not pull that session to the front.
            let script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if id of s contains "\(guid)" then
                      \(keystrokes)
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "none"
            """
            let ok = shell("/usr/bin/osascript", ["-e", script]) == "ok"
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Reads the numbered menu Claude Code is actually showing, so the panel mirrors it
    /// instead of offering options that may not exist in that prompt.
    static func readOptions(pane: String?, cwd: String, completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let guid = resolve(pane: pane, cwd: cwd) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if id of s contains "\(guid)" then return (text of s)
                  end repeat
                end repeat
              end repeat
            end tell
            return ""
            """
            let text = shell("/usr/bin/osascript", ["-e", script]) ?? ""
            let options = parseOptions(text)
            Log.write("MENU", options.isEmpty ? "no numbered menu on screen" : "read \(options.count): \(options.joined(separator: " | "))")
            DispatchQueue.main.async { completion(options) }
        }
    }

    static func parseOptions(_ text: String) -> [String] {
        var runs: [[Int: String]] = [[:]]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t❯>›"))
            guard let dot = trimmed.firstIndex(of: "."),
                  let number = Int(trimmed[trimmed.startIndex..<dot]), number > 0, number < 20
            else { continue }
            let label = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            // A number we already have starts a fresh menu rather than extending this one.
            if runs[runs.count - 1][number] != nil { runs.append([:]) }
            runs[runs.count - 1][number] = label
        }
        guard let last = runs.last(where: { $0[1] != nil }) else { return [] }
        var options: [String] = []
        var index = 1
        while let label = last[index] {
            options.append(label)
            index += 1
        }
        return options
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func canReach(pane: String?, cwd: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = resolve(pane: pane, cwd: cwd) != nil
            DispatchQueue.main.async { completion(found) }
        }
    }

    private static func sessionGUID(forCwd cwd: String) -> String? {
        // Every match is listed, not just the first: two sessions in one directory are ambiguous,
        // and typing into the wrong one is worse than not typing at all.
        let script = """
        for p in $(pgrep -x claude); do
          c=$(lsof -a -d cwd -p "$p" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
          if [ "$c" = "\(cwd)" ]; then
            ps eww -p "$p" 2>/dev/null | tr ' ' '\\n' | sed -n 's/^ITERM_SESSION_ID=//p' | head -1
          fi
        done
        """
        guard let raw = shell("/bin/sh", ["-c", script]) else { return nil }
        let matches = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard matches.count == 1 else {
            Log.write("PANE", matches.isEmpty ? "no pane for \(cwd)" : "ambiguous: \(matches.count) sessions in \(cwd)")
            return nil
        }
        return matches[0].split(separator: ":").last.map(String.init)
    }

    @discardableResult
    private static func focusITerm(guid: String) -> Bool {
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if id of s contains "\(guid)" then
                  select w
                  select t
                  select s
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "none"
        """
        return shell("/usr/bin/osascript", ["-e", script]) == "ok"
    }

    private static func activateAnyTerminal() {
        for id in ["com.googlecode.iterm2", "com.apple.Terminal", "com.microsoft.VSCode"] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }

    private static func shell(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
