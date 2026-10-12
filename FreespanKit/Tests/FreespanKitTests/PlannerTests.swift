import Foundation
import Testing
@testable import FreespanKit

@Suite("RulePlanner")
struct PlannerTests {
    static let GB: Int64 = 1_000_000_000
    static let roomy = VolumeInfo(name: "Macintosh HD", totalBytes: 500 * GB, availableBytes: 200 * GB)

    static func finding(_ path: String, _ size: Int64, label: SafetyLabel, rule: String? = nil,
                        source: ClassificationSource = .rule, title: String? = nil) -> Finding {
        Finding(path: "/Users/test/" + path, name: (path as NSString).lastPathComponent, size: size, itemCount: 1,
                modified: nil, accessed: nil, isDirectory: true,
                classification: Classification(category: .developer, label: label, title: title ?? rule ?? "Thing",
                                               explanation: "Explanation for \(rule ?? title ?? "thing").",
                                               regenerates: label == .safe, source: source,
                                               ruleID: source == .rule ? rule : nil))
    }

    @Test func emptyInput() {
        let plan = RulePlanner.plan(findings: [], volume: Self.roomy, home: "/Users/test")
        #expect(plan.steps.isEmpty)
        #expect(plan.headline == "Nothing to clean up right now.")
    }

    @Test func groupsByRuleAndOrdersSafeThenReviewLargestFirst() {
        let findings = [
            Self.finding("a/DeviceSupport/17", 3 * Self.GB, label: .safe, rule: "xcode-device-support"),
            Self.finding("a/DeviceSupport/18", 2 * Self.GB, label: .safe, rule: "xcode-device-support"),
            Self.finding("DerivedData", 10 * Self.GB, label: .safe, rule: "xcode-derived-data"),
            Self.finding("Downloads/big.dmg", 30 * Self.GB, label: .review, rule: "download-installer"),
            Self.finding("Backups/x", 8 * Self.GB, label: .review, rule: "iphone-backup"),
            Self.finding("Downloads/a.dmg", 1 * Self.GB, label: .review, rule: "download-installer"),
        ]
        let plan = RulePlanner.plan(findings: findings, volume: Self.roomy, home: "/Users/test")
        #expect(plan.steps.map(\.risk) == [.safe, .safe, .review, .review])
        #expect(plan.steps.map(\.estimatedBytes) == [10 * Self.GB, 5 * Self.GB, 31 * Self.GB, 8 * Self.GB])
        let device = plan.steps[1]
        #expect(device.title == "Clear Xcode device support files")
        #expect(device.paths == ["/Users/test/a/DeviceSupport/17", "/Users/test/a/DeviceSupport/18"])
        #expect(device.reasoning.contains("2 items"))
        #expect(device.reasoning.contains("Explanation for xcode-device-support."))
        #expect(plan.steps[2].paths.count == 2)
        #expect(plan.headline == "You can safely free about 15 GB now, and 39 GB more after a quick review.")
    }

    @Test func excludesKeepAndProtected() {
        let findings = [
            Self.finding("Music", 50 * Self.GB, label: .keep, rule: "music-folder"),
            Self.finding("System", 20 * Self.GB, label: .protected, rule: "macos"),
            Self.finding("Caches/x", 1 * Self.GB, label: .safe, rule: "app-cache"),
        ]
        let plan = RulePlanner.plan(findings: findings, volume: Self.roomy, home: "/Users/test")
        #expect(plan.steps.count == 1)
        #expect(!plan.steps.flatMap(\.paths).contains { $0.hasSuffix("Music") || $0.hasSuffix("System") })
        #expect(plan.headline == "You can safely free about 1 GB now.")
    }

    @Test func aiAndHeuristicItemsOnlyInReviewSteps() {
        let findings = [
            Self.finding("ai-safe", 9 * Self.GB, label: .safe, source: .ai, title: "Some cache"),
            Self.finding("heur-safe", 7 * Self.GB, label: .safe, source: .heuristic, title: "Cotypist AI model"),
            Self.finding("heur-review", 5 * Self.GB, label: .review, source: .heuristic, title: "Leftover data from X (app not installed)"),
            Self.finding("rule-safe", 1 * Self.GB, label: .safe, rule: "npm-cache"),
        ]
        let plan = RulePlanner.plan(findings: findings, volume: Self.roomy, home: "/Users/test")
        let safePaths = plan.steps.filter { $0.risk == .safe }.flatMap(\.paths)
        #expect(safePaths == ["/Users/test/rule-safe"])
        let reviewPaths = Set(plan.steps.filter { $0.risk == .review }.flatMap(\.paths))
        #expect(reviewPaths == ["/Users/test/ai-safe", "/Users/test/heur-safe", "/Users/test/heur-review"])
        #expect(plan.steps.first?.risk == .safe)
        #expect(plan.steps.contains { $0.title == "Review Cotypist AI model" })
        #expect(plan.steps.contains { $0.title == "Review leftover data from X (app not installed)" })
        // A heuristic step never claims to be safe.
        #expect(plan.steps.filter { $0.risk == .review }.allSatisfy { !$0.title.hasPrefix("Clear") })
        #expect(plan.headline == "You can safely free about 1 GB now, and 21 GB more after a quick review.")
    }

    @Test func capsStepsAndKeepsEveryByte() {
        var findings: [Finding] = []
        for i in 0..<20 { findings.append(Self.finding("s\(i)", Int64(i + 1) * Self.GB, label: .safe, rule: "safe-rule-\(i)")) }
        for i in 0..<10 { findings.append(Self.finding("r\(i)", Int64(i + 1) * Self.GB, label: .review, rule: "review-rule-\(i)")) }
        for i in 0..<30 { findings.append(Self.finding("tiny\(i)", 1_000_000, label: .safe, rule: "sandboxed-app-cache")) }
        let plan = RulePlanner.plan(findings: findings, volume: Self.roomy, home: "/Users/test")
        #expect(plan.steps.count <= RulePlanner.maxSteps)
        let total = findings.reduce(Int64(0)) { $0 + $1.size }
        #expect(plan.steps.reduce(Int64(0)) { $0 + $1.estimatedBytes } == total)
        #expect(Set(plan.steps.flatMap(\.paths)).count == findings.count)
        #expect(plan.steps.contains { $0.risk == .review })
        // Safe steps (including the smaller-items one) all come before review steps.
        let risks = plan.steps.map(\.risk)
        #expect(risks == risks.sorted())
        #expect(plan.steps.contains { $0.title == "Clear smaller caches and leftovers" })
        #expect(plan.steps.contains { $0.title == "Review smaller items" })
        // The 30 tiny caches group into one rule group (folded into "smaller" since it's under 50 MB).
        #expect(!plan.steps.contains { $0.title == "Clear Mac App Store app caches" })
    }

    @Test func mentionsLowFreeSpace() {
        let tight = VolumeInfo(name: "Macintosh HD", totalBytes: 500 * Self.GB, availableBytes: 20 * Self.GB)
        let plan = RulePlanner.plan(findings: [Self.finding("c", 2 * Self.GB, label: .safe, rule: "app-cache")],
                                    volume: tight, home: "/Users/test")
        #expect(plan.headline == "Your disk is nearly full (20 GB free). You can safely free about 2 GB now.")
    }

    @Test func reviewOnlyHeadlineAndDuplicates() {
        let f = Self.finding("x", 3 * Self.GB, label: .review, rule: "iphone-backup")
        let plan = RulePlanner.plan(findings: [f, f], volume: Self.roomy, home: "/Users/test")
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].estimatedBytes == 3 * Self.GB)
        #expect(plan.steps[0].title == "Review iPhone and iPad backups")
        #expect(plan.headline == "Nothing can be removed without a look first, but about 3 GB could go after a quick review.")
    }
}
