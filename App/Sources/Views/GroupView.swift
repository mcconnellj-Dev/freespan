import FreespanKit
import SwiftUI

struct GroupView: View {
    @Environment(AppModel.self) private var model
    let category: CategoryID

    @State private var sortOrder = [KeyPathComparator(\FindingRow.size, order: .reverse)]
    @State private var selection = Set<FindingRow.ID>()

    /// Rule-mates (hundreds of app caches) collapse into one expandable row; everything sorts together.
    /// Lists only visible findings (no Keep unless shown, nothing dismissed, nothing under the size threshold).
    private var rows: [FindingRow] {
        model.rows(model.tableFindings(in: category)).map { row in
            guard case .group(let group) = row else { return row }
            return .group(FindingGroup(id: group.id, title: group.title, classification: group.classification,
                                       items: group.items.sorted(using: itemOrder), size: group.size))
        }
        .sorted(using: sortOrder)
    }

    /// The table's sort order applied to individual findings inside a group.
    private var itemOrder: [KeyPathComparator<Finding>] {
        sortOrder.map { comparator in
            let order = comparator.order
            let keyPath: AnyKeyPath = comparator.keyPath
            if keyPath == \FindingRow.name { return KeyPathComparator(\Finding.name, order: order) }
            if keyPath == \FindingRow.label { return KeyPathComparator(\Finding.label, order: order) }
            if keyPath == \FindingRow.lastUsedSortKey { return KeyPathComparator(\Finding.lastUsedSortKey, order: order) }
            return KeyPathComparator(\Finding.size, order: order)
        }
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            GroupHeader(category: category)
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                table(rows)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        let hidden = model.hiddenCount(in: category)
        if hidden > 0 {
            EmptyStateView(systemImage: "eye.slash", title: "Everything here is hidden",
                           message: "\(Format.count(hidden)) item\(hidden == 1 ? " is" : "s are") hidden by your settings: items Freespan keeps, items you chose to keep, or small items.") {
                if model.keptCount(in: category) > 0 {
                    Button("Show Items Freespan Keeps") { model.showKeptItems = true }
                }
            }
        } else {
            EmptyStateView(systemImage: category.systemImage, title: "Nothing here",
                           message: "Freespan didn't find anything in \(category.displayName) on this scan.")
        }
    }

    private func table(_ rows: [FindingRow]) -> some View {
        let memberPaths = Set(rows.flatMap { row -> [String] in
            if case .group(let group) = row { return group.items.map(\.path) }
            return []
        })
        return Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { row in
                switch row {
                case .item(let finding): BasketCheckbox(finding: finding).environment(model)
                case .group(let group): GroupBasketCheckbox(items: group.items).environment(model)
                }
            }
            .width(22)

            TableColumn("Name", value: \.name) { row in
                switch row {
                case .item(let finding):
                    FindingNameCell(finding: finding, isGroupMember: memberPaths.contains(finding.path), home: model.home)
                case .group(let group): GroupNameCell(group: group)
                }
            }
            .width(min: 200, ideal: 420)

            TableColumn("Label", value: \.label) { row in
                LabelPill(label: row.label, compact: true, mode: .advanced)
            }
            .width(min: 64, ideal: 80, max: 100)

            TableColumn("Size", value: \.size) { row in
                SizeText(bytes: row.size)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 86, max: 110)

            TableColumn("Last Used", value: \.lastUsedSortKey) { row in
                Text(Format.relative(row.lastUsedSortKey == .distantPast ? nil : row.lastUsedSortKey))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 100, max: 140)

            TableColumn("Source", value: \.sourceSortKey) { row in
                SourceCell(source: row.source)
            }
            .width(min: 64, ideal: 84, max: 110)
        }
        .contextMenu(forSelectionType: FindingRow.ID.self) { ids in
            let items = findings(for: ids, in: rows)
            if ids.count == 1, let path = ids.first, !FindingGrouping.isGroupID(path) {
                ItemContextMenu(path: path, finding: model.finding(at: path), showInMap: true).environment(model)
            } else if !items.isEmpty {
                Button("Add \(items.count) Items to Basket") { model.addToBasket(items) }
                Button("Remove from Basket") { model.removeFromBasket(items.map(\.path)) }
                    .disabled(!items.contains { model.basket[$0.path] != nil })
            }
        } primaryAction: { ids in
            if let path = ids.first, !FindingGrouping.isGroupID(path) { model.showInMap(path) }
        }
        .onKeyPress(.space) {
            guard let path = selection.first, !FindingGrouping.isGroupID(path) else { return .ignored }
            model.quickLook(path)
            return .handled
        }
        .onDeleteCommand { model.addToBasket(findings(for: selection, in: rows)) }
    }

    /// Selected findings, with groups expanded to their items.
    private func findings(for ids: Set<FindingRow.ID>, in rows: [FindingRow]) -> [Finding] {
        var seen = Set<String>()
        var result: [Finding] = []
        for row in rows {
            let candidates = ids.contains(row.id) ? row.findings : row.findings.filter { ids.contains($0.path) }
            for finding in candidates where seen.insert(finding.path).inserted { result.append(finding) }
        }
        return result
    }
}

/// Friendly title first, folder name second. Inside an expanded group (where every row shares the group's
/// title) the folder name leads instead, with its location underneath.
private struct FindingNameCell: View {
    let finding: Finding
    let isGroupMember: Bool
    let home: String

    private var title: String { finding.classification.title }
    private var hasFriendlyTitle: Bool {
        !title.isEmpty && title.caseInsensitiveCompare(finding.name) != .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isGroupMember || !hasFriendlyTitle {
                Text(finding.name).lineLimit(1).truncationMode(.middle)
                Text(Format.displayPath(PathUtil.parent(of: finding.path), home: home))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(title).lineLimit(1)
                Text("\(finding.name) · \(finding.classification.explanation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .help("\(Format.displayPath(finding.path, home: home))\n\(finding.classification.explanation)")
    }
}

private struct GroupNameCell: View {
    let group: FindingGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(group.title).fontWeight(.medium).lineLimit(1)
                Text("\(Format.count(group.items.count)) items")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(group.classification.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(group.classification.explanation)
        }
        .padding(.vertical, 3)
    }
}

/// Where a label came from: a built-in rule, local identification, or the assistant.
struct SourceCell: View {
    let source: ClassificationSource

    var body: some View {
        Label(source.title, systemImage: source.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(source == .ai ? Color.accentColor : .secondary)
            .lineLimit(1)
            .help(source.help)
    }
}

extension ClassificationSource {
    var title: String {
        switch self {
        case .rule: "Rule"
        case .heuristic: "Identified"
        case .ai: "Assistant"
        }
    }

    var systemImage: String {
        switch self {
        case .rule: "checklist"
        case .heuristic: "magnifyingglass"
        case .ai: "sparkle"
        }
    }

    var help: String {
        switch self {
        case .rule: "Matched by one of Freespan's built-in rules."
        case .heuristic: "Identified from the app it belongs to. Look before removing."
        case .ai: "Identified by the assistant. Advisory only — look before removing."
        }
    }
}

extension FindingRow {
    var source: ClassificationSource {
        switch self {
        case .item(let finding): finding.classification.source
        case .group(let group): group.classification.source
        }
    }

    var sourceSortKey: String { source.title }
}

private struct GroupHeader: View {
    @Environment(AppModel.self) private var model
    let category: CategoryID

    var body: some View {
        let summary = model.summary(for: category)
        let safeCandidates = model.safeFindings.filter { $0.category == category }
        let allSafeInBasket = !safeCandidates.isEmpty && safeCandidates.allSatisfy { model.isInBasket($0.path) }
        HStack(alignment: .center, spacing: 14) {
            CategoryGlyph(category: category, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    SizeText(bytes: summary?.totalBytes ?? 0, font: .callout)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(Format.count(summary?.findingCount ?? 0)) item\(summary?.findingCount == 1 ? "" : "s")").monospacedDigit()
                    if let safe = summary?.safeBytes, safe > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(Format.bytes(safe)) safe").foregroundStyle(SafetyLabel.safe.foreground).monospacedDigit()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HiddenFootnote(category: category)
            }
            Spacer()
            if allSafeInBasket {
                Label("All Safe items in basket", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
            } else {
                Button {
                    model.addAllSafe(in: category)
                } label: {
                    Label("Add All Safe", systemImage: "basket")
                }
                .buttonStyle(.borderedProminent)
                .disabled(safeCandidates.isEmpty)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

/// "12 hidden · Show" under a group title when visibility settings hide some of its items.
private struct HiddenFootnote: View {
    @Environment(AppModel.self) private var model
    let category: CategoryID

    var body: some View {
        let hidden = model.hiddenCount(in: category)
        if hidden > 0 {
            HStack(spacing: 4) {
                Text("\(Format.count(hidden)) hidden")
                    .help(helpText)
                if model.keptCount(in: category) > 0 {
                    Button("Show") { model.showKeptItems = true }
                        .buttonStyle(.link)
                        .help("Show items Freespan keeps")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if model.keptCount(in: category) > 0 { parts.append("items Freespan keeps") }
        if model.minimumItemSize > 0 { parts.append("items smaller than \(Format.bytes(model.minimumItemSize))") }
        if !model.dismissedPaths.isEmpty { parts.append("items you chose to keep") }
        return "Hidden: " + (parts.isEmpty ? "by your settings" : parts.joined(separator: ", "))
    }
}

/// One checkbox for a whole group: adds or removes every item, and shows a dash when only some are in.
struct GroupBasketCheckbox: View {
    @Environment(AppModel.self) private var model
    let items: [Finding]

    var body: some View {
        let cleanable = items.filter { model.canAddToBasket($0) }
        let inBasket = cleanable.filter { model.isInBasket($0.path) }.count
        // Two sources that disagree when only some items are in, so the checkbox shows its mixed state.
        // Only the first one acts when clicked.
        let any = Binding<Bool>(
            get: { inBasket > 0 },
            set: { isOn in
                if isOn { model.addToBasket(cleanable) } else { model.removeFromBasket(items.map(\.path)) }
            }
        )
        let all = Binding<Bool>(get: { !cleanable.isEmpty && inBasket == cleanable.count }, set: { _ in })
        Toggle("", sources: [any, all], isOn: \.self)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(cleanable.isEmpty)
            .help(cleanable.isEmpty ? "These items can't be removed by Freespan" : "Add all \(cleanable.count) to the cleanup basket")
    }
}

/// Checkbox bound to basket membership; disabled for Keep / Protected.
struct BasketCheckbox: View {
    @Environment(AppModel.self) private var model
    let finding: Finding

    var body: some View {
        let allowed = model.canAddToBasket(finding)
        Toggle("", isOn: Binding(
            get: { model.isInBasket(finding.path) },
            set: { isOn in
                if isOn { model.addToBasket(finding) } else { model.removeFromBasket(finding.path) }
            }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(!allowed)
        .help(allowed ? "Add to cleanup basket" : "\(finding.label.displayName) items can't be removed by Freespan")
    }
}

#Preview("Group · Developer") {
    GroupView(category: .developer)
        .environment(AppModel.preview(selection: .group(.developer)))
        .environment(\.appMode, .advanced)
        .frame(width: 900, height: 560)
}

#Preview("Group · showing kept items") {
    GroupView(category: .system)
        .environment(AppModel.preview(selection: .group(.system), showKeptItems: true))
        .frame(width: 900, height: 560)
}

#Preview("Group · Downloads · dark") {
    GroupView(category: .downloads)
        .environment(AppModel.preview(selection: .group(.downloads)))
        .frame(width: 900, height: 560)
        .preferredColorScheme(.dark)
}
