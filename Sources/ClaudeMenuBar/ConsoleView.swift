import SwiftUI

struct ConsoleView: View {
    let store: Store
    let port: UInt16
    var onInstallHooks: () -> Void
    var onAbout: () -> Void
    var onQuit: () -> Void

    @State private var noteTarget: String?
    @State private var noteText = ""
    @State private var hoveredSession: String?
    @Namespace private var chipSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            requestSlot
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !store.hooksInstalled {
                        installBanner
                            .transition(.stackRow)
                    }

                    if store.allSessions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            section("Sessions")
                            Text("No sessions yet. Start Claude Code in any project.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 6)
                        }
                        .transition(.stackRow)
                    } else {
                        // One list rather than a list per group: a session that changes group is then
                        // the same row moving, not one row leaving and another appearing elsewhere.
                        ForEach(listRows) { row in
                            switch row {
                            case .heading(let title): section(title)
                            case .session(let session): sessionRow(session)
                            }
                        }
                        .transition(.stackRow)
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Motion.list, value: listShape)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(-1)

            Divider()
            footer
        }
        .frame(width: ConsoleView.size.width, height: ConsoleView.size.height)
        .background {
            Button("") { store.step(1) }.keyboardShortcut("]", modifiers: .command).hidden()
            Button("") { store.step(-1) }.keyboardShortcut("[", modifiers: .command).hidden()
        }
    }

    static let size = CGSize(width: 420, height: 580)

    private enum Layout {
        static let slot: CGFloat = 286
        static let strip: CGFloat = 18
    }

    /// What the list looks like right now. Rows animate when this changes, and not when a clock ticks.
    private var listShape: String {
        store.hooksInstalled.description + listRows.map(\.id).joined(separator: ",")
    }

    private enum ListRow: Identifiable {
        case heading(String)
        case session(SessionInfo)

        var id: String {
            switch self {
            case .heading(let title): return "heading:\(title)"
            case .session(let session): return "session:\(session.id)"
            }
        }
    }

    private var listRows: [ListRow] {
        store.sessionGroups.flatMap { group in
            [ListRow.heading(group.title)] + group.sessions.map(ListRow.session)
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: CrabIcon.mark())
                .renderingMode(.template)
                .foregroundStyle(store.pending.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.orange))
            Text("Claude sessions")
                .font(.headline)
            Spacer()
            if !store.pending.isEmpty {
                Text("\(store.pending.count)")
                    .font(.caption.bold())
                    .contentTransition(.numericText())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.black)
                    .help("\(store.pending.count) waiting on you")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .animation(Motion.badge, value: store.pending.count)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(store.hooksInstalled ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .animation(Motion.card, value: store.hooksInstalled)
            Text(store.hooksInstalled ? "Hooks active · :\(String(port))" : "Hooks not installed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(Motion.card, value: store.hooksInstalled)

            Spacer()

            PanelMenu(store: store, onInstallHooks: onInstallHooks, onAbout: onAbout, onQuit: onQuit)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    /// Exactly one request at a time in a fixed-size slot, so nothing below it ever moves.
    private var requestSlot: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = store.notice {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(notice).lineLimit(1)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .help(notice)
                .padding(.horizontal, 12)
                .frame(height: Layout.strip)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if store.pending.count > 1 {
                queueChips
                    .transition(.opacity)
            } else {
                HStack { section("Waiting on you"); Spacer() }
                    .frame(height: Layout.strip)
                    .transition(.opacity)
            }

            if let request = store.activeRequest {
                RequestCard(store: store, request: request, noteTarget: $noteTarget, noteText: $noteText)
                    .id(request.id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.99, anchor: .top))
                    ))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                    Text("Nothing needs a decision.")
                        .font(.callout)
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: Layout.slot, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .animation(Motion.card, value: store.activeRequest?.id)
        .animation(Motion.card, value: store.notice)
        .animation(Motion.card, value: store.pending.count > 1)
    }

    /// One chip per pending decision, so switching is a single click rather than hunting the list.
    private var queueChips: some View {
        ScrollViewReader { strip in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.pending) { request in
                        chip(request)
                    }
                }
                .padding(.horizontal, 12)
                .animation(Motion.chip, value: store.activeRequest?.id)
            }
            .onChange(of: store.activeRequest?.id) { _, id in
                guard let id else { return }
                withAnimation(Motion.chip) { strip.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: Layout.strip)
        .help("Click a project, or press ⌘[ and ⌘] to switch")
    }

    private func chip(_ request: PendingRequest) -> some View {
        let active = store.activeRequest?.id == request.id
        return Button { store.focus(requestId: request.id) } label: {
            Text(request.folder)
                .font(.caption2.weight(active ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background { chipBackground(active: active) }
        }
        .buttonStyle(.plain)
        .clickable()
        .id(request.id)
        .help("\(request.toolName) in \(request.folder)")
    }

    @ViewBuilder private func chipBackground(active: Bool) -> some View {
        ZStack {
            Capsule().fill(Color.primary.opacity(0.07))
            if active {
                Capsule()
                    .fill(Color.orange.opacity(0.30))
                    .overlay(Capsule().strokeBorder(Color.orange.opacity(0.55)))
                    .matchedGeometryEffect(id: "activeChip", in: chipSpace)
            }
        }
    }

    private var installBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hooks are not installed yet")
                .font(.subheadline.weight(.semibold))
            Text("Adds HTTP hooks to ~/.claude/settings.json pointing at 127.0.0.1:\(String(port)). Your existing hooks stay, and a backup is written first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Install hooks", action: onInstallHooks)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
    }

    // MARK: - Session row

    private func sessionRow(_ session: SessionInfo) -> some View {
        let waiting = store.pendingCount(for: session.id)
        let isActive = store.activeRequest?.sessionId == session.id
        let hovered = hoveredSession == session.id
        let fill: Color = isActive
            ? Color.orange.opacity(0.12)
            : (hovered ? Color.primary.opacity(0.05) : .clear)

        return HStack(spacing: 8) {
            StateDot(
                color: color(for: session.state),
                alive: session.state == .working || session.state == .waiting,
                urgent: session.state == .waiting
            )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.folder)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    // What Claude is calling this piece of work. It gives up its width first, since
                    // the folder is what you look for.
                    if let title = store.title(for: session.id) {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .contentTransition(.opacity)
                            .animation(Motion.card, value: title)
                            .help(title)
                    }
                }
                Text(session.agentType.map { "\(session.state.label) · \($0)" } ?? session.state.label)
                    .font(.caption)
                    .foregroundStyle(stateStyle(for: session.state))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(Motion.card, value: session.state)
            }

            // The animation sits outside the branch, so the badge pops on the same curve as the
            // header's rather than on whatever curve the list happens to be moving on.
            Group {
                if waiting > 1 {
                    Text("\(waiting)")
                        .font(.caption2.bold())
                        .contentTransition(.numericText())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.3), in: Capsule())
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(Motion.badge, value: waiting)

            Spacer()

            ZStack(alignment: .trailing) {
                ElapsedLabel(since: session.lastActivity)
                    .opacity(hovered ? 0 : 1)

                Button {
                    store.dismiss(session.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .clickable()
                .help("Remove from the list")
                .opacity(hovered ? 1 : 0)
                .scaleEffect(hovered ? 1 : 0.7)
                .allowsHitTesting(hovered)
            }
            .frame(width: 34, alignment: .trailing)
            .animation(Motion.hover, value: hovered)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(fill, in: RoundedRectangle(cornerRadius: 6))
        .animation(Motion.hover, value: fill)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .clickable()
        .onHover { hoveredSession = $0 ? session.id : nil }
        .onTapGesture {
            if waiting > 0 {
                store.focus(sessionId: session.id)
            } else {
                store.jump(to: session)
            }
        }
        .help("\(session.state.meaning)\n\n\(clickHint(waiting: waiting, session: session))")
    }

    private func clickHint(waiting: Int, session: SessionInfo) -> String {
        if waiting > 0 { return "Click to bring its request up here." }
        return "Click to jump to \(session.cwd.isEmpty ? "its terminal" : session.cwd)."
    }

    private func color(for state: SessionState) -> Color {
        switch state {
        case .working: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .idle: return Color.secondary.opacity(0.45)
        case .running: return Color.secondary.opacity(0.25)
        }
    }

    /// The live states carry their own colour, so a row that needs you reads differently from a quiet one.
    private func stateStyle(for state: SessionState) -> AnyShapeStyle {
        switch state {
        case .waiting, .working, .done: return AnyShapeStyle(color(for: state))
        case .idle, .running: return AnyShapeStyle(.secondary)
        }
    }

}

/// Keeps its own clock. A tick that redrew the whole panel also rebuilt the footer menu, which
/// closed any submenu you had open.
private struct ElapsedLabel: View {
    let since: Date

    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .onReceive(tick) { now = $0 }
    }

    private var text: String {
        let seconds = Int(now.timeIntervalSince(since))
        if seconds < 60 { return "\(max(seconds, 0))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

/// Its own view, so a change anywhere else in the panel cannot rebuild an open menu under the pointer.
private struct PanelMenu: View {
    let store: Store
    var onInstallHooks: () -> Void
    var onAbout: () -> Void
    var onQuit: () -> Void

    var body: some View {
        Menu {
            Button("Clear idle sessions") { store.clearIdle() }
                .disabled(store.idleCount == 0)
            Button("Reset always-allow (\(store.autoAllow.count))") { store.clearAutoAllow() }
                .disabled(store.autoAllow.isEmpty)
            Divider()
            Toggle("Mute alerts", isOn: Binding(get: { store.muted }, set: { _ in store.toggleMute() }))
            Picker("Alert sound", selection: Binding(get: { store.alertSound }, set: { store.pickSound($0) })) {
                ForEach(Sound.names, id: \.self) { name in
                    Text(name == Sound.silent ? "None — silent" : name).tag(name)
                }
            }
            Divider()
            Button(store.hooksInstalled ? "Remove hooks" : "Install hooks", action: onInstallHooks)
            Toggle("Open at login", isOn: Binding(get: { store.opensAtLogin }, set: { _ in store.toggleLoginItem() }))
            Divider()
            Button("About Permission Relay", action: onAbout)
            Button("Quit", action: onQuit)
        } label: {
            Image(systemName: store.muted ? "speaker.slash.circle" : "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }
}
