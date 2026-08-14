import AppKit

/// Brings the terminal tab running a given session to the front.
/// Claude Code's hooks carry no PID, so a session is matched by its pane id, or by cwd as a fallback.
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
            let focused: Bool
            switch resolve(pane: pane, cwd: cwd, client: client) {
            case .iTerm(let guid): focused = focusITerm(guid: guid)
            case .terminal(let tty): focused = focusTerminal(tty: tty)
            case nil: focused = false
            }
            if focused {
                Log.write("JUMP", "focused pane for \(cwd)")
                DispatchQueue.main.async { completion(true) }
                return
            }
            Log.write("JUMP", "no exact pane for \(cwd); activating the terminal only")
            DispatchQueue.main.async {
                activateAnyTerminal(client: client)
                completion(false)
            }
        }
    }

    /// How to address the pane: iTerm2 by session id, Apple Terminal by the tty its tabs expose.
    private enum Target {
        case iTerm(guid: String)
        case terminal(tty: String)
    }

    /// The pane id comes from the session's own hook, so it is exact. The cwd scan is only a fallback.
    private static func resolve(pane: String?, cwd: String, client: SessionClient) -> Target? {
        if let pane, !pane.isEmpty {
            // An iTerm id carries a wNtNpN prefix; Apple Terminal's TERM_SESSION_ID is a bare UUID.
            guard pane.contains(":") else {
                return terminalTTY(sessionId: pane).map { .terminal(tty: $0) }
            }
            return pane.split(separator: ":").last.map { .iTerm(guid: String($0)) }
        }
        // The cwd scan finds iTerm ids only, so for a session elsewhere it would name the wrong pane.
        guard client != .terminal, !cwd.isEmpty, let guid = sessionGUID(forCwd: cwd) else { return nil }
        return .iTerm(guid: guid)
    }

    private static let ttyLock = NSLock()
    private static var ttyCache: [String: String] = [:]

    /// Terminal tabs expose no session id, so the tty is the only shared handle. Cached because
    /// the menu is re-read every few seconds while a card is open.
    private static func terminalTTY(sessionId: String) -> String? {
        ttyLock.lock()
        let cached = ttyCache[sessionId]
        ttyLock.unlock()
        if let cached { return cached }

        // `ps -ax`, not pgrep: pgrep does not list the claude process that owns the calling shell.
        let script = """
        ps -ax -o pid=,comm= | awk '$2 ~ /(^|\\/)claude$/ { print $1 }' | while read -r p; do
          if ps eww -p "$p" 2>/dev/null | tr ' ' '\\n' | grep -qx "TERM_SESSION_ID=\(sessionId)"; then
            ps -o tty= -p "$p" | tr -d ' '
          fi
        done
        """
        guard let raw = shell("/bin/sh", ["-c", script]) else { return nil }
        let matches = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard let tty = matches.first, matches.count == 1 else {
            Log.write("PANE", matches.isEmpty ? "no tty for \(sessionId)" : "ambiguous: \(matches.count) ttys")
            return nil
        }
        let device = "/dev/\(tty)"
        ttyLock.lock()
        ttyCache[sessionId] = device
        ttyLock.unlock()
        return device
    }

    /// A closed tab's tty is handed out again, so a dead session's mapping must not outlive it.
    static func forget(pane: String) {
        ttyLock.lock()
        ttyCache.removeValue(forKey: pane)
        ttyLock.unlock()
    }

    /// Wraps a body so it runs against the Terminal tab on this tty, or yields the empty result.
    private static func tellTerminal(tty: String, body: String) -> String? {
        let script = """
        tell application "Terminal"
          repeat with wi from 1 to count of windows
            repeat with ti from 1 to count of tabs of window wi
              if tty of tab ti of window wi is "\(tty)" then
                \(body)
              end if
            end repeat
          end repeat
        end tell
        return "none"
        """
        return shell("/usr/bin/osascript", ["-e", script])
    }

    /// Types a key into the pane running this session. Used to pick a numbered option.
    /// Returns false when the pane can't be identified, so the caller never types blindly.
    static func send(key: TerminalKey, pane: String?, cwd: String, client: SessionClient, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok: Bool
            switch resolve(pane: pane, cwd: cwd, client: client) {
            case .iTerm(let guid): ok = sendITerm(key: key, guid: guid)
            case .terminal(let tty): ok = sendTerminal(key: key, tty: tty)
            case nil: ok = false
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// `do script` is Terminal's only way in, and it always appends a return. That is harmless after
    /// a digit, which the prompt acts on at once, but rules out sending a bare arrow key.
    private static func sendTerminal(key: TerminalKey, tty: String) -> Bool {
        let commands: String
        switch key {
        case .option(let number):
            commands = #"do script "\#(number)" in tab ti of window wi"#
        case .cancel:
            commands = "do script (character id 27) in tab ti of window wi"
        case .cancelThenSay(let text):
            commands = """
            do script (character id 27) in tab ti of window wi
            delay 0.4
            do script "\(escaped(text))" in tab ti of window wi
            """
        case .confirm, .reply:
            return false
        }
        return tellTerminal(tty: tty, body: "\(commands)\n            return \"ok\"") == "ok"
    }

    private static func sendITerm(key: TerminalKey, guid: String) -> Bool {
        let keystrokes: String
        switch key {
        case .option(let number):
            keystrokes = #"tell s to write text "\#(number)" newline NO"#
        case .cancel:
            keystrokes = "tell s to write text (character id 27) newline NO"
        case .confirm(let steps):
            // One arrow per write: the prompt reads a chunk as a single key, so two escape
            // sequences written together move the cursor one row, not two. Measured.
            let arrow = steps < 0 ? "[A" : "[B"
            let move = (0..<abs(steps)).map { _ in
                "tell s to write text ((character id 27) & \"\(arrow)\") newline NO\ndelay 0.08"
            }.joined(separator: "\n")
            // A carriage return, not iTerm's `newline YES`: that sends a line feed, which the
            // prompt ignores.
            keystrokes = move + "\ntell s to write text (character id 13) newline NO"
        case .reply:
            // Only meaningful for gated sessions, which never reach this path.
            return false
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
        return shell("/usr/bin/osascript", ["-e", script]) == "ok"
    }

    /// Reads the numbered menu Claude Code is actually showing, so the panel mirrors it
    /// instead of offering options that may not exist in that prompt.
    static func readMenu(pane: String?, cwd: String, client: SessionClient, completion: @escaping (TerminalMenu) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text: String
            switch resolve(pane: pane, cwd: cwd, client: client) {
            case .iTerm(let guid): text = readITerm(guid: guid)
            case .terminal(let tty): text = readTerminal(tty: tty)
            case nil:
                DispatchQueue.main.async { completion(TerminalMenu(options: [], rows: [], cursor: nil)) }
                return
            }
            let menu = parseMenu(text)
            Log.write("MENU", menu.options.isEmpty
                ? "no numbered menu on screen"
                : "read \(menu.options.count) cursor=\(menu.cursor.map(String.init) ?? "-"): "
                  + menu.options.map { option in
                      switch option.ticked {
                      case true: return "[✔] \(option.label)"
                      case false: return "[ ] \(option.label)"
                      case nil: return option.label
                      }
                  }.joined(separator: " | "))
            DispatchQueue.main.async { completion(menu) }
        }
    }

    private static func readITerm(guid: String) -> String {
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
        return shell("/usr/bin/osascript", ["-e", script]) ?? ""
    }

    /// Terminal needs indexed loops: `repeat with t in tabs of w` cannot coerce `contents` to text.
    private static func readTerminal(tty: String) -> String {
        let text = tellTerminal(tty: tty, body: "return (contents of tab ti of window wi) as text") ?? ""
        return text == "none" ? "" : text
    }

    static func parseMenu(_ text: String) -> TerminalMenu {
        var runs: [[Row]] = [[]]
        for line in text.components(separatedBy: .newlines) {
            let onCursor = line.contains("❯")
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t❯>›"))
            // The Submit row carries no number, so it is recognised by its own text.
            if trimmed == "Submit" {
                guard !runs[runs.count - 1].isEmpty else { continue }
                runs[runs.count - 1].append(Row(
                    number: nil, option: MenuOption(label: trimmed, ticked: nil),
                    onCursor: onCursor, labelColumn: 0
                ))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."),
               let number = Int(trimmed[trimmed.startIndex..<dot]), number > 0, number < 20 {
                let rest = trimmed[trimmed.index(after: dot)...].drop { $0 == " " }
                guard !rest.isEmpty else { continue }
                // A number we already have starts a fresh menu rather than extending this one.
                if runs[runs.count - 1].contains(where: { $0.number == number }) { runs.append([]) }
                let marker = line.prefix { " \t❯>›".contains($0) }.count
                let column = marker + (trimmed.count - rest.count)
                runs[runs.count - 1].append(Row(
                    number: number, option: box(String(rest)), onCursor: onCursor, labelColumn: column
                ))
                continue
            }
            // A wrapped label continues below its own start column, and takes the closing bracket of
            // a split tick box with it. A description sits further left, so it is left alone.
            guard var last = runs[runs.count - 1].last, last.number != nil else { continue }
            let indent = line.prefix { $0 == " " }.count
            let closing = trimmed.hasPrefix("]")
            guard !trimmed.isEmpty, closing || indent >= last.labelColumn else { continue }
            let carried = closing
                ? trimmed.dropFirst().drop { $0 == " " }
                : trimmed[trimmed.startIndex...]
            last.option.label += " " + carried
            if closing, last.option.ticked == nil { last.option.ticked = false }
            runs[runs.count - 1][runs[runs.count - 1].count - 1] = last
        }

        guard let menu = runs.last(where: { run in run.contains { $0.number == 1 } }) else {
            return TerminalMenu(options: [], rows: [], cursor: nil)
        }
        // Only a menu numbered straight through from 1 is trusted; a gap means we read something else.
        var rows: [Row] = []
        var expected = 1
        for row in menu {
            if let number = row.number {
                guard number == expected else { continue }
                expected += 1
            }
            rows.append(row)
        }
        return TerminalMenu(
            options: rows.compactMap { $0.number == nil ? nil : $0.option },
            rows: rows,
            cursor: rows.firstIndex { $0.onCursor }
        )
    }

    /// Splits a tick box off an option's text. A wrapped option splits the box itself: the bracket
    /// closes on the line below, and the mark, if any, stays next to the opening one.
    private static func box(_ text: String) -> MenuOption {
        guard text.hasPrefix("[") else { return MenuOption(label: text, ticked: nil) }
        let after = text.dropFirst()
        if let close = after.firstIndex(of: "]") {
            let mark = after[after.startIndex..<close].trimmingCharacters(in: .whitespaces)
            let label = after[after.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return MenuOption(label: String(label), ticked: !mark.isEmpty)
        }
        let mark = after.prefix { $0 != " " }
        return MenuOption(label: String(after.dropFirst(mark.count).drop { $0 == " " }), ticked: !mark.isEmpty)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
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

    @discardableResult
    private static func focusTerminal(tty: String) -> Bool {
        let body = """
        set selected tab of window wi to tab ti of window wi
                set index of window wi to 1
                activate
                return "ok"
        """
        return tellTerminal(tty: tty, body: body) == "ok"
    }

    /// The session's own app goes first, so a Terminal session never surfaces an iTerm window.
    private static func activateAnyTerminal(client: SessionClient) {
        let preferred: [String]
        switch client {
        case .iTerm: preferred = ["com.googlecode.iterm2"]
        case .terminal: preferred = ["com.apple.Terminal"]
        case .vscode: preferred = ["com.microsoft.VSCode"]
        case .other: preferred = []
        }
        for id in preferred + ["com.googlecode.iterm2", "com.apple.Terminal", "com.microsoft.VSCode"] {
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
