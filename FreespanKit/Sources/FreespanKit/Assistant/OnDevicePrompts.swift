import Foundation

/// Prompts and token budgeting for Apple's on-device model. Its context window is 4096 tokens shared by
/// instructions, the generation schema, the prompt and the answer, so everything here is compact and every
/// prompt is checked against a budget. Tokens are estimated at 3 characters each: paths tokenize densely,
/// and measuring with `SystemLanguageModel.tokenCount` showed ~3.3 characters per token for these prompts.
enum OnDevicePrompts {

    // MARK: - Budget

    static let contextSize = 4096
    /// Most input (instructions + schema + prompt) we send. The rest of the window is for the answer.
    static let inputBudget = 2800
    /// Most items per labelling batch.
    static let maxItemsPerBatch = 8
    /// Answer tokens reserved per labelled item (title, owner, 1–2 sentences, enum fields, JSON overhead).
    static let responseTokensPerItem = 110
    /// Generous allowance for the label-batch generation schema the framework adds to the prompt.
    /// `OnDeviceAssistantTests` measures the real schema against this.
    static let labelSchemaTokens = 500
    /// Allowance for the single-label (second opinion) schema.
    static let singleLabelSchemaTokens = 400
    /// Answer tokens for chat.
    static let askResponseTokens = 700

    static func estimatedTokens(_ text: String) -> Int { (text.utf8.count + 2) / 3 }

    static func labelResponseTokens(items: Int) -> Int { responseTokensPerItem * items + 60 }

    /// Estimated input tokens for one labelling request.
    static func labelInputTokens(_ prompt: String) -> Int {
        estimatedTokens(labelInstructions) + labelSchemaTokens + estimatedTokens(prompt)
    }

    // MARK: - Labelling

    static let labelInstructions = """
    You label folders and files on a Mac for Freespan, a disk-space app. You see only metadata \
    (path, size, dates, largest children), never contents. "~" is the user's home folder.

    For each numbered item give: its number, a title of at most six words, the owning app (empty if \
    unsure), a one- or two-sentence plain-English explanation of what it is and what happens if it is \
    removed, whether it regenerates on its own, a category and a label.

    label "keep": removing it loses something that can't simply be rebuilt or downloaded again: \
    documents, photos, music, projects, source code, data exports (.csv, .gz, .parquet), mail, \
    messages, browser profiles, app databases, settings, and anything in the user's own folders \
    (Documents, Desktop, work, Projects). label "review": it comes back or can be downloaded again: \
    caches, logs, build output, installers (.dmg .pkg .xip), simulators, downloaded AI models, old \
    backups. If unsure, keep.

    category: developer (Xcode, simulators, SDKs, package caches, build output, node_modules, Docker, \
    AI models), downloads (Downloads folder, installers), caches (app caches, logs, temporary files), \
    backups (iPhone and iPad backups), media (photos, video, music, podcasts), applications (apps and \
    their support data), largeOld (big files unopened for a long time), duplicates, system (macOS \
    data), other (documents, projects, data files, anything else).

    Mac facts: Library/Caches and folders named Cache, Code Cache, GPUCache or PersistentCache are \
    caches that regenerate. Library/Application Support holds app data: keep unless it is clearly a \
    cache. Google/Chrome with Default or Profile folders is the user's Chrome profiles (history, \
    passwords, bookmarks): keep. Library/Developer/CoreSimulator/Devices holds Xcode's iOS simulators: \
    review. Xcode DerivedData and DeviceSupport rebuild themselves. ~/.ollama/models holds AI models \
    downloaded by Ollama. Containers and Group Containers hold sandboxed app data. Mobile Documents is \
    iCloud Drive: keep.
    """

    static let maxPathCharacters = 140
    static let maxChildCharacters = 32
    static let maxChildren = 5

    /// One numbered line describing an item. Paths and child names are shortened to bound the size.
    static func itemLine(_ number: Int, _ item: ItemMetadata, home: String) -> String {
        let path = middleTruncated(Redactor.redact(item.path, home: home), to: maxPathCharacters)
        var parts = ["\(number). \(path)", item.isDirectory ? "folder" : "file", humanSize(item.sizeBytes)]
        if item.isDirectory { parts.append("\(item.itemCount) files") }
        if let m = item.modified { parts.append("modified \(monthString(m))") }
        if let a = item.accessed { parts.append("opened \(monthString(a))") }
        var line = parts.joined(separator: ", ")
        let children = item.topChildren.prefix(maxChildren).map {
            middleTruncated(Redactor.redactText($0, home: home), to: maxChildCharacters)
        }
        if !children.isEmpty { line += "; largest inside: " + children.joined(separator: ", ") }
        return line
    }

    static func labelPrompt(_ items: [ItemMetadata], home: String) -> String {
        let lines = items.enumerated().map { itemLine($0.offset + 1, $0.element, home: home) }
        return "Items:\n" + lines.joined(separator: "\n") + "\n\nLabel all \(items.count) items, one entry per number."
    }

    /// Splits items into batches of at most `maxItemsPerBatch` whose prompt fits the input budget and whose
    /// input plus reserved answer fits the context window.
    static func batches(_ items: [ItemMetadata], home: String) -> [[ItemMetadata]] {
        var result: [[ItemMetadata]] = []
        var current: [ItemMetadata] = []
        for item in items {
            let candidate = current + [item]
            if !current.isEmpty, current.count >= maxItemsPerBatch || !fits(candidate, home: home) {
                result.append(current)
                current = [item]
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func fits(_ batch: [ItemMetadata], home: String) -> Bool {
        let input = labelInputTokens(labelPrompt(batch, home: home))
        return input <= inputBudget && input + labelResponseTokens(items: batch.count) <= contextSize
    }

    // MARK: - Second opinion

    static let secondOpinionInstructions = """
    You give a careful second opinion on one item a Mac user is about to remove with Freespan, a \
    disk-space app. You see only metadata, never contents. "~" is the home folder. Give a title of at \
    most six words, the owning app (or an empty string), one or two plain sentences on what it is and \
    what the user loses if it is removed, whether it regenerates, a category (developer, downloads, \
    caches, backups, media, applications, largeOld, duplicates, system, other) and a label: "review" if \
    it is probably removable but worth a look, "keep" if it is the user's own data or something an app \
    needs. When in doubt, keep.
    """

    static func secondOpinionPrompt(_ item: ItemMetadata, home: String) -> String {
        "Item:\n" + itemLine(1, item, home: home) + "\n\nWhat is it, and should I remove it?"
    }

    // MARK: - Ask

    static let askInstructions = """
    You are the assistant inside Freespan, a Mac disk-space app. Answer the user's question about their \
    disk using only the scan summary in the prompt. Be brief and plain: a few short sentences or a short \
    list. Use the sizes given. Mention only items and paths that appear in the summary; if something \
    isn't there, say so. Labels: safe = rebuilds itself, review = look first, keep = the user's data, \
    don't remove. To free space, tell the user to add items to Freespan's cleanup basket, review it, and \
    move them to the Trash, where they stay restorable until it is emptied; when you suggest removing \
    anything, end with one sentence saying so. Never suggest Terminal commands, rm or sudo.
    """

    static let askTopFindings = 12
    static let askUnknown = 3
    static let maxHistoryTurns = 2
    static let maxTurnCharacters = 500
    static let maxQuestionCharacters = 800

    /// Prompt tokens available to `askPrompt` once instructions and the answer are accounted for.
    static var askPromptBudget: Int {
        min(inputBudget, contextSize - askResponseTokens) - estimatedTokens(askInstructions)
    }

    /// The summary, the last two turns and the question, trimmed (fewer findings first) until it fits.
    /// `compact` drops history and halves the findings — used to retry after a context overflow.
    static func askPrompt(_ question: String, summary: DiskSummary, history: [ChatTurn], home: String,
                          compact: Bool = false) -> String {
        let budget = askPromptBudget
        var findings = compact ? askTopFindings / 2 : askTopFindings
        let turns = compact ? [] : Array(history.suffix(maxHistoryTurns))
        while true {
            let prompt = buildAskPrompt(question, summary: summary, history: turns, findings: findings, home: home)
            if estimatedTokens(prompt) <= budget || findings == 0 { return prompt }
            findings -= 1
        }
    }

    private static func buildAskPrompt(_ question: String, summary: DiskSummary, history: [ChatTurn],
                                       findings: Int, home: String) -> String {
        let v = summary.volume
        var lines = ["Disk \"\(v.name)\": \(humanSize(v.totalBytes)) total, \(humanSize(v.usedBytes)) used, \(humanSize(v.availableBytes)) free."]
        if !summary.categories.isEmpty {
            let cats = summary.categories.map { c -> String in
                var s = "\(c.category.displayName) \(humanSize(c.bytes))"
                if c.safeBytes > 0 { s += " (\(humanSize(c.safeBytes)) safe)" }
                return s
            }
            lines.append("By category: " + cats.joined(separator: "; ") + ".")
        }
        let top = summary.topFindings.prefix(findings)
        if !top.isEmpty {
            lines.append("Largest items:")
            for f in top {
                let path = middleTruncated(Redactor.redact(f.path, home: home), to: maxPathCharacters)
                lines.append("- \(f.title): \(path), \(humanSize(f.bytes)), \(f.label.rawValue)")
            }
        }
        let unknown = summary.unknownLarge.prefix(findings == 0 ? 0 : askUnknown)
        if !unknown.isEmpty {
            lines.append("Not yet identified:")
            for u in unknown {
                lines.append("- \(middleTruncated(Redactor.redact(u.path, home: home), to: maxPathCharacters)), \(humanSize(u.sizeBytes))")
            }
        }
        var prompt = "Scan summary:\n" + lines.joined(separator: "\n")
        let turns = history.compactMap { turn -> String? in
            let t = Redactor.redactText(turn.text.trimmingCharacters(in: .whitespacesAndNewlines), home: home)
            guard !t.isEmpty else { return nil }
            return (turn.role == .user ? "User: " : "Assistant: ") + truncated(t, to: maxTurnCharacters)
        }
        if !turns.isEmpty { prompt += "\n\nEarlier in this chat:\n" + turns.joined(separator: "\n") }
        let q = Redactor.redactText(question.trimmingCharacters(in: .whitespacesAndNewlines), home: home)
        return prompt + "\n\nQuestion: " + truncated(q, to: maxQuestionCharacters)
    }

    // MARK: - Text helpers

    static func truncated(_ s: String, to limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(max(0, limit - 1))) + "…"
    }

    /// Keeps the start and (mostly) the end — the end of a path says the most about it.
    static func middleTruncated(_ s: String, to limit: Int) -> String {
        guard s.count > limit, limit > 8 else { return s }
        let head = limit / 3
        let tail = limit - head - 1
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }

    private static func monthString(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

/// Converts the cumulative snapshots a streaming model produces into deltas.
struct SnapshotDeltas {
    private var emitted = ""

    /// The new text since the last snapshot, or nil. If the model rewrote earlier text, only text beyond
    /// what was already shown is emitted (shown text can't be retracted).
    mutating func next(_ snapshot: String) -> String? {
        if snapshot.hasPrefix(emitted) {
            let delta = String(snapshot.dropFirst(emitted.count))
            guard !delta.isEmpty else { return nil }
            emitted = snapshot
            return delta
        }
        guard snapshot.count > emitted.count else { return nil }
        let delta = String(snapshot.dropFirst(emitted.count))
        emitted = snapshot
        return delta
    }
}
