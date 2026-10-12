import Foundation

/// An app installed in /Applications or ~/Applications, with the data it keeps elsewhere.
public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String?
    public let version: String?
    /// Allocated size of the .app bundle.
    public let appBytes: Int64
    /// From Spotlight (kMDItemLastUsedDate); nil when unknown.
    public let lastOpened: Date?
    public let isAppleApp: Bool
    /// False for apps Freespan won't remove (macOS apps, protected paths); see `uninstallBlockedReason`.
    public let canUninstall: Bool
    public let uninstallBlockedReason: String?
    /// The app's data outside its bundle (caches, support files, containers, preferences, logs…), each classified.
    public let related: [Finding]

    public init(path: String, name: String, bundleID: String?, version: String?, appBytes: Int64, lastOpened: Date?,
                isAppleApp: Bool, canUninstall: Bool, uninstallBlockedReason: String?, related: [Finding]) {
        self.path = path; self.name = name; self.bundleID = bundleID; self.version = version; self.appBytes = appBytes
        self.lastOpened = lastOpened; self.isAppleApp = isAppleApp; self.canUninstall = canUninstall
        self.uninstallBlockedReason = uninstallBlockedReason; self.related = related
    }

    public var dataBytes: Int64 { related.reduce(0) { $0 + $1.size } }
    public var totalBytes: Int64 { appBytes + dataBytes }
    /// What "Remove Extras" clears: related items labelled Safe by a rule (they come back on their own).
    public var extras: [Finding] { related.filter { $0.classification.label == .safe && $0.classification.source == .rule } }
    public var extrasBytes: Int64 { extras.reduce(0) { $0 + $1.size } }
}

/// Data left behind by an app that is no longer installed.
public struct Leftover: Sendable, Identifiable, Hashable {
    public var id: String { bundleID ?? ownerName }
    public let ownerName: String
    public let bundleID: String?
    public let items: [Finding]
    public var bytes: Int64 { items.reduce(0) { $0 + $1.size } }

    public init(ownerName: String, bundleID: String?, items: [Finding]) {
        self.ownerName = ownerName; self.bundleID = bundleID; self.items = items
    }
}

public struct AppInventoryResult: Sendable {
    /// Largest total first.
    public let apps: [InstalledApp]
    public let leftovers: [Leftover]
    public let builtAt: Date

    public init(apps: [InstalledApp], leftovers: [Leftover], builtAt: Date) {
        self.apps = apps; self.leftovers = leftovers; self.builtAt = builtAt
    }
}


/// Facts read from one .app bundle. Internal so tests can build inventories without real apps.
struct AppRecord: Sendable {
    var path: String
    var name: String
    var bundleID: String?
    /// CFBundleName, e.g. "Code" for Visual Studio Code (apps often name their data folder after it).
    var bundleName: String?
    var version: String?
    var appBytes: Int64
    var lastOpened: Date?
}

/// Finds installed apps, sizes them, and attaches their data from the home scan. OWNER: apps-kit agent.
///
/// Everything here is read-only. Related data is matched conservatively:
/// - by bundle ID in ~/Library/{Application Support, Caches, Containers, Saved Application State, WebKit, Logs,
///   Application Scripts}, `LaunchAgents/<bundleID>*.plist`, and Group Containers whose ID contains the bundle ID
///   (or a shorter `group.` ID no other installed app shares);
/// - by app name (display name or CFBundleName) in Application Support and Logs;
/// - by the `owner` field of KnownLocations.json (Chrome profiles, Claude's VM, Xcode's ~/Library/Developer data).
/// A folder claimed by more than one app, or containing another app's folder, is attached to none. Protected
/// paths (`ProtectedPaths`: ~/Library/Preferences, HTTPStorages, Apple containers, ...) are never attached.
///
/// Inside each attached folder, the rule findings and identified locations are listed separately (e.g. Claude's
/// "Claude virtual machine" (Review) and "App web cache" (Safe)), and the folder itself carries the remaining bytes.
/// Sizes are therefore disjoint: `dataBytes` never counts a byte twice.
///
/// Related data comes from `homeScan`; without one, apps are listed with their bundle size only.
public struct AppInventory: Sendable {
    static let freespanBundleID = "com.mcconnelldigital.Freespan"
    /// Leftover folders smaller than this are not reported.
    static let minLeftoverBytes: Int64 = 1_000_000
    /// ~/Library folders where apps keep per-app data, by lowercased name.
    static let libraryRoots = [
        "application support", "caches", "containers", "group containers", "saved application state", "webkit",
        "logs", "application scripts",
    ]
    /// App-owned paths not covered by KnownLocations.json (they sit inside a folder a rule matches as a whole).
    static let extraOwnedPaths: [String: [String]] = [
        "com.google.chrome": ["~/Library/Caches/Google/Chrome"],
        "com.google.chrome.beta": ["~/Library/Caches/Google/Chrome Beta"],
        "com.google.chrome.canary": ["~/Library/Caches/Google/Chrome Canary"],
    ]

    typealias DirectoryLister = @Sendable (String) -> [(name: String, bytes: Int64)]

    let appFolders: [String]?
    let directory: AppDirectory
    let catalog: KnownLocationCatalog
    let listDirectory: DirectoryLister

    public init() {
        self.init(appFolders: nil, directory: .shared)
    }

    /// `appFolders` defaults to /Applications and ~/Applications. `listDirectory` lists small files (name,
    /// allocated bytes) the scan rolls up, e.g. LaunchAgents plists.
    init(appFolders: [String]?, directory: AppDirectory, catalog: KnownLocationCatalog = .bundled,
         listDirectory: @escaping DirectoryLister = AppInventory.listFiles) {
        self.appFolders = appFolders
        self.directory = directory
        self.catalog = catalog
        self.listDirectory = listDirectory
    }

    /// `homeScan`/`findings` are the latest home (or whole-disk) scan results; the app bundles themselves are sized
    /// by this call (a home scan doesn't include /Applications). Read-only.
    public func inventory(homeScan: ScanResult?, findings: [Finding], home: String = NSHomeDirectory()) async throws -> AppInventoryResult {
        let home = ProtectedPaths.normalize(home) ?? home
        let folders = appFolders ?? ["/Applications", AppPaths.join(home, "Applications")]
        let bundles = Self.discoverBundles(in: folders)
        try Task.checkCancellation()
        let sizes = await Self.bundleSizes(bundles, folders: folders, tree: homeScan?.root)
        try Task.checkCancellation()
        let records = bundles.map { Self.readRecord(path: $0, appBytes: sizes[$0] ?? 0) }
        try Task.checkCancellation()
        return assemble(records: records, tree: homeScan?.root, findings: findings, home: home)
    }

    /// Everything "Uninstall" moves to the Trash: the app bundle (as a Finding) followed by all related items
    /// that are not protected. Empty when `canUninstall` is false.
    public static func uninstallItems(for app: InstalledApp) -> [Finding] {
        uninstallItems(for: app, home: NSHomeDirectory())
    }

    /// Same as `uninstallItems(for:)` for an explicit home folder. Items nested in another item are folded into
    /// it (its size includes theirs), so nothing is moved twice. Order: the bundle, then data largest first.
    public static func uninstallItems(for app: InstalledApp, home: String) -> [Finding] {
        guard app.canUninstall, !ProtectedPaths.isProtected(app.path, home: home) else { return [] }
        let bundle = Finding(
            path: app.path, name: (app.path as NSString).lastPathComponent, size: app.appBytes, itemCount: 1,
            modified: nil, accessed: nil, isDirectory: true,
            classification: Classification(
                category: .applications, label: .review, title: "\(app.name) app",
                explanation: "The app itself. Moving it to the Trash uninstalls it.",
                regenerates: false, source: .rule, ruleID: "application"))
        let candidates = app.related
            .filter { !ProtectedPaths.isProtected($0.path, home: home) && !AppPaths.isInside($0.path, app.path) }
            .sorted { $0.path.count < $1.path.count }
        var outer: [Finding] = []
        for item in candidates {
            if let i = outer.firstIndex(where: { AppPaths.isInside(item.path, $0.path) }) {
                let o = outer[i]
                outer[i] = Finding(path: o.path, name: o.name, size: o.size + item.size, itemCount: o.itemCount + item.itemCount,
                                   modified: o.modified, accessed: o.accessed, isDirectory: o.isDirectory,
                                   classification: o.classification)
            } else {
                outer.append(item)
            }
        }
        outer.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        return [bundle] + outer
    }

    // MARK: - Finding and sizing bundles

    /// `.app` bundles directly in each folder or one subfolder down. /Applications/Utilities (Apple's) and
    /// symbolic links are skipped.
    static func discoverBundles(in folders: [String]) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = AppPaths.join(folder, name)
                if isSymlink(path) { continue }
                if name.lowercased().hasSuffix(".app") { out.append(path); continue }
                if folder == "/Applications" && name.lowercased() == "utilities" { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                for sub in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
                where !sub.hasPrefix(".") && sub.lowercased().hasSuffix(".app") {
                    let subPath = AppPaths.join(path, sub)
                    if !isSymlink(subPath) { out.append(subPath) }
                }
            }
        }
        return out
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    /// Allocated size of each bundle: reused from `tree` when it contains the bundle (whole-disk scan), otherwise
    /// measured with one `DiskScanner` pass per app folder (the scanner's bounded worker pool walks bundles in
    /// parallel; both folders run concurrently).
    static func bundleSizes(_ bundles: [String], folders: [String], tree: FileNode?) async -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        var missing: [String] = []
        for b in bundles {
            if let tree, let node = AppPaths.node(at: b, in: tree) { sizes[b] = node.size } else { missing.append(b) }
        }
        guard !missing.isEmpty else { return sizes }
        let roots = folders.filter { f in missing.contains { AppPaths.isStrictlyInside($0, f) } }
        let trees = await withTaskGroup(of: FileNode?.self) { group in
            for root in roots { group.addTask { await scanFolder(root) } }
            var out: [FileNode] = []
            for await t in group { if let t { out.append(t) } }
            return out
        }
        for b in missing {
            sizes[b] = trees.lazy.compactMap { AppPaths.node(at: b, in: $0) }.first?.size ?? 0
        }
        return sizes
    }

    private static func scanFolder(_ path: String) async -> FileNode? {
        var options = ScanOptions()
        options.individualFileThreshold = 1 << 50 // only folders and bundles get nodes
        do {
            for try await event in DiskScanner(options: options).scan(root: URL(fileURLWithPath: path, isDirectory: true)) {
                if case .finished(let result) = event { return result.root }
            }
        } catch {}
        return nil
    }

    static func readRecord(path: String, appBytes: Int64) -> AppRecord {
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any]
            ?? Bundle(path: path)?.infoDictionary ?? [:]
        var name = FileManager.default.displayName(atPath: path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        if name.isEmpty { name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        return AppRecord(
            path: path, name: name,
            bundleID: (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            bundleName: (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            version: info["CFBundleShortVersionString"] as? String,
            appBytes: appBytes,
            lastOpened: Spotlight.read(path).lastUsed)
    }

    static func listFiles(_ dir: String) -> [(name: String, bytes: Int64)] {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (u.lastPathComponent, Int64(v.totalFileAllocatedSize ?? 0))
        }
    }

    /// Why Freespan won't uninstall this app, or nil when it can.
    static func uninstallBlockedReason(path: String, name: String, bundleID: String?, home: String) -> String? {
        if bundleID?.lowercased() == freespanBundleID.lowercased() || path == Bundle.main.bundlePath {
            return "This is Freespan itself."
        }
        if path.hasPrefix("/System/") || ProtectedPaths.isProtected(path, home: home) {
            return bundleID?.lowercased().hasPrefix("com.apple.") == true
                ? "\(name) is part of macOS, so it can't be removed."
                : "macOS protects this app, so Freespan can't remove it."
        }
        return nil
    }

    // MARK: - Related data and leftovers

    /// Group container `folder` (original case, so team IDs are recognised) belongs to the app `bid` (lowercased): its ID contains the bundle ID,
    /// or it is a shorter `group.`/team ID (`group.com.docker` for `com.docker.docker`) no other installed app shares.
    static func groupContainer(_ folder: String, matches bid: String, installedIDs: [String]) -> Bool {
        let (core, stripped) = BundleID.stripPrefixes(folder)
        let c = core.lowercased()
        if c == bid || c.hasPrefix(bid + ".") { return true }
        guard stripped, bid.hasPrefix(c + "."), c.split(separator: ".").count >= 2,
              !LibraryOwnership.isAppleOwned(folder) else { return false }
        return !installedIDs.contains { $0 != bid && ($0 == c || $0.hasPrefix(c + ".")) }
    }


    func assemble(records: [AppRecord], tree: FileNode?, findings: [Finding], home rawHome: String) -> AppInventoryResult {
        let home = ProtectedPaths.normalize(rawHome) ?? rawHome
        let ctx = RelatedContext(home: home, tree: tree, findings: findings, catalog: catalog, directory: directory,
                                 listDirectory: listDirectory)
        let installedIDs = records.compactMap { $0.bundleID?.lowercased() }

        // 1. Candidate folders per app, then drop anything shared between apps.
        var roots = records.map { ctx.roots(for: $0, installedIDs: installedIDs) }
        var claimants: [String: Set<Int>] = [:]
        for (i, rs) in roots.enumerated() { for r in rs { claimants[r.path, default: []].insert(i) } }
        for i in roots.indices {
            roots[i] = roots[i].filter { r in
                guard claimants[r.path]?.count == 1 else { return false }
                // A folder containing another app's folder is shared.
                return !claimants.contains { path, owners in
                    AppPaths.isStrictlyInside(path, r.path) && owners != [i]
                }
            }
            // Outermost only within one app.
            let paths = roots[i].map(\.path)
            roots[i] = roots[i].filter { r in !paths.contains { AppPaths.isStrictlyInside(r.path, $0) } }
        }

        // 2. Related findings per app.
        var apps: [InstalledApp] = []
        var claimed: [String] = []
        for (i, rec) in records.enumerated() {
            var related: [Finding] = []
            for root in roots[i] {
                guard let items = ctx.relatedItems(root: root, appName: rec.name) else { continue }
                related += items
                claimed.append(root.path)
            }
            related.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
            let reason = Self.uninstallBlockedReason(path: rec.path, name: rec.name, bundleID: rec.bundleID, home: home)
            apps.append(InstalledApp(
                path: rec.path, name: rec.name, bundleID: rec.bundleID, version: rec.version, appBytes: rec.appBytes,
                lastOpened: rec.lastOpened, isAppleApp: rec.bundleID?.lowercased().hasPrefix("com.apple.") ?? false,
                canUninstall: reason == nil, uninstallBlockedReason: reason, related: related))
        }
        apps.sort { $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.name < $1.name }

        let leftovers = ctx.leftovers(records: records, claimed: claimed)
        return AppInventoryResult(apps: apps, leftovers: leftovers, builtAt: Date())
    }
}

/// Matching an app's data in ~/Library against the scan tree.
private struct RelatedContext {
    struct Root {
        let path: String
        /// Nil for small files the scan rolled up (sized by `listDirectory`).
        let node: FileNode?
        let fileBytes: Int64
    }

    private struct Candidate {
        let path: String
        let node: FileNode?
        let size: Int64
        let classification: Classification
        /// A rule finding: its bytes never overlap another finding's, so they count as-is.
        var isRule = false
    }

    let home: String
    let lib: String
    let tree: FileNode?
    let index: FindingIndex
    let catalog: KnownLocationCatalog
    let directory: AppDirectory
    let listDirectory: AppInventory.DirectoryLister
    let engine: RuleEngine?
    let identifier: ItemIdentifier
    /// Lowercased ~/Library root name → its children by lowercased name.
    let libIndex: [String: [String: FileNode]]

    init(home: String, tree: FileNode?, findings: [Finding], catalog: KnownLocationCatalog, directory: AppDirectory,
         listDirectory: @escaping AppInventory.DirectoryLister) {
        self.home = home
        self.lib = AppPaths.join(home, "Library")
        self.tree = tree
        self.index = FindingIndex(findings)
        self.catalog = catalog
        self.directory = directory
        self.listDirectory = listDirectory
        self.engine = try? RuleEngine.bundled()
        self.identifier = ItemIdentifier(catalog: catalog, apps: directory)
        var libIndex: [String: [String: FileNode]] = [:]
        if let tree {
            let libChildren = AppPaths.childIndex(AppPaths.node(at: lib, in: tree))
            for root in AppInventory.libraryRoots { libIndex[root] = AppPaths.childIndex(libChildren[root]) }
        }
        self.libIndex = libIndex
    }

    // MARK: Candidate folders

    func roots(for rec: AppRecord, installedIDs: [String]) -> [Root] {
        guard tree != nil else { return [] }
        var out: [String: Root] = [:]
        let isApple = rec.bundleID?.lowercased().hasPrefix("com.apple.") ?? false
        func add(_ root: String, _ key: String) {
            guard let node = libIndex[root]?[key.lowercased()] else { return }
            out[node.path] = Root(path: node.path, node: node, fileBytes: 0)
        }
        if let bid = rec.bundleID {
            let b = bid.lowercased()
            for root in ["application support", "caches", "containers", "webkit", "logs", "application scripts"] { add(root, bid) }
            add("saved application state", bid + ".savedState")
            for node in (libIndex["group containers"] ?? [:]).values
            where AppInventory.groupContainer((node.path as NSString).lastPathComponent, matches: b, installedIDs: installedIDs) {
                out[node.path] = Root(path: node.path, node: node, fileBytes: 0)
            }
            let agents = AppPaths.join(lib, "LaunchAgents")
            for file in listDirectory(agents) {
                let n = file.name.lowercased()
                guard n.hasPrefix(b), n.hasSuffix(".plist") else { continue }
                let path = AppPaths.join(agents, file.name)
                out[path] = Root(path: path, node: tree.flatMap { AppPaths.node(at: path, in: $0) }, fileBytes: file.bytes)
            }
            var owned = catalog.locations.filter { $0.owner?.lowercased() == b }.flatMap { $0.paths ?? [] }
            owned += AppInventory.extraOwnedPaths[b] ?? []
            for raw in owned where raw.hasPrefix("~/") && !raw.contains("*") {
                let path = home + raw.dropFirst()
                if let tree, let node = AppPaths.node(at: path, in: tree) {
                    out[node.path] = Root(path: node.path, node: node, fileBytes: 0)
                }
            }
        }
        var names: [String] = []
        for n in [rec.name, rec.bundleName].compactMap({ $0 }) where !n.isEmpty && !names.contains(n) { names.append(n) }
        for name in names where isApple || !LibraryOwnership.isAppleOwned(name) {
            add("application support", name)
            add("logs", name)
        }
        return out.values
            .filter { !ProtectedPaths.isProtected($0.path, home: home) }
            .sorted { $0.path < $1.path }
    }

    // MARK: Items inside one folder

    /// The findings for one attached folder: rule findings and identified locations inside it, plus the folder
    /// itself with the remaining bytes. Nil when the folder must not be attached (something protected inside).
    func relatedItems(root: Root, appName: String) -> [Finding]? {
        guard let node = root.node else {
            let c = index.exact(root.path)?.classification ?? fileClassification(root.path, app: appName)
            guard root.fileBytes > 0 else { return [] }
            return [Finding(path: root.path, name: (root.path as NSString).lastPathComponent, size: root.fileBytes,
                            itemCount: 1, modified: nil, accessed: nil, isDirectory: false, classification: c)]
        }
        var cands: [String: Candidate] = [:]
        for f in engine?.findings(in: node, home: home) ?? [] {
            cands[f.path] = Candidate(path: f.path, node: nil, size: f.size, classification: f.classification, isRule: true)
        }
        // Existing findings win so labels match the rest of the app.
        for f in index.within(root.path) {
            cands[f.path] = Candidate(path: f.path, node: nil, size: f.size, classification: f.classification,
                                      isRule: f.classification.source == .rule)
        }
        if cands[root.path] == nil {
            cands[root.path] = Candidate(path: root.path, node: node, size: node.size,
                                         classification: folderClassification(node, app: appName))
        }
        if cands[root.path]?.isRule != true {
            let rulePaths = cands.values.filter(\.isRule).map(\.path)
            addKnownLocations(below: node, depth: 0, into: &cands,
                              covered: { p in rulePaths.contains { AppPaths.isInside(p, $0) } })
        }
        if cands.keys.contains(where: { ProtectedPaths.isProtected($0, home: home) }) { return nil }

        let all = Array(cands.values)
        var out: [Finding] = []
        for c in all {
            var bytes = c.size
            if !c.isRule {
                let inner = all.filter { AppPaths.isStrictlyInside($0.path, c.path) }
                let direct = inner.filter { y in
                    !inner.contains { w in !w.isRule && AppPaths.isStrictlyInside(y.path, w.path) }
                }
                bytes -= direct.reduce(0) { $0 + $1.size }
            }
            guard bytes > 0 else { continue }
            let n = c.node ?? (c.path == node.path ? node : AppPaths.node(at: c.path, in: node))
            out.append(Finding(path: c.path, name: n?.name ?? (c.path as NSString).lastPathComponent, size: bytes,
                               itemCount: n?.itemCount ?? 1, modified: n?.modified, accessed: n?.accessed,
                               isDirectory: n.map { $0.kind != .file } ?? true, classification: c.classification))
        }
        return out
    }

    /// Folders up to three levels below `node` that the known-locations table names exactly (e.g. Claude's
    /// vm_bundles), classified by `ItemIdentifier`.
    private func addKnownLocations(below node: FileNode, depth: Int, into cands: inout [String: Candidate],
                                   covered: (String) -> Bool) {
        guard depth < 3, node.kind == .directory else { return }
        let homeSegs = PathSegments.split(home)
        for child in node.children where child.kind == .directory || child.kind == .package {
            if cands[child.path] == nil, !covered(child.path),
               catalog.location(for: PathSegments.split(child.path), home: homeSegs)?.exact == true,
               let c = identifier.identify(child, home: home) {
                cands[child.path] = Candidate(path: child.path, node: child, size: child.size, classification: c)
            }
            if !covered(child.path) { addKnownLocations(below: child, depth: depth + 1, into: &cands, covered: covered) }
        }
    }

    /// Classification for an attached folder no finding covers exactly.
    private func folderClassification(_ node: FileNode, app: String) -> Classification {
        // A folder inside something a rule calls Safe as a whole (e.g. ~/Library/Logs/<app>) is Safe too.
        var dir = (node.path as NSString).deletingLastPathComponent
        while AppPaths.isStrictlyInside(dir, lib) {
            if let tree, let ancestor = AppPaths.node(at: dir, in: tree),
               let c = index.exact(dir)?.classification ?? engine?.classify(ancestor, home: home),
               c.label == .safe, c.source == .rule {
                return c
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        let parent = ((node.path as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
        let n = "\(app)"
        switch parent {
        case "saved application state":
            return Self.make(.review, "\(n) saved windows",
                             "Window positions macOS restores when you reopen \(n). Removing it just means \(n) opens with fresh windows.",
                             regenerates: true)
        case "application scripts":
            return Self.make(.review, "\(n) scripts",
                             "Scripts \(n) is allowed to run. They're only needed while \(n) is installed.", regenerates: false)
        default:
            break
        }
        if let c = identifier.identify(node, home: home), c.title != "App data" { return c }
        return Self.make(.keep, "\(n) app data",
                         "Settings, documents and other data \(n) keeps for itself. Removing it can reset the app or lose things you made in it, so manage it from inside \(n).",
                         regenerates: false)
    }

    private func fileClassification(_ path: String, app: String) -> Classification {
        if (path as NSString).deletingLastPathComponent.lowercased().hasSuffix("/library/launchagents") {
            return Self.make(.review, "\(app) login item",
                             "Starts a helper for \(app) when you log in. It's only needed while \(app) is installed.",
                             regenerates: false)
        }
        return Self.make(.review, "\(app) file", "A file \(app) keeps for itself. It's only needed while \(app) is installed.",
                         regenerates: false)
    }

    static func make(_ label: SafetyLabel, _ title: String, _ explanation: String, regenerates: Bool) -> Classification {
        Classification(category: .applications, label: label, title: title, explanation: explanation,
                       regenerates: regenerates, source: .heuristic, ruleID: nil)
    }

    // MARK: Leftovers

    /// Folders named after an app ID that no installed app has, grouped by that ID. Apple IDs, protected paths,
    /// folders attached to an installed app and anything under 1 MB are skipped.
    func leftovers(records: [AppRecord], claimed: [String]) -> [Leftover] {
        let installedIDs = records.compactMap { $0.bundleID?.lowercased() }
        let installedNames = Set(records.flatMap { [$0.name, $0.bundleName] }.compactMap { $0?.lowercased() })
        var groups: [String: [(finding: Finding, guess: String)]] = [:]
        for root in AppInventory.libraryRoots where root != "logs" {
            for (_, node) in (libIndex[root] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard node.size >= AppInventory.minLeftoverBytes,
                      !claimed.contains(where: { AppPaths.isInside(node.path, $0) || AppPaths.isInside($0, node.path) }),
                      !ProtectedPaths.isProtected(node.path, home: home) else { continue }
                var folder = (node.path as NSString).lastPathComponent
                if root == "saved application state" {
                    guard folder.lowercased().hasSuffix(".savedstate") else { continue }
                    folder = String(folder.dropLast(".savedState".count))
                }
                guard !LibraryOwnership.isAppleOwned(folder), BundleID.parse(folder) != nil,
                      case .missing(let guess, let core) = directory.owner(ofFolderNamed: folder) else { continue }
                let c = core.lowercased()
                guard !installedIDs.contains(where: { $0 == c || $0.hasPrefix(c + ".") || c.hasPrefix($0 + ".") }),
                      !installedNames.contains(guess.lowercased()) else { continue }
                let classification = index.exact(node.path)?.classification
                    ?? engine?.classify(node, home: home)
                    ?? identifier.identify(node, home: home)
                    ?? Self.make(.review, "Leftover data from \(guess) (app not installed)",
                                 "Data stored by an app with the ID “\(core)”. No app with that ID is installed, so it appears to have been left behind.",
                                 regenerates: false)
                groups[c, default: []].append((Finding(node: node, classification: classification), guess))
            }
        }
        // Fold a shorter group ID into the one longer ID it prefixes (group.com.docker → com.docker.docker).
        for key in groups.keys.sorted(by: { $0.count < $1.count }) {
            let longer = groups.keys.filter { $0.hasPrefix(key + ".") }
            if longer.count == 1, let items = groups[key] {
                groups[longer[0], default: []] += items
                groups[key] = nil
            }
        }
        return groups.map { key, items in
            let sorted = items.sorted { $0.finding.size != $1.finding.size ? $0.finding.size > $1.finding.size : $0.finding.path < $1.finding.path }
            return Leftover(ownerName: sorted[0].guess, bundleID: key, items: sorted.map(\.finding))
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : ($0.bundleID ?? "") < ($1.bundleID ?? "") }
    }
}

extension InstalledApp {
    /// Outermost related folders with the bytes of everything attached inside them (for exclusive accounting).
    var relatedRoots: [(path: String, bytes: Int64)] {
        AppPaths.outermost(related.map { ($0.path, $0.size) })
    }
}
