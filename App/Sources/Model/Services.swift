import Foundation
import FreespanKit

/// Cleanup operations the app needs. `CleanupService` conforms; previews use an in-memory fake.
protocol CleanupPerforming: Sendable {
    func moveToTrash(_ findings: [Finding]) async -> CleanupReport
    /// Findings that something has files open in, with what and whether the rest can still go.
    func inUse(_ findings: [Finding]) async -> [String: InUseStatus]
    func undo(_ entry: ActionLogEntry) async throws
    func history() async -> [ActionLogEntry]
}

extension CleanupService: CleanupPerforming {}

/// Result of running the rule catalog over a scanned tree.
struct ScanAnalysis: Sendable {
    var findings: [Finding]
    var unknown: [FileNode]
}

/// Every side effect AppModel performs goes through here, so previews can run with sample data and no I/O.
struct FreespanServices: Sendable {
    var home: String
    /// Scans `root`, skipping the given absolute path prefixes.
    var scan: @Sendable (_ root: URL, _ excluded: [String]) -> AsyncThrowingStream<ScanEvent, Error>
    /// Folders macOS guards with per-folder privacy prompts; skipped when Full Disk Access isn't granted.
    var privacyProtectedPaths: @Sendable (_ home: String) -> [String]
    /// True when Full Disk Access is granted. Must never trigger a privacy prompt.
    var hasFullDiskAccess: @Sendable () -> Bool
    var loadCache: @Sendable () throws -> ScanResult?
    var saveCache: @Sendable (ScanResult) throws -> Void
    /// Rule matching + unknown-item discovery. Called off the main actor.
    var analyze: @Sendable (_ root: FileNode, _ home: String) throws -> ScanAnalysis
    var summarize: @Sendable (_ findings: [Finding], _ rootSize: Int64) -> [CategorySummary]
    var isProtected: @Sendable (String) -> Bool
    /// True for ~/.Trash and anything in it. Never offered for cleanup.
    var isInTrash: @Sendable (String) -> Bool
    /// Fresh numbers for the volume holding `url` (nil if unreadable). Called off the main actor.
    var volumeInfo: @Sendable (_ url: URL) -> VolumeInfo?
    /// Whether something exists at a path (used to see what's still waiting in the Trash). Off the main actor.
    var itemExists: @Sendable (String) -> Bool
    var metadata: @Sendable (FileNode) -> ItemMetadata
    var diskSummary: @Sendable (ScanResult, [Finding], [FileNode]) -> DiskSummary
    var unredact: @Sendable (String) -> String
    /// Whether an unrecognized item may be sent to the assistant for identification. macOS internals and
    /// app data under ~/Library never are. Called off the main actor.
    var isEligibleForAssistant: @Sendable (_ path: String, _ home: String) -> Bool
    /// The group heading for findings of a rule ("App caches", "macOS system data"); nil for unknown rules.
    var groupTitle: @Sendable (_ ruleID: String) -> String?
    /// Names an item no rule explains, without AI. Called off the main actor.
    var identify: @Sendable (_ node: FileNode, _ home: String) -> Classification?
    /// The free Deep Clean Plan built from findings alone. Called off the main actor.
    var rulePlan: @Sendable (_ findings: [Finding], _ volume: VolumeInfo, _ home: String) -> CleanupPlan
    /// Builds the assistant for a setting; nil for `.off` (or when it can't be set up). May block briefly
    /// (locating the `claude` tool), so call it off the main actor.
    var makeAssistant: @Sendable (AssistantKind) -> (any AssistantService)?
    /// Whether an assistant can run right now, with a plain-English reason when not. Call off the main actor.
    var assistantAvailability: @Sendable (AssistantKind) -> AssistantAvailability
    var apiKey: @Sendable () -> String?
    var setAPIKey: @Sendable (String?) throws -> Void
    var cleanup: any CleanupPerforming
    var cost: @Sendable (ClaudeModel) -> Double
    var resetUsage: @Sendable () -> Void
    /// Assistant labels, persisted so relaunching from the scan cache doesn't ask the assistant again.
    var loadAILabels: @Sendable () -> [StoredAssistantLabel]
    var saveAILabels: @Sendable ([StoredAssistantLabel]) -> Void
    /// Installed apps with their data, plus leftovers of removed apps. Sizes app bundles, so call it off the main actor.
    var appInventory: @Sendable (_ scan: ScanResult?, _ findings: [Finding], _ home: String) async throws -> AppInventoryResult
    /// "What's using your space" tiles. Pure; called off the main actor.
    var spaceTiles: @Sendable (_ scan: ScanResult, _ findings: [Finding], _ apps: AppInventoryResult?, _ home: String) -> [SpaceTile]
    /// What "Uninstall" moves to the Trash: the bundle first, then its non-protected data. Empty when it can't be uninstalled.
    var uninstallItems: @Sendable (InstalledApp) -> [Finding]
    /// Whether Freespan may offer to quit this app (a regular, non-system app that's running right now).
    var canQuitApp: @Sendable (BlockingApp) -> Bool
}

extension FreespanServices {
    static func live() -> FreespanServices {
        let home = NSHomeDirectory()
        let cache = ScanCache()
        let usage = UsageMeter.shared
        let rules: RuleEngine? = try? RuleEngine.bundled()
        let labelsURL = URL.applicationSupportDirectory
            .appending(path: "Freespan", directoryHint: .isDirectory)
            .appending(path: "ai-labels.json")
        return FreespanServices(
            home: home,
            scan: { root, excluded in
                var options = ScanOptions()
                options.excludedPaths = excluded
                return DiskScanner(options: options).scan(root: root)
            },
            privacyProtectedPaths: { DiskScanner.privacyProtectedPaths(home: $0) },
            hasFullDiskAccess: {
                // TCC.db is only readable with Full Disk Access; reading it fails silently otherwise (no prompt).
                let tcc = home + "/Library/Application Support/com.apple.TCC/TCC.db"
                guard let handle = FileHandle(forReadingAtPath: tcc) else { return false }
                try? handle.close()
                return true
            },
            loadCache: { try cache.load() },
            saveCache: { try cache.save($0) },
            analyze: { root, home in
                let engine = try rules ?? RuleEngine.bundled()
                return ScanAnalysis(
                    findings: engine.findings(in: root, home: home),
                    unknown: engine.unknownLargeItems(in: root, home: home)
                )
            },
            summarize: { RuleEngine.summarize($0, rootSize: $1) },
            isProtected: { ProtectedPaths.isProtected($0, home: home) },
            isInTrash: { ProtectedPaths.isInTrash($0, home: home) },
            volumeInfo: { try? DiskScanner.volumeInfo(for: $0) },
            itemExists: { FileManager.default.fileExists(atPath: $0) },
            metadata: { SummaryBuilder.metadata(for: $0, home: home) },
            diskSummary: { SummaryBuilder.summary(scan: $0, findings: $1, unknown: $2, home: home) },
            unredact: { Redactor.unredact($0, home: home) },
            isEligibleForAssistant: { path, home in RuleEngine.isEligibleForAssistant(path: path, home: home) },
            groupTitle: { rules?.pluralTitle(forRuleID: $0) },
            identify: { node, home in ItemIdentifier().identify(node, home: home) },
            rulePlan: { findings, volume, home in RulePlanner.plan(findings: findings, volume: volume, home: home) },
            makeAssistant: { kind in
                switch kind {
                case .onDevice: OnDeviceAssistant()
                case .claudeSubscription: ClaudeCLIAssistant.locateExecutable().map { ClaudeCLIAssistant(executable: $0) }
                case .claudeAPI: AnthropicClient(apiKeyProvider: { KeychainStore.apiKey() }, usage: usage)
                case .off: nil
                }
            },
            assistantAvailability: { kind in
                switch kind {
                case .onDevice: OnDeviceAssistant.availability
                case .claudeSubscription: ClaudeCLIAssistant.availability
                case .claudeAPI:
                    (KeychainStore.apiKey() ?? "").isEmpty ? .unavailable("Add your Anthropic API key below.") : .available
                case .off: .unavailable("The assistant is off.")
                }
            },
            apiKey: { KeychainStore.apiKey() },
            setAPIKey: { try KeychainStore.setAPIKey($0) },
            cleanup: CleanupService(),
            cost: { usage.costUSD(for: $0) },
            resetUsage: { usage.reset() },
            loadAILabels: {
                // Files from before labels were keyed by size and assistant don't decode and are dropped.
                guard let data = try? Data(contentsOf: labelsURL) else { return [] }
                return (try? JSONDecoder().decode([StoredAssistantLabel].self, from: data)) ?? []
            },
            saveAILabels: { labels in
                try? FileManager.default.createDirectory(at: labelsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(labels) { try? data.write(to: labelsURL, options: .atomic) }
            },
            appInventory: { scan, findings, home in
                try await AppInventory().inventory(homeScan: scan, findings: findings, home: home)
            },
            spaceTiles: { scan, findings, apps, home in
                SpaceBreakdown.tiles(scan: scan, findings: findings, apps: apps, home: home)
            },
            uninstallItems: { AppInventory.uninstallItems(for: $0) },
            canQuitApp: { !AppModel.quittableInstances(of: $0).isEmpty }
        )
    }
}

