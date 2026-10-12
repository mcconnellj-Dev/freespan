import Foundation

/// Prompt building and response post-processing shared by the two Claude transports
/// (`AnthropicClient` over HTTPS and `ClaudeCLIAssistant` over the `claude` command-line tool).
enum ClaudeTasks {

    // MARK: - label

    /// Items deduplicated by redacted path, remembering the caller's spelling so returned labels match input paths.
    struct LabelInput {
        /// Redacted path → the caller's path.
        var originals: [String: String] = [:]
        var unique: [ItemMetadata] = []

        init(_ items: [ItemMetadata], home: String) {
            for item in items {
                let redacted = Redactor.redact(item.path, home: home)
                if originals[redacted] == nil {
                    originals[redacted] = item.path
                    unique.append(item)
                }
            }
        }

        func chunks(of size: Int) -> [[ItemMetadata]] {
            stride(from: 0, to: unique.count, by: size).map { Array(unique[$0 ..< min($0 + size, unique.count)]) }
        }

        /// Drops labels for paths that weren't asked about and duplicates, maps paths back, caps safety labels.
        func finalize<S: Sequence>(_ labels: S) -> [AILabel] where S.Element == AILabel {
            var seen = Set<String>()
            var result: [AILabel] = []
            for label in labels {
                guard let original = originals[label.path], seen.insert(label.path).inserted else { continue }
                result.append(AssistantSafety.capped(label, path: original))
            }
            return result
        }
    }

    static func labelPrompt(_ chunk: [ItemMetadata], home: String) throws -> String {
        let items = try compactJSON(chunk.map { WireItem($0, home: home) })
        return """
        <items>
        \(items)
        </items>
        Label each of these \(chunk.count) items. Return exactly one label per item, with its path copied exactly.
        """
    }

    struct LabelsEnvelope: Decodable { let labels: [AILabel] }

    // MARK: - second opinion

    static func secondOpinionPrompt(_ item: ItemMetadata, home: String) throws -> String {
        """
        <item>
        \(try compactJSON(WireItem(item, home: home)))
        </item>
        I'm about to remove this. What is it, and is it safe to remove?
        """
    }

    /// The path always comes from the input; the label is capped.
    static func finalizeSecondOpinion(_ label: AILabel, item: ItemMetadata) -> AILabel {
        AssistantSafety.capped(label, path: item.path)
    }

    // MARK: - deep clean plan

    static func planPrompt(_ wire: WireSummary) throws -> String {
        """
        <disk_summary>
        \(try compactJSON(wire))
        </disk_summary>
        Write my Deep Clean Plan.
        """
    }

    /// Keeps only paths that are in the summary and removable (never a "keep"/protected item), clamps byte
    /// estimates to what the listed items hold, and orders steps safe-before-review, larger first.
    static func validatePlan(_ plan: CleanupPlan, wire: WireSummary) -> CleanupPlan {
        var known: [String: (bytes: Int64, removable: Bool)] = [:]
        for f in wire.topFindings { known[f.path] = (f.bytes, f.label == "safe" || f.label == "review") }
        for u in wire.unknownLarge { known[u.path] = (u.bytes, true) }
        let steps = plan.steps.compactMap { step -> CleanupPlan.Step? in
            var seen = Set<String>()
            let paths = step.paths.filter { known[$0]?.removable == true && seen.insert($0).inserted }
            guard !paths.isEmpty else { return nil }
            let ceiling = paths.reduce(Int64(0)) { $0 + (known[$1]?.bytes ?? 0) }
            let risk: SafetyLabel = step.risk == .safe ? .safe : .review
            return CleanupPlan.Step(title: step.title, reasoning: step.reasoning, paths: paths,
                                    estimatedBytes: min(max(0, step.estimatedBytes), ceiling), risk: risk)
        }
        let ordered = steps.enumerated().sorted { a, b in
            if a.element.risk != b.element.risk { return a.element.risk < b.element.risk }
            if a.element.estimatedBytes != b.element.estimatedBytes { return a.element.estimatedBytes > b.element.estimatedBytes }
            return a.offset < b.offset
        }.map(\.element)
        return CleanupPlan(headline: plan.headline, steps: ordered)
    }

    // MARK: - ask (single-prompt transcript, for transports without a messages array)

    /// The disk summary, recent conversation and the new question as one user prompt.
    static func askTranscript(_ question: String, summary: DiskSummary, history: [ChatTurn], maxTurns: Int,
                              home: String) throws -> String {
        var text = "<disk_summary>\n\(try compactJSON(WireSummary(summary, home: home)))\n</disk_summary>\n"
        let recent = history.suffix(maxTurns).compactMap { turn -> String? in
            let t = Redactor.redactText(turn.text.trimmingCharacters(in: .whitespacesAndNewlines), home: home)
            guard !t.isEmpty else { return nil }
            return (turn.role == .user ? "User: " : "Assistant: ") + t
        }
        if !recent.isEmpty {
            text += "<conversation_so_far>\n\(recent.joined(separator: "\n\n"))\n</conversation_so_far>\n"
        }
        let q = Redactor.redactText(question.trimmingCharacters(in: .whitespacesAndNewlines), home: home)
        return text + "\n" + q
    }
}
