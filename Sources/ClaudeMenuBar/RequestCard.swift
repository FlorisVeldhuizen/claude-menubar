import SwiftUI

/// The one decision on screen: what is being asked, and the ways to answer it.
struct RequestCard: View {
    let store: Store
    let request: PendingRequest
    @Binding var noteTarget: String?
    @Binding var noteText: String

    var body: some View {
        card
    }

private var card: some View {
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
            // Only where Claude offers nothing better. Its own "don't ask again" is scoped to the
            // command; ours covers every call of that tool in the project, so it must not compete.
            if request.gated, choices(in: request) == nil {
                Button("Always allow \(request.toolName)") {
                    store.answer(request, key: .option(1), remember: true)
                }
                .controlSize(.small)
                .help("Allow every \(request.toolName) call in \(request.folder) from here on, without asking")
            }
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
}
