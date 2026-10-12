import Foundation

/// Matches scanned nodes against the rule catalog (Rules.json). OWNER: rules agent.
///
/// Matching model:
/// - Rules are tried in catalog order; the first rule that matches a node wins.
/// - `findings` walks the tree top-down. Once a node matches, its descendants are not visited, so nothing is
///   counted twice and the outermost match wins (e.g. only the outermost `node_modules`).
/// - Path patterns are compiled once at init. `~` expands to the `home` passed to each call.
public struct RuleEngine: Sendable {
    public let rules: [Rule]
    private let compiled: [CompiledRule]

    public init(rules: [Rule]) {
        self.rules = rules
        self.compiled = rules.map(CompiledRule.init)
    }

    /// Loads the catalog bundled in FreespanKit (Rules/Rules.json).
    public static func bundled() throws -> RuleEngine {
        RuleEngine(rules: try bundledRules())
    }

    /// The raw rules in the bundled catalog, in match order.
    public static func bundledRules() throws -> [Rule] {
        guard let url = Bundle.module.url(forResource: "Rules", withExtension: "json") else {
            throw RuleEngineError.catalogMissing
        }
        do {
            return try JSONDecoder().decode([Rule].self, from: Data(contentsOf: url))
        } catch {
            throw RuleEngineError.catalogInvalid(String(describing: error))
        }
    }

    /// Classification for one node, or nil when no rule matches. `home` is the user's home directory path.
    public func classify(_ node: FileNode, home: String) -> Classification? {
        classify(node, home: home, now: Date())
    }

    /// Same as `classify(_:home:)` with an explicit clock (for age-based rules).
    public func classify(_ node: FileNode, home: String, now: Date) -> Classification? {
        let ctx = MatchContext(home: home, now: now)
        return firstMatch(node, segments: PathSegments.split(node.path), ctx: ctx)?.classification(for: node)
    }

    /// Walks the tree and returns every matched node. When a directory matches, its descendants are not
    /// visited (no double counting), except for `yieldsToNested` rules: their descendants are matched first and the
    /// folder's own finding carries only the remaining bytes. Also emits `.largeOld` findings for big untouched
    /// files/folders not otherwise matched. Zero-byte findings are dropped. Sorted by size, largest first.
    public func findings(in root: FileNode, home: String, now: Date = Date()) -> [Finding] {
        let matcher = TreeMatcher(compiled, ctx: MatchContext(home: home, now: now))
        var out: [Finding] = []
        var segments = PathSegments.split(root.path)
        walkFindings(root, segments: &segments, live: matcher.live(for: segments), matcher: matcher, into: &out)
        out.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        return out
    }

    private func walkFindings(_ node: FileNode, segments: inout [String], live: [Int32], matcher: TreeMatcher, into out: inout [Finding]) {
        if node.kind == .smallFiles { return }
        if let rule = matcher.firstMatch(node, segments: segments, live: live) {
            guard node.size > 0 else { return }
            guard rule.yieldsToNested, node.kind == .directory else {
                out.append(Finding(node: node, classification: rule.classification(for: node)))
                return
            }
            // Let more specific rules inside claim their parts (e.g. caches inside an Apple app's container);
            // this folder's finding is whatever is left.
            var nested: [Finding] = []
            for child in node.children where child.kind != .smallFiles {
                segments.append(PathSegments.lastComponent(of: child))
                walkFindings(child, segments: &segments, live: matcher.childLive(live, segments: segments), matcher: matcher, into: &nested)
                segments.removeLast()
            }
            let rest = node.size - nested.reduce(0) { $0 + $1.size }
            out += nested
            if rest > 0 {
                out.append(Finding(path: node.path, name: node.name, size: rest, itemCount: node.itemCount,
                                   modified: node.modified, accessed: node.accessed, isDirectory: true,
                                   classification: rule.classification(for: node)))
            }
            return
        }
        guard node.kind == .directory else { return }
        for child in node.children where child.kind != .smallFiles {
            segments.append(PathSegments.lastComponent(of: child))
            walkFindings(child, segments: &segments, live: matcher.childLive(live, segments: segments), matcher: matcher, into: &out)
            segments.removeLast()
        }
    }

    /// Totals per category over the given findings (plus `.other` = root size minus everything matched).
    /// Categories with no bytes are omitted, except `.other`, which is always last.
    public static func summarize(_ findings: [Finding], rootSize: Int64) -> [CategorySummary] {
        var total: [CategoryID: Int64] = [:]
        var safe: [CategoryID: Int64] = [:]
        var count: [CategoryID: Int] = [:]
        var matched: Int64 = 0
        for f in findings {
            let c = f.classification.category
            total[c, default: 0] += f.size
            count[c, default: 0] += 1
            if f.classification.label == .safe { safe[c, default: 0] += f.size }
            matched += f.size
        }
        var result = total
            .filter { $0.key != .other && $0.value > 0 }
            .map { CategorySummary(category: $0.key, totalBytes: $0.value, safeBytes: safe[$0.key] ?? 0, findingCount: count[$0.key] ?? 0) }
            .sorted { $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.category.rawValue < $1.category.rawValue }
        // Findings explicitly in `.other` (e.g. AI-labelled) are folded into the remainder line.
        let otherBytes = max(0, rootSize - matched) + (total[.other] ?? 0)
        result.append(CategorySummary(category: .other, totalBytes: otherBytes, safeBytes: safe[.other] ?? 0, findingCount: count[.other] ?? 0))
        return result
    }

    /// Large items (>= minSize) that no rule explains, for local identification (`ItemIdentifier`) and then AI
    /// labelling. Does not descend into matched or already-returned directories. Largest first, at most `limit`.
    ///
    /// Inside ~/Library only third-party app folders are returned (a non-Apple folder in Application Support,
    /// Containers, Group Containers, Caches, ... or a vendor folder the known-locations table names); macOS's own
    /// data there is never handed on. Use `isEligibleForAssistant(path:home:)` before sending anything to an
    /// assistant: ~/Library items are for `ItemIdentifier` only.
    ///
    /// Heuristic: "unexplained" bytes of a node = its size minus bytes in matched descendants. Starting at the
    /// root, structural folders (ancestors of home, home, its direct children, direct children of ~/Library) are
    /// always opened. Any other folder is opened only while a single child holds >= 70% of its unexplained
    /// bytes; otherwise the folder itself is returned as the unit. Big unmatched files and packages are leaves
    /// and are returned as-is. Returned nodes can still contain matched descendants (e.g. a project folder whose
    /// node_modules was matched). Results are ranked by `size`.
    public func unknownLargeItems(in root: FileNode, home: String, minSize: Int64 = 500_000_000, limit: Int = 200) -> [FileNode] {
        guard limit > 0 else { return [] }
        let ctx = MatchContext(home: home, now: Date())
        let matcher = TreeMatcher(compiled, ctx: ctx)
        // Pass 1: unexplained bytes for every node that has at least `minSize` of them.
        var unexplained: [UInt64: Int64] = [:]
        var segments = PathSegments.split(root.path)
        _ = computeUnexplained(root, segments: &segments, live: matcher.live(for: segments), matcher: matcher,
                               minSize: minSize, into: &unexplained)

        // Pass 2: pick units.
        let homeSegs = ctx.homeSegments
        var picked: [FileNode] = []
        func isStructural(_ node: FileNode, _ segs: [String], isRoot: Bool) -> Bool {
            if isRoot { return true }
            if homeSegs.isEmpty { return false }
            if segs.count <= homeSegs.count { return Array(homeSegs.prefix(segs.count)) == segs }
            guard Array(segs.prefix(homeSegs.count)) == homeSegs else { return false }
            let rel = segs.count - homeSegs.count
            if rel == 1 { return true }
            return rel == 2 && segs[homeSegs.count] == "library"
        }
        func visit(_ node: FileNode, _ segs: inout [String], isRoot: Bool) {
            guard node.kind != .smallFiles, let u = unexplained[node.id], u >= minSize else { return }
            guard node.kind == .directory else { picked.append(node); return }
            let open: Bool
            if isStructural(node, segs, isRoot: isRoot) {
                // A structural folder whose bytes are spread thinly (no big child) is itself the unit,
                // unless it is home or above.
                let hasBigChild = node.children.contains { (unexplained[$0.id] ?? 0) >= minSize }
                open = hasBigChild || isRoot || segs.count <= homeSegs.count
            } else {
                var best: FileNode?
                var bestBytes: Int64 = -1
                for c in node.children {
                    let b = c.kind == .smallFiles ? c.size : (unexplained[c.id] ?? 0)
                    if b > bestBytes { bestBytes = b; best = c }
                }
                let threshold = max(minSize, Int64((Double(u) * 0.7).rounded(.up)))
                open = best != nil && best!.kind != .smallFiles && bestBytes >= threshold
            }
            guard open else { picked.append(node); return }
            for c in node.children where (unexplained[c.id] ?? 0) >= minSize {
                segs.append(PathSegments.lastComponent(of: c))
                visit(c, &segs, isRoot: false)
                segs.removeLast()
            }
        }
        var rootSegs = PathSegments.split(root.path)
        visit(root, &rootSegs, isRoot: true)
        picked.removeAll { !Self.mayReportUnknown(PathSegments.split($0.path), homeSegments: homeSegs) }
        picked.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        return Array(picked.prefix(limit))
    }

    /// False for items inside ~/Library that aren't a third-party app's (see `unknownLargeItems`).
    static func mayReportUnknown(_ segs: [String], homeSegments h: [String]) -> Bool {
        guard !h.isEmpty, segs.count > h.count, Array(segs.prefix(h.count)) == h else { return true }
        let rel = Array(segs.dropFirst(h.count))
        guard rel[0] == "library" else { return true }
        return LibraryOwnership.isThirdParty(rel: rel, segments: segs, homeSegments: h)
    }

    /// True only for user-visible places an assistant may be asked about: inside the home folder but outside
    /// ~/Library, or an item in /Applications — and never a protected path (home itself, the standard folders,
    /// dot-folders that aren't plain caches, other users, macOS). Call this before sending any path to an
    /// assistant (on-device or cloud); everything else is named by rules or `ItemIdentifier` only.
    public static func isEligibleForAssistant(path: String, home: String) -> Bool {
        guard let p = ProtectedPaths.normalizedComponents(path), let h = ProtectedPaths.normalizedComponents(home),
              !h.isEmpty, !ProtectedPaths.isProtected(path, home: home) else { return false }
        if p.count > h.count, Array(p.prefix(h.count)) == h { return p[h.count] != "library" }
        return p.first == "applications" && p.count >= 2
    }

    /// The group title for findings of rule `id` (e.g. "App caches"), or nil for an unknown rule.
    public func pluralTitle(forRuleID id: String) -> String? {
        guard let rule = rules.first(where: { $0.id == id }) else { return nil }
        return rule.groupTitle
    }

    /// Returns unexplained bytes of `node`; records nodes with >= minSize in `table`.
    private func computeUnexplained(_ node: FileNode, segments: inout [String], live: [Int32], matcher: TreeMatcher,
                                    minSize: Int64, into table: inout [UInt64: Int64]) -> Int64 {
        if node.kind == .smallFiles { return node.size }
        if matcher.firstMatch(node, segments: segments, live: live) != nil { return 0 }
        var u = node.size
        if node.kind == .directory {
            var explained: Int64 = 0
            for c in node.children where c.kind != .smallFiles {
                segments.append(PathSegments.lastComponent(of: c))
                explained += c.size - computeUnexplained(c, segments: &segments, live: matcher.childLive(live, segments: segments),
                                                         matcher: matcher, minSize: minSize, into: &table)
                segments.removeLast()
            }
            u = max(0, node.size - explained)
        }
        if u >= minSize { table[node.id] = u }
        return u
    }

    // MARK: - Matching core

    private func firstMatch(_ node: FileNode, segments: [String], ctx: MatchContext) -> CompiledRule? {
        if node.kind == .smallFiles { return nil }
        for rule in compiled where rule.matches(node, segments: segments, ctx: ctx) {
            return rule
        }
        return nil
    }
}

public enum RuleEngineError: LocalizedError, Sendable {
    case catalogMissing
    case catalogInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .catalogMissing: "Freespan's built-in cleanup rules are missing from the app bundle."
        case .catalogInvalid(let detail): "Freespan's built-in cleanup rules couldn't be read (\(detail))."
        }
    }
}

/// One entry in Rules.json. OWNER: rules agent (shape may be extended; keep it Codable).
public struct Rule: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let explanation: String
    public let category: CategoryID
    public let label: SafetyLabel
    public let regenerates: Bool
    /// What this rule matches.
    public let match: RuleMatch
    /// Title for a group of this rule's findings ("App caches", "macOS system data"). Written out in the catalog
    /// because English plurals of these titles aren't mechanical; nil falls back to `title`.
    public let pluralTitle: String?
    /// When true, more specific rules still match inside a folder this rule matches; the folder's own finding
    /// then holds only the bytes nothing inside claimed. Used for broad Keep rules (Apple app containers)
    /// that must not hide removable caches inside them.
    public let yieldsToNested: Bool?

    public init(id: String, title: String, explanation: String, category: CategoryID, label: SafetyLabel, regenerates: Bool,
                match: RuleMatch, pluralTitle: String? = nil, yieldsToNested: Bool? = nil) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.category = category
        self.label = label
        self.regenerates = regenerates
        self.match = match
        self.pluralTitle = pluralTitle
        self.yieldsToNested = yieldsToNested
    }

    /// Placeholder in `title` replaced by the matched item's name (e.g. "Other user: {name}").
    public static let namePlaceholder = "{name}"

    /// The rule's classification. A `{name}` placeholder in the title is left as is; findings and `classify`
    /// fill it in with the matched item's name.
    public var classification: Classification {
        Classification(category: category, label: label, title: title, explanation: explanation,
                       regenerates: regenerates, source: .rule, ruleID: id)
    }

    /// Group title: `pluralTitle`, or `title` without a `{name}` placeholder.
    public var groupTitle: String {
        pluralTitle ?? title.replacingOccurrences(of: " " + Self.namePlaceholder, with: "")
            .replacingOccurrences(of: Self.namePlaceholder, with: "")
    }
}

/// The `match` object of a rule. All present conditions must hold.
///
/// Path patterns are absolute (`/Library/*`), home-relative (`~/Library/Caches/*`) or unanchored (`**/node_modules`).
/// Segments: `*` = exactly one segment, `**` = any number of segments (including zero), and a segment containing
/// `*`/`?` is a glob within that segment (`*.app`, `*OS DeviceSupport`). Matching is case-insensitive (APFS default).
public struct RuleMatch: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Directory or package (`.app`, `.photoslibrary`, ...).
        case dir
        case file
        case package
        case any
    }

    public enum AgeBasis: String, Codable, Sendable {
        /// Older than `minAgeDays` by modification date.
        case modified
        /// Older than `minAgeDays` by last access date.
        case accessed
        /// Neither modified nor accessed within `minAgeDays` (folders/packages: modified only, since listing a
        /// folder updates its access date).
        case both
    }

    /// Any of these patterns must match the node's path.
    public var paths: [String]
    /// The node must not match any of these patterns.
    public var excludePaths: [String]?
    /// Exact (case-insensitive) names the node must have, if given.
    public var names: [String]?
    /// Extensions (without dot, case-insensitive) the node must have, if given.
    public var extensions: [String]?
    /// Default `.any`. `.smallFiles` aggregate nodes never match.
    public var kind: Kind?
    public var minAgeDays: Int?
    /// Default `.both`.
    public var ageBy: AgeBasis?
    public var minSize: Int64?
    /// When true, the patterns name a parent folder and each child of it is matched instead (one finding per child).
    public var matchChildren: Bool?
    /// The node must not be inside a folder with one of these names (e.g. `node_modules` for outermost-only).
    public var notInside: [String]?

    public init(paths: [String], excludePaths: [String]? = nil, names: [String]? = nil, extensions: [String]? = nil,
                kind: Kind? = nil, minAgeDays: Int? = nil, ageBy: AgeBasis? = nil, minSize: Int64? = nil,
                matchChildren: Bool? = nil, notInside: [String]? = nil) {
        self.paths = paths
        self.excludePaths = excludePaths
        self.names = names
        self.extensions = extensions
        self.kind = kind
        self.minAgeDays = minAgeDays
        self.ageBy = ageBy
        self.minSize = minSize
        self.matchChildren = matchChildren
        self.notInside = notInside
    }
}

// MARK: - Compiled form

struct MatchContext {
    let homeSegments: [String]
    let now: Date

    init(home: String, now: Date) {
        self.homeSegments = PathSegments.split(home)
        self.now = now
    }
}

enum PathSegments {
    /// Lowercased, non-empty components of an absolute path.
    static func split(_ path: String) -> [String] {
        path.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Lowercased last path component of a node (falls back to its name).
    static func lastComponent(of node: FileNode) -> String {
        let p = node.path
        if let slash = p.lastIndex(of: "/"), p.index(after: slash) < p.endIndex {
            return p[p.index(after: slash)...].lowercased()
        }
        return node.name.lowercased()
    }
}

enum Glob: Sendable, Hashable {
    case prefix(String)
    case suffix(String)
    case general([Character])

    init(_ s: String) {
        let stars = s.filter { $0 == "*" }.count
        if !s.contains("?") && stars == 1 && s.hasPrefix("*") {
            self = .suffix(String(s.dropFirst()))
        } else if !s.contains("?") && stars == 1 && s.hasSuffix("*") {
            self = .prefix(String(s.dropLast()))
        } else {
            self = .general(Array(s))
        }
    }

    func matches(_ s: String) -> Bool {
        switch self {
        case .prefix(let p): return s.hasPrefix(p)
        case .suffix(let x): return s.hasSuffix(x)
        case .general(let pat): return Glob.match(pat, Array(s))
        }
    }

    private static func match(_ p: [Character], _ s: [Character]) -> Bool {
        var pi = 0, si = 0, starP = -1, starS = 0
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) { pi += 1; si += 1 }
            else if pi < p.count && p[pi] == "*" { starP = pi; starS = si; pi += 1 }
            else if starP >= 0 { pi = starP + 1; starS += 1; si = starS }
            else { return false }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

enum PatternSegment: Sendable, Hashable {
    case home
    case literal(String)
    case one
    case glob(Glob)
    case deep

    func matches(_ s: String) -> Bool {
        switch self {
        case .literal(let l): l == s
        case .one: true
        case .glob(let g): g.matches(s)
        case .home, .deep: false
        }
    }
}

struct PathPattern: Sendable, Hashable {
    let segments: [PatternSegment]
    /// Cheap pre-check against the node's last component when the pattern ends in a single-segment matcher.
    let last: PatternSegment?

    init(_ raw: String, appendingChild: Bool = false) {
        var segs: [PatternSegment] = []
        var parts = raw.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let first = parts.first, first == "~" {
            segs.append(.home)
            parts.removeFirst()
        }
        for p in parts {
            if p == "**" { if segs.last != .deep { segs.append(.deep) } }
            else if p == "*" { segs.append(.one) }
            else if p.contains("*") || p.contains("?") { segs.append(.glob(Glob(p))) }
            else { segs.append(.literal(p)) }
        }
        if appendingChild { segs.append(.one) }
        self.segments = segs
        switch segs.last {
        case .literal, .glob: last = segs.last
        default: last = nil
        }
    }

    func matches(_ path: [String], home: [String]) -> Bool {
        if let last {
            guard let tail = path.last, last.matches(tail) else { return false }
        }
        return Self.match(segments, 0, path, 0, home)
    }

    private static func match(_ p: [PatternSegment], _ pi: Int, _ s: [String], _ si: Int, _ home: [String]) -> Bool {
        if pi == p.count { return si == s.count }
        switch p[pi] {
        case .deep:
            if pi + 1 == p.count { return true }
            var k = si
            while k <= s.count {
                if match(p, pi + 1, s, k, home) { return true }
                k += 1
            }
            return false
        case .home:
            guard !home.isEmpty, s.count - si >= home.count else { return false }
            for i in 0..<home.count where s[si + i] != home[i] { return false }
            return match(p, pi + 1, s, si + home.count, home)
        default:
            guard si < s.count, p[pi].matches(s[si]) else { return false }
            return match(p, pi + 1, s, si + 1, home)
        }
    }
}

/// Per-call matcher for tree walks. Each (rule, pattern) pair gets a concrete literal prefix (with `~` expanded)
/// and a maximum depth; while walking down, pairs whose prefix diverges or whose depth is exceeded are dropped, so
/// deep inside e.g. a project folder only the few `**` rules are still evaluated.
struct TreeMatcher {
    struct Entry {
        let rule: Int
        let prefix: [String]
        let maxDepth: Int?
    }

    let compiled: [CompiledRule]
    let ctx: MatchContext
    let entries: [Entry]

    init(_ compiled: [CompiledRule], ctx: MatchContext) {
        self.compiled = compiled
        self.ctx = ctx
        var entries: [Entry] = []
        for (i, rule) in compiled.enumerated() {
            for pattern in rule.patterns {
                var prefix: [String] = []
                var depth = 0
                var open = false
                var literal = true
                for seg in pattern.segments {
                    switch seg {
                    case .home:
                        // An empty home can never match; use an impossible segment.
                        let h = ctx.homeSegments.isEmpty ? ["\u{0}"] : ctx.homeSegments
                        if literal { prefix += h }
                        depth += h.count
                    case .literal(let l):
                        if literal { prefix.append(l) }
                        depth += 1
                    case .one, .glob:
                        literal = false
                        depth += 1
                    case .deep:
                        literal = false
                        open = true
                    }
                }
                entries.append(Entry(rule: i, prefix: prefix, maxDepth: open ? nil : depth))
            }
        }
        self.entries = entries
    }

    /// Entries that could match a node at `segments` or any of its descendants.
    func live(for segments: [String]) -> [Int32] {
        var out: [Int32] = []
        for (i, e) in entries.enumerated() {
            if let m = e.maxDepth, segments.count > m { continue }
            let n = min(segments.count, e.prefix.count)
            var ok = true
            for j in 0..<n where segments[j] != e.prefix[j] { ok = false; break }
            if ok { out.append(Int32(i)) }
        }
        return out
    }

    /// Narrows the parent's live entries for a child whose segments are `segments` (parent segments + one).
    func childLive(_ live: [Int32], segments: [String]) -> [Int32] {
        let d = segments.count - 1
        let s = segments[d]
        var out: [Int32] = []
        out.reserveCapacity(live.count)
        for i in live {
            let e = entries[Int(i)]
            if let m = e.maxDepth, segments.count > m { continue }
            if d < e.prefix.count && e.prefix[d] != s { continue }
            out.append(i)
        }
        return out
    }

    func firstMatch(_ node: FileNode, segments: [String], live: [Int32]) -> CompiledRule? {
        if node.kind == .smallFiles { return nil }
        var lastRule = -1
        for i in live {
            let e = entries[Int(i)]
            guard e.rule != lastRule, e.prefix.count <= segments.count else { continue }
            lastRule = e.rule
            if compiled[e.rule].matches(node, segments: segments, ctx: ctx) { return compiled[e.rule] }
        }
        return nil
    }
}

struct CompiledRule: Sendable {
    let rule: Rule
    let classification: Classification
    let patterns: [PathPattern]
    let excludes: [PathPattern]
    let names: Set<String>?
    let extensions: Set<String>?
    let kind: RuleMatch.Kind
    let minAge: TimeInterval?
    let ageBy: RuleMatch.AgeBasis
    let minSize: Int64?
    let notInside: Set<String>?
    let yieldsToNested: Bool
    let titleHasName: Bool

    init(_ rule: Rule) {
        let m = rule.match
        self.rule = rule
        self.classification = rule.classification
        self.patterns = m.paths.map { PathPattern($0, appendingChild: m.matchChildren ?? false) }
        self.excludes = (m.excludePaths ?? []).map { PathPattern($0) }
        self.names = m.names.map { Set($0.map { $0.lowercased() }) }
        self.extensions = m.extensions.map { Set($0.map { $0.lowercased() }) }
        self.kind = m.kind ?? .any
        self.minAge = m.minAgeDays.map { TimeInterval($0) * 86_400 }
        self.ageBy = m.ageBy ?? .both
        self.minSize = m.minSize
        self.notInside = m.notInside.map { Set($0.map { $0.lowercased() }) }
        self.yieldsToNested = rule.yieldsToNested ?? false
        self.titleHasName = rule.title.contains(Rule.namePlaceholder)
    }

    func classification(for node: FileNode) -> Classification {
        guard titleHasName else { return classification }
        let name = node.path.split(separator: "/").last.map(String.init) ?? node.name
        let c = classification
        return Classification(category: c.category, label: c.label,
                              title: c.title.replacingOccurrences(of: Rule.namePlaceholder, with: name),
                              explanation: c.explanation, regenerates: c.regenerates, source: c.source, ruleID: c.ruleID)
    }

    func matches(_ node: FileNode, segments: [String], ctx: MatchContext) -> Bool {
        switch (kind, node.kind) {
        case (_, .smallFiles): return false
        case (.dir, .file), (.file, .directory), (.file, .package), (.package, .file), (.package, .directory): return false
        default: break
        }
        if let minSize, node.size < minSize { return false }
        guard let last = segments.last else { return false }
        if let names, !names.contains(last) { return false }
        if let extensions {
            guard let dot = last.lastIndex(of: "."), extensions.contains(String(last[last.index(after: dot)...])) else { return false }
        }
        if let minAge {
            let cutoff = ctx.now.addingTimeInterval(-minAge)
            let dates: [Date?] = switch ageBy {
            case .modified: [node.modified]
            case .accessed: [node.accessed]
            // A folder's access date is bumped whenever it is listed (including by our own scan), so for
            // folders and packages only the modification date is meaningful.
            case .both: node.kind == .file ? [node.modified, node.accessed] : [node.modified]
            }
            let known = dates.compactMap { $0 }
            guard !known.isEmpty, known.allSatisfy({ $0 < cutoff }) else { return false }
        }
        guard patterns.contains(where: { $0.matches(segments, home: ctx.homeSegments) }) else { return false }
        if excludes.contains(where: { $0.matches(segments, home: ctx.homeSegments) }) { return false }
        if let notInside, segments.dropLast().contains(where: { notInside.contains($0) }) { return false }
        return true
    }
}
