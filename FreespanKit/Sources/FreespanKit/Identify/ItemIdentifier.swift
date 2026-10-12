import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Names things without AI: app-ID folder names → app name, known vendor folders, Spotlight kind/where-from,
/// and file types. Used on items no rule explains, before (or instead of) any assistant. OWNER: identify agent.
///
/// Everything here is local (Launch Services, Spotlight's on-disk metadata, a bundled table, and a few
/// `FileManager` checks for project marker files). Results are advisory: the label is never `.safe` (only
/// built-in rules can say that), and anything in a location `ProtectedPaths` refuses is capped at `.keep`.
public struct ItemIdentifier: Sendable {
    private let catalog: KnownLocationCatalog
    private let apps: AppDirectory
    private let now: @Sendable () -> Date

    public init() {
        self.init(catalog: .bundled, apps: .shared)
    }

    init(catalog: KnownLocationCatalog, apps: AppDirectory, now: @escaping @Sendable () -> Date = { Date() }) {
        self.catalog = catalog
        self.apps = apps
        self.now = now
    }

    /// Classification with `source: .heuristic` and a label of at most `.review`, or nil if nothing is known.
    /// Never nil for anything inside ~/Library: what it can't name there is "App data" (Keep), so ~/Library
    /// items never need an assistant.
    public func identify(_ node: FileNode, home: String) -> Classification? {
        guard node.kind != .smallFiles,
              let path = ProtectedPaths.normalize(node.path), path != "/",
              let homePath = ProtectedPaths.normalize(home), homePath != "/" else { return nil }
        let ctx = Context(node: node, path: path, home: homePath)
        guard let raw = identifyRaw(ctx) else { return nil }
        return Self.capped(raw, path: path, home: homePath)
    }

    // MARK: - Pipeline

    private struct Context {
        let node: FileNode
        let path: String
        let home: String
        /// Lowercased components of `path` and `home`.
        let segments: [String]
        let homeSegments: [String]
        /// Original-case components below home (empty when outside home).
        let rel: [String]
        let ext: String

        init(node: FileNode, path: String, home: String) {
            self.node = node
            self.path = path
            self.home = home
            segments = PathSegments.split(path)
            homeSegments = PathSegments.split(home)
            let inHome = segments.count > homeSegments.count && Array(segments.prefix(homeSegments.count)) == homeSegments
            let original = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            rel = inHome ? Array(original.dropFirst(homeSegments.count)) : []
            ext = (path as NSString).pathExtension.lowercased()
        }

        var inHome: Bool { !rel.isEmpty }
        var name: String { (path as NSString).lastPathComponent }
        var isFileLike: Bool { node.kind == .file || node.kind == .package }
    }

    private func identifyRaw(_ ctx: Context) -> Classification? {
        if let (entry, _) = catalog.location(for: ctx.segments, home: ctx.homeSegments) {
            return make(entry.category, entry.label, entry.title, entry.explanation, regenerates: entry.regenerates)
        }
        if ctx.inHome, ctx.rel.count >= 3, ctx.rel[0].lowercased() == "library",
           let root = LibraryRoot(rawValue: ctx.rel[1].lowercased()),
           let c = libraryItem(ctx, root: root) {
            return c
        }
        if ctx.inHome, ctx.rel[0].lowercased() == "library" { return libraryFallback(ctx) }
        if ctx.isFileLike { return fileItem(ctx) }
        guard ctx.inHome else { return nil }
        let top = ctx.rel[0]
        if top.hasPrefix(".") { return hiddenToolFolder(top) }
        if let c = codeProject(ctx) { return c }
        return make(.other, .keep, "Your files",
                    "Files in your “\(top)” folder that aren't caches or app data, so Freespan treats them as yours and keeps them. Look through them in Finder if you want to free space.",
                    regenerates: false)
    }

    // MARK: - ~/Library app folders

    private enum LibraryRoot: String {
        case applicationSupport = "application support"
        case containers
        case groupContainers = "group containers"
        case caches
        case httpStorages = "httpstorages"
        case webKit = "webkit"
        case savedState = "saved application state"
        case logs
    }


    private static let cacheNames: Set<String> = [
        "cache", "caches", "code cache", "gpucache", "cacheddata", "cache_data", "cachestorage", "shadercache",
        "grshadercache", "dawncache", "component_crx_cache", "crx_cache", "webkitcache", "blob_storage",
    ]
    private static let tempNames: Set<String> = ["tmp", "temp", "temporary items", "temporaryitems"]
    private static let logNames: Set<String> = ["logs", "log", "crashpad", "crash reports", "crashreports"]
    private static let modelNames: Set<String> = ["models", "model"]

    private func libraryItem(_ ctx: Context, root: LibraryRoot) -> Classification? {
        let folder = ctx.rel[2]
        let rest = ctx.rel.dropFirst(3).map { $0.lowercased() }
        let owner = LibraryOwnership.appleFolders.contains(folder.lowercased())
            ? AppDirectory.Owner.system(guess: folder, bundleID: folder)
            : apps.owner(ofFolderNamed: folder)

        let appName: String
        switch owner {
        case .installed(let name, _): appName = name
        case .missing(let guess, let id):
            return make(.applications, .review, "Leftover data from \(guess) (app not installed)",
                        "Data stored by an app with the ID “\(id)”. No app with that ID is installed, so the app appears to have been uninstalled and left this behind. Look inside first; if you don't use \(guess) any more, it can go.",
                        regenerates: false)
        case .system(let guess, _):
            return make(.system, .keep, "macOS data (\(guess))",
                        "Data kept by a part of macOS. macOS manages it, so Freespan leaves it alone.",
                        regenerates: false)
        case .unknown(let name):
            // Plain folder names only count as app data where apps keep it.
            guard root == .applicationSupport || root == .containers || root == .groupContainers else { return nil }
            if let sub = subKind(ctx, root: root, rest: rest) { return subItem(sub, app: name, ctx: ctx) }
            return make(.applications, .review, "\(name) app data",
                        "Data stored by \(name). Freespan couldn't find an app with that name, so it may be left over from something you removed, or belong to a helper or command-line tool. Check before removing.",
                        regenerates: false)
        }
        if let sub = subKind(ctx, root: root, rest: rest) { return subItem(sub, app: appName, ctx: ctx) }
        return make(.applications, .keep, "\(appName) app data",
                    "Settings, documents and other data \(appName) keeps for itself. Removing it can reset the app or lose things you made in it, so manage it from inside \(appName).",
                    regenerates: false)
    }

    /// Anything in ~/Library the app-folder logic couldn't name: files of a known type keep their type title;
    /// macOS's own folders are "macOS data"; everything else is "App data". Always Keep.
    private func libraryFallback(_ ctx: Context) -> Classification {
        if ctx.isFileLike, catalog.fileType(forExtension: ctx.ext) != nil { return fileItem(ctx) }
        if ctx.rel.count >= 2, !LibraryOwnership.appRoots.contains(ctx.rel[1].lowercased()),
           LibraryOwnership.isAppleOwned(ctx.rel[1]) {
            return make(.system, .keep, "macOS data (\(ctx.rel[1]))",
                        "Data kept by a part of macOS. macOS manages it, so Freespan leaves it alone.",
                        regenerates: false)
        }
        return make(.other, .keep, "App data", "Data an app keeps for itself. Remove the app to remove this.",
                    regenerates: false)
    }

    private enum SubKind { case cache, temp, logs, model(KnownLocationCatalog.Entry?), webData, savedState }

    private func subKind(_ ctx: Context, root: LibraryRoot, rest: [String]) -> SubKind? {
        if ctx.isFileLike, let ft = catalog.fileType(forExtension: ctx.ext), ft.id == "ai-model" { return .model(ft) }
        switch root {
        case .caches: return .cache
        case .logs: return .logs
        case .httpStorages, .webKit: return .webData
        case .savedState: return .savedState
        default: break
        }
        if rest.contains(where: Self.tempNames.contains) { return .temp }
        if rest.contains(where: Self.cacheNames.contains) { return .cache }
        if rest.contains(where: Self.logNames.contains) { return .logs }
        if rest.contains(where: Self.modelNames.contains) { return .model(nil) }
        return nil
    }

    private func subItem(_ kind: SubKind, app: String, ctx: Context) -> Classification {
        let note = "Freespan recognized this by where it is rather than by a built-in rule, so take a quick look first."
        switch kind {
        case .cache:
            return make(.caches, .review, "\(app) cache",
                        "Temporary files \(app) keeps to work faster. Usually fine to remove with \(app) closed; it rebuilds them. \(note)",
                        regenerates: true)
        case .temp:
            return make(.caches, .review, "\(app) temporary files",
                        "Scratch files \(app) created while working. They're usually left over and fine to remove with \(app) closed. \(note)",
                        regenerates: true)
        case .logs:
            return make(.caches, .review, "\(app) logs",
                        "Diagnostic logs and crash reports written by \(app). Fine to remove; \(app) starts new logs as needed.",
                        regenerates: true)
        case .model:
            return make(.developer, .review, "\(app) AI model",
                        "An AI model \(app) downloaded to work on your Mac. Removing it frees the space; \(app) will likely download it again the next time it needs it, or stop offering that feature.",
                        regenerates: false)
        case .webData:
            return make(.applications, .review, "\(app) website data",
                        "Web content and sign-in data \(app) keeps for the pages it shows. Removing it may sign you out inside \(app).",
                        regenerates: true)
        case .savedState:
            return make(.applications, .review, "\(app) saved windows",
                        "Window positions macOS restores when you reopen \(app). Removing it just means \(app) opens with fresh windows.",
                        regenerates: true)
        }
    }

    // MARK: - Files and packages

    private func fileItem(_ ctx: Context) -> Classification {
        let fileType = catalog.fileType(forExtension: ctx.ext)
        let utType = ctx.ext.isEmpty ? nil : UTType(filenameExtension: ctx.ext)
        let spot = Spotlight.read(ctx.path)
        let kind = fileType?.title ?? spot.kind ?? utType?.localizedDescription ?? "File"

        var parts = [Self.sentenceCase(kind)]
        if let host = spot.whereFromHost { parts.append("downloaded from \(host)") }
        let calendar = Calendar.current
        if let used = spot.lastUsed {
            parts.append("last opened \(calendar.component(.year, from: used))")
        } else if let modified = ctx.node.modified, now().timeIntervalSince(modified) > 180 * 86_400 {
            parts.append("last changed \(calendar.component(.year, from: modified))")
        }
        let title = parts.joined(separator: " · ")

        if let fileType {
            return make(fileType.category, fileType.label, title, fileType.explanation, regenerates: fileType.regenerates)
        }
        let isMedia = utType.map { $0.conforms(to: .audiovisualContent) || $0.conforms(to: .image) || $0.conforms(to: .audio) } ?? false
        if isMedia {
            return make(.media, .keep, title,
                        "A photo, video or audio file of yours. Freespan keeps your own files; delete it yourself in Finder if you don't need it.",
                        regenerates: false)
        }
        return make(.other, .keep, title,
                    "A file that isn't a cache or app data, so Freespan treats it as yours and keeps it. Delete it yourself in Finder if you don't need it.",
                    regenerates: false)
    }

    // MARK: - Folders in home

    private func hiddenToolFolder(_ top: String) -> Classification {
        let tool = String(top.dropFirst())
        return make(.developer, .keep, "Hidden data for \(tool)",
                    "Settings or data kept by a command-line tool or app (the hidden “\(top)” folder in your home). Freespan doesn't remove hidden folders; if you've stopped using \(tool), its documentation explains how to clean up.",
                    regenerates: false)
    }

    /// Marker files that make a folder a code project, with a readable project kind.
    static let projectMarkers: [(name: String, kind: String)] = [
        ("Package.swift", "Swift package"), ("package.json", "JavaScript project"), ("Cargo.toml", "Rust project"),
        ("go.mod", "Go project"), ("pyproject.toml", "Python project"), ("requirements.txt", "Python project"),
        ("setup.py", "Python project"), ("Gemfile", "Ruby project"), ("pom.xml", "Java project"),
        ("build.gradle", "Gradle project"), ("build.gradle.kts", "Gradle project"), ("pubspec.yaml", "Flutter project"),
        ("composer.json", "PHP project"), ("deno.json", "Deno project"), (".git", "Git repository"),
    ]

    /// The kind of code project at `dir`, checking the real folder for marker files, or nil.
    static func projectKind(at dir: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let set = Set(names.map { $0.lowercased() })
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { return "Xcode project" }
        return projectMarkers.first { set.contains($0.name.lowercased()) }?.kind
    }

    private func codeProject(_ ctx: Context) -> Classification? {
        let name = ctx.name
        if ctx.node.kind == .directory, let kind = Self.projectKind(at: ctx.path) {
            return make(.developer, .keep, "Code project: \(name)",
                        "Your \(kind.lowercasedFirst) “\(name)”. Freespan keeps source code; build folders and installed dependencies inside it (like node_modules or .build) are listed separately and can go.",
                        regenerates: false)
        }
        // Inside a project: walk up toward home.
        var dir = (ctx.path as NSString).deletingLastPathComponent
        while dir.count > ctx.home.count, dir.hasPrefix(ctx.home + "/") {
            if let kind = Self.projectKind(at: dir) {
                let project = (dir as NSString).lastPathComponent
                return make(.developer, .keep, "Part of code project: \(project)",
                            "Files inside your \(kind.lowercasedFirst) “\(project)”, such as data, exports or assets. Freespan treats them as yours and keeps them; delete what you don't need in Finder.",
                            regenerates: false)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        // A folder holding several projects (e.g. ~/Desktop/AppDev).
        if ctx.node.kind == .directory,
           let children = try? FileManager.default.contentsOfDirectory(atPath: ctx.path) {
            var projects = 0
            for child in children.prefix(200) where !child.hasPrefix(".") {
                if Self.projectKind(at: ctx.path + "/" + child) != nil { projects += 1 }
                if projects >= 2 { break }
            }
            if projects >= 2 {
                return make(.developer, .keep, "Code projects",
                            "A folder of your code projects. Freespan keeps source code; build folders and installed dependencies inside them are listed separately and can go.",
                            regenerates: false)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func make(_ category: CategoryID, _ label: SafetyLabel, _ title: String, _ explanation: String,
                      regenerates: Bool) -> Classification {
        Classification(category: category, label: label, title: title, explanation: explanation,
                       regenerates: regenerates, source: .heuristic, ruleID: nil)
    }

    /// Enforces the safety contract: never Safe, never Protected, and Keep where Freespan couldn't remove it anyway.
    static func capped(_ c: Classification, path: String, home: String) -> Classification {
        var label = c.label
        var explanation = c.explanation
        if label == .safe { label = .review }
        if label == .protected { label = .keep }
        if label == .review && ProtectedPaths.isProtected(path, home: home) {
            label = .keep
            explanation += " Freespan can't remove items in this location, so manage it with the app or tool that created it."
        }
        return Classification(category: c.category, label: label, title: c.title, explanation: explanation,
                              regenerates: c.regenerates, source: .heuristic, ruleID: nil)
    }

    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        // Keep names like "Swift", "JavaScript", "Xcode" as they are.
        let keepCase = ["Swift", "JavaScript", "Rust", "Go", "Python", "Ruby", "Java", "Gradle", "Flutter", "PHP", "Deno", "Git", "Xcode"]
        if keepCase.contains(where: { hasPrefix($0) }) { return self }
        return first.lowercased() + dropFirst()
    }
}

/// Spotlight metadata for one file, read from the local index (no network).
enum Spotlight {
    struct Info {
        var kind: String?
        /// Host only (e.g. "example.com"), never the full URL.
        var whereFromHost: String?
        var lastUsed: Date?
    }

    static func read(_ path: String) -> Info {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return Info() }
        var info = Info()
        info.kind = MDItemCopyAttribute(item, kMDItemKind) as? String
        if let froms = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] {
            info.whereFromHost = froms.lazy.compactMap { URL(string: $0)?.host() }.first.map(Self.trimHost)
        }
        info.lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        return info
    }

    static func trimHost(_ host: String) -> String {
        host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
