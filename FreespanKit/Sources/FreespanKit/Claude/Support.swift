import Foundation
import Security
import Synchronization

// MARK: - Keychain

/// Stores the Anthropic API key in the login Keychain. OWNER: claude agent.
public enum KeychainStore {
    public static let service = "com.mcconnelldigital.Freespan"
    public static let account = "anthropic-api-key"

    public struct KeychainError: Error, Sendable, Equatable, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }

    public static func apiKey() -> String? { apiKey(service: service) }

    /// Stores the key (trimmed). `nil` or a blank string deletes it.
    public static func setAPIKey(_ key: String?) throws { try setAPIKey(key, service: service) }

    // Service is injectable so tests don't touch the real item.
    static func apiKey(service: String) -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func setAPIKey(_ key: String?, service: String) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let query = baseQuery(service: service)
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Freespan — Anthropic API key"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

// MARK: - Redaction

/// Replaces the user's home directory with `~` (and back). OWNER: claude agent.
/// Path-boundary aware: with home `/Users/alex`, `/Users/alex2/x` is left alone.
public enum Redactor {
    public static func redact(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = normalized(home)
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func unredact(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = normalized(home)
        guard !home.isEmpty else { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    /// Redacts every occurrence of the home path inside free text (chat questions, names), respecting
    /// path boundaries: an occurrence counts only when followed by `/`, end of text, or a character that
    /// can't continue a path component (whitespace, quotes, punctuation).
    public static func redactText(_ text: String, home: String = NSHomeDirectory()) -> String {
        let home = normalized(home)
        guard !home.isEmpty, text.contains(home) else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: home) {
            let next = rest[range.upperBound...].first
            let precededOK = range.lowerBound == rest.startIndex
                ? (result.last.map(isBoundaryBefore) ?? true)
                : isBoundaryBefore(rest[rest.index(before: range.lowerBound)])
            if precededOK, next == nil || next == "/" || isBoundaryAfter(next!) {
                result += rest[..<range.lowerBound]
                result += "~"
            } else {
                result += rest[..<range.upperBound]
            }
            rest = rest[range.upperBound...]
        }
        result += rest
        return result
    }

    private static func normalized(_ home: String) -> String {
        var h = home
        while h.count > 1, h.hasSuffix("/") { h.removeLast() }
        return h == "/" ? "" : h
    }

    private static func isBoundaryBefore(_ c: Character) -> Bool {
        !(c.isLetter || c.isNumber || c == "/" || c == "_" || c == "-" || c == ".")
    }

    private static func isBoundaryAfter(_ c: Character) -> Bool {
        !(c.isLetter || c.isNumber || c == "_" || c == "-" || c == ".")
    }
}

// MARK: - Usage

/// Token totals for one model.
public struct ModelUsage: Codable, Sendable, Hashable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheWriteTokens: Int = 0
    public var requests: Int = 0
    public init() {}
}

extension ClaudeModel {
    /// Cache-read price as a fraction of the input price. Opus 5.5 reads at $0.20/MTok (0.05×);
    /// the others at the standard 0.1×.
    var cacheReadMultiplier: Double { self == .opus ? 0.05 : 0.1 }
    /// 5-minute cache writes cost 1.25× input on every model.
    var cacheWriteMultiplier: Double { 1.25 }

    func costUSD(_ u: ModelUsage) -> Double {
        let p = pricePerMTok
        let input = Double(u.inputTokens) * p.input
        let output = Double(u.outputTokens) * p.output
        let reads = Double(u.cacheReadTokens) * p.input * cacheReadMultiplier
        let writes = Double(u.cacheWriteTokens) * p.input * cacheWriteMultiplier
        return (input + output + reads + writes) / 1_000_000
    }
}

/// Tracks tokens and estimated USD spend per model, persisted in UserDefaults. OWNER: claude agent.
public final class UsageMeter: Sendable {
    public static let shared = UsageMeter()
    static let defaultsKey = "FreespanClaudeUsage.v1"

    private let state: Mutex<[ClaudeModel: ModelUsage]>
    nonisolated(unsafe) private let defaults: UserDefaults // UserDefaults is thread-safe

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [ClaudeModel: ModelUsage] = [:]
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: ModelUsage].self, from: data)
        {
            for (key, value) in stored { if let m = ClaudeModel(rawValue: key) { loaded[m] = value } }
        }
        state = Mutex(loaded)
    }

    /// Convenience for tests and previews: a meter backed by its own defaults suite.
    public convenience init(suiteName: String) {
        self.init(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }

    /// `inputTokens` is the uncached input (the API's `input_tokens`, which excludes cache reads/writes).
    public func record(model: ClaudeModel, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) {
        let snapshot = state.withLock { all in
            var u = all[model] ?? ModelUsage()
            u.inputTokens += max(0, inputTokens)
            u.outputTokens += max(0, outputTokens)
            u.cacheReadTokens += max(0, cacheReadTokens)
            u.cacheWriteTokens += max(0, cacheWriteTokens)
            u.requests += 1
            all[model] = u
            return all
        }
        persist(snapshot)
    }

    public func usage(for model: ClaudeModel) -> ModelUsage {
        state.withLock { $0[model] ?? ModelUsage() }
    }

    public func totalCostUSD() -> Double {
        state.withLock { all in all.reduce(0) { $0 + $1.key.costUSD($1.value) } }
    }

    public func costUSD(for model: ClaudeModel) -> Double {
        model.costUSD(usage(for: model))
    }

    public func reset() {
        state.withLock { $0 = [:] }
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func persist(_ all: [ClaudeModel: ModelUsage]) {
        let stored = Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

// MARK: - Summary building

/// Builds the metadata-only context sent to Claude. OWNER: claude agent.
public enum SummaryBuilder {
    public static let maxTopFindings = 60
    public static let maxUnknown = 40
    public static let maxChildren = 5

    public static func summary(scan: ScanResult, findings: [Finding], unknown: [FileNode], home: String = NSHomeDirectory()) -> DiskSummary {
        // Count nested findings once: drop any finding inside another finding.
        let outermost = outermostFindings(findings)

        var totals: [CategoryID: (bytes: Int64, safe: Int64)] = [:]
        for f in outermost {
            var t = totals[f.classification.category] ?? (0, 0)
            t.bytes += f.size
            if f.classification.label == .safe { t.safe += f.size }
            totals[f.classification.category] = t
        }
        // Everything the scan saw that no finding explains goes to "other".
        let classified = totals.filter { $0.key != .other }.reduce(Int64(0)) { $0 + $1.value.bytes }
        let otherBytes = max(0, scan.root.size - classified)
        if otherBytes > 0 || totals[.other] != nil {
            let existing = totals[.other] ?? (0, 0)
            totals[.other] = (max(existing.bytes, otherBytes), existing.safe)
        }
        let categories = totals
            .filter { $0.value.bytes > 0 }
            .map { DiskSummary.CategoryTotal(category: $0.key, bytes: $0.value.bytes, safeBytes: $0.value.safe) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.category.rawValue < $1.category.rawValue }

        let top = findings
            .filter { $0.classification.label != .protected }
            .sorted { $0.size > $1.size }
            .prefix(maxTopFindings)
            .map {
                DiskSummary.SummaryFinding(
                    path: Redactor.redact($0.path, home: home), title: $0.classification.title, bytes: $0.size,
                    label: $0.classification.label, category: $0.classification.category, lastModified: $0.modified)
            }

        let unknownLarge = unknown
            .filter { $0.kind != .smallFiles }
            .sorted { $0.size > $1.size }
            .prefix(maxUnknown)
            .map { metadata(for: $0, home: home) }

        return DiskSummary(volume: scan.volume, scannedAt: scan.scannedAt, categories: categories,
                           topFindings: Array(top), unknownLarge: Array(unknownLarge))
    }

    public static func metadata(for node: FileNode, home: String = NSHomeDirectory()) -> ItemMetadata {
        let children = node.children
            .filter { $0.kind != .smallFiles }
            .sorted { $0.size > $1.size }
            .prefix(maxChildren)
            .map { Redactor.redactText($0.name, home: home) }
        return ItemMetadata(path: Redactor.redact(node.path, home: home), sizeBytes: node.size,
                            isDirectory: node.kind != .file, itemCount: node.itemCount,
                            modified: node.modified, accessed: node.accessed, topChildren: Array(children))
    }

    private static func outermostFindings(_ findings: [Finding]) -> [Finding] {
        var seen = Set<String>()
        let unique = findings.filter { seen.insert($0.path).inserted }
        return unique.filter { f in
            var dir = (f.path as NSString).deletingLastPathComponent
            while !dir.isEmpty, dir != "/" {
                if seen.contains(dir) { return false }
                dir = (dir as NSString).deletingLastPathComponent
            }
            return !(seen.contains("/") && f.path != "/")
        }
    }
}
