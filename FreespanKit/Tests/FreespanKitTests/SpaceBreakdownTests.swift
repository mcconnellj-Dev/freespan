import Foundation
import Testing
@testable import FreespanKit

@Suite("SpaceBreakdown")
struct SpaceBreakdownTests {
    typealias F = AppsFixture
    let MB = RT.MB
    let GB = RT.GB

    static let extraItems: [RT.Item] = [
        RT.file("~/Downloads/old.dmg", 3 * RT.GB),
        RT.small(in: "~/Downloads", 100 * RT.MB),
        RT.file("~/Documents/Work/export.mov", 5 * RT.GB),
        RT.file("~/Documents/notes.txt", 200 * RT.MB),
        RT.pkg("~/Pictures/Photos Library.photoslibrary", 4 * RT.GB),
        RT.file("~/Library/Caches/com.other.cache/x", 1 * RT.GB),
        RT.file("~/Library/Developer/Xcode/DerivedData/x", 3 * RT.GB),
        RT.file("~/Desktop/AppDev/p/src.bin", 2 * RT.GB),
        RT.file("~/Desktop/AppDev/p/node_modules/x", 500 * RT.MB),
        RT.file("~/.Trash/x", 600 * RT.MB),
        RT.file("~/Music/x", 300 * RT.MB),
        RT.file("~/random/x", 1 * RT.GB),
    ]

    struct Setup {
        let scan: ScanResult
        let findings: [Finding]
        let apps: AppInventoryResult
        var total: Int64 { scan.root.size + apps.apps.reduce(0) { $0 + $1.appBytes } }
    }

    static func setup() throws -> Setup {
        let root = F.tree(extraItems)
        var findings = try F.ruleFindings(root)
        func identified(_ path: String, _ title: String, _ category: CategoryID) throws -> Finding {
            let node = try #require(root.find(RT.p(path)))
            return Finding(node: node, classification: Classification(
                category: category, label: .keep, title: title, explanation: "x", regenerates: false, source: .heuristic))
        }
        findings.append(try identified("~/Documents/Work", "Work exports", .other))
        findings.append(try identified("~/Desktop/AppDev", "Code projects", .developer))
        let apps = try F.build(root, findings: findings)
        let scan = ScanResult(root: root, volume: VolumeInfo(name: "Test", totalBytes: 100 * RT.GB, availableBytes: 10 * RT.GB),
                              scannedAt: RT.now, duration: 1, inaccessiblePaths: [])
        return Setup(scan: scan, findings: findings, apps: apps)
    }

    static func tiles(_ s: Setup, limit: Int = 20) -> [SpaceTile] {
        SpaceBreakdown.tiles(scan: s.scan, findings: s.findings, apps: s.apps, home: RT.home, limit: limit, now: RT.now)
    }

    func tile(_ tiles: [SpaceTile], _ id: String) throws -> SpaceTile {
        try #require(tiles.first { $0.id == id }, "no tile \(id): \(tiles.map(\.id))")
    }

    @Test func tilesAreExclusiveAndAddUpToTheTotal() throws {
        let s = try Self.setup()
        let tiles = Self.tiles(s)
        #expect(tiles.reduce(0) { $0 + $1.bytes } == s.total)
        #expect(Set(tiles.map(\.id)).count == tiles.count)
        #expect(tiles.last?.kind == .other)
        let shown = tiles.dropLast().map(\.bytes)
        #expect(shown == shown.sorted(by: >))
    }

    @Test func bigAppsGetTheirOwnTileWithBundleAndData() throws {
        let s = try Self.setup()
        let tiles = Self.tiles(s)
        let claude = try tile(tiles, "app:com.anthropic.claudefordesktop")
        #expect(claude.title == "Claude")
        #expect(claude.kind == .app(path: "/Applications/Claude.app", bundleID: "com.anthropic.claudefordesktop"))
        #expect(claude.bytes == 600 * MB + 9_702 * MB)
        #expect(claude.checkBytes == 9_200 * MB)
        #expect(claude.safeBytes == 500 * MB)
        let chrome = try tile(tiles, "app:com.google.Chrome")
        #expect(chrome.bytes == 3_500 * MB)
        #expect(chrome.safeBytes == 2 * GB)
        // The Apps tile holds the other bundles only.
        let apps = try tile(tiles, "apps")
        #expect(apps.bytes == 200 * MB)
        #expect(apps.subtitle == "4 apps · 1 not opened this year")
        #expect(apps.checkBytes == 0)
    }

    @Test func folderAndCategoryTiles() throws {
        let s = try Self.setup()
        let tiles = Self.tiles(s)
        #expect(try tile(tiles, "identified:Work exports").bytes == 5 * GB)
        #expect(try tile(tiles, "photos").bytes == 4 * GB)
        #expect(try tile(tiles, "photos").title == "Photos")
        let code = try tile(tiles, "code-projects")
        #expect(code.bytes == 2_500 * MB)
        #expect(code.safeBytes == 500 * MB) // node_modules
        let xcode = try tile(tiles, "xcode")
        #expect(xcode.bytes == 3 * GB && xcode.safeBytes == 3 * GB)
        // Claude's cache folder belongs to the Claude tile, not Caches. Caches = ~/Library/Caches (1,050 MB without
        // Claude's) + cache findings elsewhere: ~/Library/Logs (5 MB) and Foo's container cache (30 MB).
        let caches = try tile(tiles, "caches")
        #expect(caches.bytes == 1_085 * MB)
        #expect(caches.safeBytes == 1_085 * MB)
        let downloads = try tile(tiles, "folder:\(RT.p("~/Downloads"))")
        #expect(downloads.bytes == 3_100 * MB && downloads.checkBytes == 3 * GB)
        #expect(try tile(tiles, "trash").bytes == 600 * MB)
        // Documents keeps only what Work exports didn't take.
        #expect(try tile(tiles, "folder:\(RT.p("~/Documents"))").bytes == 200 * MB)
        #expect(try tile(tiles, "folder:\(RT.p("~/Music"))").bytes == 300 * MB)
    }

    @Test func limitFoldsTheRestIntoOther() throws {
        let s = try Self.setup()
        let all = Self.tiles(s)
        let few = Self.tiles(s, limit: 3)
        #expect(few.count == 4)
        #expect(few.map(\.id).prefix(3) == all.map(\.id).prefix(3))
        #expect(few.reduce(0) { $0 + $1.bytes } == s.total)
        // Safe / check bytes are conserved when tiles fold into "Everything else".
        #expect(few.reduce(0) { $0 + $1.safeBytes } == all.reduce(0) { $0 + $1.safeBytes })
        #expect(few.reduce(0) { $0 + $1.checkBytes } == all.reduce(0) { $0 + $1.checkBytes })
        let other = try #require(few.last)
        #expect(other.id == "other" && other.title == "Everything else")
        #expect(other.safeBytes + other.checkBytes <= other.bytes)
    }

    @Test func stableIDs() throws {
        let s = try Self.setup()
        #expect(Self.tiles(s).map(\.id) == Self.tiles(s).map(\.id))
    }

    @Test func noAppsStillAddsUp() throws {
        let s = try Self.setup()
        let tiles = SpaceBreakdown.tiles(scan: s.scan, findings: s.findings, apps: nil, home: RT.home, limit: 8, now: RT.now)
        #expect(tiles.reduce(0) { $0 + $1.bytes } == s.scan.root.size)
        #expect(!tiles.contains { if case .app = $0.kind { true } else { false } })
    }

    @Test func wholeDiskScanCountsBundlesOnce() throws {
        let items: [RT.Item] = [
            RT.pkg("/Applications/Foo.app", 100 * MB),
            RT.pkg("/Applications/Claude.app", 600 * MB),
            RT.file("/System/Library/kernel", 10 * GB),
            RT.file("/private/var/db/x", 2 * GB),
        ] + (F.libraryItems + Self.extraItems)
        let root = RT.tree(items, root: "/")
        let findings = try F.ruleFindings(root)
        let records = [F.records[0], F.records[2]]
        let apps = F.inventory().assemble(records: records, tree: root, findings: findings, home: RT.home)
        let scan = ScanResult(root: root, volume: VolumeInfo(name: "HD", totalBytes: 100 * GB, availableBytes: 10 * GB),
                              scannedAt: RT.now, duration: 1, inaccessiblePaths: [])
        let tiles = SpaceBreakdown.tiles(scan: scan, findings: findings, apps: apps, home: RT.home, limit: 20, now: RT.now)
        #expect(tiles.reduce(0) { $0 + $1.bytes } == root.size)
        #expect(try tile(tiles, "system").bytes == 12 * GB)
        #expect(try tile(tiles, "app:com.anthropic.claudefordesktop").bytes == 600 * MB + 9_702 * MB)
    }

    @Test func ledgerNeverHandsOutAByteTwice() {
        var ledger = SpaceBreakdown.ClaimLedger()
        typealias C = SpaceBreakdown.Claim
        #expect(ledger.claim(C(path: "/a", size: 10, covering: true)) == 10)
        #expect(ledger.claim(C(path: "/a/b", size: 5, covering: true)) == 0)
        #expect(ledger.claim(C(path: "/c/d", size: 3, covering: true)) == 3)
        #expect(ledger.claim(C(path: "/c", size: 10, covering: true)) == 7)
        #expect(ledger.claim(C(path: "/e", size: 4, covering: false)) == 4)
        #expect(ledger.claim(C(path: "/e/f", size: 2, covering: true)) == 2)
        #expect(ledger.claim(C(path: "/e", size: 4, covering: true)) == 0)
        #expect(ledger.claim(C(path: "/", size: 100, covering: true)) == 74)
    }
}
