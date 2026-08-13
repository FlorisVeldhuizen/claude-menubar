import Foundation

/// Writes (and removes) the Claude Code hook entries that feed this app.
/// Our entries are identified by their loopback URL, so nothing foreign is touched.
enum HookInstaller {
    static let permissionEvent = "PermissionRequest"
    /// Run as a child of `claude`, so these inherit ITERM_SESSION_ID and pin the session to one pane.
    static let paneEvents = ["SessionStart", "UserPromptSubmit"]

    static let sessionEvents = [
        "SessionEnd", "Stop", "Notification",
        // These tell us a request was settled in the terminal instead of here.
        "PostToolUse", "PermissionDenied",
    ]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static var backupURL: URL {
        settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.claude-menubar-backup")
    }

    static func isInstalled(port: UInt16) -> Bool {
        guard let hooks = load()?["hooks"] as? [String: Any] else { return false }
        guard json(hooks[permissionEvent] ?? [:]).contains(paneMarker) else { return false }
        guard sessionEvents.allSatisfy({ json(hooks[$0] ?? [:]).contains(eventURL(port: port)) }) else { return false }
        // A pane event only counts once it is the command hook that reports ITERM_SESSION_ID.
        return paneEvents.allSatisfy { json(hooks[$0] ?? [:]).contains(paneMarker) }
    }

    static func install(port: UInt16, permissionTimeout: Int) throws {
        var settings = load() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // A command hook so every permission request carries its own ITERM_SESSION_ID.
        hooks[permissionEvent] = merge(
            into: hooks[permissionEvent],
            entry: paneEntry(port: port, url: permissionURL(port: port), relayResponse: true, matcher: "*"),
            port: port
        )
        for event in sessionEvents {
            hooks[event] = merge(
                into: hooks[event],
                entry: entry(url: eventURL(port: port), timeout: 5, matcher: nil),
                port: port
            )
        }
        for event in paneEvents {
            hooks[event] = merge(
                into: hooks[event],
                entry: paneEntry(port: port),
                port: port
            )
        }

        settings["hooks"] = hooks
        try backup()
        try write(settings)
    }

    static func uninstall(port: UInt16) throws {
        guard var settings = load(), var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned = strip(groups, port: port)
            hooks[event] = cleaned.isEmpty ? nil : cleaned
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try backup()
        try write(settings)
    }

    // MARK: - Plumbing

    static func permissionURL(port: UInt16) -> String { "http://127.0.0.1:\(port)/permission" }
    static func eventURL(port: UInt16) -> String { "http://127.0.0.1:\(port)/event" }

    private static func entry(url: String, timeout: Int, matcher: String?) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [[
                "type": "http",
                "url": url,
                "timeout": timeout,
            ] as [String: Any]],
        ]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    private static func paneEntry(
        port: UInt16,
        url: String? = nil,
        relayResponse: Bool = false,
        matcher: String? = nil
    ) -> [String: Any] {
        let target = url ?? eventURL(port: port)
        let relay = relayResponse ? "    sys.stdout.write(r.read().decode())\n" : ""
        let python = """
        import sys,json,os,urllib.request as u
        try:
            d=json.load(sys.stdin)
            d["term_session"]=os.environ.get("ITERM_SESSION_ID","")
            r=u.urlopen(u.Request("\(target)", json.dumps(d).encode(), {"Content-Type":"application/json"}), timeout=5)
        \(relay)except Exception:
            pass
        """
        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": "/usr/bin/python3 -c '\(python)'",
                "timeout": 10,
            ] as [String: Any]],
        ]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    static let paneMarker = "term_session"

    private static func isOurs(_ handler: [String: Any], port: UInt16) -> Bool {
        if let url = handler["url"] as? String {
            return url == permissionURL(port: port) || url == eventURL(port: port)
        }
        if let command = handler["command"] as? String {
            return command.contains(eventURL(port: port)) || command.contains(permissionURL(port: port))
        }
        return false
    }

    private static func strip(_ groups: [[String: Any]], port: UInt16) -> [[String: Any]] {
        var groups = groups
        for index in groups.indices {
            guard var handlers = groups[index]["hooks"] as? [[String: Any]] else { continue }
            handlers.removeAll { isOurs($0, port: port) }
            groups[index]["hooks"] = handlers
        }
        groups.removeAll { (($0["hooks"] as? [[String: Any]]) ?? []).isEmpty }
        return groups
    }

    private static func merge(into existing: Any?, entry: [String: Any], port: UInt16) -> [[String: Any]] {
        var groups = strip(existing as? [[String: Any]] ?? [], port: port)
        groups.append(entry)
        return groups
    }

    private static func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func write(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func backup() throws {
        guard let data = try? Data(contentsOf: settingsURL) else { return }
        try data.write(to: backupURL, options: .atomic)
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
