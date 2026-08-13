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

                    section("Sessions")
                    if store.allSessions.isEmpty {
                        Text("No sessions yet. Start Claude Code in any project.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    } else {
                        ForEach(store.allSessions) { session in
                            sessionRow(session)
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

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(.tint)
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
                Text(notice)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .frame(height: 18)
            } else if store.pending.count > 1 {
                queueChips
            } else {
                HStack { section("Waiting on you"); Spacer() }.frame(height: 18)
            }

            if let request = store.activeRequest {
                requestCard(request)
                    .id(request.id)
                    .transition(.opacity)
            } else {
                Text("Nothing needs a decision.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 286, alignment: .top)
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
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 18)
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

    // MARK: - Request card

    private func requestCard(_ request: PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(request.toolName)
                    .font(.subheadline.weight(.semibold))
                if let level = request.permissionLevel, level != "safe" {
                    Text(level)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(level == "dangerous" ? Color.red.opacity(0.25) : Color.yellow.opacity(0.25),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                Text(request.folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { store.jump(toSessionOf: request) }
            .help("Jump to this session")

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !request.context.isEmpty {
                        Text(request.context)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if request.questions.isEmpty {
                        if !request.detail.isEmpty {
                            Text(request.detail)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ForEach(request.questions) { question in
                            questionBlock(question)
                        }
                    }
                }
                .padding(7)
            }
            .frame(height: detailHeight(for: request))
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            if request.gated, let question = choices(in: request) {
                VStack(spacing: 4) {
                    ForEach(question.options) { option in
                        Button {
                            store.answer(request, key: .reply(
                                "The user answered \"\(question.text)\" with: \(option.label). "
                                + "Continue with that choice and do not ask again."
                            ))
                        } label: {
                            Text(option.label).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .controlSize(.small)
                    }
                    // Claude Code appends this to its own menu; a gated card only sees the declared options.
                    Button {
                        noteText = ""
                        noteTarget = noteTarget == request.id ? nil : request.id
                    } label: {
                        Text("Chat about this…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .controlSize(.small)
                }
            } else if request.gated {
                HStack(spacing: 6) {
                    Button("Allow") { store.answer(request, key: .option(1)) }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                    Button("Deny") { store.answer(request, key: .cancel) }
                        .controlSize(.small)
                    Text("answered here · no terminal to reach")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if !request.terminalOptions.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(request.terminalOptions.enumerated()), id: \.offset) { index, label in
                        Button {
                            store.answer(request, key: .option(index + 1))
                        } label: {
                            Text("\(index + 1). \(label)")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Button("Yes") { store.answer(request, key: .option(1)) }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                    Button("No") { store.answer(request, key: .cancel) }
                        .controlSize(.small)
                    Text("waiting for the prompt")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 6) {
                Button("Always allow") { store.answer(request, key: .option(1), remember: true) }
                    .controlSize(.small)
                    .help("Answer yes now, and auto-allow \(request.toolName) in \(request.folder) from here on")
                if choices(in: request) == nil {
                    Button("Say why…") {
                        noteText = ""
                        noteTarget = noteTarget == request.id ? nil : request.id
                    }
                    .controlSize(.small)
                    .help("Cancel the prompt and send Claude a message instead")
                }
                Spacer()
                if !request.gated {
                    Button("Terminal") { store.jump(toSessionOf: request) }
                        .controlSize(.small)
                        .help("Jump to that pane; the card stays until the prompt is settled")
                }
            }

            if noteTarget == request.id {
                HStack(spacing: 6) {
                    TextField(request.gated ? "Say what you want instead…" : "Tell Claude what to do instead…", text: $noteText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { sendNote(request) }
                    Button("Send") { sendNote(request) }
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35)))
        .padding(.horizontal, 12)
    }

    /// A single question with options is answerable here; anything else takes the plain allow/deny row.
    private func choices(in request: PendingRequest) -> AskQuestion? {
        guard request.questions.count == 1, let question = request.questions.first,
              !question.options.isEmpty
        else { return nil }
        return question
    }

    private func detailHeight(for request: PendingRequest) -> CGFloat {
        var height: CGFloat = 150
        if noteTarget == request.id { height -= 54 }
        height -= CGFloat(max(request.terminalOptions.count, 1)) * 26
        return max(height, 60)
    }

    private func questionBlock(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(question.text)
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options) { option in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").font(.caption).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(.caption.weight(.medium))
                        if !option.detail.isEmpty {
                            Text(option.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sendNote(_ request: PendingRequest) {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.answer(request, key: text.isEmpty ? .cancel : .cancelThenSay(text))
        noteTarget = nil
        noteText = ""
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
                Text(session.agentType.map { "\(session.state.label) · \($0)" } ?? session.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .onHover { hoveredSession = $0 ? session.id : nil }
        .onTapGesture {
            if waiting > 0 {
                store.focus(sessionId: session.id)
            } else {
                store.jump(to: session)
            }
        }
        .help(waiting > 0 ? "Click to answer this session's request" : "Click to jump to \(session.cwd)")
    }

    private func color(for state: SessionState) -> Color {
        switch state {
        case .working: return .blue
        case .waiting: return .orange
        case .idle: return Color.secondary.opacity(0.45)
        case .running: return Color.secondary.opacity(0.25)
        }
    }

    private func elapsed(since date: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "\(max(seconds, 0))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
