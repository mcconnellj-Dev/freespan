import FreespanKit
import SwiftUI

/// Easy-mode list of items that need a human decision, grouped by kind, largest first.
struct CheckFirstView: View {
    @Environment(AppModel.self) private var model
    @State private var toast: EasyToast?

    var body: some View {
        let items = model.easyCheckFirstFindings
        if model.scan == nil {
            EmptyStateView(systemImage: "internaldrive", title: "Scan your Mac",
                           message: "After a scan, things worth a second look show up here.") {
                Button("Scan My Mac") { model.rescan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase.isBusy)
            }
        } else if items.isEmpty {
            EmptyStateView(systemImage: "checkmark.seal", title: "Nothing to check right now",
                           message: "Everything Freespan found is either safe to clean up from Clean or something you should keep.") {
                Button("Back to Clean") { model.selection = .clean }
            }
        } else {
            VStack(spacing: 0) {
                header(items)
                Divider()
                list(EasyGroup.make(items))
            }
            .easyToast($toast)
        }
    }

    private func header(_ items: [Finding]) -> some View {
        let total = items.reduce(0) { $0 + $1.size }
        return HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Format.bytes(total)) to look over")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("\(Format.count(items.count)) item\(items.count == 1 ? "" : "s"). Click one to preview it. Remove puts it in Cleanup; Keep hides it for good.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func list(_ groups: [EasyGroup]) -> some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        EasyItemRow(
                            finding: item,
                            remove: { toast = EasyItemActions.remove(item, model: model) ?? toast },
                            keep: { withAnimation(.snappy) { toast = EasyItemActions.keep(item, model: model) } }
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(group.kind.title)
                        Spacer()
                        Text(Format.bytes(group.size)).monospacedDigit()
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.top, 6)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .animation(.snappy, value: groups.flatMap { $0.items.map(\.path) })
    }
}

#Preview("Check first") {
    CheckFirstView()
        .environment(AppModel.easyPreview())
        .frame(width: 820, height: 700)
}

#Preview("Check first · dark") {
    CheckFirstView()
        .environment(AppModel.easyPreview())
        .frame(width: 820, height: 700)
        .preferredColorScheme(.dark)
}
