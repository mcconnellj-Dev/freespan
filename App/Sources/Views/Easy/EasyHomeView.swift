import FreespanKit
import SwiftUI

/// Easy mode's "Clean" screen: how full the Mac is with the safe cleanup beside it, what's using the space
/// (bento tiles), and what's worth a look.
struct EasyHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var cleaningUp = false
    @State private var toast: EasyToast?

    var body: some View {
        if model.scan == nil {
            EmptyStateView(systemImage: "internaldrive", title: "Scan your Mac",
                           message: "Freespan looks through your files and shows what you can safely clear. Nothing is changed while it scans.") {
                Button("Scan My Mac") { model.rescan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.phase.isBusy)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CleanHeader { cleaningUp = true }
                    SpaceBreakdownSection()
                    WorthALookCard(toast: $toast)
                    AskFooter()
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 940)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            .id(model.scan?.scannedAt)
            .easyToast($toast)
            .sheet(isPresented: $cleaningUp) {
                CleanUpSafelySheet(groups: EasyGroup.make(model.easySafeFindings))
                    .environment(model)
                    .environment(\.appMode, model.mode)
            }
        }
    }
}

// MARK: - Header

/// Small gauge, "Your Mac is 93% full", free space, Trash note; the safe cleanup card on the right.
private struct CleanHeader: View {
    @Environment(AppModel.self) private var model
    let startCleanup: () -> Void

    var body: some View {
        let fraction = model.easyUsedFraction ?? 0
        let low = model.easyIsLowOnSpace
        let tint = low ? Theme.warning : Color.accentColor
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                status(fraction: fraction, low: low, tint: tint)
                Spacer(minLength: 12)
                SafeNowCard(start: startCleanup)
                    .frame(width: 280)
            }
            VStack(alignment: .leading, spacing: 14) {
                status(fraction: fraction, low: low, tint: tint)
                SafeNowCard(start: startCleanup)
            }
        }
    }

    private func status(fraction: Double, low: Bool, tint: Color) -> some View {
        HStack(spacing: 18) {
            UsageGauge(fraction: fraction, tint: tint, lineWidth: 9, percentSize: 19, showsCaption: false)
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(fraction < 0.75
                     ? "Your Mac has plenty of space"
                     : "Your Mac is \(fraction.formatted(.percent.precision(.fractionLength(0)))) full")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.3)
                    .fixedSize()
                if let volume = model.volume {
                    Text("\(Format.bytes(volume.availableBytes)) free of \(Format.bytes(volume.totalBytes))")
                        .font(.body)
                        .foregroundStyle(low ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                }
                if model.bytesInTrashFromFreespan > 0 {
                    TrashNote(bytes: model.bytesInTrashFromFreespan)
                        .padding(.top, 2)
                }
            }
        }
    }
}

/// "62 GB is waiting in the Trash — empty it to get the space back. [Open Trash]"
/// Moving to the Trash doesn't free space; Freespan never empties the Trash itself.
private struct TrashNote: View {
    @Environment(AppModel.self) private var model
    let bytes: Int64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text("\(Format.bytes(bytes)) is waiting in the Trash — empty it to get the space back.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Trash") { model.openTrash() }
                .buttonStyle(.link)
        }
        .font(.callout)
    }
}

// MARK: - Safe to remove now

/// Tinted card: "Safe to remove now · 1.54 GB" and Clean Up Safely… (the existing review sheet).
private struct SafeNowCard: View {
    @Environment(AppModel.self) private var model
    let start: () -> Void

    var body: some View {
        let groups = EasyGroup.make(model.easySafeFindings)
        let total = groups.reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 10) {
            if groups.isEmpty {
                Label("Nothing to clean up safely right now", systemImage: "checkmark.seal")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SafetyLabel.safe.foreground)
                Text("Freespan checks again every time you scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Safe to remove now")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(Format.bytes(total))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .help(groups.prefix(5).map { "\($0.kind.title) · \(Format.bytes($0.size))" }.joined(separator: "\n"))
                Button(action: start) {
                    Text("Clean Up Safely…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isCleaning)
            }
        }
        .accessibilityElement(children: .contain)
        .card(tint: Theme.accentSoft)
    }
}

// MARK: - Worth a look

private struct WorthALookCard: View {
    @Environment(AppModel.self) private var model
    @Binding var toast: EasyToast?

    var body: some View {
        let items = model.easyCheckFirstFindings.filter { !model.isInBasket($0.path) }
        let total = items.reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(items.isEmpty ? "Worth a look" : "Worth a look · \(Format.bytes(total))")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text(items.isEmpty
                         ? "Nothing else needs a decision right now."
                         : "These could go too, but only you know if you still need them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !items.isEmpty {
                    Button(items.count > 3 ? "See All \(items.count)" : "See All") { model.selection = .checkFirst }
                        .buttonStyle(.link)
                }
            }
            if !items.isEmpty {
                VStack(spacing: 2) {
                    ForEach(items.prefix(3)) { item in
                        EasyItemRow(
                            finding: item,
                            remove: { toast = EasyItemActions.remove(item, model: model) ?? toast },
                            keep: { withAnimation(.snappy) { toast = EasyItemActions.keep(item, model: model) } }
                        )
                    }
                }
                .padding(.horizontal, -8)
                .animation(.snappy, value: items.map(\.path))
            }
        }
        .padding(4)
        .card()
    }
}

// MARK: - Footer

private struct AskFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Spacer()
            Button {
                model.showInspector = true
            } label: {
                Label("Have a question? Ask Freespan", systemImage: "sparkles")
            }
            .buttonStyle(.link)
            Spacer()
        }
        .font(.callout)
        .padding(.top, 4)
    }
}

// MARK: - Previews

extension AppModel {
    /// Sample model for Easy-mode previews.
    /// - Parameters:
    ///   - freeBytes: overrides the sample disk's free space (12 GB of 460 GB).
    ///   - safe: false drops every Safe item, for the "nothing to clean up" state.
    static func easyPreview(freeBytes: Int64? = nil, safe: Bool = true, inUse: SampleInUse = .chrome) -> AppModel {
        let model = AppModel(services: .sample(inUse: inUse), defaults: UserDefaults(suiteName: "FreespanEasyPreview") ?? .standard)
        let sample = SampleData.scan
        let volume = freeBytes.map { VolumeInfo(name: sample.volume.name, totalBytes: sample.volume.totalBytes, availableBytes: $0) }
        let scan = ScanResult(root: sample.root, volume: volume ?? sample.volume, scannedAt: sample.scannedAt,
                              duration: sample.duration, inaccessiblePaths: [])
        let findings = safe ? SampleData.findings : SampleData.findings.filter { $0.label != .safe }
        model.seed(scan: scan, analysis: ScanAnalysis(findings: findings, unknown: SampleData.unknown), scope: .home,
                   history: SampleData.history)
        model.seedApps(SampleApps.inventory)
        model.selection = .clean
        return model
    }
}

#Preview("Clean · nearly full") {
    EasyHomeView()
        .environment(AppModel.easyPreview())
        .frame(width: 900, height: 860)
}

#Preview("Clean · plenty of space · dark") {
    EasyHomeView()
        .environment(AppModel.easyPreview(freeBytes: 210 * SampleData.gb))
        .frame(width: 900, height: 860)
        .preferredColorScheme(.dark)
}

#Preview("Clean · nothing safe") {
    EasyHomeView()
        .environment(AppModel.easyPreview(safe: false))
        .frame(width: 900, height: 760)
}

#Preview("Clean · tiles still adding up") {
    let model = AppModel.easyPreview()
    model.seedApps(nil, loading: true)
    model.seedTiles([])
    return EasyHomeView()
        .environment(model)
        .frame(width: 900, height: 760)
}
