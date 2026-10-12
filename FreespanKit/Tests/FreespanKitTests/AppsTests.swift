import Foundation
import Testing
@testable import FreespanKit

/// Synthetic installed apps + home tree for AppInventory / SpaceBreakdown. No real files are touched.
enum AppsFixture {
    static let home = RT.home
    static let MB = RT.MB
    static let GB = RT.GB

    static let records: [AppRecord] = [
        AppRecord(path: "/Applications/Claude.app", name: "Claude", bundleID: "com.anthropic.claudefordesktop",
                  bundleName: "Claude", version: "1.0", appBytes: 600 * MB, lastOpened: RT.recent),
        AppRecord(path: "/Applications/Google Chrome.app", name: "Google Chrome", bundleID: "com.google.Chrome",
                  bundleName: "Chrome", version: "140", appBytes: 1 * GB, lastOpened: RT.recent),
        AppRecord(path: "/Applications/Foo.app", name: "Foo", bundleID: "com.example.foo", bundleName: "Foo",
                  version: "2.1", appBytes: 100 * MB, lastOpened: RT.old),
        AppRecord(path: "/Applications/Tools/Baz.app", name: "Widget", bundleID: "com.example.baz", bundleName: "Baz",
                  version: nil, appBytes: 30 * MB, lastOpened: nil),
        AppRecord(path: "/Applications/Qux.app", name: "Qux", bundleID: "com.example.qux", bundleName: "Widget",
                  version: nil, appBytes: 20 * MB, lastOpened: nil),
        AppRecord(path: "/Applications/Safari.app", name: "Safari", bundleID: "com.apple.Safari", bundleName: "Safari",
                  version: "19", appBytes: 50 * MB, lastOpened: RT.recent),
    ]

    static var installedIDs: [String: String] {
        Dictionary(uniqueKeysWithValues: records.compactMap { r in r.bundleID.map { ($0, r.name) } })
    }

    static func directory() -> AppDirectory {
        let ids = installedIDs
        return AppDirectory(resolver: { id in ids[id].map { URL(fileURLWithPath: "/Applications/\($0).app") } },
                            appFolders: [])
    }

    static func inventory() -> AppInventory {
        AppInventory(appFolders: [], directory: directory(), listDirectory: { dir in
            dir == home + "/Library/LaunchAgents"
                ? [("com.example.foo.helper.plist", 4096), ("com.someone.else.plist", 4096)]
                : []
        })
    }

    static let libraryItems: [RT.Item] = [
        // Claude: VM (known location), agent sessions, web cache (rule), the rest, plus a cache folder.
        RT.file("~/Library/Application Support/Claude/vm_bundles/claudevm.bundle", 8 * GB),
        RT.file("~/Library/Application Support/Claude/local-agent-mode-sessions/s1", 1_200 * MB),
        RT.file("~/Library/Application Support/Claude/Cache/data", 300 * MB),
        RT.small(in: "~/Library/Application Support/Claude", 2 * MB),
        RT.file("~/Library/Caches/com.anthropic.claudefordesktop/blob", 200 * MB),
        // Chrome: profile (owner in KnownLocations), its cache (rule), Google's shared updater (not Chrome's).
        RT.file("~/Library/Application Support/Google/Chrome/Default/Cache/data", 2 * GB),
        RT.file("~/Library/Application Support/Google/Chrome/Default/History", 500 * MB),
        RT.file("~/Library/Application Support/Google/GoogleUpdater/updater", 100 * MB),
        // Foo: by bundle ID and name.
        RT.file("~/Library/Application Support/com.example.foo/db", 50 * MB),
        RT.file("~/Library/Containers/com.example.foo/Data/Library/Caches/c", 30 * MB),
        RT.file("~/Library/Containers/com.example.foo/Data/Documents/doc", 10 * MB),
        RT.small(in: "~/Library/Saved Application State/com.example.foo.savedState", 1 * MB),
        RT.file("~/Library/Logs/Foo/foo.log", 5 * MB),
        RT.file("~/Library/Group Containers/ABCDE12345.com.example.foo.shared/x", 5 * MB),
        RT.file("~/Library/Group Containers/ABCDE12345.com.example.other/x", 5 * MB),
        RT.file("~/Library/HTTPStorages/com.example.foo/x", 2 * MB),
        // "Widget" is the display name of one app and the bundle name of another: shared, attached to neither.
        RT.file("~/Library/Application Support/Widget/w", 40 * MB),
        // Leftovers.
        RT.file("~/Library/Application Support/com.gone.app/data", 300 * MB),
        RT.file("~/Library/Containers/com.gone.app/Data/x", 200 * MB),
        RT.file("~/Library/Caches/com.gone.app/x", 50 * MB),
        RT.file("~/Library/Group Containers/group.com.gone/x", 5 * MB),
        RT.small(in: "~/Library/Application Support/com.tiny.app", 500_000),
        RT.file("~/Library/Application Support/com.apple.gone/x", 10 * MB),
        RT.file("~/Library/Containers/com.apple.Safari/Data/x", 20 * MB),
    ]

    static func tree(_ extra: [RT.Item] = []) -> FileNode { RT.tree(libraryItems + extra, root: home) }

    static func ruleFindings(_ root: FileNode) throws -> [Finding] {
        try RuleEngine.bundled().findings(in: root, home: home, now: RT.now)
    }

    static func build(_ root: FileNode, findings: [Finding]? = nil) throws -> AppInventoryResult {
        inventory().assemble(records: records, tree: root, findings: try findings ?? ruleFindings(root), home: home)
    }

    static func p(_ s: String) -> String { RT.p(s) }
}

@Suite("AppInventory – related data")
struct AppsRelatedTests {
    typealias F = AppsFixture

    func app(_ result: AppInventoryResult, _ name: String) throws -> InstalledApp {
        try #require(result.apps.first { $0.name == name })
    }

    func item(_ app: InstalledApp, _ path: String) -> Finding? {
        app.related.first { $0.path == F.p(path) }
    }

    @Test func claudeBreakdownMatchesRulesAndKnownLocations() throws {
        let result = try F.build(F.tree())
        let claude = try app(result, "Claude")
        let vm = try #require(item(claude, "~/Library/Application Support/Claude/vm_bundles"))
        #expect(vm.classification.title == "Claude virtual machine")
        #expect(vm.classification.label == .review)
        #expect(vm.size == 8 * F.GB)
        let sessions = try #require(item(claude, "~/Library/Application Support/Claude/local-agent-mode-sessions"))
        #expect(sessions.classification.label == .review)
        let cache = try #require(item(claude, "~/Library/Application Support/Claude/Cache"))
        #expect(cache.classification.label == .safe && cache.classification.source == .rule)
        let rest = try #require(item(claude, "~/Library/Application Support/Claude"))
        #expect(rest.size == 2 * F.MB) // only what nothing inside explains
        #expect(rest.classification.title == "Claude app data")
        let caches = try #require(item(claude, "~/Library/Caches/com.anthropic.claudefordesktop"))
        #expect(caches.classification.label == .safe)
        #expect(claude.dataBytes == 8 * F.GB + 1_200 * F.MB + 300 * F.MB + 2 * F.MB + 200 * F.MB)
        #expect(claude.extrasBytes == 500 * F.MB)
        #expect(claude.totalBytes == claude.appBytes + claude.dataBytes)
    }

    @Test func existingFindingsWinOverLocalClassification() throws {
        let root = F.tree()
        var findings = try F.ruleFindings(root)
        let vmNode = try #require(root.find(F.p("~/Library/Application Support/Claude/vm_bundles")))
        findings.append(Finding(node: vmNode, classification: Classification(
            category: .applications, label: .review, title: "Claude VM (from assistant)", explanation: "x",
            regenerates: true, source: .ai)))
        let claude = try app(try F.build(root, findings: findings), "Claude")
        #expect(item(claude, "~/Library/Application Support/Claude/vm_bundles")?.classification.title == "Claude VM (from assistant)")
    }

    @Test func chromeGetsItsProfileButNotGoogleSharedData() throws {
        let chrome = try app(try F.build(F.tree()), "Google Chrome")
        #expect(item(chrome, "~/Library/Application Support/Google/Chrome/Default/Cache")?.classification.label == .safe)
        #expect(item(chrome, "~/Library/Application Support/Google/Chrome")?.size == 500 * F.MB)
        #expect(!chrome.related.contains { $0.path.contains("GoogleUpdater") })
        #expect(chrome.dataBytes == 2_500 * F.MB)
    }

    @Test func fooMatchedByBundleIDNameGroupAndLaunchAgent() throws {
        let foo = try app(try F.build(F.tree()), "Foo")
        let paths = Set(foo.related.map(\.path))
        #expect(paths.contains(F.p("~/Library/Application Support/com.example.foo")))
        #expect(paths.contains(F.p("~/Library/Containers/com.example.foo/Data/Library/Caches")))
        #expect(paths.contains(F.p("~/Library/Containers/com.example.foo")))
        #expect(paths.contains(F.p("~/Library/Group Containers/ABCDE12345.com.example.foo.shared")))
        #expect(!paths.contains(F.p("~/Library/Group Containers/ABCDE12345.com.example.other")))
        // Logs/<name> inherits the Logs rule (Safe); saved state is "Check first".
        #expect(item(foo, "~/Library/Logs/Foo")?.classification.label == .safe)
        let saved = try #require(item(foo, "~/Library/Saved Application State/com.example.foo.savedState"))
        #expect(saved.classification.label == .review)
        #expect(saved.classification.title == "Foo saved windows")
        let agent = try #require(item(foo, "~/Library/LaunchAgents/com.example.foo.helper.plist"))
        #expect(agent.size == 4096 && agent.classification.label == .review)
        // Protected (HTTPStorages, Preferences) never attached.
        #expect(!foo.related.contains { ProtectedPaths.isProtected($0.path, home: F.home) })
        #expect(!paths.contains { $0.contains("HTTPStorages") })
        #expect(foo.related.allSatisfy { $0.classification.label != .protected })
    }

    @Test func sharedFolderAttachedToNoApp() throws {
        let result = try F.build(F.tree())
        for app in result.apps {
            #expect(!app.related.contains { $0.path.hasSuffix("/Widget") }, "\(app.name)")
        }
    }

    @Test func noByteCountedTwiceAcrossApps() throws {
        let result = try F.build(F.tree())
        let all = result.apps.flatMap(\.related).map(\.path)
        #expect(Set(all).count == all.count)
        let totalData = result.apps.reduce(Int64(0)) { $0 + $1.dataBytes }
        let lib = try #require(F.tree().find(F.p("~/Library")))
        #expect(totalData <= lib.size + 4096)
    }

    @Test func safariIsBlockedAndHasNoProtectedData() throws {
        let safari = try app(try F.build(F.tree()), "Safari")
        #expect(safari.isAppleApp)
        #expect(!safari.canUninstall)
        #expect(safari.uninstallBlockedReason?.contains("part of macOS") == true)
        #expect(safari.related.isEmpty)
        #expect(AppInventory.uninstallItems(for: safari, home: F.home).isEmpty)
    }

    @Test func freespanItselfIsBlocked() {
        let reason = AppInventory.uninstallBlockedReason(path: "/Applications/Freespan.app", name: "Freespan",
                                                         bundleID: "com.mcconnelldigital.Freespan", home: F.home)
        #expect(reason == "This is Freespan itself.")
        #expect(AppInventory.uninstallBlockedReason(path: "/Applications/Xcode.app", name: "Xcode",
                                                    bundleID: "com.apple.dt.Xcode", home: F.home) == nil)
    }

    @Test func appsSortedByTotalSize() throws {
        let result = try F.build(F.tree())
        let totals = result.apps.map(\.totalBytes)
        #expect(totals == totals.sorted(by: >))
        #expect(result.apps.first?.name == "Claude")
    }

    @Test func noScanMeansBundlesOnly() {
        let result = F.inventory().assemble(records: F.records, tree: nil, findings: [], home: F.home)
        #expect(result.apps.count == F.records.count)
        #expect(result.apps.allSatisfy { $0.related.isEmpty })
        #expect(result.leftovers.isEmpty)
    }
}

@Suite("AppInventory – leftovers and uninstall")
struct AppsLeftoverUninstallTests {
    typealias F = AppsFixture

    @Test func leftoversGroupedPerOwner() throws {
        let result = try F.build(F.tree())
        // com.gone.app (four folders) and the uninstalled com.example.other group container; largest first.
        #expect(result.leftovers.map(\.bundleID) == ["com.gone.app", "com.example.other"])
        let gone = try #require(result.leftovers.first)
        let paths = Set(gone.items.map(\.path))
        #expect(paths == [
            F.p("~/Library/Application Support/com.gone.app"),
            F.p("~/Library/Containers/com.gone.app"),
            F.p("~/Library/Caches/com.gone.app"),
            F.p("~/Library/Group Containers/group.com.gone"),
        ])
        #expect(gone.bytes == 555 * F.MB)
        #expect(gone.items.first?.size == 300 * F.MB) // largest first
        // Apple IDs, tiny folders and installed apps' data are never leftovers.
        let all = result.leftovers.flatMap(\.items).map(\.path)
        #expect(!all.contains { $0.contains("com.apple") || $0.contains("com.tiny") || $0.contains("com.example.foo") })
    }

    @Test func leftoverLabelsAreNeverSafeFromGuesswork() throws {
        let gone = try #require(try F.build(F.tree()).leftovers.first)
        for item in gone.items where item.classification.source != .rule {
            #expect(item.classification.label == .review)
        }
    }

    @Test func uninstallItemsBundleFirstThenOutermostData() throws {
        let claude = try #require(try F.build(F.tree()).apps.first { $0.name == "Claude" })
        let items = AppInventory.uninstallItems(for: claude, home: F.home)
        #expect(items.count == 3)
        #expect(items[0].path == "/Applications/Claude.app")
        #expect(items[0].classification.title == "Claude app")
        #expect(items[0].classification.explanation == "The app itself. Moving it to the Trash uninstalls it.")
        #expect(items[0].size == claude.appBytes)
        #expect(items[1].path == F.p("~/Library/Application Support/Claude"))
        #expect(items[1].size == 9_502 * F.MB) // nested VM, sessions and cache folded in
        #expect(items[2].path == F.p("~/Library/Caches/com.anthropic.claudefordesktop"))
        // No item inside another.
        for a in items { for b in items where a.path != b.path { #expect(!b.path.hasPrefix(a.path + "/")) } }
        #expect(items.reduce(Int64(0)) { $0 + $1.size } == claude.totalBytes)
    }

    @Test func uninstallSkipsProtectedAndBlocked() {
        let protectedItem = Finding(path: F.p("~/Library/Preferences/com.example.foo.plist"), name: "p", size: 10, itemCount: 1,
                                    modified: nil, accessed: nil, isDirectory: false,
                                    classification: Classification(category: .applications, label: .review, title: "t",
                                                                   explanation: "e", regenerates: false, source: .heuristic))
        let ok = Finding(path: F.p("~/Library/Application Support/Foo"), name: "Foo", size: 20, itemCount: 1,
                         modified: nil, accessed: nil, isDirectory: true, classification: protectedItem.classification)
        let app = InstalledApp(path: "/Applications/Foo.app", name: "Foo", bundleID: "com.example.foo", version: nil,
                               appBytes: 5, lastOpened: nil, isAppleApp: false, canUninstall: true,
                               uninstallBlockedReason: nil, related: [protectedItem, ok])
        #expect(AppInventory.uninstallItems(for: app, home: F.home).map(\.path) == ["/Applications/Foo.app", ok.path])
        let blocked = InstalledApp(path: "/Applications/Foo.app", name: "Foo", bundleID: nil, version: nil, appBytes: 5,
                                   lastOpened: nil, isAppleApp: false, canUninstall: false,
                                   uninstallBlockedReason: "no", related: [ok])
        #expect(AppInventory.uninstallItems(for: blocked, home: F.home).isEmpty)
    }

    @Test func groupContainerMatching() {
        let ids = ["com.docker.docker", "com.example.foo"]
        #expect(RelatedContextProbe.group("group.com.docker", "com.docker.docker", ids))
        #expect(RelatedContextProbe.group("ABCDE12345.com.example.foo", "com.example.foo", ids))
        #expect(!RelatedContextProbe.group("group.com.example", "com.example.foo", ids + ["com.example.bar"]))
        #expect(!RelatedContextProbe.group("UBF8T346G9.Office", "com.microsoft.Word", ids))
        #expect(!RelatedContextProbe.group("group.com.apple.notes", "com.apple.notes.x", ids))
    }
}

/// Access to the private group-container matcher through AppInventory's public behaviour.
enum RelatedContextProbe {
    static func group(_ folder: String, _ bid: String, _ ids: [String]) -> Bool {
        AppInventory.groupContainer(folder, matches: bid.lowercased(), installedIDs: ids.map { $0.lowercased() })
    }
}
