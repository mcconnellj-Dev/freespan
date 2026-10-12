import FreespanKit
import SwiftUI

struct BasketView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var selection: String?

    var body: some View {
        if model.basket.isEmpty {
            EmptyStateView(systemImage: "basket",
                           title: model.mode == .easy ? "Nothing to clean up yet" : "Your basket is empty",
                           message: model.mode == .easy
                               ? "Pick things from Home or Check First. Nothing is removed until you confirm, and everything goes to the Trash first."
                               : "Add items from a group or the Disk Map. Nothing is removed until you confirm, and everything goes to the Trash first.") {
                if model.safeBytes > 0 {
                    Button(model.mode == .easy
                           ? "Add Everything Safe to Remove · \(Format.bytes(model.safeBytes))"
                           : "Add All Safe Items · \(Format.bytes(model.safeBytes))") { model.addAllSafe() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.rows(model.basketItems)) { row in
                        switch row {
                        case .item(let item):
                            BasketRow(item: item).tag(item.path)
                        case .group(let group):
                            DisclosureGroup {
                                ForEach(group.items) { item in
                                    BasketRow(item: item).tag(item.path)
                                }
                            } label: {
                                BasketGroupRow(group: group)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let path = ids.first, !FindingGrouping.isGroupID(path) {
                        ItemContextMenu(path: path, finding: model.basket[path], showInMap: true).environment(model)
                    }
                }
                .onKeyPress(.space) {
                    guard let selection else { return .ignored }
                    model.quickLook(selection)
                    return .handled
                }
                .onDeleteCommand {
                    if let selection { model.removeFromBasket(selection) }
                }
                Divider()
                footer
            }
            .sheet(isPresented: $confirming) {
                TrashConfirmationSheet(isPresented: $confirming).environment(model)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.bytes(model.basketTotal))
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("\(model.basket.count) item\(model.basket.count == 1 ? "" : "s") · goes to the Trash · undo anytime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear Basket") { model.clearBasket() }
            Button {
                confirming = true
            } label: {
                if model.isCleaning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isCleaning)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
        .animation(.snappy, value: model.basketTotal)
    }
}

private struct BasketRow: View {
    @Environment(AppModel.self) private var model
    let item: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CategoryGlyph(category: item.category, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    LabelPill(label: item.label, compact: true, mode: model.mode)
                }
                Text(Format.displayPath(item.path, home: model.home))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.label == .review {
                    Label(item.classification.explanation, systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(SafetyLabel.review.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            SizeText(bytes: item.size)
            Button {
                model.removeFromBasket(item.path)
            } label: {
                Image(systemName: "minus.circle").font(.body)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from basket")
        }
        .padding(.vertical, 5)
    }
}

/// "App caches · 412 items · 6.2 GB" with one button to take them all out.
private struct BasketGroupRow: View {
    @Environment(AppModel.self) private var model
    let group: FindingGroup

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CategoryGlyph(category: group.category, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.title).font(.body.weight(.medium)).lineLimit(1)
                    LabelPill(label: group.label, compact: true, mode: model.mode)
                }
                Text("\(Format.count(group.items.count)) items")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SizeText(bytes: group.size)
            Button {
                model.removeFromBasket(group.items.map(\.path))
            } label: {
                Image(systemName: "minus.circle").font(.body)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove all \(group.items.count) from basket")
        }
        .padding(.vertical, 5)
    }
}

/// "Move 6 items (31.2 GB) to the Trash?" with Review items called out. Items wholly in use stay in the basket
/// unless the person quits those apps; partly open folders go without their open files. Header and buttons are
/// pinned; only the middle scrolls.
struct TrashConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var blocked: [String: InUseStatus] = [:]
    @State private var checking = true

    private var movable: [Finding] { model.basketItems.filter { blocked[$0.path].map(\.isPartial) ?? true } }

    var body: some View {
        let movable = movable
        let movableBytes = movable.reduce(0) { $0 + max(0, $1.size - (blocked[$1.path]?.busyBytes ?? 0)) }
        let review = movable.filter { $0.label == .review }
        let summary = model.inUseSummary(model.basketItems, blocked: blocked)
        PinnedSheet {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move \(movable.count) item\(movable.count == 1 ? "" : "s") to the Trash?")
                        .font(.title3.weight(.semibold))
                    Text("Empty the Trash afterwards to get \(Format.bytes(movableBytes)) back.")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if !review.isEmpty { reviewList(review) }
                if !summary.isEmpty { InUseSection(summary: summary, recheck: recheck) }
                Text(summary.apps.isEmpty && summary.backgroundBytes == 0
                     ? "Items go to the Trash. You can undo from History."
                     : "Anything in use stays where it is. Everything else goes to the Trash, and you can undo from History.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        } footer: {
            HStack {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking for open apps…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    let inUse = blocked
                    isPresented = false
                    Task { await model.moveBasketToTrash(inUse: inUse) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(checking || movable.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .animation(.snappy, value: blocked.count)
        .task { await recheck() }
    }

    private func reviewList(_ review: [Finding]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.mode == .easy
                  ? "\(review.count) item\(review.count == 1 ? " needs" : "s need") a check first"
                  : "\(review.count) item\(review.count == 1 ? " is" : "s are") marked Review", systemImage: "eye")
                .font(.callout.weight(.semibold))
                .foregroundStyle(SafetyLabel.review.foreground)
            ForEach(model.rows(review)) { row in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                        if case .group(let group) = row {
                            Text("\(Format.count(group.items.count)) items")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Spacer()
                        SizeText(bytes: row.size, font: .callout).foregroundStyle(.secondary)
                    }
                    Text(explanation(for: row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(explanation(for: row))
                }
            }
        }
        .padding(12)
        .background(SafetyLabel.review.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func recheck() async {
        checking = true
        blocked = await model.checkInUse(model.basketItems)
        checking = false
    }

    private func explanation(for row: FindingRow) -> String {
        switch row {
        case .item(let item): item.classification.explanation
        case .group(let group): group.classification.explanation
        }
    }
}

#Preview("Basket") {
    BasketView()
        .environment(AppModel.preview(selection: .basket))
        .frame(width: 820, height: 520)
}

#Preview("Basket · empty") {
    BasketView()
        .environment(AppModel.preview(selection: .basket, basket: false))
        .frame(width: 820, height: 520)
}

#Preview("Confirm sheet") {
    TrashConfirmationSheet(isPresented: .constant(true))
        .environment(AppModel.preview(selection: .basket))
}

#Preview("Confirm sheet · many apps") {
    TrashConfirmationSheet(isPresented: .constant(true))
        .environment(AppModel.preview(selection: .basket, inUse: .manyApps))
}

#Preview("Confirm sheet · background only") {
    TrashConfirmationSheet(isPresented: .constant(true))
        .environment(AppModel.preview(selection: .basket, inUse: .backgroundOnly))
}

#Preview("Confirm sheet · partly in use") {
    TrashConfirmationSheet(isPresented: .constant(true))
        .environment(AppModel.preview(selection: .basket, inUse: .partial))
}
