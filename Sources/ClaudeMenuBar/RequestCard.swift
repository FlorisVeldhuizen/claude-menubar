import SwiftUI

/// The one decision on screen: what is being asked, and the ways to answer it.
struct RequestCard: View {
    let store: Store
    let request: PendingRequest
    let now: Date
    @Binding var noteTarget: String?
    @Binding var noteText: String

    private enum Layout {
        static let detailBox: CGFloat = 150
        static let answerRow: CGFloat = 26
        static let noteRow: CGFloat = 54
        static let smallestDetail: CGFloat = 60
        /// Claude's own menu is usually three lines. Holding that much room from the start means the
        /// card doesn't reshuffle when the real options arrive a few seconds later.
        static let expectedOptions = 3
        /// Past this the menu is not coming, so the card offers the plain guess instead of waiting.
        static let menuGiveUp: TimeInterval = 9
    }

    private struct Answer: Identifiable {
        let id: Int
        let label: String
        let key: TerminalKey
        /// Set only on a multiple-choice question, where the digit ticks a box instead of answering.
        var ticked: Bool?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            detailBox
            answerRows
            actionRow
            if noteTarget == request.id { noteRow }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35)))
        .padding(.horizontal, 12)
        .background { shortcuts }
    }

    // MARK: - Answers

    /// The options this card can answer with, in the order they are numbered on screen.
    private var answers: [Answer] {
        if request.gated, let question = choices {
            return question.options.enumerated().map { index, option in
                Answer(id: index, label: option.label, key: .reply(
                    "The user answered \"\(question.text)\" with: \(option.label). "
                    + "Continue with that choice and do not ask again."
                ))
            }
        }
        if !request.gated {
            return request.menu.enumerated().map { index, option in
                Answer(id: index, label: option.label, key: .option(index + 1), ticked: option.ticked)
            }
        }
        return []
    }

    /// A single question with options is answerable here; anything else takes the plain allow/deny row.
    private var choices: AskQuestion? {
        guard request.questions.count == 1, let question = request.questions.first,
              !question.options.isEmpty
        else { return nil }
        return question
    }

    /// Command digits rather than plain ones, so typing into the note field still works.
    private var shortcuts: some View {
        ForEach(answers.prefix(9)) { answer in
            Button("") { pick(answer) }
                .keyboardShortcut(KeyEquivalent(Character("\(answer.id + 1)")), modifiers: .command)
                .hidden()
        }
    }

    private func pick(_ answer: Answer) {
        if answer.ticked == nil {
            store.answer(request, key: answer.key)
        } else {
            store.tick(request, option: answer.id + 1)
        }
    }

    // MARK: - Parts

    private var titleRow: some View {
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
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.up.forward.app")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .clickable()
        .onTapGesture { store.jump(toSessionOf: request) }
        .help("Jump to this session")
    }

    private var detailBox: some View {
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
        .frame(height: detailHeight)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var answerRows: some View {
        Group {
            if !answers.isEmpty {
                optionButtons
            } else if request.gated {
                pairRow(allow: "Allow", deny: "Deny", note: "answered here · no terminal to reach")
            } else if now.timeIntervalSince(request.receivedAt) > Layout.menuGiveUp {
                pairRow(allow: "Yes", deny: "No", note: "no menu on screen — this answers 1 or Esc")
            } else {
                waitingRows
            }
        }
        .frame(minHeight: CGFloat(reservedRows) * Layout.answerRow, alignment: .top)
        .animation(.easeInOut(duration: 0.15), value: request.terminalOptions)
    }

    private var optionButtons: some View {
        VStack(spacing: 4) {
            ForEach(answers) { answer in
                Button {
                    pick(answer)
                } label: {
                    HStack(spacing: 5) {
                        if let ticked = answer.ticked {
                            Image(systemName: ticked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(ticked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        }
                        Text("\(answer.id + 1). \(answer.label)")
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
                .help(answer.id < 9 ? "⌘\(answer.id + 1)" : answer.label)
            }
            // A tick list stays on screen until Return, so the card has to offer that key too.
            if request.isTickList {
                Button("Submit") { store.submit(request) }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .help("⌘↩ · send the ticked options")
            }
            // Claude Code appends this to its own menu; a gated card only sees the declared options.
            if request.gated {
                Button(action: toggleNote) {
                    Text("Chat about this…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
                .keyboardShortcut("k", modifiers: .command)
                .help("⌘K")
            }
        }
    }

    /// Claude draws its menu about six seconds after the hook, and the buttons must mirror it exactly.
    /// So the card holds the space and says so, rather than showing a guess it has to replace.
    private var waitingRows: some View {
        VStack(spacing: 4) {
            ForEach(0..<Layout.expectedOptions, id: \.self) { row in
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: Layout.answerRow - 4)
                    .overlay(alignment: .leading) {
                        if row == 0 {
                            Text("Waiting for Claude's menu…")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 7)
                        }
                    }
            }
        }
    }

    private func pairRow(allow: String, deny: String, note: String) -> some View {
        HStack(spacing: 6) {
            Button(allow) { store.answer(request, key: .option(1)) }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .help("⌘↩")
            Button(deny) { store.answer(request, key: .cancel) }
                .controlSize(.small)
                .keyboardShortcut("d", modifiers: .command)
                .help("⌘D")
            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            // Only where Claude offers nothing better. Its own "don't ask again" is scoped to the
            // command; ours covers every call of that tool in the project, so it must not compete.
            if request.gated, choices == nil {
                Button("Always allow \(request.toolName)") {
                    store.answer(request, key: .option(1), remember: true)
                }
                .controlSize(.small)
                .help("Allow every \(request.toolName) call in \(request.folder) from here on, without asking")
            }
            if choices == nil {
                Button("Say why…", action: toggleNote)
                    .controlSize(.small)
                    .keyboardShortcut("k", modifiers: .command)
                    .help("⌘K · cancel the prompt and send Claude a message instead")
            }
            Spacer()
            if !request.gated {
                Button("Terminal") { store.jump(toSessionOf: request) }
                    .controlSize(.small)
                    .help("Jump to that pane; the card stays until the prompt is settled")
            }
        }
    }

    private var noteRow: some View {
        HStack(spacing: 6) {
            TextField(request.gated ? "Say what you want instead…" : "Tell Claude what to do instead…", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit(sendNote)
            Button("Send", action: sendNote)
                .controlSize(.small)
        }
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

    // MARK: - Sizing and actions

    /// A gated card never changes shape, so it only reserves what it shows. A terminal one holds room
    /// for the menu it is about to mirror, so nothing moves when that menu arrives.
    private var reservedRows: Int {
        guard request.gated else {
            return max(answers.count + (request.isTickList ? 1 : 0), Layout.expectedOptions)
        }
        return max(answers.count, 1) + (choices == nil ? 0 : 1)
    }

    /// The card sits in a fixed slot, so the detail box gives up whatever the answer rows need.
    private var detailHeight: CGFloat {
        var height = Layout.detailBox - CGFloat(reservedRows) * Layout.answerRow
        if noteTarget == request.id { height -= Layout.noteRow }
        return max(height, Layout.smallestDetail)
    }

    private func toggleNote() {
        noteText = ""
        noteTarget = noteTarget == request.id ? nil : request.id
    }

    private func sendNote() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.answer(request, key: text.isEmpty ? .cancel : .cancelThenSay(text))
        noteTarget = nil
        noteText = ""
    }
}
