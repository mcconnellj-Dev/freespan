import AppKit
import FreespanKit
import SwiftUI

/// "Uninstall <App>…": lists what moves to the Trash, asks the app to quit politely if it's running, trashes
/// everything, then shows the result with Undo. Present with `.environment(model)` re-injected.
struct UninstallSheet: View {
    enum Phase {
        case confirm
        case quitting
        case stillRunning([BlockingApp])
        case working
        case done(CleanupReport)
        case undoing
        case restored(count: Int, of: Int)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: InstalledApp
    /// Snapshot of `AppInventory.uninstallItems(for:)`: the bundle first, then its data.
    let items: [Finding]
    @State private var phase: Phase
    /// The app's personal data (bookmarks, settings, documents it keeps) stays unless the person opts in.
    @State private var includePersonalData = false

    init(app: InstalledApp, items: [Finding], phase: Phase = .confirm) {
        self.app = app
        self.items = items
        _phase = State(initialValue: phase)
    }

    private func isBundle(_ item: Finding) -> Bool { item.path == app.path }
    /// Items labelled Keep: data the person may want (e.g. a browser profile). Opt-in.
    private var personalData: [Finding] { items.filter { !isBundle($0) && $0.label == .keep } }
    private var standardItems: [Finding] { items.filter { isBundle($0) || $0.label != .keep } }
    private var selectedItems: [Finding] { includePersonalData ? items : standardItems }
    private var total: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    private var personalBytes: Int64 { personalData.reduce(0) { $0 + $1.size } }

    var body: some View {
        Group {
            switch phase {
            case .confirm: confirm
            case .quitting: progress("Asking \(app.name) to quit…")
            case .stillRunning(let apps): stillRunning(apps)
            case .working: progress("Moving \(app.name) to the Trash…")
            case .done(let report): done(report)
            case .undoing: progress("Putting \(app.name) back…")
            case .restored(let count, let total): restored(count: count, total: total)
            }
        }
        .frame(width: SheetMetrics.width)
        .interactiveDismissDisabled(isBusy)
    }

    private var isBusy: Bool {
        switch phase {
        case .quitting, .working, .undoing: true
        default: false
        }
    }

    // MARK: Confirm

    /// Header and buttons pinned; the item list scrolls once the sheet would be taller than the screen allows.
    private var confirm: some View {
        PinnedSheet {
            HStack(spacing: 14) {
                AppIcon(path: app.path, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Uninstall \(app.name)?")
                        .font(.title2.weight(.semibold))
                    Text("These move to the Trash · \(Format.bytes(total))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text("Freespan can't remove this app.")
                        .foregroundStyle(.secondary)
                        .padding(20)
                } else {
                    ForEach(Array(standardItems.enumerated()), id: \.element.id) { index, item in
                        itemRow(item, isBundle: isBundle(item))
                        if index < standardItems.count - 1 { Divider().padding(.leading, 56) }
                    }
                    if !personalData.isEmpty { personalDataSection }
                }
                Divider().padding(.top, 4)
                Label("Freespan asks \(app.name) to quit first. Everything goes to the Trash, so you can put it back.",
                      systemImage: "arrow.uturn.backward.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .padding(.vertical, 4)
        } footer: {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { Task { await uninstall() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || model.isCleaning)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    /// Opt-in section for the app's personal data, off by default.
    private var personalDataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Toggle(isOn: $includePersonalData) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also remove \(app.name)'s personal data · \(Format.bytes(personalBytes))")
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                    Text("Things like bookmarks, history, settings or saved files. Leave this off if you might use \(app.name) again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            if includePersonalData {
                VStack(spacing: 0) {
                    ForEach(personalData) { itemRow($0, isBundle: false) }
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func itemRow(_ item: Finding, isBundle: Bool) -> some View {
        HStack(spacing: 12) {
            if isBundle {
                AppIcon(path: app.path, size: 28)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppSizeBar.dataColor)
                    .frame(width: 28, height: 28)
                    .background(AppSizeBar.dataColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(isBundle ? "The app itself" : item.classification.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(Format.displayPath(item.path, home: model.home))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            SizeText(bytes: item.size, font: .callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    // MARK: Progress & results

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }

    /// The same compact app chips as the in-use section; only apps a person can quit are named.
    private func stillRunning(_ apps: [BlockingApp]) -> some View {
        let named = apps.filter(model.canQuit)
        let shown = named.isEmpty ? [BlockingApp(bundleID: app.bundleID, name: app.name, pids: [])] : named
        return VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(SafetyLabel.review.foreground)
            Text("\(BlockingApp.list(shown.map(\.name))) \(shown.count == 1 ? "is" : "are") still open")
                .font(.title3.weight(.semibold))
            AppChips(apps: shown)
            Text("It may be waiting for you to save something. Quit it, then try again. Nothing was moved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { Task { await uninstall() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func done(_ report: CleanupReport) -> some View {
        let bundleSkip = report.skipped.first { $0.path == app.path }
        let needsFinder = bundleSkip.map(Self.isPermissionProblem) ?? false
        let movedAny = !report.trashed.isEmpty
        VStack(spacing: 12) {
            Image(systemName: bundleSkip == nil ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(bundleSkip == nil ? SafetyLabel.safe.foreground : SafetyLabel.review.foreground)
            Text(bundleSkip == nil ? "\(app.name) is in the Trash" : "\(app.name) is still installed")
                .font(.title2.weight(.semibold))
            if needsFinder {
                Text("macOS needs your password to remove this app — drag it from Applications to the Trash in Finder.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let bundleSkip {
                Text(bundleSkip.inUseHint ?? bundleSkip.reason)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if movedAny {
                VStack(spacing: 3) {
                    Text(bundleSkip == nil
                         ? "Moved \(Format.bytes(report.bytesFreed)) to the Trash. Empty the Trash in Finder to get the space back."
                         : "Its data (\(Format.bytes(report.bytesFreed))) is in the Trash. Empty the Trash in Finder to get the space back.")
                        .font(.callout)
                    Text("Until then, you can undo or put things back from the Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            let otherSkips = report.skipped.filter { $0.path != app.path }
            if !otherSkips.isEmpty {
                Text("Skipped \(otherSkips.count) item\(otherSkips.count == 1 ? "" : "s"): "
                     + otherSkips.prefix(2).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
                     + (otherSkips.count > 2 ? "…" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(otherSkips.map { "\(($0.path as NSString).lastPathComponent): \($0.inUseHint ?? $0.reason)" }.joined(separator: "\n"))
            }
            HStack {
                if needsFinder {
                    Button("Reveal in Finder") { model.revealInFinder(app.path) }
                }
                if movedAny {
                    Button("Undo") { Task { await undo(report) } }
                        .help("Put everything back where it was")
                    Button("Open Trash") { model.openTrash() }
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private func restored(count: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: count == total ? "arrow.uturn.backward.circle.fill" : "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(count == total ? Color.accentColor : SafetyLabel.review.foreground)
            Text(count == total ? "\(app.name) is back" : "Put back \(count) of \(total) items")
                .font(.title2.weight(.semibold))
            Text(count == total ? "Everything is where it was." : "The rest are still in the Trash. You can try again from History.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    /// Quits the app politely if it's running (never force-quits), then moves everything to the Trash.
    private func uninstall() async {
        guard !items.isEmpty, !model.isCleaning else { return }
        if let running = runningApp() {
            phase = .quitting
            let stillOpen = await model.quitApps([running])
            if !stillOpen.isEmpty {
                phase = .stillRunning(stillOpen)
                return
            }
        }
        phase = .working
        let report = await model.uninstall(app, items: selectedItems)
        phase = .done(report)
    }

    private func undo(_ report: CleanupReport) async {
        phase = .undoing
        let restored = await model.undo(report.trashed)
        if restored == report.trashed.count { model.notice = nil } // the sheet says so
        model.scheduleAppsRefresh()
        phase = .restored(count: restored, of: report.trashed.count)
    }

    /// The app as a quittable `BlockingApp` when it's running; nil otherwise.
    private func runningApp() -> BlockingApp? {
        guard let id = app.bundleID else { return nil }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }
        guard !instances.isEmpty else { return nil }
        let blocking = BlockingApp(bundleID: id, name: app.name, pids: instances.map(\.processIdentifier))
        return model.canQuit(blocking) ? blocking : nil
    }

    /// The bundle couldn't be moved because macOS wants an admin password (App Store apps are owned by root).
    private static func isPermissionProblem(_ skip: CleanupReport.Skipped) -> Bool {
        guard skip.blockingApps == nil else { return false }
        let reason = skip.reason.lowercased()
        return reason.contains("permission") || reason.contains("not permitted") || reason.contains("password")
    }
}

// MARK: - Previews

#Preview("Uninstall · confirm") {
    let model = AppModel.preview(mode: .easy, selection: .apps)
    let app = SampleApps.apps[1]
    return UninstallSheet(app: app, items: SampleApps.uninstallItems(for: app))
        .environment(model)
}

#Preview("Uninstall · still running") {
    let model = AppModel.preview(mode: .easy, selection: .apps)
    let app = SampleApps.apps[1]
    let running = BlockingApp(bundleID: app.bundleID ?? "preview.app", name: app.name, pids: [1])
    return UninstallSheet(app: app, items: SampleApps.uninstallItems(for: app), phase: .stillRunning([running]))
        .environment(model)
}

#Preview("Uninstall · done") {
    let model = AppModel.preview(mode: .easy, selection: .apps)
    let app = SampleApps.apps[1]
    let items = SampleApps.uninstallItems(for: app)
    let report = CleanupReport(trashed: items.map {
        ActionLogEntry(originalPath: $0.path, trashPath: SampleData.home + "/.Trash/" + $0.name, size: $0.size)
    }, skipped: [])
    return UninstallSheet(app: app, items: items, phase: .done(report))
        .environment(model)
}

#Preview("Uninstall · needs Finder") {
    let model = AppModel.preview(mode: .easy, selection: .apps)
    let app = SampleApps.apps[0]
    let items = SampleApps.uninstallItems(for: app)
    let report = CleanupReport(trashed: items.dropFirst().map {
        ActionLogEntry(originalPath: $0.path, trashPath: SampleData.home + "/.Trash/" + $0.name, size: $0.size)
    }, skipped: [.init(path: app.path, reason: "macOS didn't give Freespan permission to move this.")])
    return UninstallSheet(app: app, items: items, phase: .done(report))
        .environment(model)
}
