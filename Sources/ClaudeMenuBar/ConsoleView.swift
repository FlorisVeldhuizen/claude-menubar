import SwiftUI

struct ConsoleView: View {
    let store: Store
    let port: UInt16
    var onInstallHooks: () -> Void
    var onQuit: () -> Void

    @State private var noteTarget: String?
    @State private var noteText = ""
    @State private var hoveredSession: String?
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                    }

                    if store.allSessions.isEmpty {
                        section("Sessions")
                        Text("No sessions yet. Start Claude Code in any project.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    } else {
                        ForEach(store.sessionGroups) { group in
                            section(group.title)
                            ForEach(group.sessions) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(-1)

            Divider()
            footer
        }
        .frame(width: ConsoleView.size.width, height: ConsoleView.size.height)
        .onReceive(tick) { now = $0 }
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

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(store.pending.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.orange))
            Text("Claude sessions")
                .font(.headline)
            Spacer()
            if !store.pending.isEmpty {
                Text("\(store.pending.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.black)
                    .help("\(store.pending.count) waiting on you")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(store.hooksInstalled ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(store.hooksInstalled ? "Hooks active · :\(String(port))" : "Hooks not installed")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Button("Clear idle sessions") { store.clearIdle() }
                    .disabled(store.idleCount == 0)
                Button("Reset always-allow (\(store.autoAllow.count))") { store.clearAutoAllow() }
                    .disabled(store.autoAllow.isEmpty)
                Divider()
                Button(store.hooksInstalled ? "Remove hooks" : "Install hooks", action: onInstallHooks)
                Divider()
                Button("Quit", action: onQuit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
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
            } else if store.pending.count > 1 {
                queueChips
            } else {
                HStack { section("Waiting on you"); Spacer() }.frame(height: Layout.strip)
            }

            if let request = store.activeRequest {
                RequestCard(store: store, request: request, now: now, noteTarget: $noteTarget, noteText: $noteText)
                    .id(request.id)
                    .transition(.opacity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                    Text("Nothing needs a decision.")
                        .font(.callout)
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: Layout.slot, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.18), value: store.activeRequest?.id)
    }

    /// One chip per pending decision, so switching is a single click rather than hunting the list.
    private var queueChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.pending) { request in
                    let active = store.activeRequest?.id == request.id
                    Button { store.focus(requestId: request.id) } label: {
                        Text(request.folder)
                            .font(.caption2.weight(active ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                active ? Color.orange.opacity(0.30) : Color.primary.opacity(0.07),
                                in: Capsule()
                            )
                            .overlay(Capsule().stroke(Color.orange.opacity(active ? 0.55 : 0)))
                    }
                    .buttonStyle(.plain)
                    .clickable()
                    .help("\(request.toolName) in \(request.folder)")
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: Layout.strip)
        .help("Click a project, or press ⌘[ and ⌘] to switch")
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

        return HStack(spacing: 8) {
            Circle()
                .fill(color(for: session.state))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.folder)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.agentType.map { "\(session.state.label) · \($0)" } ?? session.state.label)
                    .font(.caption)
                    .foregroundStyle(stateStyle(for: session.state))
                    .lineLimit(1)
            }

            if waiting > 1 {
                Text("\(waiting)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.3), in: Capsule())
            }

            Spacer()

            ZStack(alignment: .trailing) {
                Text(elapsed(since: session.lastActivity))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .opacity(hoveredSession == session.id ? 0 : 1)

                if hoveredSession == session.id {
                    Button {
                        store.dismiss(session.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .clickable()
                    .help("Remove from the list")
                }
            }
            .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            isActive ? Color.orange.opacity(0.12) : (hoveredSession == session.id ? Color.primary.opacity(0.05) : .clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
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

    private func elapsed(since date: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "\(max(seconds, 0))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
