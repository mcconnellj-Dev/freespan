import AppKit
import Foundation
import FreespanKit
import Observation

/// App state. The only type that talks to FreespanKit (always through `FreespanServices`).
@Observable
@MainActor
final class AppModel {
    let services: FreespanServices
    @ObservationIgnored private let defaults: UserDefaults
    var home: String { services.home }

    // MARK: Scan

    private(set) var scan: ScanResult?
    private(set) var phase: ScanPhase = .idle
    private(set) var scannedScope: ScanScope?
    var scope: ScanScope {
        didSet { defaults.set(scope.rawValue, forKey: Keys.scope) }
    }

    // MARK: Classification

    private(set) var findings: [Finding] = []
    private(set) var summaries: [CategorySummary] = []
    /// Large items no rule or local heuristic explains. Candidates for the assistant.
    private(set) var unknown: [FileNode] = []
    /// Items still waiting for the assistant in the current identification pass.
    private(set) var identifyingCount = 0
    var isLabeling: Bool { identifyingCount > 0 }
    @ObservationIgnored private var ruleFindings: [Finding] = []
    @ObservationIgnored private var heuristicFindings: [Finding] = []
    @ObservationIgnored private var aiFindings: [String: Finding] = [:]
    @ObservationIgnored private var storedLabels: [String: StoredAssistantLabel] = [:]
    @ObservationIgnored private var findingIndex: [String: Finding] = [:]

    // MARK: Mode & visibility (see tasks/ux-modes.md)

    /// Easy (default) or Advanced. Switching resets the sidebar to the mode's start screen.
    var mode: AppMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: SettingsKey.mode)
            inspectorByMode[oldValue] = showInspector
            showInspector = inspectorByMode[mode] ?? false
            selection = mode.homeItem
            refreshVisibleFindings()
        }
    }
    /// Show items labelled Keep or Protected. Off by default in both modes.
    var showKeptItems: Bool {
        didSet {
            guard showKeptItems != oldValue else { return }
            defaults.set(showKeptItems, forKey: SettingsKey.showKeptItems)
            refreshVisibleFindings()
        }
    }
    /// Advanced group tables hide items smaller than this. 0 = show everything.
    var minimumItemSize: Int64 {
        didSet {
            guard minimumItemSize != oldValue else { return }
            defaults.set(minimumItemSize, forKey: SettingsKey.minimumItemSize)
            refreshVisibleFindings()
        }
    }
    /// Items the user chose to Keep in Easy mode; hidden everywhere until undismissed.
    private(set) var dismissedPaths: Set<String> {
        didSet {
            defaults.set(Array(dismissedPaths).sorted(), forKey: SettingsKey.dismissedPaths)
            refreshVisibleFindings()
        }
    }
    /// Folders the next scan skips (Advanced). Absolute paths.
    var excludedFolders: [String] {
        didSet { defaults.set(excludedFolders, forKey: SettingsKey.excludedFolders) }
    }
    /// Findings the UI lists: no zero-byte items, no dismissed items, and no Keep/Protected items unless
    /// `showKeptItems`. Largest first. Advanced tables additionally apply `minimumItemSize` (`tableFindings(in:)`).
    private(set) var visibleFindings: [Finding] = []
    /// Category totals over what the lists show (`visibleFindings`, plus the size threshold in Advanced),
    /// largest first; only categories with something listed.
    private(set) var visibleSummaries: [CategorySummary] = []

    // MARK: Navigation

    /// Sidebar selection. Never nil, and falls back to the mode's start screen if a group disappears.
    var selection: SidebarItem? = .clean {
        didSet { if selection == nil { selection = oldValue ?? mode.homeItem } }
    }
    /// The Ask panel. Closed at launch; each mode remembers its own state for the session.
    var showInspector = false
    @ObservationIgnored private var inspectorByMode: [AppMode: Bool] = [:]
    /// Folder the Disk Map is centered on; nil = scan root.
    var mapFocusPath: String?
    /// The app shown on the right of the Apps screen (its .app path).
    var selectedAppPath: String?
    var quickLookURL: URL?
    var notice: Notice?

    // MARK: Apps & space breakdown

    /// Installed apps and leftovers of removed apps. Rebuilt after every scan, cache load and cleanup.
    private(set) var apps: AppInventoryResult?
    private(set) var appsLoading = false
    /// "What's using your space" tiles; recomputed off the main actor when the scan, findings or apps change.
    private(set) var tiles: [SpaceTile] = []
    private(set) var tilesLoading = false

    // MARK: Basket & history

    private(set) var basket: [String: Finding] = [:]
    private(set) var isCleaning = false
    var lastCleanup: CleanupReport?
    private(set) var history: [ActionLogEntry] = []
    /// Bytes Freespan moved to the Trash that are still there. Moving to the Trash doesn't free space until
    /// the Trash is emptied, so the UI says so. Refreshed with history.
    private(set) var bytesInTrashFromFreespan: Int64 = 0

    // MARK: Assistant

    /// Which assistant answers questions and identifies unknown items. On-device by default; Claude is opt-in.
    var assistantKind: AssistantKind {
        didSet {
            guard assistantKind != oldValue else { return }
            defaults.set(assistantKind.rawValue, forKey: Keys.assistantKind)
            configureAssistant()
        }
    }
    private(set) var assistant: (any AssistantService)?
    /// Nil while being checked.
    private(set) var assistantAvailability: AssistantAvailability?
    private(set) var hasAPIKey = false
    private(set) var chat: [ChatMessage] = []
    private(set) var isAnswering = false
    var draft = ""

    // MARK: Deep Clean Plan

    /// Built from findings by `RulePlanner` after every scan. Free and instant.
    private(set) var rulePlan: CleanupPlan?
    /// Claude's refinement of the plan, when the user asked for one.
    private(set) var refinedPlan: CleanupPlan?
    private(set) var planState: PlanState = .idle
    var plan: CleanupPlan? { refinedPlan ?? rulePlan }

    /// Whether Freespan can read privacy-protected folders. Rechecked whenever the app becomes active.
    private(set) var hasFullDiskAccess = false
    var fullDiskAccessDismissed: Bool {
        didSet { defaults.set(fullDiskAccessDismissed, forKey: Keys.fdaDismissed) }
    }

    /// True when the selected assistant is set up and can answer.
    var assistantReady: Bool { assistant != nil && assistantAvailability == .available }
    /// Plain-English reason the assistant can't answer, or nil when it can (or is still being checked).
    var assistantUnavailableReason: String? {
        if case .unavailable(let reason)? = assistantAvailability { return reason }
        return nil
    }
    var assistantName: String { assistant?.displayName ?? assistantKind.shortName }
    /// "Ask Claude to refine" is offered for Claude only; the on-device model adds little over the rules.
    var canRefinePlan: Bool { assistantKind.isClaude && assistantReady }

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var chatTask: Task<Void, Never>?
    @ObservationIgnored private var labelTask: Task<Void, Never>?
    @ObservationIgnored private var labelToken: UUID?
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var didLaunch = false
    /// Bumped by every rescan and Stop. Scan work captured with an older value must not touch state.
    @ObservationIgnored private var scanGeneration = 0
    /// Bumped whenever `scan` is replaced or pruned; guards background work derived from a snapshot of it.
    @ObservationIgnored private var resultsRevision = 0
    /// Bumped whenever findings are rebuilt.
    @ObservationIgnored private var findingsRevision = 0
    /// Bumped whenever the assistant setting changes.
    @ObservationIgnored private var assistantRevision = 0
    /// Bumped by every app inventory request; only the latest one publishes.
    @ObservationIgnored private var appsGeneration = 0
    @ObservationIgnored private var appsTask: Task<Void, Never>?
    /// Bumped by every tiles request; only the latest one publishes.
    @ObservationIgnored private var tilesGeneration = 0

    private enum Keys {
        static let scope = "scanScope"
        static let assistantKind = "assistantKind"
        /// The old "Use AI features" toggle; read once to migrate.
        static let legacyAIEnabled = "useAI"
        static let fdaDismissed = "fullDiskAccessBannerDismissed"
    }

    init(services: FreespanServices, defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
        self.scope = defaults.string(forKey: Keys.scope).flatMap(ScanScope.init(rawValue:)) ?? .home
        if let kind = defaults.string(forKey: Keys.assistantKind).flatMap(AssistantKind.init(rawValue:)) {
            self.assistantKind = kind
        } else {
            // Someone who switched AI off before keeps it off; everyone else starts on-device.
            let legacy = defaults.object(forKey: Keys.legacyAIEnabled) as? Bool
            self.assistantKind = legacy == false ? .off : .onDevice
        }
        self.fullDiskAccessDismissed = defaults.bool(forKey: Keys.fdaDismissed)
        let mode = defaults.string(forKey: SettingsKey.mode).flatMap(AppMode.init(rawValue:)) ?? .easy
        self.mode = mode
        self.selection = mode.homeItem
        self.showKeptItems = defaults.bool(forKey: SettingsKey.showKeptItems)
        self.minimumItemSize = (defaults.object(forKey: SettingsKey.minimumItemSize) as? NSNumber)?.int64Value
            ?? Self.defaultMinimumItemSize
        self.dismissedPaths = Set(defaults.stringArray(forKey: SettingsKey.dismissedPaths) ?? [])
        self.excludedFolders = defaults.stringArray(forKey: SettingsKey.excludedFolders) ?? []
    }

    static let defaultMinimumItemSize: Int64 = 10_000_000

    // MARK: - Launch & scanning

    /// Loads the cached scan. Never starts a scan by itself: with no cache the Welcome screen asks first,
    /// because scanning triggers macOS privacy prompts unless Full Disk Access is granted.
    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
        refreshAPIKeyState()
        recheckFullDiskAccess()
        configureAssistant()
        phase = .loadingCache
        let generation = scanGeneration
        let services = services
        async let historyLoad: Void = refreshHistory()
        let (cached, labels) = await Task.detached(priority: .userInitiated) {
            ((try? services.loadCache()) ?? nil, services.loadAILabels())
        }.value
        storedLabels = Dictionary(labels.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        await historyLoad
        if let cached, generation == scanGeneration {
            await apply(cached, fresh: false, generation: generation,
                        scope: cached.root.path == home ? .home : .wholeDisk)
        }
        if phase == .loadingCache { phase = .idle }
    }

    func recheckFullDiskAccess() {
        let granted = services.hasFullDiskAccess()
        if granted != hasFullDiskAccess { hasFullDiskAccess = granted }
    }

    func rescan() {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let scanningScope = effectiveScope
        let url = scanningScope.rootURL(home: home)
        recheckFullDiskAccess()
        // Without Full Disk Access, skip the folders macOS would prompt for one by one.
        let excluded = (hasFullDiskAccess ? [] : services.privacyProtectedPaths(home)) + excludedFolders
        phase = .scanning(nil)
        scanTask = Task { [weak self] in
            guard let self else { return }
            var finished = false
            do {
                for try await event in services.scan(url, excluded) {
                    guard isCurrent(generation) else { return }
                    switch event {
                    case .progress(let progress):
                        phase = .scanning(progress)
                    case .finished(let result):
                        finished = true
                        phase = .analyzing
                        guard await apply(result, fresh: true, generation: generation, scope: scanningScope) else { return }
                        let services = services
                        Task.detached(priority: .utility) { try? services.saveCache(result) }
                        if case .group? = selection { selection = mode.homeItem }
                    }
                }
                guard isCurrent(generation) else { return }
                phase = finished ? .idle : .failed("The scan ended before it finished. Try again.")
            } catch {
                guard isCurrent(generation) else { return }
                phase = .failed(Self.scanFailureMessage(error))
            }
        }
    }

    /// What a rescan covers: Easy mode always scans the home folder.
    var effectiveScope: ScanScope { mode == .easy ? .home : scope }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        phase = .idle
    }

    /// True while work started for `generation` is still wanted: no newer scan or Stop, and not cancelled.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == scanGeneration && !Task.isCancelled
    }

    private static func scanFailureMessage(_ error: Error) -> String {
        "Freespan couldn't finish scanning. " + friendly(error)
    }

    static func friendly(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return error.localizedDescription
    }

    /// Everything derived from a scan, computed off the main actor.
    private struct Prepared: Sendable {
        var ruleFindings: [Finding]
        var heuristicFindings: [Finding]
        var unknown: [FileNode]
        var aiFindings: [String: Finding]
        var derived: Derived
        var plan: CleanupPlan
    }

    private struct Derived: Sendable {
        var findings: [Finding]
        var index: [String: Finding]
        var summaries: [CategorySummary]
    }

    /// Rules → local identification → stored assistant labels → totals → rule plan. Pure; runs off the main actor.
    private nonisolated static func prepare(
        _ result: ScanResult, home: String, kind: AssistantKind,
        stored: [String: StoredAssistantLabel], services: FreespanServices
    ) throws -> Prepared {
        let analysis = try services.analyze(result.root, home)
        var heuristic: [Finding] = []
        var remaining: [FileNode] = []
        for node in analysis.unknown {
            if let classification = services.identify(node, home) {
                heuristic.append(Finding(node: node, classification: classification))
            } else {
                remaining.append(node)
            }
        }
        // Items the assistant may never see (macOS internals, app data) don't get its stored labels either.
        let ai = aiFindings(for: remaining.filter { services.isEligibleForAssistant($0.path, home) }, kind: kind, stored: stored)
        let derived = derive(rule: analysis.findings, heuristic: heuristic, ai: Array(ai.values),
                             rootSize: result.root.size, services: services)
        return Prepared(ruleFindings: analysis.findings, heuristicFindings: heuristic, unknown: remaining,
                        aiFindings: ai, derived: derived, plan: services.rulePlan(derived.findings, result.volume, home))
    }

    private nonisolated static func aiFindings(for nodes: [FileNode], kind: AssistantKind,
                                               stored: [String: StoredAssistantLabel]) -> [String: Finding] {
        var result: [String: Finding] = [:]
        guard kind != .off else { return result }
        for node in nodes {
            if let label = stored[StoredAssistantLabel.key(path: node.path, size: node.size, kind: kind)] {
                result[node.path] = makeAIFinding(label.label, node: node)
            }
        }
        return result
    }

    /// Merges, caps and totals findings. Pure; safe to run off the main actor.
    private nonisolated static func derive(rule: [Finding], heuristic: [Finding], ai: [Finding], rootSize: Int64,
                                           services: FreespanServices) -> Derived {
        let advisory = (heuristic + ai).map { capped($0, isProtected: services.isProtected) }
        let all = (rule + advisory).sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        let summaries = services.summarize(all, rootSize)
            .filter { $0.totalBytes > 0 }
            .sorted { $0.totalBytes > $1.totalBytes }
        return Derived(findings: all, index: Dictionary(all.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }),
                       summaries: summaries)
    }

    /// Safety contract, enforced here whatever a service returns: only built-in rules can say Safe or Protected.
    /// AI and heuristic labels are capped at Review (Protected becomes Keep), and ProtectedPaths always wins.
    nonisolated static func capped(_ finding: Finding, isProtected: (String) -> Bool) -> Finding {
        let c = finding.classification
        guard c.source != .rule else { return finding }
        var label = c.label
        switch label {
        case .safe: label = .review
        case .protected: label = .keep
        case .review, .keep: break
        }
        if isProtected(finding.path) { label = .protected }
        guard label != c.label else { return finding }
        var result = finding
        result.classification = Classification(category: c.category, label: label, title: c.title, explanation: c.explanation,
                                               regenerates: c.regenerates, source: c.source, ruleID: c.ruleID)
        return result
    }

    /// Runs rules and identification off the main actor, then publishes — unless a newer scan or Stop
    /// happened meanwhile. Returns whether the result was applied.
    @discardableResult
    private func apply(_ result: ScanResult, fresh: Bool, generation: Int, scope: ScanScope) async -> Bool {
        let services = services
        let home = home
        let kind = assistantKind
        let stored = storedLabels
        let prepared: Prepared
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepare(result, home: home, kind: kind, stored: stored, services: services)
            }.value
        } catch {
            guard isCurrent(generation) else { return false }
            notice = Notice(kind: .warning, title: "Couldn't sort your files into groups", message: Self.friendly(error))
            let empty = Derived(findings: [], index: [:], summaries: services.summarize([], result.root.size).filter { $0.totalBytes > 0 })
            prepared = Prepared(ruleFindings: [], heuristicFindings: [], unknown: [], aiFindings: [:], derived: empty,
                                plan: CleanupPlan(headline: "", steps: []))
        }
        guard isCurrent(generation) else { return false }

        cancelLabeling()
        planTask?.cancel()
        resultsRevision += 1
        scan = result
        scannedScope = scope
        ruleFindings = prepared.ruleFindings
        heuristicFindings = prepared.heuristicFindings
        unknown = prepared.unknown
        aiFindings = prepared.aiFindings
        install(prepared.derived)
        if kind != assistantKind { reapplyStoredLabels() }
        if case .group(let category)? = selection, !groups.contains(where: { $0.category == category }) {
            selection = mode.homeItem
        }
        refreshBasketAfterRescan()
        if let focus = mapFocusPath, node(at: focus) == nil { mapFocusPath = nil }
        rulePlan = prepared.plan
        if fresh {
            refinedPlan = nil
            planState = .idle
        }
        labelUnknownItems()
        scheduleAppsRefresh()
        return true
    }

    private func install(_ derived: Derived) {
        findings = derived.findings
        findingIndex = derived.index
        summaries = derived.summaries
        findingsRevision += 1
        refreshVisibleFindings()
        refreshTiles()
    }

    // MARK: - Visibility

    /// Findings as list rows: rule-mates collapse into one group titled from the rule catalog.
    func rows(_ findings: [Finding]) -> [FindingRow] {
        FindingGrouping.rows(findings, groupTitle: services.groupTitle)
    }

    /// Whether the assistant may be asked about this path (Explain, Second opinion). macOS internals and
    /// ~/Library app data are never sent.
    func canAskAssistant(about path: String) -> Bool {
        services.isEligibleForAssistant(path, home)
    }

    /// Whether the UI lists `finding` at all (both modes; see `visibleFindings`).
    func isVisible(_ finding: Finding) -> Bool {
        guard finding.size > 0, !dismissedPaths.contains(finding.path) else { return false }
        if !showKeptItems, finding.label == .keep || finding.label == .protected { return false }
        if mode == .easy, finding.category == .system || services.isInTrash(finding.path) { return false }
        return true
    }

    private func refreshVisibleFindings() {
        let visible = findings.filter(isVisible)
        visibleFindings = visible
        // Totals match what the group tables list, so Advanced also applies the size threshold here.
        let minimum = mode == .advanced ? minimumItemSize : 0
        let listed = minimum > 0 ? visible.filter { $0.size >= minimum } : visible
        visibleSummaries = services.summarize(listed, scan?.root.size ?? 0)
            .filter { $0.findingCount > 0 && $0.totalBytes > 0 }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    /// Hide an item from now on ("Keep" in Easy mode). Also takes it out of the basket.
    func dismiss(_ path: String) {
        guard !dismissedPaths.contains(path) else { return }
        dismissedPaths.insert(path)
        removeFromBasket(path)
    }

    func undismiss(_ path: String) {
        dismissedPaths.remove(path)
    }

    func undismissAll() {
        if !dismissedPaths.isEmpty { dismissedPaths = [] }
    }

    /// Visible findings in a group, as the group table lists them: Advanced also drops items under `minimumItemSize`.
    func tableFindings(in category: CategoryID) -> [Finding] {
        let minimum = mode == .advanced ? minimumItemSize : 0
        return visibleFindings.filter { $0.category == category && $0.size >= minimum }
    }

    /// How many findings in a group are hidden by the visibility settings (Keep, dismissed, size threshold).
    func hiddenCount(in category: CategoryID) -> Int {
        findings.lazy.filter { $0.category == category && $0.size > 0 }.count - tableFindings(in: category).count
    }

    /// How many of a group's findings are hidden only because they're labelled Keep or Protected.
    func keptCount(in category: CategoryID) -> Int {
        guard !showKeptItems else { return 0 }
        return findings.lazy.filter {
            $0.category == category && $0.size > 0 && ($0.label == .keep || $0.label == .protected)
        }.count
    }

    /// Re-totals after a small change (a batch of assistant labels). Cheap enough for the main actor.
    private func rebuildFindings() {
        install(Self.derive(rule: ruleFindings, heuristic: heuristicFindings, ai: Array(aiFindings.values),
                            rootSize: scan?.root.size ?? 0, services: services))
    }

    /// Shows the stored labels of the current assistant (and drops the previous assistant's).
    private func reapplyStoredLabels() {
        aiFindings = Self.aiFindings(for: assistantCandidates, kind: assistantKind, stored: storedLabels)
        rebuildFindings()
    }

    private func refreshBasketAfterRescan() {
        var refreshed: [String: Finding] = [:]
        for path in basket.keys {
            if let finding = findingIndex[path] ?? node(at: path).flatMap(cleanableFinding(for:)) {
                refreshed[path] = finding
            }
        }
        basket = refreshed
    }

    /// Rebuilds the free rule plan in the background (after labels arrive or items are trashed).
    private func refreshRulePlan() {
        guard let volume = scan?.volume else { return }
        planTask?.cancel()
        let findings = findings
        let services = services
        let home = home
        let revision = findingsRevision
        planTask = Task { [weak self] in
            let plan = await Task.detached(priority: .utility) { services.rulePlan(findings, volume, home) }.value
            guard let self, !Task.isCancelled, revision == findingsRevision else { return }
            rulePlan = plan
        }
    }

    // MARK: - Derived data

    var volume: VolumeInfo? { scan?.volume }

    var needsFullDiskAccess: Bool {
        guard let scan else { return false }
        let library = home + "/Library"
        return scan.inaccessiblePaths.contains { PathUtil.isSameOrDescendant($0, of: library) }
    }

    var showFullDiskAccessBanner: Bool {
        scan != nil && (!hasFullDiskAccess || needsFullDiskAccess) && !fullDiskAccessDismissed
    }

    /// Only built-in rules can mark something Safe; AI and heuristic findings never count here.
    var safeFindings: [Finding] {
        visibleFindings.filter { $0.label == .safe && $0.classification.source == .rule && canAddToBasket($0) }
    }
    var safeBytes: Int64 { safeFindings.reduce(0) { $0 + $1.size } }

    func findings(in category: CategoryID) -> [Finding] {
        findings.filter { $0.category == category }
    }

    /// Totals for a category over the visible findings.
    func summary(for category: CategoryID) -> CategorySummary? {
        visibleSummaries.first { $0.category == category }
    }

    /// Groups shown in the Advanced sidebar: categories with at least one visible finding, System last.
    var groups: [CategorySummary] {
        let shown = visibleSummaries.filter { $0.category != .other }
        return shown.filter { $0.category != .system } + shown.filter { $0.category == .system }
    }

    func finding(at path: String) -> Finding? { findingIndex[path] }

    /// The finding that covers `path` — itself or its nearest classified ancestor.
    func coveringFinding(for path: String) -> Finding? {
        var current = path
        while true {
            if let finding = findingIndex[current] { return finding }
            let parent = PathUtil.parent(of: current)
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    func node(at path: String) -> FileNode? {
        guard var current = scan?.root else { return nil }
        while current.path != path {
            guard let next = current.children.first(where: {
                $0.kind != .smallFiles && PathUtil.isSameOrDescendant(path, of: $0.path)
            }) else { return nil }
            current = next
        }
        return current
    }

    /// The map's outermost folder: the scan root, or the home folder in Easy mode (even after a whole-disk scan).
    var mapRoot: FileNode? {
        guard let root = scan?.root else { return nil }
        if mode == .easy, root.path != home, let homeNode = node(at: home) { return homeNode }
        return root
    }

    var mapFocus: FileNode? {
        guard let root = mapRoot else { return nil }
        if let mapFocusPath, PathUtil.isSameOrDescendant(mapFocusPath, of: root.path), let node = node(at: mapFocusPath) {
            return node
        }
        return root
    }

    /// Root → focus, for the breadcrumb bar.
    var mapTrail: [FileNode] {
        guard let root = mapRoot else { return [] }
        guard let target = mapFocusPath, target != root.path else { return [root] }
        var trail = [root]
        var current = root
        while current.path != target,
              let next = current.children.first(where: { $0.kind != .smallFiles && PathUtil.isSameOrDescendant(target, of: $0.path) }) {
            trail.append(next)
            current = next
        }
        return trail
    }

    func showInMap(_ path: String) {
        guard let node = node(at: path) else { return }
        mapFocusPath = node.children.isEmpty ? PathUtil.parent(of: path) : path
        selection = .diskMap
    }

    // MARK: - Basket

    func canAddToBasket(_ finding: Finding) -> Bool {
        finding.label.canBeCleaned && !services.isProtected(finding.path) && !services.isInTrash(finding.path)
            && finding.path != scan?.root.path && finding.path != home
    }

    /// In the basket itself or inside a folder that is. Walks up the path, so it's cheap for large baskets.
    func isInBasket(_ path: String) -> Bool {
        Self.isCovered(path, by: basket)
    }

    private static func isCovered(_ path: String, by basket: [String: Finding]) -> Bool {
        guard !basket.isEmpty else { return false }
        var current = path
        while true {
            if basket[current] != nil { return true }
            let parent = PathUtil.parent(of: current)
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }

    /// A finding usable for the basket for any node in the map: its own classification, its classified
    /// ancestor's, or an unrecognized "Review" item. Nil for aggregates and the scan root.
    func cleanableFinding(for node: FileNode) -> Finding? {
        guard node.kind != .smallFiles, node.path != scan?.root.path, node.path != home else { return nil }
        if let own = findingIndex[node.path] { return own }
        if let parent = coveringFinding(for: node.path) {
            return Finding(node: node, classification: parent.classification)
        }
        let classification = Classification(
            category: .other, label: .review, title: node.name,
            explanation: "Freespan doesn't recognize this item. Look inside before removing it.",
            regenerates: false, source: .rule, ruleID: "manual"
        )
        return Finding(node: node, classification: classification)
    }

    @discardableResult
    func addToBasket(_ finding: Finding, quiet: Bool = false) -> Bool {
        guard canAddToBasket(finding) else {
            if !quiet {
                let reason = finding.label == .keep
                    ? "Freespan marks this as something to keep, so it can't go in the basket."
                    : "This is a protected location. Freespan never removes it."
                notice = Notice(kind: .warning, title: "Can't add “\(finding.name)”", message: reason)
            }
            return false
        }
        return !addToBasket([finding]).isEmpty || isInBasket(finding.path)
    }

    /// Adds many findings in one change. Skips ones that can't be cleaned or are already covered, and
    /// replaces basket entries inside an added folder. Returns the findings that were added.
    @discardableResult
    func addToBasket(_ items: [Finding]) -> [Finding] {
        var updated = basket
        var added: [Finding] = []
        // Parents first, so their children are recognized as covered.
        for finding in items.sorted(by: { $0.path.count < $1.path.count }) where canAddToBasket(finding) {
            guard !Self.isCovered(finding.path, by: updated) else { continue }
            if updated.keys.contains(where: { PathUtil.isDescendant($0, of: finding.path) }) {
                updated = updated.filter { !PathUtil.isDescendant($0.key, of: finding.path) }
            }
            updated[finding.path] = finding
            added.append(finding)
        }
        if !added.isEmpty { basket = updated }
        return added
    }

    func addToBasket(node: FileNode) {
        guard let finding = cleanableFinding(for: node) else { return }
        addToBasket(finding)
    }

    func removeFromBasket(_ path: String) {
        basket[path] = nil
    }

    func removeFromBasket(_ paths: [String]) {
        var updated = basket
        for path in paths { updated[path] = nil }
        if updated.count != basket.count { basket = updated }
    }

    func toggleBasket(_ finding: Finding) {
        if basket[finding.path] != nil { removeFromBasket(finding.path) } else { addToBasket(finding) }
    }

    func clearBasket() { basket = [:] }

    /// Adds every Safe finding (optionally only one group). Returns how many were added.
    @discardableResult
    func addAllSafe(in category: CategoryID? = nil) -> Int {
        let added = addToBasket(safeFindings.filter { category == nil || $0.category == category })
        if !added.isEmpty {
            let bytes = added.reduce(0) { $0 + $1.size }
            notice = Notice(kind: .success, title: "Added \(added.count) Safe item\(added.count == 1 ? "" : "s") to the basket", message: "\(Format.bytes(bytes)) ready to clear.")
        }
        return added.count
    }

    var basketItems: [Finding] { basket.values.sorted { $0.size > $1.size } }
    var basketTotal: Int64 { basket.values.reduce(0) { $0 + $1.size } }
    var basketReviewItems: [Finding] { basketItems.filter { $0.label == .review } }

    /// Moves the basket to the Trash. Items wholly in use (per `inUse`) stay in the basket and are reported as
    /// skipped, so the result can offer "Quit Google Chrome and try again". Folders only partly in use go: their
    /// free parts are moved and the open files stay.
    func moveBasketToTrash(inUse: [String: InUseStatus] = [:]) async {
        guard !basket.isEmpty, !isCleaning else { return }
        let isHeld: (Finding) -> Bool = { inUse[$0.path].map { !$0.isPartial } ?? false }
        let items = basketItems.filter { !isHeld($0) }
        let held = basketItems.filter(isHeld).compactMap { item in
            inUse[item.path].map {
                CleanupReport.Skipped(path: item.path, reason: CleanupService.inUseReason($0.apps), blockingApps: $0.apps)
            }
        }
        let report = await moveToTrash(items)
        lastCleanup = CleanupReport(trashed: report.trashed, skipped: report.skipped + held, partial: report.partial)
    }

    /// Moves exactly these items to the Trash, without touching the rest of the basket and without the
    /// result banner (callers show their own). Items that can't be cleaned are reported as skipped.
    /// Never deletes anything: the Trash is the only destination, and Freespan never empties it.
    @discardableResult
    func moveToTrash(_ items: [Finding]) async -> CleanupReport {
        guard !items.isEmpty, !isCleaning else { return CleanupReport(trashed: [], skipped: []) }
        let allowed = items.filter(canAddToBasket)
        let refused = items.filter { !canAddToBasket($0) }.map {
            CleanupReport.Skipped(path: $0.path, reason: services.isInTrash($0.path)
                                  ? "Already in the Trash. Empty the Trash in Finder to get the space back."
                                  : "Freespan doesn't remove this item.")
        }
        isCleaning = true
        let report = allowed.isEmpty ? CleanupReport(trashed: [], skipped: [])
                                     : await services.cleanup.moveToTrash(allowed)
        let removed = Set(report.trashed.map(\.originalPath))
        // A partly cleaned folder leaves the basket too: what's left is in use and was reported.
        removeFromBasket(Array(removed) + report.partial.map(\.path))
        if !removed.isEmpty { await removeFromTree(removed) }
        isCleaning = false
        if !removed.isEmpty { scheduleAppsRefresh() }
        await refreshHistory()
        return CleanupReport(trashed: report.trashed, skipped: report.skipped + refused, partial: report.partial)
    }

    private struct Pruned: Sendable {
        var scan: ScanResult
        var ruleFindings: [Finding]
        var heuristicFindings: [Finding]
        var unknown: [FileNode]
        var derived: Derived
        var plan: CleanupPlan
    }

    /// Drops trashed paths from the tree and findings so the UI reflects the cleanup without a full rescan.
    /// The pruning and re-totalling run off the main actor; results are dropped if a newer scan landed meanwhile.
    private func removeFromTree(_ paths: Set<String>) async {
        guard let scan else { return }
        let revision = resultsRevision
        let findingsRevisionBefore = findingsRevision
        let services = services
        let home = home
        let rule = ruleFindings
        let heuristic = heuristicFindings
        let ai = Array(aiFindings.values)
        let unknown = unknown
        let pruned = await Task.detached(priority: .userInitiated) { () -> Pruned in
            let root = Self.prune(scan.root, removing: paths) ?? scan.root
            // Trashed items still use space until the Trash is emptied: re-read the real numbers rather than
            // pretending the space came back.
            let volume = services.volumeInfo(URL(fileURLWithPath: scan.root.path)) ?? scan.volume
            let updated = ScanResult(root: root, volume: volume, scannedAt: scan.scannedAt,
                                     duration: scan.duration, inaccessiblePaths: scan.inaccessiblePaths)
            let gone: (String) -> Bool = { path in paths.contains { PathUtil.isSameOrDescendant(path, of: $0) } }
            // Folders cleaned partly stay listed with what's left in them.
            let shrunk: (Finding) -> Finding = { f in
                guard paths.contains(where: { PathUtil.isDescendant($0, of: f.path) }),
                      let node = Self.node(at: f.path, in: root), node.size != f.size else { return f }
                return Finding(path: f.path, name: f.name, size: min(f.size, node.size), itemCount: node.itemCount,
                               modified: f.modified, accessed: f.accessed, isDirectory: f.isDirectory,
                               classification: f.classification)
            }
            let keptRule = rule.filter { !gone($0.path) }.map(shrunk).filter { $0.size > 0 }
            let keptHeuristic = heuristic.filter { !gone($0.path) }.map(shrunk).filter { $0.size > 0 }
            let derived = Self.derive(rule: keptRule, heuristic: keptHeuristic, ai: ai.filter { !gone($0.path) },
                                      rootSize: root.size, services: services)
            return Pruned(scan: updated, ruleFindings: keptRule, heuristicFindings: keptHeuristic,
                          unknown: unknown.filter { !gone($0.path) }, derived: derived,
                          plan: services.rulePlan(derived.findings, volume, home))
        }.value
        guard revision == resultsRevision else { return }

        resultsRevision += 1
        self.scan = pruned.scan
        ruleFindings = pruned.ruleFindings
        heuristicFindings = pruned.heuristicFindings
        self.unknown = pruned.unknown
        aiFindings = aiFindings.filter { entry in !paths.contains { PathUtil.isSameOrDescendant(entry.key, of: $0) } }
        if findingsRevision == findingsRevisionBefore {
            install(pruned.derived)
            rulePlan = pruned.plan
        } else {
            // Assistant labels arrived while pruning; include them.
            rebuildFindings()
            refreshRulePlan()
        }
        if let focus = mapFocusPath, node(at: focus) == nil { mapFocusPath = nil }
        let updated = pruned.scan
        Task.detached(priority: .utility) { try? services.saveCache(updated) }
    }

    /// The node at `path` below `root`, or nil when the tree doesn't reach it.
    nonisolated static func node(at path: String, in root: FileNode) -> FileNode? {
        var current = root
        while current.path != path {
            guard let next = current.children.first(where: {
                $0.kind != .smallFiles && PathUtil.isSameOrDescendant(path, of: $0.path)
            }) else { return nil }
            current = next
        }
        return current
    }

    nonisolated static func prune(_ node: FileNode, removing paths: Set<String>) -> FileNode? {
        if node.kind != .smallFiles, paths.contains(node.path) { return nil }
        guard !node.children.isEmpty, paths.contains(where: { PathUtil.isDescendant($0, of: node.path) }) else { return node }
        var kept: [FileNode] = []
        var removedBytes: Int64 = 0
        var removedItems = 0
        for child in node.children {
            if let pruned = prune(child, removing: paths) {
                kept.append(pruned)
                removedBytes += child.size - pruned.size
                removedItems += child.itemCount - pruned.itemCount
            } else {
                removedBytes += child.size
                removedItems += child.itemCount
            }
        }
        return FileNode(id: node.id, name: node.name, path: node.path, kind: node.kind,
                        size: node.size - removedBytes, itemCount: node.itemCount - removedItems,
                        modified: node.modified, accessed: node.accessed,
                        children: kept.sorted { $0.size > $1.size })
    }

    func refreshHistory() async {
        let entries = await services.cleanup.history()
        history = entries
        let exists = services.itemExists
        let pending = entries.filter { !$0.restored }
        bytesInTrashFromFreespan = await Task.detached(priority: .utility) {
            pending.filter { exists($0.trashPath) }.reduce(0) { $0 + $1.size }
        }.value
    }

    /// Opens the Trash in Finder so the user can empty it. Freespan never empties it itself.
    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash", isDirectory: true))
    }

    /// Puts several items back and posts one summary notice. Returns how many were restored.
    @discardableResult
    func undo(_ entries: [ActionLogEntry]) async -> Int {
        var restored = 0
        var firstError: String?
        for entry in entries where !entry.restored {
            do {
                try await services.cleanup.undo(entry)
                restored += 1
            } catch {
                firstError = firstError ?? Self.friendly(error)
            }
        }
        await refreshHistory()
        let total = entries.filter { !$0.restored }.count
        if restored == total {
            notice = Notice(kind: .success, title: "Put back \(restored) item\(restored == 1 ? "" : "s")",
                            message: "Everything is where it was. Rescan to see it in Freespan again.")
        } else {
            notice = Notice(kind: .warning, title: "Put back \(restored) of \(total) items",
                            message: (firstError.map { $0 + " " } ?? "") + "The rest are still in the Trash. Try again from History.")
        }
        return restored
    }

    func undo(_ entry: ActionLogEntry) async {
        do {
            try await services.cleanup.undo(entry)
            let name = (entry.originalPath as NSString).lastPathComponent
            notice = Notice(kind: .success, title: "Restored “\(name)”", message: "It's back where it was. Rescan to see it in the map again.")
        } catch {
            notice = Notice(kind: .error, title: "Couldn't restore that item", message: Self.friendly(error))
        }
        await refreshHistory()
    }

    // MARK: - Apps & tiles

    /// Rebuilds the app inventory from the current scan off the main actor. Only the latest request publishes,
    /// so a rescan or cleanup that lands meanwhile wins. Keeps the previous inventory if this one fails.
    func refreshApps() async {
        guard let scan else { return }
        appsGeneration += 1
        let generation = appsGeneration
        let services = services
        let findings = findings
        let home = home
        appsLoading = true
        let result = await Task.detached(priority: .utility) {
            try? await services.appInventory(scan, findings, home)
        }.value
        guard generation == appsGeneration else { return }
        appsLoading = false
        if let result {
            apps = result
            if let selected = selectedAppPath, !result.apps.contains(where: { $0.path == selected }) { selectedAppPath = nil }
            refreshTiles()
        } else if apps == nil {
            apps = AppInventoryResult(apps: [], leftovers: [], builtAt: Date())
        }
    }

    /// Starts `refreshApps()` without waiting, replacing any refresh still running.
    func scheduleAppsRefresh() {
        appsTask?.cancel()
        appsTask = Task { [weak self] in await self?.refreshApps() }
    }

    /// Recomputes the space tiles off the main actor from the current scan, findings and apps.
    private func refreshTiles() {
        guard let scan else {
            tiles = []
            return
        }
        tilesGeneration += 1
        let generation = tilesGeneration
        let services = services
        let findings = findings
        let apps = apps
        let home = home
        tilesLoading = true
        Task { [weak self] in
            let computed = await Task.detached(priority: .utility) {
                services.spaceTiles(scan, findings, apps, home)
            }.value
            guard let self, generation == tilesGeneration else { return }
            tilesLoading = false
            tiles = computed
        }
    }

    func installedApp(at path: String) -> InstalledApp? {
        apps?.apps.first { $0.path == path }
    }

    /// Opens the Apps screen with this app selected.
    func showApp(path: String) {
        selectedAppPath = path
        selection = .apps
    }

    /// Opens the Space Map (Explore / Disk Map) centered on `path`, or on its root when nil or not in the scan.
    func explore(path: String?) {
        if let path, let node = node(at: path) {
            mapFocusPath = node.children.isEmpty && node.path != mapRoot?.path ? PathUtil.parent(of: path) : path
        } else {
            mapFocusPath = nil
        }
        selection = .diskMap
    }

    /// What "Uninstall" would move to the Trash for this app (bundle first). Empty when it can't be uninstalled.
    func uninstallItems(for app: InstalledApp) -> [Finding] {
        guard app.canUninstall else { return [] }
        return services.uninstallItems(app)
    }

    /// Moves the app and the chosen data to the Trash. `items` must come from `uninstallItems(for:)`; the sheet
    /// leaves the app's personal data (Keep items) out unless the person opts in, so Keep is allowed through here.
    /// Protected paths are still refused by `moveToTrash`.
    func uninstall(_ app: InstalledApp, items: [Finding]) async -> CleanupReport {
        let allowed = Set(uninstallItems(for: app).map(\.path))
        return await moveToTrash(Self.explicitlyChosen(items.filter { allowed.contains($0.path) }))
    }

    /// Moves a removed app's leftover data to the Trash (after the person confirmed it).
    func removeLeftover(_ leftover: Leftover) async {
        let report = await moveToTrash(Self.explicitlyChosen(leftover.items))
        lastCleanup = report
    }

    /// Clears an app's Safe extras (caches and the like). The result shows in the usual cleanup banner with Undo.
    func removeExtras(of app: InstalledApp) async {
        guard !app.extras.isEmpty else { return }
        lastCleanup = await moveToTrash(app.extras)
    }

    /// Items the person picked one by one: Keep becomes Review so they can go to the Trash. Protected stays as is,
    /// and `canAddToBasket` refuses it.
    private nonisolated static func explicitlyChosen(_ items: [Finding]) -> [Finding] {
        items.map { finding in
            guard finding.label == .keep else { return finding }
            var copy = finding
            let c = finding.classification
            copy.classification = Classification(category: c.category, label: .review, title: c.title, explanation: c.explanation,
                                                 regenerates: c.regenerates, source: c.source, ruleID: c.ruleID)
            return copy
        }
    }

    // MARK: - Finder & Quick Look

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func quickLook(_ path: String) {
        let url = URL(fileURLWithPath: path)
        quickLookURL = quickLookURL == url ? nil : url
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Settings

    func refreshAPIKeyState() {
        hasAPIKey = !(services.apiKey() ?? "").isEmpty
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try services.setAPIKey(trimmed.isEmpty ? nil : trimmed)
        refreshAPIKeyState()
        refreshAssistantAvailability()
    }

    func removeAPIKey() throws {
        try services.setAPIKey(nil)
        refreshAPIKeyState()
        refreshAssistantAvailability()
    }

    // MARK: - Assistant setup

    /// Rebuilds the assistant for the current setting. Labels from the previous assistant are hidden
    /// (they stay on disk), and this assistant's stored labels come back.
    private func configureAssistant() {
        cancelLabeling()
        planTask?.cancel()
        assistantRevision += 1
        assistant = nil
        assistantAvailability = assistantKind == .off ? .unavailable("The assistant is off.") : nil
        if planState == .loading { planState = .idle }
        if !assistantKind.isClaude { refinedPlan = nil }
        if scan != nil {
            reapplyStoredLabels()
            refreshRulePlan()
        }
        refreshAssistantAvailability()
    }

    /// Re-checks whether the assistant can run (e.g. after installing Claude Code or adding a key) and
    /// starts identifying unknown items once it can. Setup runs off the main actor.
    func refreshAssistantAvailability() {
        let kind = assistantKind
        let revision = assistantRevision
        let needsAssistant = assistant == nil
        let services = services
        Task { [weak self] in
            let (made, availability) = await Task.detached(priority: .userInitiated) {
                (needsAssistant ? services.makeAssistant(kind) : nil, services.assistantAvailability(kind))
            }.value
            guard let self, revision == assistantRevision else { return }
            if let made { assistant = made }
            var resolved = availability
            if kind != .off, assistant == nil, resolved.isAvailable {
                resolved = .unavailable("Freespan couldn't set up \(kind.shortName). Try choosing it again.")
            }
            if resolved != assistantAvailability { assistantAvailability = resolved }
            labelUnknownItems()
        }
    }

    // MARK: - Identification (assistant)

    private nonisolated static func makeAIFinding(_ label: AILabel, node: FileNode) -> Finding {
        let classification = Classification(
            category: label.category, label: label.label, title: label.title, explanation: label.explanation,
            regenerates: label.regenerates, source: .ai
        )
        // Capped to Review (and checked against ProtectedPaths) in `derive`.
        return Finding(node: node, classification: classification)
    }

    private func cancelLabeling() {
        labelTask?.cancel()
        labelTask = nil
        labelToken = nil
        if identifyingCount != 0 { identifyingCount = 0 }
    }

    /// Asks the assistant about items neither the rules nor local identification could name. Runs in the
    /// background after the scan is shown; labels are saved so relaunching doesn't ask again.
    func labelUnknownItems() {
        guard labelTask == nil, let assistant, assistantReady else { return }
        let pending = assistantCandidates.filter { aiFindings[$0.path] == nil }
        guard !pending.isEmpty else { return }
        let kind = assistantKind
        let token = UUID()
        labelToken = token
        identifyingCount = pending.count
        // The on-device model has a small context window; Claude handles bigger batches.
        let batchSize = kind == .onDevice ? 8 : 40
        labelTask = Task { [weak self] in
            guard let self else { return }
            var newlyLabeled: [Finding] = []
            for batch in pending.chunked(into: batchSize) {
                let byMetadataPath = Dictionary(batch.map { (services.metadata($0).path, $0) }, uniquingKeysWith: { a, _ in a })
                let metadata = batch.map(services.metadata)
                do {
                    let labels = try await assistant.label(metadata)
                    guard !Task.isCancelled, labelToken == token else { return }
                    let current = Set(unknown.map(\.path))
                    for label in labels {
                        guard let node = byMetadataPath[label.path] ?? byMetadataPath[services.unredact(label.path)],
                              current.contains(node.path) else { continue }
                        let stored = StoredAssistantLabel(
                            label: AILabel(path: node.path, title: label.title, explanation: label.explanation,
                                           ownerApp: label.ownerApp, regenerates: label.regenerates,
                                           category: label.category, label: label.label),
                            size: node.size, kind: kind)
                        storedLabels[stored.key] = stored
                        let finding = Self.makeAIFinding(stored.label, node: node)
                        aiFindings[node.path] = finding
                        newlyLabeled.append(finding)
                    }
                    identifyingCount = max(0, identifyingCount - batch.count)
                    rebuildFindings()
                    persistLabels()
                } catch {
                    guard !Task.isCancelled, labelToken == token, !(error is CancellationError) else { return }
                    notice = Notice(kind: .warning, title: "\(assistant.displayName) couldn't identify some items",
                                    message: Self.friendly(error))
                    break
                }
            }
            guard labelToken == token else { return }
            labelTask = nil
            labelToken = nil
            identifyingCount = 0
            // Results show up as labels in the lists; the Ask panel stays Q&A only.
            if !newlyLabeled.isEmpty { refreshRulePlan() }
        }
    }

    /// Unrecognized items the assistant is allowed to see. macOS internals and ~/Library app data are never sent.
    private var assistantCandidates: [FileNode] {
        unknown.filter { services.isEligibleForAssistant($0.path, home) }
    }

    private func persistLabels() {
        let labels = Array(storedLabels.values)
        let save = services.saveAILabels
        Task.detached(priority: .utility) { save(labels) }
    }

    // MARK: - Ask

    /// Starter questions for the Ask panel, worded for the current mode.
    var suggestedQuestions: [String] {
        switch mode {
        case .easy: ["What's safe to delete?", "Why is my Mac so full?", "What does Check first mean?"]
        case .advanced: ["What's safe to delete?", "Why is System Data so big?", "What are these simulators?"]
        }
    }

    private func assistantUnavailableNotice(_ title: String) -> Notice {
        let message = assistantKind == .off
            ? "Choose an assistant in Settings › Assistant."
            : assistantUnavailableReason ?? "The assistant is still starting. Try again in a moment."
        return Notice(kind: .info, title: title, message: message)
    }

    func ask(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        showInspector = true
        guard let assistant, assistantReady else {
            notice = assistantUnavailableNotice("Ask Freespan is unavailable")
            return
        }
        guard let scan else {
            notice = Notice(kind: .info, title: "Scan first", message: "Freespan answers questions about your scan.")
            return
        }
        let history: [ChatTurn] = chat.compactMap { message in
            guard message.isConversation, !message.isError, !message.isStreaming else { return nil }
            return ChatTurn(role: message.isUser ? .user : .assistant, text: message.text)
        }
        draft = ""
        chat.append(ChatMessage(author: .user, text: question))
        let reply = ChatMessage(author: .assistant(assistantKind, name: assistant.displayName), text: "", isStreaming: true)
        chat.append(reply)
        isAnswering = true
        let summary = services.diskSummary(scan, findings, assistantCandidates)
        let stream = assistant.ask(question, summary: summary, history: history)
        chatTask = Task { [weak self] in
            do {
                for try await delta in stream {
                    self?.updateMessage(reply.id) { $0.text += delta }
                }
            } catch is CancellationError {
            } catch {
                self?.updateMessage(reply.id) { message in
                    let friendly = Self.friendly(error)
                    message.text = message.text.isEmpty ? friendly : message.text + "\n\n" + friendly
                    message.isError = true
                }
            }
            self?.updateMessage(reply.id) { $0.isStreaming = false }
            self?.isAnswering = false
        }
    }

    func stopAnswering() {
        chatTask?.cancel()
    }

    func clearChat() {
        guard !isAnswering else { return }
        chat.removeAll()
    }

    private func updateMessage(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = chat.firstIndex(where: { $0.id == id }) else { return }
        change(&chat[index])
    }

    /// "Explain this" for any item in the map or a group.
    func explain(path: String, name: String, size: Int64) {
        guard canAskAssistant(about: path) else { return }
        let display = Format.displayPath(path, home: home)
        ask("What is “\(name)” at \(display) (\(Format.bytes(size)))? Is it safe to remove, and what happens if I do?")
    }

    func secondOpinion(on node: FileNode) {
        guard canAskAssistant(about: node.path) else { return }
        showInspector = true
        guard let assistant, assistantReady else {
            notice = assistantUnavailableNotice("Second opinions need an assistant")
            return
        }
        chat.append(ChatMessage(author: .user, text: "Second opinion on “\(node.name)” (\(Format.bytes(node.size)))?",
                                isConversation: false))
        let reply = ChatMessage(author: .assistant(assistantKind, name: assistant.displayName),
                                text: "", isStreaming: true, isConversation: false)
        let mode = mode
        chat.append(reply)
        let metadata = services.metadata(node)
        let isProtected = services.isProtected(node.path)
        Task { [weak self] in
            do {
                let label = try await assistant.secondOpinion(metadata)
                // Advisory only: never Safe, and protected locations stay Protected.
                let verdict: SafetyLabel = isProtected ? .protected
                    : (label.label == .safe ? .review : label.label == .protected ? .keep : label.label)
                self?.updateMessage(reply.id) {
                    $0.text = "**\(label.title).** \(label.explanation)\n\nVerdict: **\(verdict.title(for: mode))**"
                    $0.isStreaming = false
                }
            } catch {
                self?.updateMessage(reply.id) {
                    $0.text = Self.friendly(error)
                    $0.isError = true
                    $0.isStreaming = false
                }
            }
        }
    }

    // MARK: - Deep Clean Plan

    /// Asks Claude to rework the rule plan using the whole-disk summary. The rule plan stays as the fallback.
    func refinePlan() {
        guard canRefinePlan, let assistant, let scan, planState != .loading else { return }
        planState = .loading
        let summary = services.diskSummary(scan, findings, assistantCandidates)
        let revision = assistantRevision
        Task { [weak self] in
            do {
                let plan = try await assistant.deepCleanPlan(summary)
                guard let self, revision == assistantRevision else { return }
                refinedPlan = plan
                planState = .idle
            } catch {
                guard let self, revision == assistantRevision else { return }
                planState = .failed(Self.friendly(error))
            }
        }
    }

    /// Goes back to the free rule-based plan.
    func useRulePlan() {
        refinedPlan = nil
        planState = .idle
    }

    /// Findings a plan step refers to that can actually go in the basket.
    func findings(for step: CleanupPlan.Step) -> [Finding] {
        var seen = Set<String>()
        return step.paths.compactMap { redacted -> Finding? in
            let path = services.unredact(redacted)
            guard seen.insert(path).inserted else { return nil }
            if let finding = findingIndex[path] { return canAddToBasket(finding) ? finding : nil }
            guard let node = node(at: path), let finding = cleanableFinding(for: node) else { return nil }
            return canAddToBasket(finding) ? finding : nil
        }
    }

    func addPlanStep(_ step: CleanupPlan.Step) {
        let items = findings(for: step)
        addToBasket(items)
        if !items.isEmpty {
            notice = Notice(kind: .success, title: "Added “\(step.title)” to the basket",
                            message: "\(items.count) item\(items.count == 1 ? "" : "s") · \(Format.bytes(items.reduce(0) { $0 + $1.size }))")
        }
    }

    func isPlanStepInBasket(_ step: CleanupPlan.Step) -> Bool {
        let items = findings(for: step)
        return !items.isEmpty && items.allSatisfy { isInBasket($0.path) }
    }

    // MARK: - Previews

    /// Installs state synchronously (previews only — no I/O, no detached work).
    func seed(scan: ScanResult, analysis: ScanAnalysis, scope: ScanScope, basketPaths: [String] = [],
              chat: [ChatMessage] = [], plan: CleanupPlan? = nil, refinedPlan: CleanupPlan? = nil,
              history: [ActionLogEntry] = [], assistant kind: AssistantKind = .onDevice, hasAPIKey: Bool = true) {
        didLaunch = true
        self.scan = scan
        self.scannedScope = scope
        self.scope = scope
        self.hasAPIKey = hasAPIKey
        assistantKind = kind
        assistantRevision += 1 // discard the async setup started by the didSet
        assistant = services.makeAssistant(kind)
        assistantAvailability = kind == .claudeAPI && !hasAPIKey
            ? .unavailable("Add your Anthropic API key below.") : services.assistantAvailability(kind)
        ruleFindings = analysis.findings.filter { $0.classification.source == .rule }
        heuristicFindings = analysis.findings.filter { $0.classification.source == .heuristic }
        aiFindings = kind == .off ? [:] : Dictionary(analysis.findings.filter { $0.classification.source == .ai }.map { ($0.path, $0) },
                                                    uniquingKeysWith: { a, _ in a })
        unknown = analysis.unknown
        rebuildFindings()
        tiles = services.spaceTiles(scan, findings, apps, home)
        addToBasket(basketPaths.compactMap { findingIndex[$0] })
        self.chat = chat
        rulePlan = plan
        self.refinedPlan = refinedPlan
        self.history = history
    }

    func seedScanning(_ progress: ScanProgress?) {
        didLaunch = true
        phase = .scanning(progress)
    }

    func seedFailure(_ message: String) {
        didLaunch = true
        phase = .failed(message)
    }

    func seedPlanState(_ state: PlanState) { planState = state }

    /// Installs an app inventory (nil = not built yet) and recomputes the tiles synchronously.
    func seedApps(_ result: AppInventoryResult?, loading: Bool = false) {
        apps = result
        appsLoading = loading
        if let scan { tiles = services.spaceTiles(scan, findings, result, home) }
    }

    func seedTiles(_ tiles: [SpaceTile], loading: Bool = false) {
        tilesGeneration += 1 // drop any computation still running
        self.tiles = tiles
        tilesLoading = loading
    }

    func seedIdentifying(_ count: Int) { identifyingCount = count }
}
