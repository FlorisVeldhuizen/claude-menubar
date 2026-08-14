import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSPopoverDelegate {
    static let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["CLAUDE_MENUBAR_PORT"] ?? "") ?? 7788
    static let staleAfter = TimeInterval(Int(ProcessInfo.processInfo.environment["CLAUDE_MENUBAR_STALE_MINUTES"] ?? "") ?? 30) * 60

    private let store = Store()
    private var server: HookServer?
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var notificationsReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        setUpNotifications()

        store.onChange = { [weak self] in self?.refreshStatusItem() }
        store.onNewRequest = { [weak self] request in self?.announce(request) }

        HookInstaller.refreshIfInstalled(port: Self.port)
        startServer()
        refreshStatusItem()

        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in self.store.sweep(staleAfter: Self.staleAfter) }
        }

        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.store.pollPending() }
        }

        SessionScan.run { [weak self] in self?.store.merge(scan: $0) }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            SessionScan.run { [weak self] found in
                Task { @MainActor in
                    self?.store.merge(scan: found)
                    self?.store.refreshTitles()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.releaseAll()
        server?.stop()
    }

    // MARK: - Server

    private func startServer() {
        let store = self.store
        let server = HookServer(port: Self.port) { path, body in
            guard let event = try? HookEvent.decode(body) else {
                Log.write("BAD", String(decoding: body, as: UTF8.self))
                return Data("{}".utf8)
            }
            if path.hasPrefix("/pretool") {
                let result = await store.gate(event)
                return result.preToolUseJSON
            }
            if path.hasPrefix("/permission") {
                Log.write("ASK", String(decoding: body, as: UTF8.self))
                let reply = await store.capture(event).json
                Log.write("REPLY", String(decoding: reply, as: UTF8.self))
                return reply
            }
            Log.write("EVENT", "\(event.hookEventName ?? "?") session=\(event.sessionId ?? "?") pane=\(event.termSession ?? "-")")
            await store.record(event)
            return Data("{}".utf8)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            let alert = NSAlert()
            alert.messageText = "Port \(Self.port) is busy"
            alert.informativeText = "Another copy may be running. Set CLAUDE_MENUBAR_PORT to use a different port."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        // Fixed width: a variable-width item moves the popover's anchor when the badge appears or clears.
        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setUpPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let controller = NSHostingController(
            rootView: ConsoleView(
                store: store,
                port: Self.port,
                onInstallHooks: { [weak self] in self?.toggleHooks() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        // Without this the controller re-measures the SwiftUI content and the popover drifts off the status item.
        controller.sizingOptions = []
        controller.preferredContentSize = ConsoleView.size
        popover.contentSize = ConsoleView.size
        popover.contentViewController = controller
    }

    private func refreshStatusItem() {
        store.hooksInstalled = HookInstaller.isInstalled(port: Self.port)
        let count = store.pending.count
        drawStatusIcon(count: count)
        statusItem.button?.toolTip = count > 0 ? "\(count) waiting on you" : "Claude sessions"
        if count == 0, popover.isShown, store.sessions.isEmpty { popover.performClose(nil) }
    }

    private func drawStatusIcon(count: Int) {
        statusItem.button?.image = Self.statusImage(count: count, badge: badgeScale)
    }

    private var badgeScale: CGFloat = 1
    private var badgePop: Timer?
    private var badgeFrame = 0

    /// Frames rather than a curve: an NSImage cannot tween, so the pop is drawn one step at a time.
    private static let badgeFrames: [CGFloat] = [0.2, 0.7, 1.08, 1.22, 1.14, 1.05, 1.0]

    /// A new request has to catch your eye up in the menu bar, so the dot lands with one pop.
    private func popBadge() {
        badgePop?.invalidate()
        guard !Motion.reduced else { return }
        badgeFrame = 0
        badgePop = Timer.scheduledTimer(withTimeInterval: 1.0 / 40.0, repeats: true) { timer in
            Task { @MainActor in
                guard self.badgeFrame < Self.badgeFrames.count else {
                    timer.invalidate()
                    self.badgeScale = 1
                    self.drawStatusIcon(count: self.store.pending.count)
                    return
                }
                self.badgeScale = Self.badgeFrames[self.badgeFrame]
                self.badgeFrame += 1
                self.drawStatusIcon(count: self.store.pending.count)
            }
        }
    }

    /// The count is punched out of the icon so the item stays one snug fixed width.
    private static func statusImage(count: Int, badge: CGFloat = 1) -> NSImage {
        let size = NSSize(width: 24, height: 18)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude sessions")?
            .withSymbolConfiguration(config)
        else { return NSImage() }

        let image = NSImage(size: size, flipped: false) { _ in
            // Centred in the image, which is centred in the item, so the popover arrow lands on the glyph.
            symbol.draw(in: NSRect(x: (size.width - 16) / 2, y: 1, width: 16, height: 16))
            guard count > 0 else { return true }

            // A digit this small is unreadable over the glyph, so the badge is just a dot.
            // The count itself lives in the tooltip and the panel.
            let centre = NSPoint(x: 18.5, y: 13.5)
            let radius = 3.5 * max(badge, 0.01)
            let dot = NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            let gap = dot.insetBy(dx: -radius / 2, dy: -radius / 2)

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: gap).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A transient popover also closes on its own, so the flag can't be left set by the toggle alone.
    func popoverDidClose(_ notification: Notification) {
        store.panelOpen = false
        statusItem.button?.highlight(false)
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            store.panelOpen = false
            button.highlight(false)
        } else {
            // The item reads as pressed for as long as its panel is up, the way every other one does.
            button.highlight(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            store.panelOpen = true
            store.verifyPending()
            store.refreshTitles()
        }
    }

    /// Which build this is. The app never updates itself, so this is the only way to tell.
    private static var buildLine: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "Claude MenuBar" }
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let commit = info?["GitCommit"] as? String ?? "?"
        return "Claude MenuBar \(version) · build \(build) · \(commit)"
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: Self.buildLine, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let installed = HookInstaller.isInstalled(port: Self.port)
        menu.addItem(withTitle: installed ? "Hooks installed" : "Hooks not installed", action: nil, keyEquivalent: "")
            .isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: installed ? "Remove hooks from settings.json" : "Install hooks into settings.json",
                     action: #selector(toggleHooks), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reveal settings.json", action: #selector(revealSettings), keyEquivalent: "").target = self

        let mute = menu.addItem(withTitle: "Mute alerts", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        mute.state = store.muted ? .on : .off

        let soundItem = menu.addItem(withTitle: "Alert sound", action: nil, keyEquivalent: "")
        let sounds = NSMenu()
        for name in Sound.names {
            let title = name == Sound.silent ? "None — silent" : name
            let item = sounds.addItem(withTitle: title, action: #selector(pickSound(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == store.alertSound ? .on : .off
        }
        soundItem.submenu = sounds
        let login = menu.addItem(withTitle: "Open at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change the login item"
            alert.informativeText = "This usually works only once the app is in /Applications."
            alert.runModal()
        }
    }

    @objc private func pickSound(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        store.pickSound(name)
    }

    @objc private func toggleMute() {
        store.toggleMute()
    }

    @objc private func revealSettings() {
        NSWorkspace.shared.activateFileViewerSelecting([HookInstaller.settingsURL])
    }

    @objc private func toggleHooks() {
        do {
            if HookInstaller.isInstalled(port: Self.port) {
                try HookInstaller.uninstall(port: Self.port)
            } else {
                try HookInstaller.install(port: Self.port)
            }
            refreshStatusItem()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not update settings.json"
            alert.runModal()
        }
    }

    // MARK: - Notifications

    private func setUpNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "permission",
                actions: [
                    UNNotificationAction(identifier: "allow", title: "Allow", options: []),
                    UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
                    UNNotificationAction(identifier: "options", title: "More options…", options: [.foreground]),
                ],
                intentIdentifiers: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationsReady = granted }
        }
    }

    private func announce(_ request: PendingRequest) {
        Sound.play()
        popBadge()

        guard notificationsReady, !popover.isShown else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(request.toolName) · \(request.folder)"
        content.body = request.detail.isEmpty ? "Waiting for your decision" : String(request.detail.prefix(180))
        content.categoryIdentifier = "permission"
        content.userInfo = ["requestId": request.id]

        let notification = UNNotificationRequest(identifier: request.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(notification)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            self.handle(action: action, requestId: id)
            completionHandler()
        }
    }

    private func handle(action: String, requestId: String) {
        guard let request = store.pending.first(where: { $0.id == requestId }) else { return }
        switch action {
        case "allow":
            store.answer(request, key: .option(1))
        case "deny":
            store.answer(request, key: .cancel)
        default:
            NSApp.activate(ignoringOtherApps: true)
            if !popover.isShown { togglePopover() }
        }
    }
}
