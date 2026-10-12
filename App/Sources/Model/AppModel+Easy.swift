import AppKit
import Foundation
import FreespanKit

/// Read-only helpers for the Easy-mode screens (Home, Check first, Clean Up Safely).
extension AppModel {
    /// Rule-based Safe items the user hasn't hidden. Only built-in rules can say Safe.
    var easySafeFindings: [Finding] {
        visibleFindings.filter {
            $0.label == .safe && $0.classification.source == .rule && $0.category != .system && canAddToBasket($0)
        }
    }

    /// Items that need a human decision ("Check first"), largest first. Includes ones already in Cleanup.
    var easyCheckFirstFindings: [Finding] {
        visibleFindings
            .filter { $0.label == .review && $0.category != .system && canAddToBasket($0) }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
    }

    /// Used share of the startup disk, 0...1. Nil before the first scan.
    var easyUsedFraction: Double? {
        guard let volume, volume.totalBytes > 0 else { return nil }
        return min(max(Double(volume.usedBytes) / Double(volume.totalBytes), 0), 1)
    }

    /// Under 10% free.
    var easyIsLowOnSpace: Bool {
        guard let volume, volume.totalBytes > 0 else { return false }
        return Double(volume.availableBytes) / Double(volume.totalBytes) < 0.10
    }
}

// MARK: - Items in use

/// Items a running app has open can't be emptied from the Trash ("The item is in use") and trashing them can
/// upset the app, so cleanup checks first and offers to quit those apps politely.
extension AppModel {
    /// Which of these findings something has open (path → what, and whether the rest can still go).
    /// Freespan itself never counts.
    func checkInUse(_ findings: [Finding]) async -> [String: InUseStatus] {
        guard !findings.isEmpty else { return [:] }
        let own = Bundle.main.bundleIdentifier
        let map = await services.cleanup.inUse(findings)
        return map.compactMapValues { status in
            let others = status.apps.filter { $0.bundleID == nil || $0.bundleID != own }
            return others.isEmpty ? nil : InUseStatus(apps: others, isPartial: status.isPartial, busyBytes: status.busyBytes)
        }
    }

    /// True when Freespan can offer to quit this app: a regular (Dock) app that's running and isn't Freespan,
    /// Finder or another part of macOS.
    func canQuit(_ app: BlockingApp) -> Bool { services.canQuitApp(app) }

    /// What the in-use check means for these findings, in two buckets: apps the person can quit (with the bytes
    /// quitting them would free) and everything only macOS background tasks are holding.
    func inUseSummary(_ findings: [Finding], blocked: [String: InUseStatus]) -> InUseSummary {
        var summary = InUseSummary()
        var seenApps: Set<String> = []
        var seenBackground: Set<String> = []
        for finding in findings {
            guard let status = blocked[finding.path] else { continue }
            let quittable = status.apps.filter(canQuit)
            if status.isPartial { summary.partialCount += 1 }
            if quittable.isEmpty {
                summary.backgroundBytes += status.busyBytes
                for app in status.apps where seenBackground.insert(app.name).inserted { summary.backgroundNames.append(app.name) }
            } else {
                summary.appBytes += status.busyBytes
                for app in quittable where seenApps.insert(app.id).inserted { summary.apps.append(app) }
            }
        }
        summary.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        summary.backgroundNames.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return summary
    }

    /// Asks each app to quit the normal way (like ⌘Q, so it can ask to save), then waits up to ~10 seconds.
    /// Never force-quits or signals anything. Returns the apps still running (including any it may not quit).
    func quitApps(_ apps: [BlockingApp]) async -> [BlockingApp] {
        let targets = apps.map { ($0, Self.quittableInstances(of: $0)) }
        for (_, instances) in targets {
            for instance in instances { _ = instance.terminate() }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        // Wait for the apps and for their helper processes (which hold most of the open files) to exit.
        let helperPIDs = targets.filter { !$0.1.isEmpty }.flatMap(\.0.pids)
        func waiting() -> Bool {
            targets.contains { $0.1.contains { !$0.isTerminated } } || helperPIDs.contains(where: Self.isProcessAlive)
        }
        while waiting(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return targets.filter { app, instances in instances.isEmpty || instances.contains { !$0.isTerminated } }
            .map(\.0)
    }

    /// Tries the in-use items from an earlier cleanup again and merges the outcome into that report, so the
    /// earlier Undo still covers everything. `candidates` supplies findings the model no longer lists.
    func retryInUse(_ report: CleanupReport, candidates: [Finding] = []) async -> CleanupReport {
        let retryPaths = Set(report.skipped.filter { $0.blockingApps != nil }.map(\.path))
        // Partly cleaned folders: only what stayed behind is left to try, so size them by that.
        let leftovers = Dictionary(report.partial.filter { $0.skippedBytes > 0 }.map { ($0.path, $0.skippedBytes) },
                                   uniquingKeysWith: { a, _ in a })
        let byPath = Dictionary(candidates.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let findings = retryPaths.union(leftovers.keys).sorted().compactMap { path -> Finding? in
            guard let f = byPath[path] ?? basket[path] ?? finding(at: path) else { return nil }
            guard let left = leftovers[path] else { return f }
            return Finding(path: f.path, name: f.name, size: left, itemCount: f.itemCount, modified: f.modified,
                           accessed: f.accessed, isDirectory: f.isDirectory, classification: f.classification)
        }
        guard !findings.isEmpty else { return report }
        let retried = await moveToTrash(findings)
        let found = Set(findings.map(\.path))
        let keptSkips = report.skipped.filter { !found.contains($0.path) }
        let keptPartial = report.partial.filter { !found.contains($0.path) }
        // A folder that was partly cleaned before and is now fully moved is no longer partial.
        return CleanupReport(trashed: report.trashed + retried.trashed, skipped: keptSkips + retried.skipped,
                             partial: keptPartial + retried.partial)
    }

    /// Read-only liveness check (no signal is sent).
    private nonisolated static func isProcessAlive(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
    }

    /// Running instances Freespan may ask to quit: regular (Dock) apps only, never Freespan itself, and never
    /// anything inside /System unless it's one of Apple's everyday apps (`BlockingApp.isQuittableApp`).
    nonisolated static func quittableInstances(of app: BlockingApp) -> [NSRunningApplication] {
        guard app.isQuittableApp, let id = app.bundleID, id != Bundle.main.bundleIdentifier else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        let userFacingApple = BlockingApp.userFacingAppleBundleIDs.contains(id.lowercased())
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
            guard $0.activationPolicy == .regular, $0.processIdentifier != own, !$0.isTerminated else { return false }
            return userFacingApple || !($0.bundleURL?.path.hasPrefix("/System/") ?? false)
        }
    }
}

/// The in-use check boiled down for one sheet: quittable apps (shown as chips) and the bytes only macOS
/// background tasks hold (one quiet line; their names only appear in Advanced mode's tooltip).
struct InUseSummary: Equatable {
    var apps: [BlockingApp] = []
    /// Bytes the quittable apps are holding; quitting them frees these.
    var appBytes: Int64 = 0
    /// Bytes only background processes or macOS are holding; skipped this time.
    var backgroundBytes: Int64 = 0
    var backgroundNames: [String] = []
    /// Folders that will be cleaned partly (the open files stay).
    var partialCount = 0

    var isEmpty: Bool { apps.isEmpty && backgroundBytes == 0 }
}

extension CleanupReport {
    /// Apps and processes that kept something from moving (skipped items and the open parts of partly cleaned
    /// folders), without duplicates. Empty when nothing was left behind because it was in use.
    var inUseApps: [BlockingApp] {
        var seen: Set<String> = []
        let skippedApps = skipped.flatMap { $0.blockingApps ?? [] }
        let partialApps = partial.filter { $0.skippedBytes > 0 }.flatMap(\.blockingApps)
        return (skippedApps + partialApps).filter { seen.insert($0.id).inserted }
    }
}

extension CleanupReport.Skipped {
    /// "Quit Google Chrome and try again." for items skipped because an app had them open.
    var inUseHint: String? {
        guard let apps = blockingApps, !apps.isEmpty else { return nil }
        let names = apps.filter(\.isQuittableApp).map(\.name)
        guard !names.isEmpty else { return "In use by a background task. Try again in a little while." }
        return "Quit \(BlockingApp.list(names)) and try again."
    }
}

extension BlockingApp {
    /// "Google Chrome", "Google Chrome and Slack", "Google Chrome, Slack and 2 others".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            let rest = names.count - 2
            return "\(names[0]), \(names[1]) and \(rest) other\(rest == 1 ? "" : "s")"
        }
    }

    /// The app's icon, or a generic app icon when it can't be found.
    var icon: NSImage {
        if let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
