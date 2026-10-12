import Foundation

/// The curated table in KnownLocations.json: vendor/tool folders and file types, each with plain-English text.
struct KnownLocationCatalog: Sendable {
    struct Entry: Codable, Sendable {
        let id: String
        let title: String
        let explanation: String
        let category: CategoryID
        let label: SafetyLabel
        let regenerates: Bool
        let paths: [String]?
        let extensions: [String]?
        /// Bundle ID of the app this data belongs to (used to attach it to that app), when exactly one app owns it.
        var owner: String? = nil
    }

    private struct File: Codable {
        let locations: [Entry]
        let fileTypes: [Entry]
    }

    private struct Compiled: Sendable {
        let entry: Entry
        let pattern: [PatternSegment]
        let anchoredAtHome: Bool
    }

    let locations: [Entry]
    let fileTypes: [Entry]
    private let compiled: [Compiled]
    private let byExtension: [String: Entry]

    init(locations: [Entry], fileTypes: [Entry]) {
        self.locations = locations
        self.fileTypes = fileTypes
        var compiled: [Compiled] = []
        for entry in locations {
            for raw in entry.paths ?? [] {
                var parts = raw.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                let anchored = parts.first == "~"
                if anchored { parts.removeFirst() }
                let segs: [PatternSegment] = parts.map { p in
                    if p == "*" { return .one }
                    if p.contains("*") || p.contains("?") { return .glob(Glob(p)) }
                    return .literal(p)
                }
                compiled.append(Compiled(entry: entry, pattern: segs, anchoredAtHome: anchored))
            }
        }
        self.compiled = compiled
        var byExt: [String: Entry] = [:]
        for t in fileTypes { for e in t.extensions ?? [] { byExt[e.lowercased()] = byExt[e.lowercased()] ?? t } }
        self.byExtension = byExt
    }

    /// Loaded once from the FreespanKit bundle. An unreadable table degrades to empty (identification still works).
    static let bundled: KnownLocationCatalog = {
        guard let url = Bundle.module.url(forResource: "KnownLocations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            assertionFailure("KnownLocations.json missing or invalid")
            return KnownLocationCatalog(locations: [], fileTypes: [])
        }
        return KnownLocationCatalog(locations: file.locations, fileTypes: file.fileTypes)
    }()

    /// The most specific location whose path is `segments` or one of its ancestors.
    /// `segments` and `home` are lowercased path components. Returns the entry and whether it matched exactly.
    func location(for segments: [String], home: [String]) -> (entry: Entry, exact: Bool)? {
        var best: (entry: Entry, exact: Bool, length: Int)?
        for c in compiled {
            let prefix = c.anchoredAtHome ? home : []
            let length = prefix.count + c.pattern.count
            guard length <= segments.count, length > (best?.length ?? 0) else { continue }
            guard Array(segments.prefix(prefix.count)) == prefix else { continue }
            var ok = true
            for (i, seg) in c.pattern.enumerated() where !seg.matches(segments[prefix.count + i]) {
                ok = false
                break
            }
            if ok { best = (c.entry, length == segments.count, length) }
        }
        return best.map { ($0.entry, $0.exact) }
    }

    func fileType(forExtension ext: String) -> Entry? {
        ext.isEmpty ? nil : byExtension[ext.lowercased()]
    }
}
