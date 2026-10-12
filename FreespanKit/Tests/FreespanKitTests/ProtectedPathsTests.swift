import Foundation
import Testing
@testable import FreespanKit

@Suite("ProtectedPaths")
struct ProtectedPathsTests {
    static let home = "/Users/test"

    static let protectedCases: [String] = [
        // Not absolute / empty
        "", "Users/test/Downloads/a.zip", "~/Downloads/a.zip", "./a", "../Users/test/Downloads/x",
        // Outside home
        "/", "/System", "/System/Library/CoreServices", "/Library", "/Library/Caches/com.apple.x",
        "/private/var/vm/swapfile0", "/usr/local/bin", "/opt/homebrew", "/Users", "/Users/Shared/file",
        "/Users/other/Downloads/a.dmg", "/Users/testing/Downloads/a.dmg", "/Volumes/External/file",
        // /Applications exceptions
        "/Applications", "/Applications/", "/Applications/Safari.app", "/Applications/Utilities",
        "/Applications/Xcode.app/Contents/Developer", "/applications/safari.APP",
        // Home and standard folders themselves
        "/Users/test", "/Users/test/", "/Users/test/Library", "/Users/test/Desktop", "/Users/test/Documents",
        "/Users/test/Downloads", "/Users/test/Pictures", "/Users/test/Music", "/Users/test/Movies",
        "/Users/test/Public", "/Users/test/Applications", "/Users/test/.Trash",
        // ~/Library protected trees
        "/Users/test/Library/Keychains", "/Users/test/Library/Keychains/login.keychain-db",
        "/Users/test/Library/Preferences/com.apple.finder.plist", "/Users/test/Library/Mail/V10",
        "/Users/test/Library/Messages/chat.db", "/Users/test/Library/Mobile Documents/com~apple~CloudDocs",
        "/Users/test/Library/Accounts", "/Users/test/Library/CloudStorage/Dropbox/file",
        "/Users/test/Library/Cookies", "/Users/test/Library/HTTPStorages/x", "/Users/test/Library/Safari/History.db",
        "/Users/test/Library/Calendars", "/Users/test/Library/Reminders",
        // ~/Library folders protected only themselves
        "/Users/test/Library/Containers", "/Users/test/Library/Group Containers",
        "/Users/test/Library/Application Support", "/Users/test/Library/Caches", "/Users/test/Library/Developer",
        "/Users/test/Library/Photos",
        "/Users/test/Library/Containers/com.apple.mail", "/Users/test/Library/Group Containers/group.com.apple.notes",
        // Photos / Music libraries and their contents
        "/Users/test/Pictures/Photos Library.photoslibrary",
        "/Users/test/Pictures/Photos Library.photoslibrary/originals/A/IMG_1.HEIC",
        "/Users/test/Downloads/Old.photoslibrary", "/Users/test/Music/Music/Music Library.musiclibrary",
        "/Users/test/Music/Music/Music Library.musiclibrary/Library.musicdb",
        // Dotfiles and non-allow-listed dot folders
        "/Users/test/.ssh", "/Users/test/.ssh/id_ed25519", "/Users/test/.gnupg", "/Users/test/.config/gh/hosts.yml",
        "/Users/test/.aws/credentials", "/Users/test/.zshrc", "/Users/test/.gitconfig", "/Users/test/.docker/config.json",
        "/Users/test/.gradle", "/Users/test/.gradle/gradle.properties", "/Users/test/.cargo/credentials.toml",
        "/Users/test/.yarn", "/Users/test/.bun/bin/bun", "/Users/test/.ollama", "/Users/test/.ollama/id_ed25519",
        // Case-insensitivity
        "/users/TEST/library/KEYCHAINS/x", "/USERS/test/DOWNLOADS", "/Users/test/.SSH/id_rsa", "/SYSTEM",
        // Traversal and odd spellings
        "/Users/test/Downloads/../Library", "/Users/test/Downloads/../../other/x", "/Users/test/Downloads/./../.ssh/x",
        "/Users/test/../test/Library/Keychains", "/Users/test//Library", "/Users/test/Library/Caches/",
        "/Users/test/Downloads/../../../..", "/Users/test/Downloads/", "/Users/test/Library/Caches/foo/../../Preferences/x",
    ]

    static let allowedCases: [String] = [
        "/Users/test/Downloads/a.dmg", "/Users/test/Downloads/Folder/x", "/Users/test/Desktop/AppDev/site/node_modules",
        "/Users/test/Documents/big.mov", "/Users/test/Pictures/Exports", "/Users/test/Movies/clip.mov",
        "/Users/test/Library/Caches/com.spotify.client", "/Users/test/Library/Logs",
        "/Users/test/Library/Developer/Xcode/DerivedData", "/Users/test/Library/Developer/CoreSimulator/Devices/ABC",
        "/Users/test/Library/Application Support/MobileSync/Backup/0000",
        "/Users/test/Library/Application Support/Foo",
        "/Users/test/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
        "/Users/test/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        "/Users/test/Library/Mail Downloads",
        "/Users/test/.npm", "/Users/test/.npm/_cacache", "/Users/test/.cache", "/Users/test/.cache/uv",
        "/Users/test/.gradle/caches", "/Users/test/.gradle/wrapper/dists", "/Users/test/.yarn/berry/cache",
        "/Users/test/.bun/install/cache", "/Users/test/.cargo/registry", "/Users/test/.pnpm-store",
        "/Users/test/.ollama/models", "/Users/test/.ollama/models/blobs/sha256-abc", "/Users/test/.cache/huggingface/hub",
        "/Users/test/.Trash/old.zip",
        "/Applications/Slack.app", "/Applications/Utilities/Tool.app", "/Applications/Vendor/Thing.app",
        "/Users/test/Applications/Chrome App.app",
        // Normalization that lands somewhere allowed
        "/Users/test/Downloads/x/../a.dmg", "/USERS/TEST/downloads/A.DMG",
        "/Users/test/Library/Caches/../Logs", "/Users/test/./Downloads/a",
        // Similar names that are NOT the protected ones
        "/Users/test/Library/Mailboxes-export", "/Users/test/Documents/.ssh-notes/x",
        "/Users/test/node_modules",
    ]

    @Test(arguments: protectedCases)
    func protected(_ path: String) {
        #expect(ProtectedPaths.isProtected(path, home: Self.home), "\(path)")
    }

    @Test(arguments: allowedCases)
    func allowed(_ path: String) {
        #expect(!ProtectedPaths.isProtected(path, home: Self.home), "\(path)")
    }

    @Test func badHomeFailsClosed() {
        #expect(ProtectedPaths.isProtected("/Users/test/Downloads/a", home: ""))
        #expect(ProtectedPaths.isProtected("/Users/test/Downloads/a", home: "relative/home"))
        #expect(ProtectedPaths.isProtected("/Downloads/a", home: "/"))
    }

    @Test func homeWithTrailingSlashOrCase() {
        #expect(!ProtectedPaths.isProtected("/Users/test/Downloads/a", home: "/Users/test/"))
        #expect(!ProtectedPaths.isProtected("/Users/test/Downloads/a", home: "/users/TEST"))
    }

    @Test func normalize() {
        #expect(ProtectedPaths.normalize("/a/b/../c/./d/") == "/a/c/d")
        #expect(ProtectedPaths.normalize("/../..") == "/")
        #expect(ProtectedPaths.normalize("//a//b") == "/a/b")
        #expect(ProtectedPaths.normalize("a/b") == nil)
        #expect(ProtectedPaths.normalize("") == nil)
    }

    @Test func trashDetection() {
        #expect(ProtectedPaths.isInTrash("/Users/test/.Trash/x", home: Self.home))
        #expect(ProtectedPaths.isInTrash("/users/test/.trash/x/y", home: Self.home))
        #expect(ProtectedPaths.isInTrash("/Users/test/.Trash", home: Self.home)) // the Trash itself counts
        #expect(!ProtectedPaths.isInTrash("/Users/test", home: Self.home))
        #expect(!ProtectedPaths.isInTrash("/Users/test/Downloads/.Trash/x", home: Self.home))
        #expect(ProtectedPaths.isInTrash("/Users/test/Downloads/../.Trash/x", home: Self.home))
    }
}

@Suite("Rules – catalog vs ProtectedPaths")
struct RulesProtectedConsistencyTests {
    /// Rules whose finding is intentionally a protected path the user acts on elsewhere
    /// (the Trash: "empty the Trash in Finder"; CleanupService skips it with that message).
    static let exempt: Set<String> = ["trash"]

    /// A synthetic disk covering every rule target and every protected location, all big and old so that
    /// size/age conditions never hide a match.
    static func syntheticDisk() -> FileNode {
        let paths = ProtectedPathsTests.protectedCases.filter { $0.hasPrefix("/") && !$0.contains("..") && !$0.contains("//") && !$0.hasSuffix("/") }
            + ProtectedPathsTests.allowedCases.filter { !$0.contains("..") && !$0.contains("/./") && !$0.hasSuffix("/") }
            + [
                "/Users/test/Library/Developer/Xcode/Archives/2024-01-01/App.xcarchive",
                "/Users/test/Library/Developer/Xcode/iOS DeviceSupport/17.4",
                "/Users/test/Library/Developer/Xcode/watchOS DeviceSupport/10.0",
                "/Users/test/Library/Developer/Xcode/UserData/Previews",
                "/Users/test/Library/Developer/Xcode/DocumentationCache",
                "/Users/test/Library/Developer/CoreSimulator/Caches",
                "/Users/test/Library/Caches/org.swift.swiftpm", "/Users/test/Library/Caches/CocoaPods",
                "/Users/test/Library/Caches/Homebrew", "/Users/test/Library/Caches/Yarn", "/Users/test/Library/pnpm/store",
                "/Users/test/Library/Caches/pip", "/Users/test/.cache/pip", "/Users/test/Desktop/Pkg/.build",
                "/Users/test/Downloads/Setup.pkg", "/Users/test/Downloads/old.pdf", "/Users/test/Documents/vm.img",
                "/Users/test/.Trash", "/Users/test/.zsh_history", "/Users/test/.ssh/big.key",
                "/Users/test/Library/Keychains/big.db", "/Users/test/Library/Preferences/big.plist",
                "/Users/test/Library/Messages/Attachments/big.mov", "/Users/test/Library/Safari/big.db",
                "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/big.mov",
                "/Users/test/Library/CloudStorage/GoogleDrive/big.mov",
                "/private/var/vm/sleepimage", "/private/var/folders/xy/T/x", "/private/tmp/x", "/private/etc/hosts",
                "/Library/Fonts/x.ttf", "/System/Library/Kernels/kernel", "/cores/core.123",
                "/Users/test/Downloads/recent-file.txt",
                "/Users/test/Library/Containers/com.example.app/Data/Library/Caches",
                "/Users/test/Library/Application Support/Code/CachedData", "/Users/test/.cache/puppeteer",
                "/Users/test/Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage",
                "/Users/test/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel",
                "/Users/test/Library/Application Support/Google/GoogleUpdater/crx_cache",
                "/Users/test/Library/Application Support/Slack/Cache",
                "/Users/test/Library/Application Support/Spotify/PersistentCache",
                "/Users/test/Library/Caches/JetBrains",
                "/Users/test/Library/Android/sdk/system-images/android-34",
                "/Users/test/.ollama/models", "/Users/test/.cache/huggingface",
                "/Users/test/Documents/Zoom",
                "/Users/test/.cache/codex-runtimes", "/Users/test/.cache/gem", "/Users/test/.cache/pre-commit",
                "/Users/test/.cache/node-gyp", "/Users/test/.cache/go-build", "/Users/test/.cache/bazel",
                "/Users/test/.cache/prisma", "/Users/test/.cache/electron", "/Users/test/.cache/typescript",
                "/Users/test/.cache/polyedge",
            ]
        // Leaves only: drop any path that is a prefix-folder of another, keep unique.
        let unique = Set(paths.map { ProtectedPaths.normalize($0)! })
        let leaves = unique.filter { p in !unique.contains { $0.hasPrefix(p + "/") } && p != "/" }
        return RT.tree(leaves.sorted().map { path in
            let kind = Self.realisticKind(path)
            let date = path.contains("recent") ? RT.recent : RT.old
            return RT.Item(path: path, size: 2 * RT.GB, kind: kind,
                           modified: date, accessed: date)
        })
    }

    /// The kind the scanner would report for a path in the tables above.
    static func realisticKind(_ path: String) -> FileNode.Kind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["app", "photoslibrary", "photolibrary", "musiclibrary", "xcarchive"].contains(ext) { return .package }
        let fileExts: Set<String> = ["dmg", "pkg", "zip", "raw", "mov", "pdf", "img", "txt", "ttf", "db", "plist", "heic",
                                     "musicdb", "key", "json", "toml", "yml", "keychain-db", "bin", "pages"]
        let name = (path as NSString).lastPathComponent
        if fileExts.contains(ext) || ["kernel", "swapfile0", "sleepimage", "hosts", "credentials", "id_ed25519",
                                      "id_rsa", "bun", "file", "x", ".zshrc", ".gitconfig", ".zsh_history"].contains(name) {
            return .file
        }
        return .directory
    }

    @Test func noRemovableFindingIsProtected() throws {
        let engine = try RT.engine()
        let disk = Self.syntheticDisk()
        let findings = engine.findings(in: disk, home: RT.home, now: RT.now)
        #expect(findings.count > 40)
        var removable = 0
        for f in findings where f.classification.label <= .review {
            guard let id = f.classification.ruleID, !Self.exempt.contains(id) else { continue }
            removable += 1
            #expect(!ProtectedPaths.isProtected(f.path, home: RT.home), "rule \(id) suggests protected \(f.path)")
        }
        #expect(removable > 25)
        // Every rule id that can produce a removable finding appears at least once on the synthetic disk.
        let removableRules = try RuleEngine.bundledRules().filter { $0.label <= .review }.map(\.id)
        let seen = Set(findings.compactMap(\.classification.ruleID))
        for id in removableRules {
            #expect(seen.contains(id), "rule \(id) was not exercised by the synthetic disk")
        }
    }

    @Test func protectedLocationsNeverClassifyAsRemovable() throws {
        let engine = try RT.engine()
        for path in ProtectedPathsTests.protectedCases where path.hasPrefix("/") {
            // Directories always; plus the kind the scanner would really report for this path.
            for kind in Set([FileNode.Kind.directory, Self.realisticKind(path)]) {
                let node = FileNode(id: 1, name: (path as NSString).lastPathComponent, path: path, kind: kind,
                                    size: 50 * RT.GB, itemCount: 1, modified: RT.old, accessed: RT.old, children: [])
                guard let c = engine.classify(node, home: RT.home, now: RT.now), let id = c.ruleID else { continue }
                if Self.exempt.contains(id) { continue }
                // Paths with `..`/`//` are lexically different; only check those that normalize to themselves.
                guard ProtectedPaths.normalize(path) == path else { continue }
                #expect(c.label >= .keep, "\(path) [\(kind)] classified \(id) as \(c.label)")
            }
        }
    }
}
