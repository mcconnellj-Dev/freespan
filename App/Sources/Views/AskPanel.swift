import FreespanKit
import SwiftUI

/// The "Ask Freespan" inspector: questions and answers only. Identification happens quietly elsewhere
/// (toolbar status, labels in lists).
struct AskPanel: View {
    @Environment(AppModel.self) private var model
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.assistantKind == .off {
                assistantOff
            } else if model.assistantReady {
                conversation
                Divider()
                composer
            } else if let reason = model.assistantUnavailableReason {
                unavailable(reason)
            } else {
                checking
            }
        }
        .background(.background.secondary)
    }

    private var header: some View {
        HStack {
            Text("Ask Freespan")
                .font(.headline)
            Spacer()
            if !model.chat.isEmpty, !model.isAnswering {
                Button("Clear") { model.clearChat() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.chat.isEmpty {
                        intro
                    }
                    ForEach(model.chat) { message in
                        ChatBubble(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: model.chat.last?.text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: model.chat.count) {
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.mode == .easy ? "Ask anything about your Mac's storage." : "Ask anything about this disk.")
                .font(.callout.weight(.medium))
            Text(model.assistantKind == .onDevice
                 ? "\(model.assistantName) reads a summary of your scan on this Mac. Nothing leaves your Mac."
                 : "\(model.assistantName) reads a summary of your scan: names, sizes and dates. Never file contents.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
    }

    private var composer: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(model.suggestedQuestions, id: \.self) { question in
                    Button(question) { model.ask(question) }
                        .buttonStyle(ChipButtonStyle())
                        .disabled(model.isAnswering || model.scan == nil)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your disk…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .focused($composerFocused)
                    .onSubmit { model.ask(model.draft) }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                if model.isAnswering {
                    Button { model.stopAnswering() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")
                } else {
                    Button { model.ask(model.draft) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Ask \(model.assistantName)")
                }
            }
        }
        .padding(14)
    }

    private var assistantOff: some View {
        placeholder(systemImage: "sparkles", title: "The assistant is off") {
            Text("Freespan still sorts, sizes and names everything with its built-in rules. Turn on an assistant to ask questions about your disk.")
            SettingsLink { Text("Choose an Assistant…") }
        }
    }

    private func unavailable(_ reason: String) -> some View {
        placeholder(systemImage: "exclamationmark.circle", title: "\(model.assistantKind.shortName) isn't available") {
            Text(reason)
            SettingsLink { Text("Open Settings…") }
            Text("Freespan works fully without an assistant.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var checking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Starting \(model.assistantKind.shortName)…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder<Content: View>(systemImage: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
            content()
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// User questions sit on the right in a tinted bubble; answers sit on the left as plain text with a small caption.
struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if message.text.isEmpty && message.isStreaming {
                    TypingDots()
                } else {
                    MarkdownText(message.text)
                        .font(.callout)
                        .foregroundStyle(message.isError ? Theme.warning : .primary)
                        .textSelection(.enabled)
                }
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
        }
    }

    private var caption: String {
        guard case .assistant(let kind, _) = message.author else { return "" }
        return kind == .onDevice ? "On-device" : "Claude"
    }
}

/// Renders a model answer: paragraphs, bulleted/numbered lists and headings line by line, with inline
/// Markdown (bold, italics, code, links) inside each line. Falls back to plain text if parsing fails.
struct MarkdownText: View {
    let source: String
    init(_ source: String) { self.source = source }

    private enum Block: Hashable {
        case paragraph(String)
        case heading(String)
        case bullet(marker: String, text: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                case .heading(let text):
                    Text(Self.inline(text)).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                case .bullet(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let bullet = Self.bullet(line) {
                flush()
                result.append(bullet)
            } else if line.hasPrefix("#") {
                flush()
                result.append(.heading(String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    private static func bullet(_ line: String) -> Block? {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            return .bullet(marker: "•", text: String(line.dropFirst(prefix.count)))
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .bullet(marker: digits + ".", text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate * 3) % 3
            HStack(spacing: 4) {
                ForEach(0 ..< 3) { index in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                        .opacity(index == phase ? 1 : 0.35)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct ChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.accentSoft.opacity(configuration.isPressed ? 1 : 0.75), in: Capsule())
            .opacity(isEnabled ? 1 : 0.6)
    }
}

#Preview("Ask panel") {
    AskPanel()
        .environment(AppModel.preview())
        .frame(width: 320, height: 640)
}

#Preview("Ask panel · Easy, empty") {
    let model = AppModel.preview(mode: .easy)
    let _ = model.clearChat()
    AskPanel()
        .environment(model)
        .frame(width: 320, height: 640)
}

#Preview("Ask panel · dark") {
    AskPanel()
        .environment(AppModel.preview())
        .frame(width: 320, height: 640)
        .preferredColorScheme(.dark)
}

#Preview("Ask panel · off") {
    AskPanel()
        .environment(AppModel.preview(assistant: .off))
        .frame(width: 320, height: 640)
}

#Preview("Ask panel · Claude API, no key") {
    AskPanel()
        .environment(AppModel.preview(assistant: .claudeAPI, hasAPIKey: false))
        .frame(width: 320, height: 640)
}
