import Foundation
import Testing
@testable import FreespanKit

@Suite("Rules – summarize & unknown items")
struct RulesSummaryTests {
    func finding(_ path: String, _ size: Int64, _ category: CategoryID, _ label: SafetyLabel) -> Finding {
        Finding(path: path, name: (path as NSString).lastPathComponent, size: size, itemCount: 1,
                modified: nil, accessed: nil, isDirectory: true,
                classification: Classification(category: category, label: label, title: "t", explanation: "e",
                                               regenerates: false, source: .rule, ruleID: "r"))
    }

    @Test func summarizeTotalsSafeBytesAndOther() {
        let f = [
            finding("/a", 10, .developer, .safe),
            finding("/b", 5, .developer, .review),
            finding("/c", 7, .caches, .safe),
            finding("/d", 3, .system, .protected),
        ]
        let s = RuleEngine.summarize(f, rootSize: 100)
        #expect(s.map(\.category) == [.developer, .caches, .system, .other])
        let dev = s[0]
        #expect(dev.totalBytes == 15 && dev.safeBytes == 10 && dev.findingCount == 2)
        #expect(s[1].totalBytes == 7 && s[1].safeBytes == 7)
        #expect(s[2].safeBytes == 0)
        #expect(s.last!.totalBytes == 100 - 25)
        #expect(s.last!.findingCount == 0)
    }

    @Test func summarizeOmitsEmptyCategoriesButKeepsOther() {
        let s = RuleEngine.summarize([], rootSize: 42)
        #expect(s == [CategorySummary(category: .other, totalBytes: 42, safeBytes: 0, findingCount: 0)])
        let zero = RuleEngine.summarize([finding("/z", 0, .downloads, .review)], rootSize: 10)
        #expect(!zero.contains { $0.category == .downloads })
    }

    @Test func summarizeOtherNeverNegative() {
        let s = RuleEngine.summarize([finding("/a", 500, .caches, .safe)], rootSize: 100)
        #expect(s.last!.category == .other)
        #expect(s.last!.totalBytes == 0)
    }

    @Test func summarizeOverRealFindings() throws {
        let root = RT.tree([
            RT.dir("~/Library/Caches/A", 3 * RT.GB),
            RT.dir("~/Library/Developer/Xcode/DerivedData/X", 2 * RT.GB),
            RT.file("~/Downloads/a.dmg", 1 * RT.GB),
            RT.file("~/Documents/notes.txt", 4 * RT.GB),
        ])
        let f = try RT.engine().findings(in: root, home: RT.home, now: RT.now)
        let s = RuleEngine.summarize(f, rootSize: root.size)
        #expect(s.reduce(0) { $0 + $1.totalBytes } == root.size)
        #expect(s.first { $0.category == .other }?.totalBytes == 4 * RT.GB)
        #expect(s.first { $0.category == .downloads }?.safeBytes == 0)
    }

    // MARK: - unknownLargeItems

    @Test func unknownPrefersDeepestDominantFolder() throws {
        let root = RT.tree([
            // Foo: two equal halves → Foo itself is the unit.
            RT.dir("~/Library/Application Support/Foo/a", 10 * RT.GB),
            RT.dir("~/Library/Application Support/Foo/b", 10 * RT.GB),
            // Bar → Data holds 90% → descend; Data's children are split → Data is the unit.
            RT.dir("~/Library/Application Support/Bar/Data/x", 2 * RT.GB),
            RT.dir("~/Library/Application Support/Bar/Data/y", 2_500 * RT.MB),
            RT.small(in: "~/Library/Application Support/Bar", 500 * RT.MB),
            // Matched: never returned.
            RT.dir("~/Library/Caches/Big", 30 * RT.GB),
            // Project whose bulk is node_modules (matched) → little unexplained → not returned.
            RT.dir("~/Desktop/AppDev/site/node_modules", 3 * RT.GB),
            RT.dir("~/Desktop/AppDev/site/src", 200 * RT.MB),
            // Folder of many small files → the folder is the unit.
            RT.small(in: "~/Documents/Taxes", 1 * RT.GB),
            // A big unmatched recent file.
            RT.file("~/Documents/VM/disk.img", 8 * RT.GB),
            // Below threshold.
            RT.dir("~/Documents/Small", 100 * RT.MB),
        ])
        let unknown = try RT.engine().unknownLargeItems(in: root, home: RT.home)
        #expect(unknown.map(\.path) == [
            RT.p("~/Library/Application Support/Foo"),
            RT.p("~/Documents/VM/disk.img"),
            RT.p("~/Library/Application Support/Bar/Data"),
            RT.p("~/Documents/Taxes"),
        ])
    }

    @Test func unknownNeverReturnsHomeOrItsAncestors() throws {
        let root = RT.tree([
            RT.small(in: "~", 5 * RT.GB),
            RT.dir("~/Pictures/Exports/a", 200 * RT.MB),
            RT.dir("~/Pictures/Exports/b", 200 * RT.MB),
            RT.dir("~/Pictures/Other/c", 400 * RT.MB),
        ])
        let unknown = try RT.engine().unknownLargeItems(in: root, home: RT.home)
        // Pictures is structural; no child reaches 500 MB, so Pictures itself is the unit.
        #expect(unknown.map(\.path) == [RT.p("~/Pictures")])
    }

    @Test func unknownRespectsLimitAndMinSize() throws {
        var items: [RT.Item] = []
        for i in 0..<10 { items.append(RT.dir("~/Documents/D\(i)/x", Int64(i + 1) * RT.GB)) }
        let engine = try RT.engine()
        let root = RT.tree(items)
        let top3 = engine.unknownLargeItems(in: root, home: RT.home, limit: 3)
        #expect(top3.map(\.size) == [10, 9, 8].map { $0 * RT.GB })
        #expect(engine.unknownLargeItems(in: root, home: RT.home, minSize: 6 * RT.GB).count == 5)
    }
}
