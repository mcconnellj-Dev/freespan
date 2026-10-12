import FreespanKit
import SwiftUI

/// "Clean Up Safely…": choose which Safe groups to clear, move them to the Trash, then show the result
/// with Undo. Present with `.environment(model)` re-injected (sheets drop it on macOS).
struct CleanUpSafelySheet: View {
    enum Phase {
        case choose
        case working
        case done(CleanupReport)
        case undoing
        case retrying
        case restored(count: Int, of: Int)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Snapshot taken when the sheet opens, so the list doesn't change underneath the user mid-cleanup.
    @State private var groups: [EasyGroup]
    @State private var excluded: Set<String> = []
    @State private var phase: Phase
    /// What something has open (path → status). Wholly open items are left out; partly open folders go
    /// without their open files.
    @State private var blocked: [String: InUseStatus] = [:]
    @State private var checking = true

    init(groups: [EasyGroup], phase: Phase = .choose) {
        _groups = State(initialValue: groups)
        _phase = State(initialValue: phase)
    }

    private func isHeld(_ item: Finding) -> Bool { blocked[item.path].map { !$0.isPartial } ?? false }
    private func available(_ group: EasyGroup) -> [Finding] { group.items.filter { !isHeld($0) } }
    /// What would actually move: available items minus the open parts of partly open folders.
    private func availableBytes(_ group: EasyGroup) -> Int64 {
        available(group).reduce(0) { total, item in
            total + max(0, item.size - (blocked[item.path]?.busyBytes ?? 0))
        }
    }
    private func hasPartial(_ group: EasyGroup) -> Bool { group.items.contains { blocked[$0.path]?.isPartial == true } }
    private var selectedGroups: [EasyGroup] {
        groups.filter { !excluded.contains($0.id) && !available($0).isEmpty }
    }
    private var selectedBytes: Int64 { selectedGroups.reduce(0) { $0 + availableBytes($1) } }
    private var inUseSummary: InUseSummary {
        model.inUseSummary(groups.filter { !excluded.contains($0.id) }.flatMap(\.items), blocked: blocked)
    }

    var body: some View {
        Group {
            switch phase {
            case .choose, .working: chooser
            case .done(let report):
                DoneView(report: report, undo: { Task { await undo(report) } },
                         retry: { Task { await retry(report) } }, close: { dismiss() })
            case .undoing: progress("Putting everything back…")
            case .retrying: progress("Trying again…")
            case .restored(let count, let total): restoredView(count: count, total: total)
            }
        }
        .frame(width: SheetMetrics.width)
        .interactiveDismissDisabled(isBusy)
        .animation(.snappy, value: phaseKey)
    }

    private var phaseKey: Int {
        switch phase {
        case .choose: 0
        case .working: 1
        case .done: 2
        case .undoing: 3
        case .restored: 4
        case .retrying: 5
        }
    }

    // MARK: Choose

    @ViewBuilder private var chooser: some View {
        if groups.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(SafetyLabel.safe.foreground)
                Text("Nothing to clean up safely right now").font(.title3.weight(.semibold))
                Text("Freespan checks again every time you scan.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 6)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        } else {
            let summary = inUseSummary
            PinnedSheet {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free up \(Format.bytes(selectedBytes)) safely")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("These come back on their own or are spare copies. Everything goes to the Trash first, so you can undo.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)
            } content: {
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        groupRow(group)
                        if group.id != groups.last?.id { Divider().padding(.leading, 56) }
                    }
                    if !summary.isEmpty {
                        InUseSection(summary: summary, recheck: checkInUse)
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .disabled(isWorking)
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                HStack(spacing: 10) {
                    if case .working = phase {
                        ProgressView().controlSize(.small)
                        Text("Moving to the Trash…").font(.callout).foregroundStyle(.secondary)
                    } else if checking {
                        ProgressView().controlSize(.small)
                        Text("Checking for open apps…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(selectedGroups.isEmpty ? "Nothing selected" : "\(Format.bytes(selectedBytes)) selected")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Move to Trash") { Task { await moveToTrash() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedGroups.isEmpty || model.isCleaning || checking)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .disabled(isWorking)
            }
            .animation(.snappy, value: selectedBytes)
            .animation(.snappy, value: blocked.count)
            .task { await checkInUse() }
        }
    }

    private var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    private var isBusy: Bool {
        switch phase {
        case .working, .undoing, .retrying: true
        default: false
        }
    }

    /// Title, one line of why, size and a toggle. Groups with the uv cache add its "may free less" caveat.
    private func groupRow(_ group: EasyGroup) -> some View {
        let bytes = availableBytes(group)
        let allInUse = !group.items.isEmpty && available(group).isEmpty
        let isOn = Binding(
            get: { !excluded.contains(group.id) && !allInUse },
            set: { on in if on { excluded.remove(group.id) } else { excluded.insert(group.id) } }
        )
        let why = allInUse ? "In use right now, so it's skipped this time"
            : hasPartial(group) ? "A few files are in use and will be skipped"
            : group.explanation
        let caveat = group.items.first { $0.classification.ruleID == "uv-cache" }?.classification.explanation
        return HStack(spacing: 10) {
            KindGlyph(kind: group.kind, color: group.color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.kind.title).font(.body.weight(.medium)).lineLimit(1)
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(why == group.explanation ? why : "\(why). \(group.explanation)")
                if let caveat {
                    Text(caveat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            SizeText(bytes: allInUse ? group.size : bytes, font: .callout)
                .foregroundStyle(isOn.wrappedValue ? .primary : .tertiary)
            Toggle(group.kind.title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(allInUse)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .disabled(isWorking)
        .help("\(Format.count(group.items.count)) item\(group.items.count == 1 ? "" : "s")")
    }

    // MARK: Results

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }

    private func restoredView(count: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: count == total ? "arrow.uturn.backward.circle.fill" : "exclamationmark.triangle")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(count == total ? Color.accentColor : SafetyLabel.review.foreground)
            Text(count == total ? "Everything is back" : "Put back \(count) of \(total) items")
                .font(.title2.weight(.semibold))
            Text(count == total
                 ? "It's all where it was before. Scan again to see it in Freespan."
                 : "The rest are still in the Trash. You can try again from History.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Scan Again") {
                    dismiss()
                    model.rescan()
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

    // MARK: Actions

    /// Finds what open apps are holding. Wholly open items are left out until the apps quit.
    private func checkInUse() async {
        checking = true
        blocked = await model.checkInUse(groups.flatMap(\.items))
        checking = false
    }

    /// Moves just the selected groups to the Trash, minus items wholly in use (partly open folders lose only their
    /// free parts). The basket is left as the user had it.
    private func moveToTrash() async {
        let selected = selectedGroups.flatMap(available)
        guard !selected.isEmpty, !model.isCleaning else { return }
        phase = .working
        let report = await model.moveToTrash(selected)
        phase = .done(report)
    }

    private func retry(_ report: CleanupReport) async {
        phase = .retrying
        let merged = await model.retryInUse(report, candidates: groups.flatMap(\.items))
        phase = .done(merged)
    }

    private func undo(_ report: CleanupReport) async {
        phase = .undoing
        let restored = await model.undo(report.trashed)
        let total = report.trashed.count
        if restored == total { model.notice = nil } // the sheet already says so
        phase = .restored(count: restored, of: total)
    }
}

/// Big checkmark, "Moved 62 GB to the Trash", Open Trash / Undo / Done, plus any skipped items.
/// Honest about space: nothing is freed until the user empties the Trash, which Freespan never does itself.
private struct DoneView: View {
    @Environment(AppModel.self) private var model
    let report: CleanupReport
    let undo: () -> Void
    var retry: (() -> Void)?
    let close: () -> Void
    @State private var showSkipped = false
    @State private var appeared = false

    var body: some View {
        let movedAny = !report.trashed.isEmpty
        VStack(spacing: 12) {
            Image(systemName: movedAny ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(movedAny ? SafetyLabel.safe.foreground : SafetyLabel.review.foreground)
                .symbolEffect(.bounce, value: appeared)
                .padding(.bottom, 2)
            Text(movedAny ? "Moved \(Format.bytes(report.bytesFreed)) to the Trash" : "Nothing was moved to the Trash")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            if movedAny {
                VStack(spacing: 3) {
                    Text("Empty the Trash in Finder to get the space back.")
                        .font(.callout)
                    Text("Until then, you can undo or put things back from the Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }
            if report.bytesLeftInUse > 0 {
                Text("\(Format.bytes(report.bytesLeftInUse)) of files in use stayed where they were.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !report.skipped.isEmpty { skipped }
            let held = report.inUseApps
            if !held.isEmpty, let retry {
                HStack(spacing: 8) {
                    Text(inUseSummary(held)).font(.callout).foregroundStyle(.secondary)
                    Button("Retry", action: retry).controlSize(.small)
                }
            }
            HStack {
                if movedAny {
                    Button("Undo", action: undo)
                        .help("Put everything back where it was")
                    Button("Open Trash") { model.openTrash() }
                        .help("Open the Trash in Finder, where you can empty it")
                }
                Button("Done", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }

    /// "Quit Google Chrome and try again." across everything left behind because it was in use.
    private func inUseSummary(_ held: [BlockingApp]) -> String {
        let apps = held.filter(model.canQuit)
        guard !apps.isEmpty else { return "Some items were in use. Try again in a little while." }
        return "Quit \(BlockingApp.list(apps.map(\.name))) and try again."
    }

    private var skipped: some View {
        let count = report.skipped.count
        return DisclosureGroup(isExpanded: $showSkipped) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.skipped, id: \.self) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text((item.path as NSString).lastPathComponent)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.inUseHint ?? item.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxHeight: 120)
        } label: {
            Text(count == 1 ? "1 item was skipped" : "\(count) items were skipped")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.top, 4)
    }
}

// MARK: - Previews

#Preview("Clean Up Safely · choose") {
    let model = AppModel.easyPreview(inUse: .none)
    return CleanUpSafelySheet(groups: EasyGroup.make(model.easySafeFindings + SampleData.extraSafeFindings))
        .environment(model)
}

#Preview("Clean Up Safely · many apps in use") {
    let model = AppModel.easyPreview(inUse: .manyApps)
    return CleanUpSafelySheet(groups: EasyGroup.make(model.easySafeFindings + SampleData.extraSafeFindings))
        .environment(model)
}

#Preview("Clean Up Safely · background only") {
    let model = AppModel.easyPreview(inUse: .backgroundOnly)
    return CleanUpSafelySheet(groups: EasyGroup.make(model.easySafeFindings + SampleData.extraSafeFindings))
        .environment(model)
}

#Preview("Clean Up Safely · partly in use") {
    let model = AppModel.easyPreview(inUse: .partial)
    return CleanUpSafelySheet(groups: EasyGroup.make(model.easySafeFindings + SampleData.extraSafeFindings))
        .environment(model)
}

#Preview("Clean Up Safely · done, partly cleaned") {
    let model = AppModel.easyPreview()
    let logs = SampleData.extraSafeFindings[0]
    let report = CleanupReport(trashed: [
        ActionLogEntry(originalPath: logs.path + "/DiagnosticReports", trashPath: SampleData.home + "/.Trash/DiagnosticReports",
                       size: 280_000_000),
    ], skipped: [], partial: [
        .init(path: logs.path, movedBytes: 280_000_000, skippedBytes: 44_700_000,
              blockingApps: [BlockingApp(bundleID: nil, name: "cloudd", pids: [2])]),
    ])
    return CleanUpSafelySheet(groups: EasyGroup.make([logs]), phase: .done(report))
        .environment(model)
}

#Preview("Clean Up Safely · done") {
    let model = AppModel.easyPreview()
    let trashed = model.easySafeFindings.map {
        ActionLogEntry(originalPath: $0.path, trashPath: SampleData.home + "/.Trash/" + $0.name, size: $0.size)
    }
    let report = CleanupReport(trashed: trashed, skipped: [
        .init(path: SampleData.home + "/Library/Caches/Google", reason: "Google Chrome is using this right now. Quit Google Chrome, then try again.",
              blockingApps: [BlockingApp(bundleID: "com.google.Chrome", name: "Google Chrome", pids: [1])]),
        .init(path: SampleData.home + "/.npm", reason: "You don't have permission to move it."),
    ])
    return CleanUpSafelySheet(groups: EasyGroup.make(model.easySafeFindings), phase: .done(report))
        .environment(model)
}

#Preview("Clean Up Safely · nothing") {
    CleanUpSafelySheet(groups: [])
        .environment(AppModel.easyPreview(safe: false))
}
