import Foundation

/// Moves items to the Trash and records every action so it can be undone. OWNER: rules agent.
///
/// Never deletes permanently: the only destructive operation is `FileManager.trashItem`, and every success
/// is written to a JSON action log so it can be put back with `undo`.
public actor CleanupService {
    /// Moves the item at the URL to the Trash and returns where it ended up.
    typealias TrashOperation = @Sendable (URL) throws -> URL
    /// Lists which processes have files open right now. One snapshot per cleanup.
    typealias OpenFilesProvider = @Sendable () -> OpenFilesSnapshot
    /// Bytes on disk at a path (a folder's whole contents). Only used for partly-open folders.
    typealias SizeProvider = @Sendable (String) -> Int64

    private let logURL: URL
    private let home: String
    private let trashOperation: TrashOperation
    private let openFiles: OpenFilesProvider
    private let sizeOf: SizeProvider
    /// Freespan's own process never counts as "using" something.
    private let ownPID = getpid()
    private var entries: [ActionLogEntry]?

    public init(logURL: URL? = nil) {
        self.init(logURL: logURL ?? Self.defaultLogURL, home: NSHomeDirectory(), trashOperation: Self.systemTrash,
                  openFiles: { OpenFilesSnapshot.capture() }, sizeOf: Self.allocatedSize)
    }

    /// Test seam: inject the home folder and the trash operation (e.g. a move into a temp "fake trash").
    init(logURL: URL, home: String, trashOperation: @escaping TrashOperation,
         openFiles: @escaping OpenFilesProvider = { .empty }, sizeOf: @escaping SizeProvider = CleanupService.allocatedSize) {
        self.logURL = logURL
        self.home = home
        self.trashOperation = trashOperation
        self.openFiles = openFiles
        self.sizeOf = sizeOf
    }

    static var defaultLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Freespan/actions.json")
    }

    static let systemTrash: TrashOperation = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    /// Moves each finding to the Trash. Protected paths, paths that no longer exist, and items a running app
    /// has open are skipped and reported. Never quits or signals any process.
    ///
    /// A folder with only some files open is cleaned partly: the parts nothing has open go to the Trash one by
    /// one (each logged, so Undo works), the open parts stay, and the folder itself is never moved.
    public func moveToTrash(_ findings: [Finding]) async -> CleanupReport {
        var log = loadedEntries()
        var trashed: [ActionLogEntry] = []
        var skipped: [CleanupReport.Skipped] = []
        var partial: [CleanupReport.Partial] = []
        var seen: Set<String> = []
        var candidates: [Finding] = []

        for finding in findings {
            let path = finding.path
            if let reason = skipReason(for: finding) {
                skipped.append(.init(path: path, reason: reason))
                continue
            }
            let key = ProtectedPaths.normalize(path)?.lowercased() ?? path
            guard seen.insert(key).inserted else { continue }
            candidates.append(finding)
        }

        // Trashing files an app holds open breaks emptying the Trash ("item is in use") and can upset the app.
        let snapshot = candidates.isEmpty ? OpenFilesSnapshot.empty : openFiles()
        for finding in candidates {
            let path = finding.path
            let apps = blockingApps(for: path, in: snapshot)
            if !apps.isEmpty {
                guard let plan = partialPlan(for: path, in: snapshot) else {
                    skipped.append(.init(path: path, reason: Self.inUseReason(apps), blockingApps: apps))
                    continue
                }
                var moved: Int64 = 0
                var movedCount = 0
                var leftBehind = plan.busy.reduce(Int64(0)) { $0 + sizeOf($1) }
                for child in plan.movable {
                    let size = sizeOf(child)
                    do {
                        let result = try trashOperation(URL(fileURLWithPath: child))
                        let entry = ActionLogEntry(originalPath: child, trashPath: result.path, size: size)
                        trashed.append(entry)
                        log.append(entry)
                        moved += size
                        movedCount += 1
                    } catch {
                        leftBehind += size
                    }
                }
                if movedCount == 0 {
                    skipped.append(.init(path: path, reason: Self.inUseReason(apps), blockingApps: apps))
                } else {
                    partial.append(.init(path: path, movedBytes: moved, skippedBytes: leftBehind, blockingApps: apps))
                }
                continue
            }
            do {
                let result = try trashOperation(URL(fileURLWithPath: path))
                let entry = ActionLogEntry(originalPath: path, trashPath: result.path, size: finding.size)
                trashed.append(entry)
                log.append(entry)
            } catch {
                skipped.append(.init(path: path, reason: Self.describeTrashFailure(error)))
            }
        }
        if !trashed.isEmpty {
            entries = log
            persist()
        }
        return CleanupReport(trashed: trashed, skipped: skipped, partial: partial)
    }

    /// Which of these findings a running app or process has files open in, keyed by finding path, and whether
    /// the rest of a folder can still go (see `moveToTrash`). Findings nothing is using are left out. Takes one
    /// snapshot for the whole list.
    public func inUse(_ findings: [Finding]) async -> [String: InUseStatus] {
        guard !findings.isEmpty else { return [:] }
        let snapshot = openFiles()
        var result: [String: InUseStatus] = [:]
        for finding in findings {
            let apps = blockingApps(for: finding.path, in: snapshot)
            guard !apps.isEmpty else { continue }
            if let plan = partialPlan(for: finding.path, in: snapshot) {
                let busy = plan.busy.reduce(Int64(0)) { $0 + sizeOf($1) }
                result[finding.path] = InUseStatus(apps: apps, isPartial: true, busyBytes: min(busy, finding.size))
            } else {
                result[finding.path] = InUseStatus(apps: apps, isPartial: false, busyBytes: finding.size)
            }
        }
        return result
    }

    // MARK: - Partly open folders

    /// How deep below a finding Freespan looks for the open parts of a folder.
    static let partialDepth = 3

    /// What can go and what stays when only some of a folder is open.
    struct PartialPlan: Sendable, Equatable {
        /// Paths inside the folder nothing has open: moved to the Trash one by one.
        var movable: [String] = []
        /// Paths that are open, or that contain something open below the depth limit: left in place.
        var busy: [String] = []
    }

    /// Nil when the item isn't a plain folder (files, links and packages such as apps are all-or-nothing) or
    /// when nothing inside it could be moved.
    func partialPlan(for path: String, in snapshot: OpenFilesSnapshot) -> PartialPlan? {
        guard Self.isPlainDirectory(path) else { return nil }
        var plan = PartialPlan()
        collect(path, level: 1, snapshot: snapshot, into: &plan)
        return plan.movable.isEmpty ? nil : plan
    }

    private func collect(_ dir: String, level: Int, snapshot: OpenFilesSnapshot, into plan: inout PartialPlan) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            plan.busy.append(dir)
            return
        }
        for name in names.sorted() {
            let child = (dir as NSString).appendingPathComponent(name)
            if !isOpen(child, in: snapshot) {
                plan.movable.append(child)
            } else if level < Self.partialDepth, Self.isPlainDirectory(child) {
                collect(child, level: level + 1, snapshot: snapshot, into: &plan)
            } else {
                plan.busy.append(child)
            }
        }
    }

    private func isOpen(_ path: String, in snapshot: OpenFilesSnapshot) -> Bool {
        snapshot.pids(using: path).contains { $0 != ownPID }
    }

    /// A real folder: not a symlink, not a package (an `.app` or document bundle is never split up).
    static func isPlainDirectory(_ path: String) -> Bool {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType,
              type == .typeDirectory else { return false }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage != true
    }

    /// Bytes on disk for a file, or everything inside a folder (links are not followed).
    static let allocatedSize: SizeProvider = { path in
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey,
                                         .isSymbolicLinkKey]
        func size(_ url: URL) -> Int64 {
            guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
        }
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard v.isDirectory == true, v.isSymbolicLink != true else { return size(url) }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                    errorHandler: { _, _ in true })
        while let item = walker?.nextObject() as? URL {
            total += size(item)
        }
        return total
    }

    private func blockingApps(for path: String, in snapshot: OpenFilesSnapshot) -> [BlockingApp] {
        let users = snapshot.users(of: path).filter { $0.pid != ownPID }
        return BlockingApp.group(users)
    }

    /// "Google Chrome is using this right now. Quit Google Chrome, then try again."
    public static func inUseReason(_ apps: [BlockingApp]) -> String {
        let named = apps.filter(\.isQuittableApp)
        guard !named.isEmpty else {
            let who = apps.first.map { $0.isApp ? $0.name : "A background process (\($0.name))" } ?? "Another process"
            return "\(who) is using this right now. Try again in a little while, or after restarting your Mac."
        }
        let shown = named.prefix(2).map(\.name)
        let more = apps.count > shown.count
        let list = more ? shown.joined(separator: ", ") + " and others" : shown.joined(separator: " and ")
        let verb = shown.count == 1 && !more ? "is" : "are"
        let quit = more ? "Quit them" : "Quit \(list)"
        return "\(list) \(verb) using this right now. \(quit), then try again."
    }

    /// Restores one logged action from the Trash to its original location.
    public func undo(_ entry: ActionLogEntry) async throws {
        var log = loadedEntries()
        let index = log.firstIndex { $0.id == entry.id }
        let current = index.map { log[$0] } ?? entry
        if current.restored { throw CleanupError.alreadyRestored(current.originalPath) }

        let fm = FileManager.default
        guard Self.itemExists(current.trashPath) else { throw CleanupError.trashItemMissing(current.originalPath) }
        guard !Self.itemExists(current.originalPath) else { throw CleanupError.originalPathOccupied(current.originalPath) }
        do {
            let parent = (current.originalPath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: current.trashPath, toPath: current.originalPath)
        } catch {
            throw CleanupError.restoreFailed(current.originalPath, error.localizedDescription)
        }
        if let index {
            log[index].restored = true
            entries = log
            persist()
        }
    }

    /// Most recent first.
    public func history() async -> [ActionLogEntry] {
        loadedEntries().sorted { $0.date > $1.date }
    }

    // MARK: - Checks

    private func skipReason(for finding: Finding) -> String? {
        let path = finding.path
        guard ProtectedPaths.normalize(path) != nil else {
            return "This isn't a full file location, so Freespan won't touch it."
        }
        if ProtectedPaths.isInTrash(path, home: home) {
            return "Already in the Trash — empty the Trash in Finder to free this space"
        }
        switch finding.classification.label {
        case .protected:
            return "Protected — this belongs to macOS or another app's essential data, so Freespan won't remove it."
        case .keep:
            return "Marked Keep — this is your own data or something an app needs, so Freespan won't remove it. Manage it in the app it belongs to or in Finder."
        case .safe, .review:
            break
        }
        if ProtectedPaths.isProtected(path, home: home) {
            return "Protected location — Freespan never removes system files, your top-level folders, or important settings."
        }
        guard Self.itemExists(path) else {
            return "No longer there — it may have already been moved or deleted."
        }
        // Re-check with symlinks in the parent chain resolved, so a link can't redirect us somewhere protected.
        let resolved = Self.resolvingParentSymlinks(path)
        let resolvedHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        if ProtectedPaths.isInTrash(resolved, home: resolvedHome) {
            return "Already in the Trash — empty the Trash in Finder to free this space"
        }
        if ProtectedPaths.isProtected(resolved, home: resolvedHome) {
            return "Protected location — this item is reached through a link into a protected folder."
        }
        if let reason = Self.missingMarkerReason(for: finding) { return reason }
        return nil
    }

    /// Build-folder rules match by folder name alone. Before trashing, require the project file that proves the
    /// folder really is a dependency/build folder (`package.json` next to `node_modules`, `Package.swift` next to
    /// `.build`), so a user folder that merely has that name is never removed.
    static let requiredSiblingMarkers: [String: (file: String, reason: String)] = [
        "node-modules": ("package.json",
                         "This folder isn't next to a package.json, so it may not be a real npm install — remove it manually if you're sure."),
        "swift-build-folder": ("Package.swift",
                               "This folder isn't next to a Package.swift, so it may not be a real Swift build folder — remove it manually if you're sure."),
    ]

    static func missingMarkerReason(for finding: Finding) -> String? {
        guard let id = finding.classification.ruleID,
              let marker = requiredSiblingMarkers[id] else { return nil }
        let parent = URL(fileURLWithPath: finding.path).deletingLastPathComponent()
        let markerPath = parent.appendingPathComponent(marker.file).path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: markerPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return marker.reason
        }
        return nil
    }

    /// Exists without following a final symlink (a dangling link still counts as an item).
    static func itemExists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    static func resolvingParentSymlinks(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent).path
    }

    static func describeTrashFailure(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "macOS didn't give Freespan permission to move this. Check Full Disk Access in System Settings > Privacy & Security."
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "No longer there — it may have already been moved or deleted."
            case NSFileWriteVolumeReadOnlyError:
                return "This is on a read-only disk, so it can't be moved to the Trash."
            default:
                break
            }
        }
        return "Couldn't move this to the Trash: \(error.localizedDescription)"
    }

    // MARK: - Log persistence

    private func loadedEntries() -> [ActionLogEntry] {
        if let entries { return entries }
        let loaded: [ActionLogEntry]
        if let data = try? Data(contentsOf: logURL),
           let decoded = try? Self.decoder.decode([ActionLogEntry].self, from: data) {
            loaded = decoded
        } else {
            loaded = []
        }
        entries = loaded
        return loaded
    }

    private func persist() {
        guard let entries else { return }
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: logURL, options: .atomic)
        } catch {
            // The items are in the Trash either way; Finder's "Put Back" still works without our log.
            NSLog("Freespan: couldn't save the cleanup log at %@: %@", logURL.path, error.localizedDescription)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum CleanupError: LocalizedError, Sendable, Equatable {
    case trashItemMissing(String)
    case originalPathOccupied(String)
    case alreadyRestored(String)
    case restoreFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .trashItemMissing(let path):
            "“\((path as NSString).lastPathComponent)” is no longer in the Trash — the Trash may have been emptied, so it can't be put back."
        case .originalPathOccupied(let path):
            "Something named “\((path as NSString).lastPathComponent)” is already back in its original folder. Move or rename it, then try again."
        case .alreadyRestored(let path):
            "“\((path as NSString).lastPathComponent)” has already been put back."
        case .restoreFailed(let path, let detail):
            "Couldn't put back “\((path as NSString).lastPathComponent)”: \(detail)"
        }
    }
}

public struct CleanupReport: Sendable {
    /// Everything moved, including the individual parts of partly cleaned folders.
    public let trashed: [ActionLogEntry]
    public let skipped: [Skipped]
    /// Folders only partly cleaned because some files inside were open.
    public let partial: [Partial]
    public var bytesFreed: Int64 { trashed.reduce(0) { $0 + $1.size } }
    /// Bytes left behind in partly cleaned folders.
    public var bytesLeftInUse: Int64 { partial.reduce(0) { $0 + $1.skippedBytes } }

    /// A folder whose free parts went to the Trash while the open parts stayed.
    public struct Partial: Sendable, Hashable {
        public let path: String
        public let movedBytes: Int64
        public let skippedBytes: Int64
        /// What had the remaining files open.
        public let blockingApps: [BlockingApp]
        public init(path: String, movedBytes: Int64, skippedBytes: Int64, blockingApps: [BlockingApp]) {
            self.path = path
            self.movedBytes = movedBytes
            self.skippedBytes = skippedBytes
            self.blockingApps = blockingApps
        }
    }

    public struct Skipped: Sendable, Hashable {
        public let path: String
        public let reason: String
        /// Set when the item was skipped because these apps or processes had files open inside it.
        public let blockingApps: [BlockingApp]?
        public init(path: String, reason: String, blockingApps: [BlockingApp]? = nil) {
            self.path = path
            self.reason = reason
            self.blockingApps = blockingApps
        }
    }

    public init(trashed: [ActionLogEntry], skipped: [Skipped], partial: [Partial] = []) {
        self.trashed = trashed
        self.skipped = skipped
        self.partial = partial
    }
}

public struct ActionLogEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let originalPath: String
    public let trashPath: String
    public let size: Int64
    public let date: Date
    public var restored: Bool

    public init(id: UUID = UUID(), originalPath: String, trashPath: String, size: Int64, date: Date = Date(), restored: Bool = false) {
        self.id = id
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.size = size
        self.date = date
        self.restored = restored
    }
}
