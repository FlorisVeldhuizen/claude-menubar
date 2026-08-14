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

        let script = """
        \(Shell.claudePIDs) | while read -r p; do
          if ps eww -p "$p" 2>/dev/null | tr ' ' '\\n' | grep -qx "TERM_SESSION_ID=\(sessionId)"; then
            ps -o tty= -p "$p" | tr -d ' '
          fi
        done
        """
        guard let raw = Shell.sh(script) else { return nil }
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
        return Shell.osascript(script)
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
        return Shell.osascript(script) == "ok"
    }

    /// Reads the numbered menu Claude Code is actually showing, so the panel mirrors it
    /// instead of offering options that may not exist in that prompt.
    static func readMenu(pane: String?, cwd: String, client: SessionClient, completion: @escaping (TerminalMenu) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let screen: Screen
            switch resolve(pane: pane, cwd: cwd, client: client) {
            case .iTerm(let guid): screen = readITerm(guid: guid)
            case .terminal(let tty): screen = readTerminal(tty: tty)
            case nil:
                DispatchQueue.main.async { completion(TerminalMenu(options: [], rows: [], cursor: nil)) }
                return
            }
            let menu = parseMenu(screen.visible)
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

    /// Both terminals hand over the whole scrollback, so the height comes with it and the read is
    /// cut down to the rows on screen. Menus Claude drew earlier sit in that history, and one of
    /// those must never be mirrored in place of the prompt that is actually waiting.
    private struct Screen {
        let text: String
        let rows: Int?

        /// A row count arrives on the first line, so anything before the first newline is that.
        init(payload: String) {
            guard let end = payload.firstIndex(of: "\n"),
                  let count = Int(payload[..<end].trimmingCharacters(in: .whitespaces))
            else {
                text = payload
                rows = nil
                return
            }
            text = String(payload[payload.index(after: end)...])
            rows = count > 0 ? count : nil
        }

        var visible: String {
            guard let rows else { return text }
            return text.components(separatedBy: .newlines).suffix(rows).joined(separator: "\n")
        }
    }

    private static func readITerm(guid: String) -> Screen {
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if id of s contains "\(guid)" then return ((rows of s) as text) & linefeed & (text of s)
              end repeat
            end repeat
          end repeat
        end tell
        return ""
        """
        return Screen(payload: Shell.osascript(script) ?? "")
    }

    /// Terminal needs indexed loops: `repeat with t in tabs of w` cannot coerce `contents` to text.
    private static func readTerminal(tty: String) -> Screen {
        let body = """
        set r to 0
                try
                  set r to (number of rows of tab ti of window wi)
                end try
                return (r as text) & linefeed & ((contents of tab ti of window wi) as text)
        """
        let text = tellTerminal(tty: tty, body: body) ?? ""
        return Screen(payload: text == "none" ? "" : text)
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
            let indent = line.prefix { $0 == " " }.count
            // A line that sits under an open label belongs to it, even where the wrap happens to
            // break onto a digit and a dot: "1.5s" is the rest of an option, not the next one.
            let carriesOn = runs[runs.count - 1].last.map { $0.number != nil && indent >= $0.labelColumn } ?? false
            if !carriesOn, let dot = trimmed.firstIndex(of: "."),
               let number = Int(trimmed[trimmed.startIndex..<dot]), number > 0, number < 20,
               number == 1 || number == next(in: runs[runs.count - 1]) {
                let rest = trimmed[trimmed.index(after: dot)...].drop { $0 == " " }
                guard !rest.isEmpty else { continue }
                // A menu is numbered straight through, so a 1 is always the start of a fresh one.
                if number == 1, !runs[runs.count - 1].isEmpty { runs.append([]) }
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
            let closing = trimmed.hasPrefix("]")
            guard !trimmed.isEmpty, closing || indent >= last.labelColumn else { continue }
            let carried = closing
                ? trimmed.dropFirst().drop { $0 == " " }
                : trimmed[trimmed.startIndex...]
            last.option.label += " " + carried
            if closing, last.option.ticked == nil { last.option.ticked = false }
            runs[runs.count - 1][runs[runs.count - 1].count - 1] = last
        }

        guard let rows = runs.last(where: { run in run.contains { $0.number != nil } }) else {
            return TerminalMenu(options: [], rows: [], cursor: nil)
        }
        return TerminalMenu(
            options: rows.compactMap { $0.number == nil ? nil : $0.option },
            rows: rows,
            cursor: rows.firstIndex { $0.onCursor }
        )
    }

    /// The number a menu row must carry to continue this one. Anything else is prose, or a wrapped
    /// label that happens to break onto a digit, and it leaves the menu it interrupts intact.
    private static func next(in run: [Row]) -> Int {
        (run.last { $0.number != nil }?.number ?? 0) + 1
    }

    // MARK: - Tab titles

    /// The title Claude Code keeps in the tab, which is its own summary of what it is doing. Keyed by
    /// the pane ids the hooks report, so the caller needs to know nothing about either terminal.
    /// nil means the read failed, which is not the same as a screen with no titles on it.
    static func readTitles(panes: [String: String], completion: @escaping ([String: String]?) -> Void) {
        // Running only. `tell application` launches what it addresses, and a poll must never open a
        // terminal that was closed. NSRunningApplication is read here, on the caller's thread.
        let wantITerm = panes.values.contains { $0.contains(":") } && isRunning("com.googlecode.iterm2")
        let wantTerminal = panes.values.contains { !$0.contains(":") } && isRunning("com.apple.Terminal")
        guard wantITerm || wantTerminal else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let iterm = wantITerm ? readITermTitles() : [:]
            let terminal = wantTerminal ? readTerminalTitles() : [:]
            // One terminal failing must not blank the titles of the other, so only a read where
            // everything we asked for failed counts as a failed read.
            guard iterm != nil || terminal != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var found: [String: String] = [:]
            for (sessionId, pane) in panes {
                switch resolve(pane: pane, cwd: "", client: .other) {
                case .iTerm(let guid): found[sessionId] = iterm?[guid]
                case .terminal(let tty): found[sessionId] = terminal?[tty]
                case nil: continue
                }
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// Both lists in one go, then flattened here. A property read per session is an Apple Event each,
    /// which is the difference between 0.2s and 0.7s for a couple of dozen tabs.
    private static func readITermTitles() -> [String: String]? {
        let script = """
        tell application "iTerm2"
          set idRows to id of every session of every tab of every window
          set nameRows to name of every session of every tab of every window
        end tell
        set out to ""
        repeat with wi from 1 to (count of idRows)
          set wIds to item wi of idRows
          set wNames to item wi of nameRows
          repeat with ti from 1 to (count of wIds)
            set tIds to item ti of wIds
            set tNames to item ti of wNames
            repeat with si from 1 to (count of tIds)
              set out to out & (item si of tIds) & tab & (item si of tNames) & linefeed
            end repeat
          end repeat
        end repeat
        return out
        """
        return titles(from: Shell.osascript(script), stripJob: true)
    }

    /// Terminal needs indexed loops here too, and its `name` will not coerce to text at all, so the
    /// title comes from `custom title` — which is the one the escape sequence writes.
    /// The delimiter is bound outside the tell block: inside it, `tab` is Terminal's own tab class.
    private static func readTerminalTitles() -> [String: String]? {
        let script = """
        set delim to character id 9
        tell application "Terminal"
          set out to ""
          repeat with wi from 1 to (count of windows)
            repeat with ti from 1 to (count of tabs of window wi)
              set out to out & (tty of tab ti of window wi) & delim & ¬
                (custom title of tab ti of window wi) & linefeed
            end repeat
          end repeat
          return out
        end tell
        """
        return titles(from: Shell.osascript(script), stripJob: false)
    }

    private static func titles(from output: String?, stripJob: Bool) -> [String: String]? {
        guard let output else { return nil }
        var found: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2, !parts[0].isEmpty,
                  let title = claudeTitle(parts[1], stripJob: stripJob)
            else { continue }
            found[parts[0]] = title
        }
        return found
    }

    /// Claude Code opens its title with a spinner glyph, and a shell opens with a path or a command
    /// name. So the glyph is how a title worth showing is told from the terminal's own default.
    private static func claudeTitle(_ raw: String, stripJob: Bool) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let marker = text.first, !marker.isLetter, !marker.isNumber, !"~/.".contains(marker)
        else { return nil }

        var body = text.dropFirst().trimmingCharacters(in: .whitespaces)
        // iTerm appends the running job in brackets. One bracketed word is that; a bracketed phrase
        // is more likely part of what Claude called the task.
        if stripJob, body.hasSuffix(")"), let open = body.lastIndex(of: "(") {
            let job = body[body.index(after: open)..<body.index(before: body.endIndex)]
            if !job.isEmpty, !job.contains(" ") {
                body = String(body[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return body.isEmpty ? nil : body
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
        \(Shell.claudePIDs) | while read -r p; do
          c=$(lsof -a -d cwd -p "$p" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
          if [ "$c" = "\(cwd)" ]; then
            ps eww -p "$p" 2>/dev/null | tr ' ' '\\n' | sed -n 's/^ITERM_SESSION_ID=//p' | head -1
          fi
        done
        """
        guard let raw = Shell.sh(script) else { return nil }
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
        return Shell.osascript(script) == "ok"
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
}
