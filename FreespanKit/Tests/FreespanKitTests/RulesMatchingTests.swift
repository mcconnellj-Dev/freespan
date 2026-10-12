import Foundation
import Testing
@testable import FreespanKit

@Suite("Rules – catalog matching")
struct RulesMatchingTests {
    let engine: RuleEngine

    init() throws { engine = try RT.engine() }

    func ruleID(_ item: RT.Item) -> String? {
        engine.classify(RT.node(item), home: RT.home, now: RT.now)?.ruleID
    }

    @Test func otherToolCachesAreNamedAndNeedACheck() throws {
        let c = try #require(engine.classify(RT.node(RT.dir("~/.cache/polyedge", RT.GB)), home: RT.home, now: RT.now))
        #expect(c.title == "Tool cache: polyedge")
        #expect(c.label == .review)
        let uv = try #require(engine.classify(RT.node(RT.dir("~/.cache/uv", RT.GB)), home: RT.home, now: RT.now))
        #expect(uv.label == .safe)
        #expect(uv.explanation.contains("downloads them again") && uv.explanation.contains("free less space"))
    }

    @Test func catalogLoadsWithUniqueIDsAndText() throws {
        let rules = try RuleEngine.bundledRules()
        #expect(rules.count >= 40)
        #expect(Set(rules.map(\.id)).count == rules.count)
        for r in rules {
            #expect(!r.title.isEmpty && !r.explanation.isEmpty, "\(r.id)")
            #expect(!r.match.paths.isEmpty, "\(r.id)")
        }
    }

    static let cases: [(RT.Item, String?)] = [
        // Developer
        (RT.dir("~/Library/Developer/Xcode/DerivedData", RT.GB), "xcode-derived-data"),
        (RT.dir("~/Library/Developer/Xcode/DerivedData/App-abcdef", RT.GB), nil),
        (RT.pkg("~/Library/Developer/Xcode/Archives/2024-03-01/App 3-1-24, 10.00.xcarchive", RT.GB), "xcode-archives"),
        (RT.dir("~/Library/Developer/Xcode/Archives", RT.GB), nil),
        (RT.dir("~/Library/Developer/Xcode/iOS DeviceSupport/17.4 (21E219)", RT.GB), "xcode-device-support"),
        (RT.dir("~/Library/Developer/Xcode/watchOS DeviceSupport/Watch6,1 10.0", RT.GB), "xcode-device-support"),
        (RT.dir("~/Library/Developer/Xcode/iOS DeviceSupport", RT.GB), nil),
        (RT.dir("~/Library/Developer/Xcode/UserData/Previews", RT.GB), "xcode-previews"),
        (RT.dir("~/Library/Developer/Xcode/DocumentationCache", RT.GB), "xcode-documentation-cache"),
        (RT.dir("~/Library/Developer/CoreSimulator/Caches", RT.GB), "simulator-caches"),
        (RT.dir("~/Library/Developer/CoreSimulator/Devices/0B6F9C3A-1111-2222-3333-444455556666", RT.GB), "simulator-device"),
        (RT.dir("~/Library/Developer/CoreSimulator/Devices", RT.GB), nil),
        (RT.dir("~/Desktop/AppDev/site/node_modules", RT.GB), "node-modules"),
        (RT.dir("~/Desktop/AppDev/site/node_modules/react/node_modules", RT.GB), nil),
        (RT.dir("~/Library/Application Support/Code/node_modules", RT.GB), nil),
        (RT.dir("~/.vscode/extensions/ext/node_modules", RT.GB), nil),
        (RT.dir("~/.nvm/versions/node/v20/lib/node_modules", RT.GB), nil),
        (RT.dir("~/Desktop/AppDev/Pkg/.build", RT.GB), "swift-build-folder"),
        (RT.dir("~/.npm", RT.GB), "npm-cache"),
        (RT.dir("~/Library/Caches/Yarn", RT.GB), "yarn-cache"),
        (RT.dir("~/Library/pnpm/store", RT.GB), "pnpm-store"),
        (RT.dir("~/Library/Caches/pip", RT.GB), "pip-cache"),
        (RT.dir("~/.cache/uv", RT.GB), "uv-cache"),
        // ~/.cache: known tools are Safe one by one; anything else is a Review "Tool cache"; never the whole folder.
        (RT.dir("~/.cache", 40 * RT.GB), nil),
        (RT.dir("~/.cache/pip", RT.GB), "pip-cache"),
        (RT.dir("~/.cache/yarn", RT.GB), "yarn-cache"),
        (RT.dir("~/.cache/codex-runtimes", RT.GB), "codex-runtimes"),
        (RT.dir("~/.cache/gem", RT.GB), "gem-cache"),
        (RT.dir("~/.cache/pre-commit", RT.GB), "pre-commit-cache"),
        (RT.dir("~/.cache/node-gyp", RT.GB), "node-gyp-cache"),
        (RT.dir("~/.cache/go-build", RT.GB), "go-build-cache"),
        (RT.dir("~/.cache/bazel", RT.GB), "bazel-cache"),
        (RT.dir("~/.cache/prisma", RT.GB), "prisma-engines"),
        (RT.dir("~/.cache/electron", RT.GB), "electron-downloads"),
        (RT.dir("~/.cache/typescript", RT.GB), "typescript-cache"),
        (RT.dir("~/.cache/ms-playwright", RT.GB), "browser-automation-cache"),
        (RT.dir("~/.cache/polyedge", RT.GB), "tool-cache"),
        (RT.dir("~/.cache/hyperframes", RT.GB), "tool-cache"),
        (RT.dir("~/.cache/gh", RT.GB), "tool-cache"),
        (RT.file("~/.cache/settings.json", RT.GB), "tool-cache"),
        (RT.dir("~/.cache/polyedge/data", RT.GB), nil),
        (RT.dir("~/.cache/lm-studio", RT.GB), nil),
        (RT.dir("~/.gradle/caches", RT.GB), "gradle-cache"),
        (RT.dir("~/Library/Caches/CocoaPods", RT.GB), "cocoapods-cache"),
        (RT.dir("~/Library/Caches/org.swift.swiftpm", RT.GB), "swiftpm-cache"),
        (RT.dir("~/Library/Caches/Homebrew", RT.GB), "homebrew-cache"),
        (RT.file("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", 60 * RT.GB), "docker-disk-image"),
        // Caches & logs
        (RT.dir("~/Library/Caches/com.spotify.client", RT.GB), "app-cache"),
        (RT.dir("~/Library/Caches", RT.GB), nil),
        (RT.dir("~/Library/Containers/com.microsoft.Excel/Data/Library/Caches", RT.GB), "sandboxed-app-cache"),
        (RT.dir("~/Library/Application Support/Code/CachedData", RT.GB), "editor-cache"),
        (RT.dir("~/Library/Application Support/Code/User", RT.GB), nil),
        (RT.dir("~/.cache/puppeteer", RT.GB), "browser-automation-cache"),
        (RT.dir("~/Library/Logs", RT.GB), "user-logs"),
        (RT.dir("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", RT.GB), "mail-downloads"),
        (RT.dir("~/.Trash", RT.GB), "trash"),
        (RT.dir("/Library/Caches", RT.GB), "system-caches"),
        // Browser, Electron and tool caches (specific rules before the broad ones)
        (RT.dir("~/Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage", 5 * RT.GB), "browser-cache"),
        (RT.dir("~/Library/Application Support/Google/Chrome/Profile 3/Code Cache", RT.GB), "browser-cache"),
        (RT.dir("~/Library/Application Support/Google/Chrome/Default/GPUCache", RT.GB), "browser-cache"),
        (RT.dir("~/Library/Application Support/Google/Chrome/Default/Service Worker/ScriptCache", RT.GB), "browser-cache"),
        (RT.dir("~/Library/Application Support/Google/Chrome/component_crx_cache", RT.GB), "browser-cache"),
        (RT.dir("~/Library/Application Support/Microsoft Edge/Default/Cache", RT.GB), "browser-cache"),
        (RT.dir("~/Library/Application Support/BraveSoftware/Brave-Browser/Default/Code Cache", RT.GB), "browser-cache"),
        (RT.dir("~/Library/Application Support/Arc/User Data/Profile 1/Service Worker/CacheStorage", RT.GB), "browser-cache"),
        (RT.dir("~/Library/Application Support/Google/Chrome/Default", RT.GB), nil),
        (RT.dir("~/Library/Application Support/Google/Chrome/Default/Service Worker/Database", RT.GB), nil),
        (RT.dir("~/Library/Application Support/Google/Chrome/Default/IndexedDB", RT.GB), nil),
        (RT.dir("~/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", 4 * RT.GB), "chrome-ai-model"),
        (RT.dir("~/Library/Application Support/Google/GoogleUpdater/crx_cache", RT.GB), "google-updater-cache"),
        (RT.dir("~/Library/Application Support/Slack/Cache", RT.GB), "electron-app-cache"),
        (RT.dir("~/Library/Application Support/Slack/Service Worker/CacheStorage", RT.GB), "electron-app-cache"),
        (RT.dir("~/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Cache", RT.GB), "electron-app-cache"),
        (RT.dir("~/Library/Application Support/discord/Code Cache", RT.GB), "electron-app-cache"),
        (RT.dir("~/Library/Application Support/Microsoft/Teams/Cache", RT.GB), "electron-app-cache"),
        (RT.dir("~/Library/Application Support/Claude/Cache", RT.GB), "electron-app-cache"),
        (RT.dir("~/Library/Application Support/Code/GPUCache", RT.GB), "electron-app-cache"),
        (RT.dir("~/Library/Application Support/Code/Cache", RT.GB), "editor-cache"),
        (RT.dir("~/Library/Application Support/Claude", RT.GB), nil),
        (RT.dir("~/Library/Application Support/Claude/vm_bundles", RT.GB), nil),
        (RT.dir("~/Library/Application Support/SomeApp/Cache", RT.GB), nil),
        (RT.dir("~/Library/Application Support/Spotify/PersistentCache", 3 * RT.GB), "spotify-offline"),
        (RT.dir("~/Library/Caches/JetBrains", RT.GB), "jetbrains-cache"),
        (RT.dir("~/Library/Caches/JetBrains/IntelliJIdea2024.1", RT.GB), nil),
        (RT.dir("~/Library/Android/sdk/system-images/android-34", 8 * RT.GB), "android-system-images"),
        (RT.dir("~/Library/Android/sdk/system-images", 8 * RT.GB), nil),
        (RT.dir("~/.ollama/models", 20 * RT.GB), "ollama-models"),
        (RT.dir("~/.ollama", 20 * RT.GB), nil),
        (RT.dir("~/.cache/huggingface", 10 * RT.GB), "huggingface-cache"),
        (RT.dir("~/Documents/Zoom", 2 * RT.GB), "zoom-recordings"),
        // Backups
        (RT.dir("~/Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E", 40 * RT.GB), "iphone-backup"),
        (RT.dir("~/Library/Application Support/MobileSync/Backup", RT.GB), nil),
        // Downloads
        (RT.file("~/Downloads/Xcode_16.xip", 3 * RT.GB), "download-installer"),
        (RT.file("~/Downloads/Setup.PKG", RT.MB), "download-installer"),
        (RT.file("~/Downloads/report.pdf", RT.MB, old: true), "download-old"),
        (RT.dir("~/Downloads/Project Files", RT.GB, old: true), "download-old"),
        (RT.file("~/Downloads/report.pdf", RT.MB), "download-recent"),
        (RT.dir("~/Downloads/stuff/inner.dmg", RT.MB), nil),
        // Media
        (RT.pkg("~/Pictures/Photos Library.photoslibrary", 13 * RT.GB), "photos-library"),
        (RT.pkg("~/Downloads/Old Library.photoslibrary", 13 * RT.GB), "photos-library"),
        (RT.dir("~/Music", RT.GB), "music-folder"),
        (RT.dir("~/Movies", RT.GB), "movies-folder"),
        // Applications
        (RT.pkg("/Applications/Slack.app", RT.GB), "application"),
        (RT.pkg("/Applications/Utilities/Some Tool.app", RT.GB), "application"),
        (RT.pkg("~/Applications/Chrome App.app", RT.GB), "application"),
        (RT.pkg("/Applications/Safari.app", RT.GB), "apple-app"),
        // System
        (RT.dir("/System", RT.GB), "macos"),
        (RT.dir("/usr", RT.GB), "macos"),
        (RT.dir("/opt", RT.GB), "macos"),
        (RT.dir("/private/var/vm", RT.GB), "virtual-memory"),
        (RT.dir("/private/var/folders", RT.GB), "system-temporary"),
        (RT.dir("/private/var/db", RT.GB), "system-private"),
        (RT.dir("/private/etc", RT.GB), "system-private"),
        (RT.dir("/private", RT.GB), nil),
        (RT.dir("/private/var", RT.GB), nil),
        (RT.dir("/Library/Fonts", RT.GB), "system-library"),
        (RT.dir("/Library", RT.GB), nil),
        (RT.dir("/Users", RT.GB), nil),
        (RT.dir("/Users/Shared", RT.GB), "shared-users-folder"),
        (RT.dir("/Users/alex-work", RT.GB), "other-users"),
        (RT.dir("/Users/test", RT.GB), nil),
        (RT.dir("/Applications", RT.GB), nil),
        // Large & old
        (RT.file("~/Documents/Archive/old-video.mov", 600 * RT.MB, old: true), "large-old-file"),
        (RT.file("~/Documents/Archive/new-video.mov", 600 * RT.MB), nil),
        (RT.file("~/Documents/Archive/small-old.mov", 400 * RT.MB, old: true), nil),
        (RT.dir("~/Documents/Archive", 600 * RT.GB, old: true), nil),
        (RT.file("~/Library/Application Support/Foo/db.sqlite", 2 * RT.GB, old: true), nil),
        (RT.file("~/.docker/big.raw", 2 * RT.GB, old: true), nil),
        (RT.file("~/.zsh_history", 2 * RT.GB, old: true), nil),
    ]

    @Test(arguments: cases)
    func classifies(_ item: RT.Item, _ expected: String?) {
        #expect(ruleID(item) == expected, "\(item.path)")
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(ruleID(RT.dir("/Users/test/LIBRARY/developer/XCODE/derivedData", RT.GB)) == "xcode-derived-data")
        #expect(ruleID(RT.dir("/users/TEST/Library/Caches/Foo", RT.GB)) == "app-cache")
        #expect(engine.classify(RT.node(RT.dir("/Users/test/Library/Caches/Foo", 1)), home: "/USERS/Test")?.ruleID == "app-cache")
    }

    @Test func largeOldNeedsBothDatesOld() {
        var item = RT.file("~/Documents/vm.img", RT.GB, old: true)
        item.accessed = RT.recent
        #expect(ruleID(item) == nil)
        item.accessed = nil
        #expect(ruleID(item) == "large-old-file")
        item.modified = nil
        #expect(ruleID(item) == nil) // no dates → unknown age → not old
    }

    @Test func folderAgeIgnoresAccessDate() {
        // Listing a folder (e.g. our own scan) bumps its access date; only modification counts for folders.
        var item = RT.dir("~/Downloads/Old Project", RT.GB, old: true)
        item.accessed = RT.recent
        #expect(ruleID(item) == "download-old")
        var file = RT.file("~/Downloads/old.pdf", RT.MB, old: true)
        file.accessed = RT.recent
        #expect(ruleID(file) == "download-recent")
    }

    @Test func smallFilesNeverMatch() {
        let n = FileNode(id: 1, name: "Small files", path: RT.p("~/Library/Caches/Foo"), kind: .smallFiles,
                         size: RT.GB, itemCount: 100, modified: RT.old, accessed: RT.old, children: [])
        #expect(engine.classify(n, home: RT.home, now: RT.now) == nil)
    }

    @Test func classificationCarriesRuleText() throws {
        let c = try #require(engine.classify(RT.node(RT.dir("~/Library/Developer/Xcode/DerivedData", 1)), home: RT.home))
        #expect(c.source == .rule)
        #expect(c.category == .developer)
        #expect(c.label == .safe)
        #expect(c.regenerates)
        #expect(c.title.contains("DerivedData"))
    }

    // MARK: - Tree walking

    @Test func firstMatchDoesNotDescend() {
        let root = RT.tree([
            RT.dir("~/Library/Caches/com.example/node_modules", RT.GB),
            RT.file("~/Library/Caches/com.example/blob", 2 * RT.GB, old: true),
        ])
        let f = engine.findings(in: root, home: RT.home, now: RT.now)
        #expect(f.map(\.path) == [RT.p("~/Library/Caches/com.example")])
        #expect(f.first?.size == 3 * RT.GB)
        #expect(f.first?.classification.ruleID == "app-cache")
    }

    @Test func nodeModulesOutermostOnly() {
        let root = RT.tree([
            RT.dir("~/Desktop/AppDev/site/node_modules/react/node_modules/x", 100 * RT.MB),
            RT.dir("~/Desktop/AppDev/site/node_modules/vite", 300 * RT.MB),
            RT.dir("~/Desktop/AppDev/api/node_modules/a", 50 * RT.MB),
            RT.file("~/Desktop/AppDev/site/src/index.ts", 1 * RT.MB),
        ])
        let f = engine.findings(in: root, home: RT.home, now: RT.now)
        #expect(f.map(\.path) == [RT.p("~/Desktop/AppDev/site/node_modules"), RT.p("~/Desktop/AppDev/api/node_modules")])
        #expect(f.allSatisfy { $0.classification.ruleID == "node-modules" })
        #expect(f[0].size == 400 * RT.MB)
    }

    @Test func matchChildrenGivesOneFindingPerChild() {
        let root = RT.tree([
            RT.dir("~/Library/Developer/Xcode/iOS DeviceSupport/17.4 (21E219)", 5 * RT.GB),
            RT.dir("~/Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A3354)", 6 * RT.GB),
            RT.dir("~/Library/Developer/Xcode/iOS DeviceSupport/16.1 (20B82)", 4 * RT.GB),
            RT.small(in: "~/Library/Developer/Xcode/iOS DeviceSupport", RT.MB),
            RT.dir("~/Library/Application Support/MobileSync/Backup/aaaa", 30 * RT.GB),
            RT.dir("~/Library/Application Support/MobileSync/Backup/bbbb", 10 * RT.GB),
        ])
        let f = engine.findings(in: root, home: RT.home, now: RT.now)
        #expect(f.map(\.size) == [30, 10, 6, 5, 4].map { $0 * RT.GB })
        #expect(f.filter { $0.classification.ruleID == "xcode-device-support" }.count == 3)
        #expect(f.filter { $0.classification.ruleID == "iphone-backup" }.count == 2)
        #expect(!f.contains { $0.path.hasSuffix("iOS DeviceSupport") })
    }

    @Test func downloadsSplitByTypeAndAge() {
        let root = RT.tree([
            RT.file("~/Downloads/Xcode.xip", 7 * RT.GB, old: true),
            RT.file("~/Downloads/movie.mp4", 2 * RT.GB, old: true),
            RT.file("~/Downloads/today.pdf", 5 * RT.MB),
            RT.small(in: "~/Downloads", 3 * RT.MB),
        ])
        let f = engine.findings(in: root, home: RT.home, now: RT.now)
        let ids = Dictionary(uniqueKeysWithValues: f.map { ($0.name, $0.classification.ruleID ?? "") })
        #expect(ids == ["Xcode.xip": "download-installer", "movie.mp4": "download-old", "today.pdf": "download-recent"])
    }

    @Test func largeOldFindingsOnlyForUnmatchedHomeFiles() {
        let root = RT.tree([
            RT.file("~/Documents/vm/disk.img", 20 * RT.GB, old: true),
            RT.file("~/Desktop/clip.mov", 700 * RT.MB, old: true),
            RT.file("~/Desktop/fresh.mov", 700 * RT.MB),
            RT.file("~/Library/Application Support/App/data.bin", 5 * RT.GB, old: true),
            RT.file("/Users/Shared/big.bin", 5 * RT.GB, old: true),
            RT.file("~/Downloads/old.iso", 5 * RT.GB, old: true),
        ])
        let f = engine.findings(in: root, home: RT.home, now: RT.now)
        let largeOld = f.filter { $0.classification.category == .largeOld }.map(\.path)
        #expect(largeOld == [RT.p("~/Documents/vm/disk.img"), RT.p("~/Desktop/clip.mov")])
        #expect(f.first { $0.name == "old.iso" }?.classification.ruleID == "download-installer")
    }

    @Test func wholeDiskShapeFromRealMac() {
        let root = RT.tree([
            RT.dir("/System/Library", 15 * RT.GB),
            RT.dir("/private/var/vm", 4 * RT.GB),
            RT.dir("/private/var/db/uuidtext", 1 * RT.GB),
            RT.pkg("/Applications/Xcode.app", 12 * RT.GB),
            RT.dir("/Library/Caches/com.apple.x", 1 * RT.GB),
            RT.dir("/Library/Developer/CoreSimulator", 9 * RT.GB),
            RT.dir("~/Library/Developer/Xcode/DerivedData/A", 1 * RT.GB),
            RT.dir("~/Library/Caches/Google", 3 * RT.GB),
            RT.file("~/Downloads/a.dmg", 1 * RT.GB),
        ])
        let f = engine.findings(in: root, home: RT.home, now: RT.now)
        let byPath = Dictionary(uniqueKeysWithValues: f.map { ($0.path, $0.classification.ruleID ?? "") })
        #expect(byPath == [
            "/System": "macos",
            "/private/var/vm": "virtual-memory",
            "/private/var/db": "system-private",
            "/Applications/Xcode.app": "application",
            "/Library/Caches": "system-caches",
            "/Library/Developer": "system-library",
            RT.p("~/Library/Developer/Xcode/DerivedData"): "xcode-derived-data",
            RT.p("~/Library/Caches/Google"): "app-cache",
            RT.p("~/Downloads/a.dmg"): "download-installer",
        ])
    }

    @Test func customRuleShapeDecodes() throws {
        let json = """
        [{"id":"x","title":"X","explanation":"E","category":"developer","label":"safe","regenerates":true,
          "match":{"paths":["~/Projects/*"],"names":["Pods"],"kind":"dir","minSize":10}}]
        """
        let rules = try JSONDecoder().decode([Rule].self, from: Data(json.utf8))
        let e = RuleEngine(rules: rules)
        #expect(e.classify(RT.node(RT.dir("~/Projects/Pods", 100)), home: RT.home)?.ruleID == "x")
        #expect(e.classify(RT.node(RT.dir("~/Projects/Pods", 5)), home: RT.home) == nil)
        #expect(e.classify(RT.node(RT.file("~/Projects/Pods", 100)), home: RT.home) == nil)
        #expect(e.classify(RT.node(RT.dir("~/Projects/Other", 100)), home: RT.home) == nil)
    }

    @Test func globSegments() {
        #expect(Glob("*.app").matches("xcode.app"))
        #expect(!Glob("*.app").matches("xcode.apps"))
        #expect(Glob(".*").matches(".ssh"))
        #expect(Glob("a?c*z").matches("abcxyz"))
        #expect(!Glob("a?c*z").matches("acxyz"))
        #expect(Glob("*os devicesupport").matches("watchos devicesupport"))
    }

    @Test func findingsOverLargeTreeIsFast() throws {
        // ~300k nodes spread across home, with a mix of matched and unmatched subtrees.
        var items: [RT.Item] = []
        items.reserveCapacity(300_000)
        for p in 0..<300 {
            for f in 0..<400 { items.append(RT.file("~/Desktop/AppDev/p\(p)/src/m\(f / 40)/f\(f).swift", 2 * RT.MB)) }
            for f in 0..<300 { items.append(RT.file("~/Desktop/AppDev/p\(p)/node_modules/pkg\(f / 30)/i\(f).js", RT.MB)) }
            for f in 0..<200 { items.append(RT.file("~/Documents/d\(p)/sub\(f / 20)/doc\(f).pdf", RT.MB)) }
        }
        let root = RT.tree(items)
        let engine = try RT.engine()
        let start = ContinuousClock.now
        let f = engine.findings(in: root, home: RT.home, now: RT.now)
        let elapsed = ContinuousClock.now - start
        #expect(f.count == 300)
        print("findings over \(items.count) leaves took \(elapsed)")
        #expect(elapsed < .seconds(5)) // debug build; release is well under 1s
    }
}

extension RT.Item: CustomTestStringConvertible {
    var testDescription: String { "\(kind.rawValue) \(path)" }
}
