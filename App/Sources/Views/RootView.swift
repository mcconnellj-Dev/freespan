import FreespanKit
import QuickLook
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            DetailColumn()
                .navigationSplitViewColumnWidth(min: 560, ideal: 900)
        }
        .inspector(isPresented: $model.showInspector) {
            AskPanel()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar { MainToolbar() }
        .environment(\.appMode, model.mode)
        .quickLookPreview($model.quickLookURL)
        .task { await model.launch() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckFullDiskAccess()
        }
        .frame(minWidth: MainWindowSize.minWidth, minHeight: MainWindowSize.minHeight)
    }
}

/// Detail content plus the banner stack (cleanup result, Full Disk Access, notices).
private struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { BannerStack() }
            .navigationTitle(title)
    }

    @ViewBuilder private var content: some View {
        if model.scan == nil {
            ScanStatusView()
        } else {
            switch model.selection ?? model.mode.homeItem {
            case .clean: EasyHomeView()
            case .checkFirst: CheckFirstView()
            case .apps: AppsView()
            case .overview: OverviewView()
            case .diskMap: DiskMapView()
            case .group(let category): GroupView(category: category).id(category)
            case .basket: BasketView()
            case .history: HistoryView()
            }
        }
    }

    private var title: String {
        switch model.selection ?? model.mode.homeItem {
        case .clean: "Clean"
        case .checkFirst: "Check First"
        case .apps: "Apps"
        case .overview: "Overview"
        case .diskMap: model.mode == .easy ? "Explore" : "Disk Map"
        case .group(let category): category.displayName
        case .basket: model.mode == .easy ? "Cleanup" : "Cleanup Basket"
        case .history: "History"
        }
    }
}

private struct BannerStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let report = model.lastCleanup {
                CleanupResultBanner(report: report, onOpenTrash: { model.openTrash() }, onUndo: {
                    model.lastCleanup = nil
                    Task { await model.undo(report.trashed) }
                }, onRetry: {
                    Task { model.lastCleanup = await model.retryInUse(report) }
                }) { model.lastCleanup = nil }
            }
            if model.showFullDiskAccessBanner {
                NoticeBanner(systemImage: "lock.shield", tint: .accentColor,
                             title: model.hasFullDiskAccess ? "Rescan to see everything" : "Grant Full Disk Access to see everything",
                             message: model.hasFullDiskAccess
                                 ? "Access is on now. Rescan to measure the folders that were skipped."
                                 : "Protected folders like Desktop, Documents, iPhone backups and Mail were skipped. One permission covers them all.",
                             onDismiss: { model.fullDiskAccessDismissed = true }) {
                    if model.hasFullDiskAccess {
                        Button("Rescan") { model.rescan() }.controlSize(.small)
                    } else {
                        Button("Open Settings") { model.openFullDiskAccessSettings() }.controlSize(.small)
                    }
                }
            }
            if let notice = model.notice {
                NoticeBanner(systemImage: notice.kind.symbol, tint: notice.kind.tint, title: notice.title,
                             message: notice.message, onDismiss: { model.notice = nil }) { EmptyView() }
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(notice.kind == .error ? 8 : 5))
                        if model.notice?.id == notice.id { withAnimation { model.notice = nil } }
                    }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, hasContent ? 12 : 0)
        .animation(.snappy, value: model.notice)
        .animation(.snappy, value: model.lastCleanup == nil)
        .animation(.snappy, value: model.showFullDiskAccessBanner)
    }

    private var hasContent: Bool {
        model.lastCleanup != nil || model.showFullDiskAccessBanner || model.notice != nil
    }
}

/// "Moved 62 GB to the Trash" — honest that the space only comes back once the Trash is emptied.
struct CleanupResultBanner: View {
    let report: CleanupReport
    var onOpenTrash: (() -> Void)?
    var onUndo: (() -> Void)?
    /// Tries the items an open app was holding again (after the person quits it).
    var onRetry: (() -> Void)?
    let onDismiss: () -> Void


    var body: some View {
        NoticeBanner(systemImage: report.trashed.isEmpty ? "exclamationmark.triangle" : "checkmark.circle.fill",
                     tint: report.trashed.isEmpty ? SafetyLabel.review.foreground : SafetyLabel.safe.foreground,
                     title: title, message: message, onDismiss: onDismiss) {
            if !report.inUseApps.isEmpty, let onRetry { Button("Retry", action: onRetry).controlSize(.small) }
            if !report.trashed.isEmpty {
                if let onUndo { Button("Undo", action: onUndo).controlSize(.small) }
                if let onOpenTrash { Button("Open Trash", action: onOpenTrash).controlSize(.small) }
            }
        }
    }

    private var title: String {
        if report.trashed.isEmpty { return "Nothing was moved to the Trash" }
        return "Moved \(Format.bytes(report.bytesFreed)) to the Trash"
    }

    private var message: String? {
        var parts: [String] = []
        if !report.trashed.isEmpty { parts.append("Empty the Trash in Finder to get the space back.") }
        if report.bytesLeftInUse > 0 {
            parts.append("\(Format.bytes(report.bytesLeftInUse)) of files in use stayed where they were.")
        }
        if !report.skipped.isEmpty {
            let lines = report.skipped.prefix(3).map { "\(($0.path as NSString).lastPathComponent): \($0.inUseHint ?? $0.reason)" }
            let more = report.skipped.count > 3 ? " +\(report.skipped.count - 3) more." : ""
            parts.append("Skipped \(report.skipped.count): " + lines.joined(separator: "; ") + more)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

extension Notice.Kind {
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .info: .accentColor
        case .success: SafetyLabel.safe.foreground
        case .warning: SafetyLabel.review.foreground
        case .error: SafetyLabel.keep.foreground
        }
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ScanStatusLabel()
        }
        if model.mode == .advanced {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Scan", selection: Binding(get: { model.scope }, set: { scope in
                        guard scope != model.scope else { return }
                        model.scope = scope
                        model.rescan()
                    })) {
                        ForEach(ScanScope.allCases) { scope in
                            Label(scope.title, systemImage: scope.systemImage).tag(scope)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(model.scope.title, systemImage: model.scope.systemImage)
                }
                .disabled(model.phase.isBusy)
                .help(model.phase.isBusy ? "Stop the scan to change what's scanned" : "What to scan")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if model.phase.isBusy {
                Button { model.cancelScan() } label: { Label("Stop Scan", systemImage: "stop.circle") }
                    .help("Stop scanning")
            } else {
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Rescan (⌘R)")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.showInspector.toggle() } label: { Label("Ask", systemImage: "sparkles") }
                .help("Ask Freespan a question (⌥⌘I)")
        }
    }
}

/// "Scanned 2 min ago · 1.9M files" or live progress while scanning.
struct ScanStatusLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .scanning(let progress):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Format.count(progress?.filesSeen ?? 0)) files")
                            .font(.caption.weight(.medium)).monospacedDigit()
                        Text(progress.map { Format.displayPath($0.currentPath, home: model.home) } ?? "Starting…")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(width: 200, alignment: .leading)
                }
            case .analyzing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sorting into groups…").font(.caption).foregroundStyle(.secondary)
                }
            default:
                if model.isLabeling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Identifying \(Format.count(model.identifyingCount)) item\(model.identifyingCount == 1 ? "" : "s")…")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .help("\(model.assistantName) is naming items Freespan's rules don't recognize.")
                } else if let scan = model.scan {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("Scanned \(scan.scannedAt.formatted(.relative(presentation: .named))) · \(Format.count(scan.root.itemCount)) files")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .fixedSize()
    }
}

#Preview("Main window") {
    RootView()
        .environment(AppModel.preview())
        .frame(width: 1280, height: 800)
}

#Preview("Main window · Easy") {
    RootView()
        .environment(AppModel.preview(mode: .easy))
        .frame(width: 1180, height: 760)
}

#Preview("Main window · dark") {
    RootView()
        .environment(AppModel.preview(selection: .diskMap))
        .frame(width: 1280, height: 800)
        .preferredColorScheme(.dark)
}
