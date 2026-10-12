import Foundation

/// One tile in "What's using your space".
public struct SpaceTile: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// All installed apps together.
        case apps
        /// One app's bundle plus its data. `path` is the .app path (for its icon).
        case app(path: String, bundleID: String?)
        /// A user folder or identified location (e.g. ~/Downloads, a code-projects folder).
        case folder(path: String)
        case category(CategoryID)
        /// Everything not shown in another tile.
        case other
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let kind: Kind
    public let bytes: Int64
    /// Bytes inside this tile labelled Safe by rules.
    public let safeBytes: Int64
    /// Bytes inside this tile labelled Review ("Check first").
    public let checkBytes: Int64

    public init(id: String, title: String, subtitle: String?, kind: Kind, bytes: Int64, safeBytes: Int64, checkBytes: Int64) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.kind = kind
        self.bytes = bytes; self.safeBytes = safeBytes; self.checkBytes = checkBytes
    }
}

/// Groups the disk into a handful of tiles people recognise. OWNER: apps-kit agent.
///
/// Tiles are mutually exclusive: every byte belongs to exactly one tile, and the tiles (including the final
/// "Everything else") add up to `scan.root.size` plus the size of app bundles outside the scanned folder
/// (a home scan doesn't include /Applications).
///
/// Bytes are claimed in this order; a later tile only gets what earlier tiles didn't take:
/// 1. Big apps: every app with at least 2 GB of data gets its own tile holding its bundle **and** its data
///    (Xcode also takes the rest of ~/Library/Developer). The Apps tile then excludes those bundles.
/// 2. Apps: the remaining app bundles.
/// 3. Photos (Photos libraries), Code projects, big identified folders outside ~/Library (by their title).
/// 4. Xcode (~/Library/Developer, when Xcode has no app tile), iPhone backups, Trash, Caches.
/// 5. Downloads, Desktop, Documents, Movies, Music, Pictures (what's left in each).
/// 6. macOS & system files (whole-disk scans).
/// Tiles smaller than 0.5% of the total, and those beyond `limit`, fold into "Everything else".
///
/// `safeBytes`/`checkBytes` come from the findings inside each tile (Safe from rules / Review). App bundles never
/// count as "to check"; app tiles use the app's own related items.
public enum SpaceBreakdown {
    static let appTileMinDataBytes: Int64 = 2_000_000_000
    static let identifiedMinBytes: Int64 = 1_000_000_000
    static let genericTitles: Set<String> = ["Your files", "App data"]
    static let userFolders = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"]
    static let bundleRuleIDs: Set<String> = ["application", "apple-app"]

    /// Largest first; at most `limit` tiles plus a final `.other` tile so the total matches the scan.
    public static func tiles(scan: ScanResult, findings: [Finding], apps: AppInventoryResult?,
                             home: String = NSHomeDirectory(), limit: Int = 8) -> [SpaceTile] {
        tiles(scan: scan, findings: findings, apps: apps, home: home, limit: limit, now: Date())
    }

    static func tiles(scan: ScanResult, findings: [Finding], apps: AppInventoryResult?,
                      home rawHome: String, limit: Int, now: Date) -> [SpaceTile] {
        let home = ProtectedPaths.normalize(rawHome) ?? rawHome
        let root = scan.root
        let lib = AppPaths.join(home, "Library")
        let index = FindingIndex(findings)
        func treeSize(_ path: String) -> Int64? { AppPaths.node(at: path, in: root)?.size }
        /// Rule findings claim their whole folder, except a "yields to nested" remainder (smaller than the folder).
        func claim(_ f: Finding) -> Claim {
            let covering = f.classification.source != .rule || (treeSize(f.path).map { $0 <= f.size } ?? true)
            return Claim(path: f.path, size: f.size, covering: covering)
        }

        var drafts: [Draft] = []

        // 1. Apps with lots of data: bundle + data.
        let installed = apps?.apps ?? []
        let bigApps = installed.filter { $0.dataBytes >= appTileMinDataBytes }
            .sorted { $0.dataBytes != $1.dataBytes ? $0.dataBytes > $1.dataBytes : $0.path < $1.path }
        var developerTaken = false
        for app in bigApps {
            var claims = [Claim(path: app.path, size: app.appBytes, covering: true)]
            claims += app.relatedRoots.map { Claim(path: $0.path, size: $0.bytes, covering: true) }
            if app.bundleID == "com.apple.dt.Xcode", let size = treeSize(AppPaths.join(lib, "Developer")) {
                claims.append(Claim(path: AppPaths.join(lib, "Developer"), size: size, covering: true))
                developerTaken = true
            }
            var d = Draft(id: "app:\(app.bundleID ?? app.path)", title: app.name, kind: .app(path: app.path, bundleID: app.bundleID),
                          claims: claims)
            d.app = app
            d.safe = app.extrasBytes
            d.check = app.related.filter { $0.classification.label == .review }.reduce(0) { $0 + $1.size }
            drafts.append(d)
        }

        // 2. All other app bundles.
        let tiled = Set(bigApps.map(\.path))
        let rest = installed.filter { !tiled.contains($0.path) }
        if !rest.isEmpty {
            var d = Draft(id: "apps", title: "Apps", kind: .apps,
                          claims: rest.map { Claim(path: $0.path, size: $0.appBytes, covering: true) })
            d.subtitle = appsSubtitle(rest, now: now)
            d.bundlesOnly = true
            drafts.append(d)
        } else if apps == nil {
            // No inventory: app bundles a whole-disk scan found.
            let bundles = findings.filter { $0.classification.ruleID == "application" }
            if !bundles.isEmpty {
                var d = Draft(id: "apps", title: "Apps", kind: .apps, claims: bundles.map(claim))
                d.subtitle = bundles.count == 1 ? "1 app" : "\(bundles.count) apps"
                d.bundlesOnly = true
                drafts.append(d)
            }
        }

        // 3. Photos, code projects, identified folders.
        let photos = findings.filter { $0.classification.ruleID == "photos-library" }
        if !photos.isEmpty {
            drafts.append(Draft(id: "photos", title: "Photos", kind: .folder(path: largest(photos)), claims: photos.map(claim)))
        }
        let identified = findings.filter { f in
            f.classification.source != .rule && f.isDirectory && AppPaths.isStrictlyInside(f.path, home)
                && !AppPaths.isInside(f.path, lib)
        }
        let projects = identified.filter { isCodeProject($0.classification.title) }
        if !projects.isEmpty {
            drafts.append(Draft(id: "code-projects", title: "Code projects", kind: .folder(path: largest(projects)),
                                claims: projects.map(claim)))
        }
        var byTitle: [String: [Finding]] = [:]
        for f in identified where f.size >= identifiedMinBytes && !isCodeProject(f.classification.title)
            && !genericTitles.contains(f.classification.title) {
            byTitle[f.classification.title, default: []].append(f)
        }
        for (title, items) in byTitle.sorted(by: { $0.key < $1.key }) {
            drafts.append(Draft(id: "identified:\(title)", title: title, kind: .folder(path: largest(items)), claims: items.map(claim)))
        }

        // 4. Developer data, backups, Trash, caches.
        if !developerTaken, let size = treeSize(AppPaths.join(lib, "Developer")) {
            drafts.append(Draft(id: "xcode", title: "Xcode", kind: .category(.developer),
                                claims: [Claim(path: AppPaths.join(lib, "Developer"), size: size, covering: true)]))
        }
        let backups = findings.filter { $0.classification.category == .backups && $0.classification.source == .rule }
        if !backups.isEmpty {
            drafts.append(Draft(id: "backups", title: "iPhone backups", kind: .category(.backups), claims: backups.map(claim)))
        }
        let trash = findings.filter { $0.classification.ruleID == "trash" }
        if !trash.isEmpty {
            drafts.append(Draft(id: "trash", title: "Trash", kind: .folder(path: AppPaths.join(home, ".Trash")), claims: trash.map(claim)))
        }
        var cacheClaims: [Claim] = []
        if let size = treeSize(AppPaths.join(lib, "Caches")) {
            cacheClaims.append(Claim(path: AppPaths.join(lib, "Caches"), size: size, covering: true))
        }
        cacheClaims += findings.filter {
            $0.classification.category == .caches && $0.classification.source == .rule && $0.classification.ruleID != "trash"
        }.map(claim)
        if !cacheClaims.isEmpty {
            drafts.append(Draft(id: "caches", title: "Caches", kind: .category(.caches), claims: cacheClaims))
        }

        // 5. User folders.
        for name in userFolders {
            let path = AppPaths.join(home, name)
            if let size = treeSize(path) {
                drafts.append(Draft(id: "folder:\(path)", title: name, kind: .folder(path: path),
                                    claims: [Claim(path: path, size: size, covering: true)]))
            }
        }

        // 6. macOS (whole-disk scans).
        let system = findings.filter { $0.classification.category == .system && !AppPaths.isInside($0.path, home) }
        if !system.isEmpty {
            drafts.append(Draft(id: "system", title: "macOS & system files", kind: .category(.system), claims: system.map(claim)))
        }

        // Claim bytes in priority order.
        var ledger = ClaimLedger()
        for i in drafts.indices {
            drafts[i].bytes = drafts[i].claims.reduce(0) { $0 + ledger.claim($1) }
        }

        // Safe / check bytes from findings, attributed to the first tile whose claims contain them.
        var otherSafe: Int64 = 0, otherCheck: Int64 = 0
        for f in findings {
            let c = f.classification
            if let id = c.ruleID, bundleRuleIDs.contains(id) { continue }
            let isSafe = c.label == .safe && c.source == .rule
            guard isSafe || c.label == .review else { continue }
            let bytes = index.exclusiveBytes(f)
            guard bytes > 0 else { continue }
            guard let i = drafts.firstIndex(where: { d in d.claims.contains { AppPaths.isInside(f.path, $0.path) } }) else {
                if isSafe { otherSafe += bytes } else { otherCheck += bytes }
                continue
            }
            // App tiles count their own related items (already in `safe`/`check`); bundles are never "to check".
            if let app = drafts[i].app,
               AppPaths.isInside(f.path, app.path) || app.relatedRoots.contains(where: { AppPaths.isInside(f.path, $0.path) }) { continue }
            if drafts[i].bundlesOnly { continue }
            if isSafe { drafts[i].safe += bytes } else { drafts[i].check += bytes }
        }

        // Pick the visible tiles; everything else folds into "Everything else".
        let outside = installed.filter { !AppPaths.isInside($0.path, root.path) }.reduce(Int64(0)) { $0 + $1.appBytes }
        let total = root.size + outside
        let minVisible = max(1, total / 200)
        let ranked = drafts.filter { $0.bytes >= minVisible }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
        let visible = Array(ranked.prefix(max(0, limit)))
        let visibleIDs = Set(visible.map(\.id))
        for d in drafts where !visibleIDs.contains(d.id) {
            otherSafe += d.safe
            otherCheck += d.check
        }
        var tiles = visible.map { $0.tile }
        let otherBytes = max(0, total - visible.reduce(0) { $0 + $1.bytes })
        let safe = min(otherSafe, otherBytes)
        tiles.append(SpaceTile(id: "other", title: "Everything else", subtitle: nil, kind: .other, bytes: otherBytes,
                               safeBytes: safe, checkBytes: min(otherCheck, otherBytes - safe)))
        return tiles
    }

    static func isCodeProject(_ title: String) -> Bool {
        title == "Code projects" || title.hasPrefix("Code project: ") || title.hasPrefix("Part of code project: ")
    }

    private static func largest(_ items: [Finding]) -> String {
        items.max { $0.size != $1.size ? $0.size < $1.size : $0.path > $1.path }?.path ?? ""
    }

    /// "142 apps · 9 not opened this year" (the second part only when Spotlight knows when apps were last opened).
    static func appsSubtitle(_ apps: [InstalledApp], now: Date) -> String {
        let count = apps.count == 1 ? "1 app" : "\(apps.count) apps"
        let known = apps.compactMap(\.lastOpened)
        guard !known.isEmpty else { return count }
        let stale = known.filter { now.timeIntervalSince($0) > 365 * 86_400 }.count
        return "\(count) · \(stale) not opened this year"
    }

    struct Claim {
        let path: String
        let size: Int64
        /// True when the claim takes everything inside `path`; false for a rule's "remainder" finding whose nested
        /// findings are separate.
        let covering: Bool
    }

    private struct Draft {
        let id: String
        let title: String
        var subtitle: String?
        let kind: SpaceTile.Kind
        let claims: [Claim]
        var app: InstalledApp?
        var bundlesOnly = false
        var bytes: Int64 = 0
        var safe: Int64 = 0
        var check: Int64 = 0

        init(id: String, title: String, kind: SpaceTile.Kind, claims: [Claim]) {
            self.id = id; self.title = title; self.kind = kind; self.claims = claims
        }

        var tile: SpaceTile {
            let s = min(safe, bytes)
            return SpaceTile(id: id, title: title, subtitle: subtitle, kind: kind, bytes: bytes,
                             safeBytes: s, checkBytes: min(check, bytes - s))
        }
    }

    /// Hands out bytes so no byte is claimed twice. Each entry records the bytes claimed at or under its path.
    struct ClaimLedger {
        private var entries: [(path: String, bytes: Int64, covering: Bool)] = []

        /// Bytes newly claimed: the claim's size minus what earlier claims already took inside it.
        mutating func claim(_ c: Claim) -> Int64 {
            if entries.contains(where: { $0.path == c.path || ($0.covering && AppPaths.isInside(c.path, $0.path)) }) { return 0 }
            let inner = entries.filter { AppPaths.isStrictlyInside($0.path, c.path) && (c.covering || $0.covering) }
            let taken = inner.reduce(0) { $0 + $1.bytes }
            let bytes = max(0, c.size - taken)
            if c.covering {
                entries.removeAll { AppPaths.isStrictlyInside($0.path, c.path) }
                entries.append((c.path, bytes + taken, true))
            } else {
                entries.append((c.path, bytes, false))
            }
            return bytes
        }
    }
}
