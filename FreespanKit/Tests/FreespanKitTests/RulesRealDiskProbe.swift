import Foundation
import Testing
@testable import FreespanKit

/// Read-only probe of the real home folder. Only runs when FREESPAN_PROBE=1. Never modifies anything.
@Suite("Rules – real disk probe", .enabled(if: ProcessInfo.processInfo.environment["FREESPAN_PROBE"] == "1"))
struct RulesRealDiskProbe {
    @Test func probeHome() async throws {
        let home = NSHomeDirectory()
        var result: ScanResult?
        for try await event in DiskScanner().scan(root: URL(fileURLWithPath: home)) {
            if case .finished(let r) = event { result = r }
        }
        let root = try #require(result).root
        let engine = try RuleEngine.bundled()
        let start = ContinuousClock.now
        let findings = engine.findings(in: root, home: home)
        let t1 = ContinuousClock.now - start
        let unknown = engine.unknownLargeItems(in: root, home: home)
        let fmt = ByteCountFormatter()
        print("PROBE findings: \(findings.count) in \(t1)")
        for s in RuleEngine.summarize(findings, rootSize: root.size) {
            print("PROBE cat \(s.category.rawValue): \(fmt.string(fromByteCount: s.totalBytes)) safe \(fmt.string(fromByteCount: s.safeBytes)) n=\(s.findingCount)")
        }
        for f in findings.prefix(40) {
            print("PROBE top \(fmt.string(fromByteCount: f.size)) [\(f.classification.ruleID ?? "")/\(f.classification.label.rawValue)] \(f.path)")
        }
        for u in unknown.prefix(25) {
            print("PROBE unknown \(fmt.string(fromByteCount: u.size)) \(u.path)")
        }
        let eligible = unknown.filter { RuleEngine.isEligibleForAssistant(path: $0.path, home: home) }
        let identifier = ItemIdentifier()
        let unnamed = unknown.filter { identifier.identify($0, home: home) == nil }
        print("PROBE unknown \(unknown.count), assistant-eligible \(eligible.count), unnamed by identifier \(unnamed.count), unnamed+eligible \(unnamed.filter { RuleEngine.isEligibleForAssistant(path: $0.path, home: home) }.count)")
        for u in unnamed { print("PROBE unnamed \(fmt.string(fromByteCount: u.size)) eligible=\(RuleEngine.isEligibleForAssistant(path: u.path, home: home)) \(u.path.hasPrefix(home) ? "~" + u.path.dropFirst(home.count) : u.path)") }
        let library = unknown.filter { $0.path.hasPrefix(home + "/Library/") }
        #expect(library.allSatisfy { identifier.identify($0, home: home) != nil })
        for rel in ["Library/Metadata/CoreSpotlight", "Library/Biome"] {
            if let node = root.findNode(home + "/" + rel), let c = engine.classify(node, home: home) {
                print("PROBE \(rel): \(fmt.string(fromByteCount: node.size)) [\(c.ruleID ?? "")] \(c.category.rawValue)/\(c.label.rawValue) \"\(c.title)\"")
            } else {
                print("PROBE \(rel): not in scan")
            }
        }
        let bad = findings.filter { $0.classification.label <= .review && $0.classification.ruleID != "trash" && ProtectedPaths.isProtected($0.path, home: home) }
        for b in bad { print("PROBE PROTECTED-CONFLICT \(b.path)") }
        #expect(bad.isEmpty)
    }
}

private extension FileNode {
    /// Walks down by path prefix (cheap on a full home tree).
    func findNode(_ target: String) -> FileNode? {
        if path == target && kind != .smallFiles { return self }
        guard target.hasPrefix(path == "/" ? "/" : path + "/") else { return nil }
        for c in children { if let f = c.findNode(target) { return f } }
        return nil
    }
}
