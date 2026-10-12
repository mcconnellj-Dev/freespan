import AppKit
import Foundation

/// Turns app-ID folder names (`com.spotify.client`, `group.com.docker`, `9K33E3U3T4.net.example`) into app names,
/// using Launch Services. Lookups are cached and thread-safe. Purely local.
final class AppDirectory: @unchecked Sendable {
    typealias Resolver = @Sendable (String) -> URL?

    static let shared = AppDirectory(
        resolver: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        appFolders: ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications"]
    )

    private let resolver: Resolver
    private let appFolders: [String]
    private let lock = NSLock()
    private var nameByID: [String: String?] = [:]
    private var appExistsByName: [String: Bool] = [:]

    init(resolver: @escaping Resolver, appFolders: [String]) {
        self.resolver = resolver
        self.appFolders = appFolders
    }

    /// Display name of the installed app with this exact bundle identifier, or nil.
    func appName(bundleID: String) -> String? {
        let key = bundleID.lowercased()
        lock.lock()
        if let cached = nameByID[key] { lock.unlock(); return cached }
        lock.unlock()
        let name = resolver(bundleID).map { $0.deletingPathExtension().lastPathComponent }
        lock.lock()
        nameByID[key] = .some(name)
        lock.unlock()
        return name
    }

    /// True when an app with this name is in one of the standard Applications folders.
    func hasApp(named name: String) -> Bool {
        let key = name.lowercased()
        lock.lock()
        if let cached = appExistsByName[key] { lock.unlock(); return cached }
        lock.unlock()
        let fm = FileManager.default
        let exists = appFolders.contains { fm.fileExists(atPath: "\($0)/\(name).app") }
        lock.lock()
        appExistsByName[key] = exists
        lock.unlock()
        return exists
    }

    /// Who owns a folder named after an app.
    enum Owner: Equatable {
        /// An installed app, found by bundle ID or by name.
        case installed(name: String, bundleID: String?)
        /// A bundle ID with no installed app. `guess` is a readable name derived from the ID.
        case missing(guess: String, bundleID: String)
        /// A macOS component (`com.apple.*` with no app of that ID).
        case system(guess: String, bundleID: String)
        /// A plain folder name (e.g. "Cisco Spark") with no app of that name.
        case unknown(name: String)
    }

    func owner(ofFolderNamed folder: String) -> Owner {
        guard let id = BundleID.parse(folder) else {
            let name = BundleID.stripPrefixes(folder).name.trimmingCharacters(in: .whitespaces)
            return hasApp(named: name) ? .installed(name: name, bundleID: nil) : .unknown(name: name)
        }
        for candidate in id.candidates {
            if let name = appName(bundleID: candidate) { return .installed(name: name, bundleID: candidate) }
        }
        if id.core.lowercased().hasPrefix("com.apple.") { return .system(guess: id.guess, bundleID: id.core) }
        return .missing(guess: id.guess, bundleID: id.core)
    }
}

/// Parsing of reverse-DNS folder names.
enum BundleID {
    struct Parsed: Equatable {
        /// The ID with `group.` and team prefixes removed, e.g. `com.docker`.
        let core: String
        /// IDs to try, most likely first.
        let candidates: [String]
        /// Readable best-guess app name, e.g. "Spotify".
        let guess: String
    }

    static let topLevel: Set<String> = [
        "com", "net", "org", "io", "app", "co", "dev", "ai", "me", "us", "uk", "de", "fr", "jp", "ch", "se", "nl",
        "ca", "au", "tv", "cc", "so", "sh", "ru", "it", "es", "eu", "be", "at", "dk", "no", "fi", "pl", "cz", "br",
        "in", "cn", "kr", "tw", "hk", "xyz", "info", "edu", "gov", "studio", "tech", "pro", "is", "ly", "to", "md",
    ]

    static let genericWords: Set<String> = [
        "client", "app", "apps", "mac", "macos", "osx", "desktop", "helper", "agent", "launcher", "daemon", "service",
        "services", "extension", "plugin", "ios", "main", "ui", "shared", "group", "data", "application", "mas",
        "appstore", "macapp", "beta", "free", "pro", "lite", "full", "x",
    ]

    /// Nil when the folder name doesn't look like an app ID.
    static func parse(_ folder: String) -> Parsed? {
        let (name, fromGroupOrTeam) = stripPrefixes(folder)
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return nil }
        guard topLevel.contains(parts[0].lowercased()) && (parts.count >= 3 || fromGroupOrTeam) else { return nil }

        var candidates = [name]
        // group.com.docker → com.docker.docker
        if fromGroupOrTeam, let last = parts.last { candidates.append(name + "." + last) }
        // com.microsoft.OneDrive.FinderSync → com.microsoft.OneDrive
        var shorter = parts
        while shorter.count > 3 {
            shorter.removeLast()
            candidates.append(shorter.joined(separator: "."))
        }
        return Parsed(core: name, candidates: candidates, guess: guessName(parts))
    }

    /// Removes a leading `group.` and/or a team ID (ten uppercase letters/digits and a dot, e.g. "9K33E3U3T4.").
    static func stripPrefixes(_ folder: String) -> (name: String, stripped: Bool) {
        var name = folder
        var stripped = false
        if name.lowercased().hasPrefix("group.") { name.removeFirst(6); stripped = true }
        if name.count > 11, name[name.index(name.startIndex, offsetBy: 10)] == ".",
           name.prefix(10).allSatisfy({ ($0.isUppercase && $0.isASCII) || $0.isNumber }),
           name.prefix(10).contains(where: \.isNumber) {
            name.removeFirst(11)
            stripped = true
        }
        return (name, stripped)
    }

    static func guessName(_ parts: [String]) -> String {
        let meaningful = parts.dropFirst().filter { !genericWords.contains($0.lowercased()) && !$0.allSatisfy(\.isNumber) }
        let pick = meaningful.last ?? parts.last ?? ""
        let spaced = pick.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first, spaced == spaced.lowercased() else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }
}
