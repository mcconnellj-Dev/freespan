import Foundation
import Testing
@testable import FreespanKit

@Suite("ItemIdentifier")
struct IdentifyTests {
    static let home = "/Users/test"

    static func node(_ path: String, kind: FileNode.Kind = .directory, size: Int64 = 2_000_000_000,
                     modified: Date? = Date()) -> FileNode {
        let full = path.hasPrefix("~") ? home + path.dropFirst() : path
        return FileNode(id: 1, name: (full as NSString).lastPathComponent, path: full, kind: kind, size: size,
                        itemCount: 1, modified: modified, accessed: modified, children: [])
    }

    /// An identifier whose "installed apps" are exactly `apps` (bundle ID → app name).
    static func identifier(apps: [String: String] = [:]) -> ItemIdentifier {
        let directory = AppDirectory(resolver: { id in
            apps[id].map { URL(fileURLWithPath: "/Applications/\($0).app") }
        }, appFolders: [])
        return ItemIdentifier(catalog: .bundled, apps: directory)
    }

    final class TempHome {
        let url: URL
        var path: String { url.path }
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("freespan-identify-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func touch(_ rel: String) throws {
            let f = url.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: f)
        }
        func mkdir(_ rel: String) throws {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        func node(_ rel: String, kind: FileNode.Kind = .directory) -> FileNode {
            let p = url.appendingPathComponent(rel).path
            return FileNode(id: 1, name: (p as NSString).lastPathComponent, path: p, kind: kind, size: 1_000_000_000,
                            itemCount: 1, modified: Date(), accessed: Date(), children: [])
        }
    }

    // MARK: App IDs

    @Test func resolvesInstalledAppleAppByBundleID() throws {
        #expect(AppDirectory.shared.appName(bundleID: "com.apple.Safari") == "Safari")
        let c = try #require(ItemIdentifier().identify(Self.node("~/Library/Containers/com.apple.Safari/Data/Library/Thing"), home: Self.home))
        #expect(c.title == "Safari app data")
        #expect(c.label == .keep)
        #expect(c.source == .heuristic && c.ruleID == nil)
    }

    @Test func uninstalledBundleIDIsLeftoverForReview() throws {
        let c = try #require(ItemIdentifier().identify(
            Self.node("~/Library/Application Support/com.freespantest.photoeditor"), home: Self.home))
        #expect(c.title == "Leftover data from Photoeditor (app not installed)")
        #expect(c.label == .review)
        #expect(c.explanation.contains("uninstalled"))
        #expect(c.explanation.contains("com.freespantest.photoeditor"))
    }

    @Test func parsesTeamPrefixedAndGroupIDs() {
        let team = BundleID.parse("9K33E3U3T4.net.whatever.tool")
        #expect(team?.core == "net.whatever.tool")
        let group = BundleID.parse("group.com.docker")
        #expect(group?.core == "com.docker")
        #expect(group?.candidates.contains("com.docker.docker") == true)
        let both = BundleID.parse("group.ABCDE12345.com.vendor.app")
        #expect(both?.core == "com.vendor.app")
        #expect(BundleID.parse("com.spotify.client")?.guess == "Spotify")
        #expect(BundleID.parse("com.microsoft.OneDrive.FinderSync")?.candidates.contains("com.microsoft.OneDrive") == true)
        #expect(BundleID.parse("Cisco Spark") == nil)
        #expect(BundleID.parse("UBF8T346G9.Office") == nil)
        #expect(BundleID.parse("Google") == nil)
        #expect(BundleID.parse("node.js") == nil)
    }

    @Test func groupAndTeamIDsResolveToInstalledApps() throws {
        let id = Self.identifier(apps: ["com.docker.docker": "Docker", "net.whatever.tool": "Whatever Tool",
                                        "com.example.Writer": "Writer"])
        let group = try #require(id.identify(Self.node("~/Library/Group Containers/group.com.example.Writer/Stuff"), home: Self.home))
        #expect(group.title == "Writer app data")
        let team = try #require(id.identify(Self.node("~/Library/Group Containers/9K33E3U3T4.net.whatever.tool"), home: Self.home))
        #expect(team.title == "Whatever Tool app data")
        let docker = AppDirectory(resolver: { $0 == "com.docker.docker" ? URL(fileURLWithPath: "/Applications/Docker.app") : nil },
                                  appFolders: [])
        #expect(docker.owner(ofFolderNamed: "group.com.docker") == .installed(name: "Docker", bundleID: "com.docker.docker"))
        #expect(docker.owner(ofFolderNamed: "com.apple.something.agent") == .system(guess: "Something", bundleID: "com.apple.something.agent"))
    }

    @Test func appSubfoldersGetSpecificTitles() throws {
        let id = Self.identifier(apps: ["com.microsoft.Excel": "Microsoft Excel", "app.cotypist.Cotypist": "Cotypist"])
        let tmp = try #require(id.identify(Self.node("~/Library/Containers/com.microsoft.Excel/Data/tmp/Content.MSO"), home: Self.home))
        #expect(tmp.title == "Microsoft Excel temporary files")
        #expect(tmp.label == .review && tmp.regenerates)
        let model = try #require(id.identify(
            Self.node("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma.gguf", kind: .file), home: Self.home))
        #expect(model.title == "Cotypist AI model")
        #expect(model.label == .review)
    }

    // MARK: Known locations

    @Test func knownLocationsTable() throws {
        let id = Self.identifier()
        let chrome = try #require(id.identify(Self.node("~/Library/Application Support/Google/Chrome"), home: Self.home))
        #expect(chrome.title == "Google Chrome data")
        #expect(chrome.label == .keep)
        let profile = try #require(id.identify(Self.node("~/Library/Application Support/Google/Chrome/Default"), home: Self.home))
        #expect(profile.title == "Google Chrome data")
        let ollama = try #require(id.identify(Self.node("~/.ollama/models"), home: Self.home))
        #expect(ollama.title == "Ollama AI models")
        #expect(ollama.label == .review)
        let blobs = try #require(id.identify(Self.node("~/.ollama/models/blobs"), home: Self.home))
        #expect(blobs.title == "Ollama AI models")
        let vm = try #require(id.identify(Self.node("~/Library/Application Support/Claude/vm_bundles/claudevm.bundle"), home: Self.home))
        #expect(vm.title == "Claude virtual machine")
        let office = try #require(id.identify(Self.node("~/Library/Group Containers/UBF8T346G9.Office"), home: Self.home))
        #expect(office.title == "Microsoft Office shared data")
        let dropbox = try #require(id.identify(Self.node("~/Dropbox/Photos"), home: Self.home))
        #expect(dropbox.title == "Dropbox files" && dropbox.label == .keep)
    }

    @Test func catalogLoadsAndEveryEntryIsUsable() {
        let catalog = KnownLocationCatalog.bundled
        #expect(catalog.locations.count >= 50)
        #expect(Set(catalog.locations.map(\.id)).count == catalog.locations.count)
        for e in catalog.locations + catalog.fileTypes {
            #expect(!e.title.isEmpty && !e.explanation.isEmpty, "\(e.id)")
            #expect(e.label != .safe && e.label != .protected, "\(e.id) must be at most review")
        }
    }

    /// Dot folders Freespan can't remove are never offered for review, even if the table says review.
    @Test func protectedLocationsAreCappedAtKeep() throws {
        let id = Self.identifier()
        let versions = try #require(id.identify(Self.node("~/.rustup/toolchains/stable"), home: Self.home))
        #expect(versions.label == .keep)
        let c = Classification(category: .caches, label: .safe, title: "t", explanation: "e", regenerates: true, source: .ai)
        #expect(ItemIdentifier.capped(c, path: "/Users/test/Library/Application Support/X", home: Self.home).label == .review)
        let p = Classification(category: .system, label: .protected, title: "t", explanation: "e", regenerates: false, source: .ai)
        #expect(ItemIdentifier.capped(p, path: "/Users/test/Library/Application Support/X", home: Self.home).label == .keep)
        let r = Classification(category: .other, label: .review, title: "t", explanation: "e", regenerates: false, source: .ai)
        #expect(ItemIdentifier.capped(r, path: "/Users/test/.ssh/big", home: Self.home).label == .keep)
    }

    // MARK: Projects and user files

    @Test func detectsCodeProjects() throws {
        let h = try TempHome()
        try h.touch("Projects/site/package.json")
        try h.mkdir("Projects/site/data")
        try h.touch("Projects/Pkg/Package.swift")
        try h.mkdir("Projects/App/App.xcodeproj")
        try h.mkdir("Projects/plain")
        let id = Self.identifier()
        let site = try #require(id.identify(h.node("Projects/site"), home: h.path))
        #expect(site.title == "Code project: site")
        #expect(site.label == .keep && site.category == .developer)
        let data = try #require(id.identify(h.node("Projects/site/data"), home: h.path))
        #expect(data.title == "Part of code project: site")
        #expect(id.identify(h.node("Projects/App"), home: h.path)?.title == "Code project: App")
        #expect(id.identify(h.node("Projects"), home: h.path)?.title == "Code projects")
        let plain = try #require(id.identify(h.node("Projects/plain"), home: h.path))
        #expect(plain.title == "Your files" && plain.label == .keep)
    }

    @Test func userFoldersAreKept() throws {
        let id = Self.identifier()
        let docs = try #require(id.identify(Self.node("~/Documents/Taxes"), home: Self.home))
        #expect(docs.label == .keep)
        #expect(docs.title == "Your files")
        let exports = try #require(id.identify(Self.node("~/work/charter-redshift/exports"), home: Self.home))
        #expect(exports.label == .keep)
        let movie = try #require(id.identify(Self.node("~/Documents/clip.mov", kind: .file), home: Self.home))
        #expect(movie.label == .keep && movie.category == .media)
    }

    @Test func oldDiskImagesAndArchivesAreReview() throws {
        let id = Self.identifier()
        let old = Date(timeIntervalSinceNow: -400 * 86_400)
        let dmg = try #require(id.identify(Self.node("~/Documents/Installers/Tool.dmg", kind: .file, modified: old), home: Self.home))
        #expect(dmg.label == .review && dmg.category == .downloads)
        #expect(dmg.title.hasPrefix("Disk image"))
        #expect(dmg.title.contains("last changed"))
        let zip = try #require(id.identify(Self.node("~/Desktop/backup.zip", kind: .file), home: Self.home))
        #expect(zip.label == .review)
    }

    @Test func neverReturnsSafe() {
        let id = ItemIdentifier()
        let paths = [
            "~/Library/Application Support/Google/Chrome", "~/.ollama/models", "~/.cache/huggingface",
            "~/Library/Caches/com.example.thing", "~/Library/Logs/com.example.thing",
            "~/Library/Containers/com.example.gone/Data/Library/Caches", "~/Library/Application Support/Foo/Cache",
            "~/Library/HTTPStorages/com.example.gone", "~/Library/Saved Application State/com.apple.Safari.savedState",
            "~/Documents/a", "~/Desktop/b.zip", "~/.secret", "~/Library/Developer/Xcode/CodingAssistant",
            "/opt/homebrew", "/Applications/Foo.app",
        ]
        for p in paths {
            for kind in [FileNode.Kind.directory, .file] {
                guard let c = id.identify(Self.node(p, kind: kind), home: Self.home) else { continue }
                #expect(c.label != .safe && c.label != .protected, "\(p)")
                #expect(c.source == .heuristic, "\(p)")
                #expect(c.ruleID == nil)
            }
        }
    }

    /// Nothing in ~/Library is left for an assistant: unnamed items are "App data", macOS's own folders "macOS data".
    @Test func libraryItemsAreNeverNil() throws {
        let id = Self.identifier()
        let mystery = try #require(id.identify(Self.node("~/Library/SomethingElse"), home: Self.home))
        #expect(mystery.title == "App data" && mystery.category == .other && mystery.label == .keep)
        #expect(mystery.explanation == "Data an app keeps for itself. Remove the app to remove this.")
        let biome = try #require(id.identify(Self.node("~/Library/Biome/streams"), home: Self.home))
        #expect(biome.title == "macOS data (Biome)" && biome.category == .system && biome.label == .keep)
        let paths = [
            "~/Library", "~/Library/Metadata/CoreSpotlight/index", "~/Library/Caches/PlainName",
            "~/Library/Logs/PlainName", "~/Library/HTTPStorages/PlainName", "~/Library/Containers",
            "~/Library/Containers/0F1E2D3C-UUID", "~/Library/Developer/Xcode/UserData/Thing",
            "~/Library/Mystery/deep/file.bin", "~/Library/Daemon Containers/ABC/Data",
        ]
        for p in paths {
            for kind in [FileNode.Kind.directory, .file] {
                let c = id.identify(Self.node(p, kind: kind), home: Self.home)
                #expect(c != nil, "\(p) [\(kind)]")
                #expect(c.map { $0.label == .keep || $0.label == .review } ?? false, "\(p)")
            }
        }
    }

    @Test func unknownOrIrrelevantReturnsNil() {
        let id = Self.identifier()
        #expect(id.identify(Self.node("/Users/test", kind: .directory), home: Self.home) == nil)
        #expect(id.identify(Self.node("/System/Library", kind: .directory), home: Self.home) == nil)
        let small = FileNode(id: 1, name: "Small files", path: "/Users/test/Documents", kind: .smallFiles, size: 1,
                             itemCount: 1, modified: nil, accessed: nil, children: [])
        #expect(id.identify(small, home: Self.home) == nil)
    }
}
