import Foundation
import Testing
@testable import FreespanKit

/// Read-only probe: this Mac's app inventory and "What's using your space" tiles for a fresh home scan.
/// Only runs when FREESPAN_PROBE=1. Never modifies or trashes anything. Home is printed as `~`.
@Suite("Apps – real disk probe", .enabled(if: ProcessInfo.processInfo.environment["FREESPAN_PROBE"] == "1"))
struct AppsRealDiskProbe {
    @Test func probeInventoryAndTiles() async throws {
        let home = NSHomeDirectory()
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        func b(_ n: Int64) -> String { fmt.string(fromByteCount: n) }
        func redact(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

        var result: ScanResult?
        for try await event in DiskScanner().scan(root: URL(fileURLWithPath: home)) {
            if case .finished(let r) = event { result = r }
        }
        let scan = try #require(result)
        let engine = try RuleEngine.bundled()
        let identifier = ItemIdentifier()
        // Same findings the app builds: rules plus locally identified large unknown items.
        var findings = engine.findings(in: scan.root, home: home)
        for node in engine.unknownLargeItems(in: scan.root, home: home) {
            if let c = identifier.identify(node, home: home) { findings.append(Finding(node: node, classification: c)) }
        }
        print("PROBE home scan \(b(scan.root.size)) in \(String(format: "%.1f", scan.duration)) s, \(findings.count) findings")

        let start = ContinuousClock.now
        let inventory = try await AppInventory().inventory(homeScan: scan, findings: findings, home: home)
        let elapsed = ContinuousClock.now - start
        let appBytes = inventory.apps.reduce(Int64(0)) { $0 + $1.appBytes }
        let dataBytes = inventory.apps.reduce(Int64(0)) { $0 + $1.dataBytes }
        print("PROBE inventory: \(inventory.apps.count) apps, bundles \(b(appBytes)), data \(b(dataBytes)) in \(elapsed)")
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        for app in inventory.apps.prefix(10) {
            let opened = app.lastOpened.map(dateFmt.string(from:)) ?? "unknown"
            let blocked = app.canUninstall ? "" : " [blocked: \(app.uninstallBlockedReason ?? "")]"
            print("PROBE app | \(app.name) | app \(b(app.appBytes)) | data \(b(app.dataBytes)) | extras \(b(app.extrasBytes)) | last opened \(opened)\(blocked)")
            for item in app.related.prefix(4) {
                print("PROBE      - \(b(item.size)) \(item.classification.label.rawValue) \(item.classification.title) | \(redact(item.path))")
            }
        }
        let leftoverBytes = inventory.leftovers.reduce(Int64(0)) { $0 + $1.bytes }
        print("PROBE leftovers: \(inventory.leftovers.count) apps, \(b(leftoverBytes))")
        for l in inventory.leftovers.prefix(5) {
            print("PROBE leftover | \(l.ownerName) (\(l.bundleID ?? "-")) | \(b(l.bytes)) | \(l.items.count) items")
        }

        let tiles = SpaceBreakdown.tiles(scan: scan, findings: findings, apps: inventory, home: home)
        let total = tiles.reduce(Int64(0)) { $0 + $1.bytes }
        print("PROBE tiles (sum \(b(total)) = home \(b(scan.root.size)) + app bundles \(b(appBytes))):")
        for t in tiles {
            print("PROBE tile | \(t.title) | \(b(t.bytes)) | safe \(b(t.safeBytes)) | check \(b(t.checkBytes))\(t.subtitle.map { " | \($0)" } ?? "")")
        }

        #expect(total == scan.root.size + inventory.apps.filter { !$0.path.hasPrefix(home + "/") }.reduce(0) { $0 + $1.appBytes })
        #expect(inventory.apps.flatMap(\.related).allSatisfy { !ProtectedPaths.isProtected($0.path, home: home) })
    }
}
