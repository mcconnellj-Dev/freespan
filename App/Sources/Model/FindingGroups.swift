import Foundation
import FreespanKit

/// Many findings from one rule (e.g. hundreds of per-app caches), shown as a single collapsible row.
struct FindingGroup: Identifiable, Hashable {
    let id: String
    /// Plural display name, e.g. "App caches".
    let title: String
    let classification: Classification
    /// Largest first.
    let items: [Finding]
    let size: Int64

    var label: SafetyLabel { classification.label }
    var category: CategoryID { classification.category }
    var lastUsed: Date? { items.compactMap(\.lastUsed).max() }
}

/// A row in a findings list: one finding, or a group of findings that share a rule.
enum FindingRow: Identifiable, Hashable {
    case item(Finding)
    case group(FindingGroup)

    var id: String {
        switch self {
        case .item(let finding): finding.path
        case .group(let group): group.id
        }
    }

    var name: String {
        switch self {
        case .item(let finding): finding.name
        case .group(let group): group.title
        }
    }

    var size: Int64 {
        switch self {
        case .item(let finding): finding.size
        case .group(let group): group.size
        }
    }

    var label: SafetyLabel {
        switch self {
        case .item(let finding): finding.label
        case .group(let group): group.label
        }
    }

    var lastUsedSortKey: Date {
        switch self {
        case .item(let finding): finding.lastUsedSortKey
        case .group(let group): group.lastUsed ?? .distantPast
        }
    }

    /// Findings this row stands for.
    var findings: [Finding] {
        switch self {
        case .item(let finding): [finding]
        case .group(let group): group.items
        }
    }

    /// Children for outline tables; nil for single findings.
    var children: [FindingRow]? {
        if case .group(let group) = self { return group.items.map(FindingRow.item) }
        return nil
    }
}

enum FindingGrouping {
    /// Rules with at least this many findings collapse into one row.
    static let minimumGroupSize = 3
    static let idPrefix = "group:"

    /// Findings from the same built-in rule share a key, so per-item titles ("Other user: alex") still group.
    /// Rules with the same group title, label and category (the sandboxed and regular "App caches" rules) share
    /// one too. AI, heuristic and manual findings are never grouped: their titles are per item.
    static func key(for finding: Finding, groupTitle: (String) -> String?) -> String? {
        let c = finding.classification
        guard c.source == .rule, let ruleID = c.ruleID, ruleID != "manual" else { return nil }
        return "\(c.category.rawValue)|\(c.label.rawValue)|\(groupTitle(ruleID) ?? "rule:" + ruleID)"
    }

    /// Collapses rule-mates into groups (when there are enough of them), keeping the input order of first
    /// appearance. Group items are sorted largest first. `groupTitle` maps a rule ID to its catalog heading
    /// (`RuleEngine.pluralTitle(forRuleID:)`); without one the item title is pluralized locally.
    static func rows(_ findings: [Finding], groupTitle: (String) -> String? = { _ in nil }) -> [FindingRow] {
        var buckets: [String: [Finding]] = [:]
        for finding in findings {
            if let key = key(for: finding, groupTitle: groupTitle) { buckets[key, default: []].append(finding) }
        }
        var emitted = Set<String>()
        var rows: [FindingRow] = []
        rows.reserveCapacity(findings.count)
        for finding in findings {
            guard let key = key(for: finding, groupTitle: groupTitle), let bucket = buckets[key],
                  bucket.count >= minimumGroupSize else {
                rows.append(.item(finding))
                continue
            }
            guard emitted.insert(key).inserted else { continue }
            let items = bucket.sorted { $0.size > $1.size }
            let title = finding.classification.ruleID.flatMap(groupTitle) ?? pluralize(finding.classification.title)
            rows.append(.group(FindingGroup(
                id: idPrefix + key,
                title: title,
                classification: finding.classification,
                items: items,
                size: items.reduce(0) { $0 + $1.size }
            )))
        }
        return rows
    }

    static func isGroupID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// Words that don't take an "s": "macOS system data", not "macOS system datas".
    private static let uncountable: Set<String> = [
        "data", "metadata", "media", "software", "firmware", "information", "info", "storage", "stuff", "mail",
        "music", "content", "equipment", "support", "history", "trash", "news", "series", "species",
    ]

    /// "App cache" → "App caches"; "macOS system data" stays put; already-plural titles ("Logs",
    /// "App caches", "Xcode device files") are left alone. Only the last word changes, and a trailing
    /// parenthetical ("Simulator (old)") is kept. Fallback only: the catalog's
    /// `pluralTitle` (via `groupTitle`) wins whenever the rule is known.
    static func pluralize(_ title: String) -> String {
        guard title.split(separator: "·").count == 1 else { return title }
        var head = title.trimmingCharacters(in: .whitespaces)
        var tail = ""
        if head.hasSuffix(")"), let open = head.lastIndex(of: "(") {
            tail = " " + head[open...]
            head = head[..<open].trimmingCharacters(in: .whitespaces)
        }
        guard let lastWord = head.split(separator: " ").last, let last = lastWord.last, last.isLetter else { return title }
        let lower = lastWord.lowercased()
        if uncountable.contains(lower) || uncountable.contains(head.lowercased()) { return title }
        // Already plural (or ends in -ss/-us/-is, which read fine as a group heading).
        if lower.hasSuffix("s") { return title }
        let plural: String
        if lower.hasSuffix("ch") || lower.hasSuffix("sh") || lower.hasSuffix("x") || lower.hasSuffix("z") {
            plural = head + "es"
        } else if lower.hasSuffix("y"), let beforeY = lower.dropLast().last, !"aeiou".contains(beforeY) {
            plural = String(head.dropLast()) + "ies"
        } else {
            plural = head + "s"
        }
        return plural + tail
    }
}
