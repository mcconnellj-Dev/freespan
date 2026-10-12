import Foundation
import Testing
@testable import FreespanKit

/// Read-only probe: how many of the largest unexplained items in the real home folder ItemIdentifier can name.
/// Only runs when FREESPAN_PROBE=1. Never modifies or trashes anything. Home is printed as `~`.
@Suite("Identify – real disk probe", .enabled(if: ProcessInfo.processInfo.environment["FREESPAN_PROBE"] == "1"))
struct IdentifyRealDiskProbe {
    @Test func probeUnknownItems() async throws {
        let home = NSHomeDirectory()
        var result: ScanResult?
        for try await event in DiskScanner().scan(root: URL(fileURLWithPath: home)) {
            if case .finished(let r) = event { result = r }
        }
        let root = try #require(result).root
        let engine = try RuleEngine.bundled()
        let findings = engine.findings(in: root, home: home)
        let unknown = engine.unknownLargeItems(in: root, home: home, limit: 40)
        let identifier = ItemIdentifier()
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        func redact(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

        let start = ContinuousClock.now
        let labeled = unknown.map { ($0, identifier.identify($0, home: home)) }
        let elapsed = ContinuousClock.now - start
        let hits = labeled.filter { $0.1 != nil }
        let unknownBytes = unknown.reduce(Int64(0)) { $0 + $1.size }
        let hitBytes = hits.reduce(Int64(0)) { $0 + $1.0.size }
        let safeBytes = findings.filter { $0.classification.label == .safe }.reduce(Int64(0)) { $0 + $1.size }
        print("PROBE rules: \(findings.count) findings, \(fmt.string(fromByteCount: safeBytes)) safe")
        print("PROBE identified \(hits.count)/\(unknown.count) unknown items (\(fmt.string(fromByteCount: hitBytes)) of \(fmt.string(fromByteCount: unknownBytes))) in \(elapsed)")
        for (node, c) in labeled.prefix(15) {
            let label = c.map { "\($0.label.rawValue)" } ?? "-"
            let title = c?.title ?? "(unidentified)"
            print("PROBE | \(fmt.string(fromByteCount: node.size)) | \(label) | \(title) | \(redact(node.path))")
        }
        for (node, c) in labeled where c == nil { print("PROBE miss \(fmt.string(fromByteCount: node.size)) \(redact(node.path))") }

        let plan = RulePlanner.plan(findings: findings + hits.map { Finding(node: $0.0, classification: $0.1!) },
                                    volume: try #require(result).volume, home: home)
        print("PROBE plan: \(plan.headline)")
        for s in plan.steps { print("PROBE step [\(s.risk.rawValue)] \(fmt.string(fromByteCount: s.estimatedBytes)) \(s.title) (\(s.paths.count))") }

        #expect(hits.allSatisfy { $0.1!.label != .safe && $0.1!.source == .heuristic })
    }
}
