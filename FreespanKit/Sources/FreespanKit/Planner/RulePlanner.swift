import Foundation

/// Builds a Deep Clean Plan from findings alone — no AI. OWNER: identify agent.
///
/// Safety: only findings labeled `.safe` by a built-in rule (`source == .rule`) can land in a Safe step.
/// Everything else that's removable (`.review`, or anything identified heuristically or by an assistant)
/// can only appear in a Review step. `.keep` and `.protected` findings never appear.
public enum RulePlanner {
    /// At most this many steps, including the "smaller items" steps.
    public static let maxSteps = 12
    /// Groups smaller than this are folded into a "smaller items" step.
    static let minStepBytes: Int64 = 50_000_000

    /// Steps grouped by rule/title: Safe first, then Review; larger first. Never includes keep/protected.
    public static func plan(findings: [Finding], volume: VolumeInfo, home: String = NSHomeDirectory()) -> CleanupPlan {
        let groups = makeGroups(findings)
        let safe = groups.filter { $0.risk == .safe }.sorted(by: largerFirst)
        let review = groups.filter { $0.risk == .review }.sorted(by: largerFirst)

        var steps: [CleanupPlan.Step] = []
        let (safeMain, safeRest) = split(safe, reviewGroups: review.count)
        steps += safeMain.map(step)
        if !safeRest.isEmpty { steps.append(smallerStep(safeRest, risk: .safe)) }
        let budget = maxSteps - steps.count
        let reviewBig = review.filter { $0.bytes >= minStepBytes }
        let reviewSmall = review.filter { $0.bytes < minStepBytes }
        let needsRest = !reviewSmall.isEmpty || reviewBig.count > budget
        let reviewMain = Array(reviewBig.prefix(max(0, needsRest ? budget - 1 : budget)))
        let reviewRest = Array(reviewBig.dropFirst(reviewMain.count)) + reviewSmall
        steps += reviewMain.map(step)
        if !reviewRest.isEmpty && steps.count < maxSteps { steps.append(smallerStep(reviewRest, risk: .review)) }

        let safeBytes = safe.reduce(Int64(0)) { $0 + $1.bytes }
        let reviewBytes = review.reduce(Int64(0)) { $0 + $1.bytes }
        return CleanupPlan(headline: headline(safe: safeBytes, review: reviewBytes, volume: volume), steps: steps)
    }

    // MARK: - Grouping

    struct Group {
        let key: String
        let risk: SafetyLabel
        var findings: [Finding]
        var bytes: Int64 { findings.reduce(0) { $0 + $1.size } }
        var classification: Classification { findings[0].classification }
    }

    /// The label a finding can carry in a plan, or nil when it must not appear.
    static func planRisk(_ c: Classification) -> SafetyLabel? {
        switch c.label {
        case .safe: c.source == .rule ? .safe : .review
        case .review: .review
        case .keep, .protected: nil
        }
    }

    static func makeGroups(_ findings: [Finding]) -> [Group] {
        var order: [String] = []
        var byKey: [String: Group] = [:]
        var seen: Set<String> = []
        for f in findings {
            guard let risk = planRisk(f.classification), f.size > 0, seen.insert(f.path).inserted else { continue }
            let c = f.classification
            let base = c.source == .rule ? (c.ruleID.map { "rule:" + $0 } ?? "title:" + c.title) : "\(c.source.rawValue):" + c.title
            let key = base + "|" + risk.rawValue
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = Group(key: key, risk: risk, findings: [])
            }
            byKey[key]!.findings.append(f)
        }
        return order.compactMap { byKey[$0] }
    }

    private static func largerFirst(_ a: Group, _ b: Group) -> Bool {
        a.bytes != b.bytes ? a.bytes > b.bytes : a.key < b.key
    }

    /// Splits Safe groups into their own steps and a remainder, leaving room for Review steps.
    private static func split(_ safe: [Group], reviewGroups: Int) -> ([Group], [Group]) {
        let big = safe.filter { $0.bytes >= minStepBytes }
        let small = safe.filter { $0.bytes < minStepBytes }
        // Keep room for Review steps (up to a third of the plan, plus one for smaller items).
        let reserve = min(reviewGroups, maxSteps / 3 + 1)
        var limit = maxSteps - reserve
        let needsRest = !small.isEmpty || big.count > limit
        if needsRest { limit -= 1 }
        let main = Array(big.prefix(max(0, limit)))
        return (main, Array(big.dropFirst(main.count)) + small)
    }

    // MARK: - Steps

    private static func step(_ g: Group) -> CleanupPlan.Step {
        let c = g.classification
        let count = g.findings.count
        let size = format(g.bytes)
        let what = count == 1 ? "1 item" : "\(count) items"
        var reasoning = "\(what), \(size) in total. \(c.explanation)"
        if g.risk == .review && c.source != .rule {
            reasoning = "\(what), \(size) in total. Freespan identified this from its location and type rather than a built-in rule, so look before removing. \(c.explanation)"
        }
        return CleanupPlan.Step(title: stepTitle(c, risk: g.risk), reasoning: reasoning,
                                paths: g.findings.sorted { $0.size > $1.size }.map(\.path),
                                estimatedBytes: g.bytes, risk: g.risk)
    }

    private static func smallerStep(_ groups: [Group], risk: SafetyLabel) -> CleanupPlan.Step {
        let findings = groups.flatMap(\.findings).sorted { $0.size > $1.size }
        let bytes = findings.reduce(Int64(0)) { $0 + $1.size }
        let kinds = groups.sorted(by: largerFirst).prefix(4).map { $0.classification.title.lowercasedFirstWord(ruleTitle: $0.classification.source == .rule) }
        let more = groups.count > 4 ? ", and more" : ""
        let list = kinds.joined(separator: ", ") + more
        let title: String
        let reasoning: String
        if risk == .safe {
            title = "Clear smaller caches and leftovers"
            reasoning = "\(findings.count) smaller items, \(format(bytes)) in total: \(list). Each comes back on its own or is plainly disposable, according to Freespan's built-in rules."
        } else {
            title = "Review smaller items"
            reasoning = "\(findings.count) smaller items, \(format(bytes)) in total: \(list). Look at each before removing; some may still be in use."
        }
        return CleanupPlan.Step(title: title, reasoning: reasoning, paths: findings.map(\.path),
                                estimatedBytes: bytes, risk: risk)
    }

    /// Hand-written step titles for built-in rules; others are derived from the rule title.
    static let ruleStepTitles: [String: String] = [
        "trash": "Empty the Trash",
        "xcode-derived-data": "Clear Xcode build data (DerivedData)",
        "xcode-archives": "Review old Xcode archives",
        "xcode-device-support": "Clear Xcode device support files",
        "xcode-previews": "Clear SwiftUI preview data",
        "xcode-documentation-cache": "Clear Xcode's documentation cache",
        "simulator-caches": "Clear Simulator caches",
        "simulator-device": "Review Simulator devices",
        "swiftpm-cache": "Clear the Swift Package Manager cache",
        "cocoapods-cache": "Clear the CocoaPods cache",
        "homebrew-cache": "Clear Homebrew downloads",
        "yarn-cache": "Clear the Yarn cache",
        "pnpm-store": "Clear the pnpm package store",
        "npm-cache": "Clear the npm cache",
        "bun-cache": "Clear the Bun cache",
        "pip-cache": "Clear the pip cache",
        "uv-cache": "Clear the uv cache",
        "gradle-cache": "Clear the Gradle cache",
        "cargo-registry": "Clear the Rust crate cache",
        "docker-disk-image": "Review Docker's disk image",
        "node-modules": "Remove node_modules folders",
        "swift-build-folder": "Remove Swift package build folders",
        "mail-downloads": "Clear Mail attachment copies",
        "sandboxed-app-cache": "Clear Mac App Store app caches",
        "editor-cache": "Clear code editor caches",
        "browser-automation-cache": "Clear test browser downloads",
        "browser-cache": "Clear browser caches",
        "chrome-ai-model": "Review Chrome's on-device AI model",
        "google-updater-cache": "Clear Google updater downloads",
        "electron-app-cache": "Clear app web caches",
        "spotify-offline": "Review Spotify offline music",
        "jetbrains-cache": "Clear JetBrains IDE caches",
        "android-system-images": "Review Android emulator system images",
        "ollama-models": "Review Ollama AI models",
        "huggingface-cache": "Review Hugging Face model downloads",
        "app-cache": "Clear app caches",
        "user-logs": "Clear logs",
        "iphone-backup": "Review iPhone and iPad backups",
        "download-installer": "Review installers and archives in Downloads",
        "download-old": "Review old downloads",
        "download-recent": "Review recent downloads",
        "application": "Review apps you may not use",
        "large-old-file": "Review large files you haven't opened in months",
    ]

    static func stepTitle(_ c: Classification, risk: SafetyLabel) -> String {
        if c.source == .rule, let id = c.ruleID, let title = ruleStepTitles[id] {
            // A hand-written "Clear …" title must never sit on a Review step.
            if risk == .safe || !title.hasPrefix("Clear") && !title.hasPrefix("Remove") { return title }
        }
        let verb = risk == .safe ? "Clear" : "Review"
        return "\(verb) \(c.title.lowercasedFirstWord(ruleTitle: c.source == .rule))"
    }

    // MARK: - Headline

    static func headline(safe: Int64, review: Int64, volume: VolumeInfo) -> String {
        var parts: [String] = []
        if volume.totalBytes > 0, volume.availableBytes * 10 < volume.totalBytes {
            parts.append("Your disk is nearly full (\(format(max(0, volume.availableBytes))) free).")
        }
        switch (safe > 0, review > 0) {
        case (true, true):
            parts.append("You can safely free about \(format(safe)) now, and \(format(review)) more after a quick review.")
        case (true, false):
            parts.append("You can safely free about \(format(safe)) now.")
        case (false, true):
            parts.append("Nothing can be removed without a look first, but about \(format(review)) could go after a quick review.")
        case (false, false):
            parts.append("Nothing to clean up right now.")
        }
        return parts.joined(separator: " ")
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension String {
    /// "Device support files" → "device support files"; leaves "Xcode …", "SwiftUI …", "npm …" alone.
    /// Heuristic titles usually start with an app name, so for those only well-known common words are lowercased.
    func lowercasedFirstWord(ruleTitle: Bool = true) -> String {
        let firstWord = String(prefix { $0 != " " })
        guard let first = firstWord.first, first.isUppercase,
              firstWord.dropFirst().allSatisfy({ !$0.isUppercase }) else { return self }
        let lower = ruleTitle ? !Self.properNouns.contains(firstWord) : Self.commonWords.contains(firstWord)
        return lower ? first.lowercased() + dropFirst() : self
    }

    static let properNouns: Set<String> = [
        "Xcode", "Safari", "Chrome", "Spotify", "Docker", "Ollama", "Android", "Mail", "Homebrew", "Yarn", "Gradle",
        "Bun", "Python", "Rust", "Swift", "Simulator", "Google", "Hugging", "Claude", "Slack", "Zoom", "Adobe",
        "Unity", "Steam", "Microsoft", "Finder", "Photos", "Music",
    ]

    static let commonWords: Set<String> = [
        "Leftover", "Disk", "Archive", "Installer", "Virtual", "Database", "Your", "Part", "Code", "Hidden", "File",
    ]
}
