import FreespanKit
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let volume = model.volume, let scan = model.scan {
                    VolumeCard(volume: volume, scanRoot: scan.root, summaries: model.summaries, scope: model.scannedScope ?? model.scope)
                }
                if model.plan?.steps.isEmpty ?? true {
                    HStack(alignment: .top, spacing: 16) {
                        ReadyToClearCard()
                        DeepCleanPlanCard()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    // A plan with steps gets the full width.
                    ReadyToClearCard()
                    DeepCleanPlanCard()
                }
                CategoryGrid()
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Always open at the top (the volume summary), and start fresh after every scan.
        .defaultScrollAnchor(.top)
        .id(model.scan?.scannedAt)
    }
}

// MARK: - Volume

private struct VolumeCard: View {
    let volume: VolumeInfo
    let scanRoot: FileNode
    let summaries: [CategorySummary]
    let scope: ScanScope

    private struct Segment: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let color: Color
    }

    private var lowOnSpace: Bool {
        volume.totalBytes > 0 && Double(volume.availableBytes) / Double(volume.totalBytes) < 0.10
    }

    private var segments: [Segment] {
        var result = summaries
            .filter { $0.category != .other && $0.totalBytes > 0 }
            .map { Segment(id: $0.category.rawValue, name: $0.category.displayName, bytes: $0.totalBytes, color: $0.category.color) }
        let matched = result.reduce(0) { $0 + $1.bytes }
        let rest = max(0, scanRoot.size - matched)
        if rest > 0 {
            result.append(Segment(id: "rest", name: "Everything else", bytes: rest, color: CategoryID.other.color))
        }
        let outside = max(0, volume.usedBytes - scanRoot.size)
        if outside > 0 {
            result.append(Segment(id: "outside", name: scope == .home ? "Outside your home folder" : "System & purgeable",
                                  bytes: outside, color: CategoryID.system.color.opacity(0.55)))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                EyebrowLabel(volume.name)
                Spacer()
                if lowOnSpace {
                    Label("Low on space", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.bytes(volume.usedBytes))
                    .font(.system(size: 40, weight: .bold))
                    .tracking(-0.8)
                Text("of \(Format.bytes(volume.totalBytes)) used")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary).font(.title3)
                Text("\(Format.bytes(volume.availableBytes)) free")
                    .font(.title3.weight(lowOnSpace ? .semibold : .regular))
                    .foregroundStyle(lowOnSpace ? Theme.warning : .secondary)
            }
            .monospacedDigit()

            bar
            legend
        }
        .card()
    }

    private var bar: some View {
        GeometryReader { geo in
            let total = max(Double(volume.totalBytes), 1)
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(2, geo.size.width * Double(segment.bytes) / total - 2))
                        .help("\(segment.name) · \(Format.bytes(segment.bytes))")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.freeSpace)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(height: 22)
    }

    private var legend: some View {
        FlowLayout(spacing: 14) {
            ForEach(segments) { segment in
                legendItem(segment.name, bytes: segment.bytes, color: segment.color)
            }
            legendItem("Free", bytes: volume.availableBytes, color: Theme.freeSpace)
        }
    }

    private func legendItem(_ name: String, bytes: Int64, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(name).font(.caption)
            Text(Format.bytes(bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

// MARK: - Ready to clear

private struct ReadyToClearCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let safe = model.safeFindings
        let notInBasket = safe.filter { !model.isInBasket($0.path) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                EyebrowLabel("Ready to clear")
                Spacer()
                LabelPill(label: .safe, compact: true)
            }
            Text(Format.bytes(model.safeBytes))
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
            Text(safe.isEmpty
                 ? "Nothing is marked Safe yet. Safe items regenerate on their own or are installers you no longer need."
                 : "\(safe.count) items marked Safe. They regenerate on their own or are installers you no longer need.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if !safe.isEmpty && notInBasket.isEmpty {
                Button("Review Basket") { model.selection = .basket }
            } else {
                Button {
                    model.addAllSafe()
                } label: {
                    Label("Add All Safe to Basket", systemImage: "basket")
                }
                .buttonStyle(.borderedProminent)
                .disabled(safe.isEmpty)
            }
        }
        .card(tint: Theme.accentSoft, fillHeight: true)
    }
}

// MARK: - Deep Clean Plan

struct DeepCleanPlanCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                EyebrowLabel("Deep Clean Plan")
                Spacer()
                if model.refinedPlan != nil {
                    Text("Refined by \(model.assistantName)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(model.assistantKind.tint)
                }
            }
            content
        }
        .card(fillHeight: true)
    }

    @ViewBuilder private var content: some View {
        if let plan = model.plan, !plan.steps.isEmpty {
            PlanStepsView(plan: plan)
        } else {
            Text(model.scan == nil
                 ? "After a scan, Freespan lists the biggest wins in order, Safe first."
                 : "Nothing else stands out. The groups below show everything Freespan found.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if model.canRefinePlan { RefinePlanControl() }
        }
    }
}

/// "Ask Claude to Refine" — offered only when the assistant is Claude.
private struct RefinePlanControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.planState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(model.assistantName) is reviewing your disk…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.refinePlan() }.controlSize(.small)
            }
        case .idle:
            if model.refinedPlan != nil {
                HStack(spacing: 12) {
                    Button("Refine Again") { model.refinePlan() }
                    Button("Use Basic Plan") { model.useRulePlan() }
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                Button {
                    model.refinePlan()
                } label: {
                    Label("Ask Claude to Refine", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .help("Claude reviews the whole-disk summary and reorders the plan. Sends names, sizes and dates only.")
            }
        }
    }
}

private struct PlanStepsView: View {
    @Environment(AppModel.self) private var model
    let plan: CleanupPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !plan.headline.isEmpty {
                Text(plan.headline).font(.headline)
            }
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(step.title).font(.callout.weight(.semibold))
                            LabelPill(label: step.risk, compact: true)
                            Spacer(minLength: 4)
                            SizeText(bytes: step.estimatedBytes, font: .callout).foregroundStyle(.secondary)
                        }
                        Text(step.reasoning).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    stepButton(step)
                }
            }
            if model.canRefinePlan {
                HStack {
                    Spacer()
                    RefinePlanControl()
                }
            }
        }
    }

    @ViewBuilder private func stepButton(_ step: CleanupPlan.Step) -> some View {
        let matches = model.findings(for: step)
        if !matches.isEmpty && matches.allSatisfy({ model.isInBasket($0.path) }) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                .frame(width: 28).help("In the basket")
        } else {
            Button { model.addPlanStep(step) } label: { Image(systemName: "basket") }
                .disabled(matches.isEmpty)
                .help(matches.isEmpty ? "Nothing in this step can be removed by Freespan" : "Add \(matches.count) item\(matches.count == 1 ? "" : "s") to the basket")
        }
    }
}

// MARK: - Groups

private struct CategoryGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EyebrowLabel("Groups")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                // Visible groups (System last), then everything Freespan didn't sort.
                ForEach(model.groups + model.summaries.filter { $0.category == .other && $0.totalBytes > 0 }) { summary in
                    CategoryCard(summary: summary)
                }
            }
        }
    }
}

private struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    let summary: CategorySummary
    @State private var hovering = false

    private var navigable: Bool { summary.findingCount > 0 && summary.category != .other }

    var body: some View {
        Button {
            if navigable { model.selection = .group(summary.category) } else { model.selection = .diskMap }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CategoryGlyph(category: summary.category)
                    Spacer()
                    if navigable {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                Text(summary.category.displayName).font(.callout.weight(.medium)).foregroundStyle(.primary)
                SizeText(bytes: summary.totalBytes, font: .system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                Group {
                    if summary.safeBytes > 0 {
                        Text("\(Format.bytes(summary.safeBytes)) safe to clear").foregroundStyle(SafetyLabel.safe.foreground)
                    } else if summary.category == .other {
                        Text("Not sorted into a group").foregroundStyle(.secondary)
                    } else {
                        Text("\(summary.findingCount) item\(summary.findingCount == 1 ? "" : "s") · nothing marked Safe").foregroundStyle(.secondary)
                    }
                }
                .font(.caption).monospacedDigit()
            }
            .card()
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(summary.category.color.opacity(hovering ? 0.6 : 0), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

#Preview("Overview") {
    OverviewView()
        .environment(AppModel.preview())
        .frame(width: 960, height: 820)
}

#Preview("Overview · plan · dark") {
    OverviewView()
        .environment(AppModel.preview(plan: true))
        .frame(width: 960, height: 980)
        .preferredColorScheme(.dark)
}

#Preview("Overview · Claude refined") {
    OverviewView()
        .environment(AppModel.preview(plan: true, refined: true, assistant: .claudeSubscription))
        .frame(width: 960, height: 980)
}

#Preview("Overview · assistant off") {
    OverviewView()
        .environment(AppModel.preview(basket: false, assistant: .off))
        .frame(width: 960, height: 820)
}
