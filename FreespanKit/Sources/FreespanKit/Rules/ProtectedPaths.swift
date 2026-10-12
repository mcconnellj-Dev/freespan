import Foundation

/// Paths Freespan will never delete. Checked by CleanupService before every action. OWNER: rules agent.
///
/// Fails closed: anything not explicitly allowed is protected. Comparison is lexical and case-insensitive
/// (APFS is case-insensitive by default); `CleanupService` additionally re-checks the symlink-resolved path.
///
/// Allowed (not protected):
/// - Items inside the home folder, except the folders and files listed below.
/// - Items inside /Applications (but not /Applications itself, /Applications/Utilities itself,
///   built-in Apple apps, or anything *inside* an app bundle).
public enum ProtectedPaths {
    /// Standard folders directly in home. The folders themselves are protected; their contents are not.
    static let standardHomeFolders: Set<String> = [
        "library", "desktop", "documents", "downloads", "pictures", "music", "movies", "public", "applications",
    ]

    /// ~/Library children protected together with everything inside them.
    static let protectedLibraryTrees: Set<String> = [
        "keychains", "preferences", "mail", "messages", "mobile documents", "accounts", "cloudstorage",
        "cookies", "httpstorages", "safari", "calendars", "reminders",
    ]

    /// ~/Library children where only the folder itself is protected (their children may be cleaned).
    static let protectedLibraryFolders: Set<String> = [
        "containers", "group containers", "application support", "caches", "developer", "photos",
    ]

    /// Dot-folder locations in home that hold only re-downloadable caches. Everything at or below these is
    /// allowed; every other dotfile/dot-folder directly in home (and everything inside it) is protected.
    static let allowedDotPaths: [[String]] = [
        [".npm"],
        [".cache"],
        [".pnpm-store"],
        [".gradle", "caches"],
        [".gradle", "wrapper"],
        [".yarn", "berry", "cache"],
        [".bun", "install", "cache"],
        [".cargo", "registry"],
        [".cocoapods", "repos"],
        [".m2", "repository"],
        [".ollama", "models"],
    ]

    /// Library packages whose contents (and the package itself) are never removed.
    static let protectedPackageExtensions: [String] = [".photoslibrary", ".photolibrary", ".musiclibrary"]

    /// Apple apps that live in /Applications but belong to macOS.
    static let systemApplications: Set<String> = ["safari.app"]

    public static func isProtected(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard let p = normalizedComponents(path), let h = normalizedComponents(home), !h.isEmpty else { return true }

        // Photos / Music library packages anywhere, and everything inside them.
        if p.contains(where: { c in protectedPackageExtensions.contains { c.hasSuffix($0) } }) { return true }

        // /Applications: children allowed, with exceptions.
        if p.first == "applications" && h.first != "applications" {
            guard p.count >= 2 else { return true }
            if systemApplications.contains(p[1]) { return true }
            if p.count == 2 && p[1] == "utilities" { return true }
            // Inside an app bundle (e.g. /Applications/Xcode.app/Contents/...): removing parts breaks the app.
            if p.dropLast().contains(where: { $0.hasSuffix(".app") }) { return true }
            return false
        }

        // Outside home → protected. Home itself → protected.
        guard p.count > h.count, Array(p.prefix(h.count)) == h else { return true }
        let rel = Array(p.dropFirst(h.count))
        let first = rel[0]

        if first.hasPrefix(".") {
            if first == ".trash" { return rel.count == 1 }
            return !allowedDotPaths.contains { allowed in
                rel.count >= allowed.count && Array(rel.prefix(allowed.count)) == allowed
            }
        }

        if rel.count == 1 { return standardHomeFolders.contains(first) }

        if first == "library" {
            let second = rel[1]
            if protectedLibraryTrees.contains(second) { return true }
            if rel.count == 2 && protectedLibraryFolders.contains(second) { return true }
            // Apple's own app containers hold app data (mail, notes, ...). Contents may be cleaned by specific rules.
            if rel.count == 3 && second == "containers" && rel[2].hasPrefix("com.apple.") { return true }
            if rel.count == 3 && second == "group containers" && rel[2].hasPrefix("group.com.apple.") { return true }
        }
        return false
    }

    /// Lexically normalized absolute path: resolves `.`/`..`, collapses `//`, strips a trailing slash.
    /// Returns nil for relative or empty paths. Case is preserved.
    public static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var out: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(c)
        }
        return "/" + out.joined(separator: "/")
    }

    /// Lowercased components of the normalized path, or nil when the path isn't absolute.
    static func normalizedComponents(_ path: String) -> [String]? {
        guard let n = normalize(path) else { return nil }
        return n.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// True when `path` is the user's Trash or something inside it.
    public static func isInTrash(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard let p = normalizedComponents(path), let h = normalizedComponents(home), !h.isEmpty else { return false }
        return p.count > h.count && Array(p.prefix(h.count)) == h && p[h.count] == ".trash"
    }
}
