import Foundation

/// Path mapping between what the scanner opens on disk and what it reports.
enum ScanPaths {
    /// The writable APFS Data volume. Scanning it is "whole disk" mode; the firmlinked paths users and rules
    /// know (`/Users/…`, `/Applications/…`) are this prefix stripped off.
    static let dataVolumeRoot = "/System/Volumes/Data"
    static let wholeDiskName = "Macintosh HD"

    /// `/System/Volumes/Data/Users/alex` → `/Users/alex`, `/System/Volumes/Data` → `/`. Other paths unchanged.
    static func displayPath(forReal real: String) -> String {
        let root = dataVolumeRoot
        guard real.hasPrefix(root) else { return real }
        if real.count == root.count { return "/" }
        let rest = real.dropFirst(root.count)
        if rest == "/" { return "/" }
        return rest.hasPrefix("/") ? String(rest) : real
    }

    static func isWholeDisk(_ realRoot: String) -> Bool {
        displayPath(forReal: realRoot) == "/"
    }

    /// Joins a directory path and a child name without producing `//` under `/`.
    @inline(__always)
    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    /// Standardized absolute path of `url` without a trailing slash (except for `/`).
    static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }
}

/// Prefix matcher for `ScanOptions.excludedPaths` (matches the path itself or anything beneath it).
struct ExclusionList: Sendable {
    private let exact: Set<String>
    private let prefixes: [String]

    init(_ paths: [String]) {
        let normalized = paths.filter { !$0.isEmpty }.map(ScanPaths.normalize)
        exact = Set(normalized)
        prefixes = normalized.map { $0 == "/" ? "/" : $0 + "/" }
    }

    var isEmpty: Bool { exact.isEmpty }

    func contains(_ path: String) -> Bool {
        if exact.isEmpty { return false }
        if exact.contains(path) { return true }
        for prefix in prefixes where path.hasPrefix(prefix) { return true }
        return false
    }
}
