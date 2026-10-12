import FreespanKit
import SwiftUI

/// Easy: Clean, Apps, Explore, then Cleanup and History — no sizes except Cleanup. (Check First opens from
/// Clean › Worth a look › See all.)
/// Advanced: Overview, Disk Map, Apps, every visible group with its size (System last), Cleanup Basket, History.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            switch model.mode {
            case .easy: easyRows
            case .advanced: advancedRows
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.basket.isEmpty {
                BasketTotalCard()
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.basket.isEmpty)
    }

    @ViewBuilder private var easyRows: some View {
        Section {
            SidebarRow(title: "Clean", systemImage: "sparkles", tint: .accentColor)
                .tag(SidebarItem.clean)
            SidebarRow(title: "Apps", systemImage: "square.grid.2x2", tint: .accentColor)
                .tag(SidebarItem.apps)
            SidebarRow(title: "Explore", systemImage: "chart.pie", tint: .accentColor)
                .tag(SidebarItem.diskMap)
        }
        Section {
            SidebarRow(title: "Cleanup", systemImage: "basket", tint: .accentColor, trailing: basketBadge)
                .tag(SidebarItem.basket)
            SidebarRow(title: "History", systemImage: "clock.arrow.circlepath", tint: .secondary)
                .tag(SidebarItem.history)
        }
    }

    @ViewBuilder private var advancedRows: some View {
        Section {
            SidebarRow(title: "Overview", systemImage: "gauge.with.dots.needle.33percent", tint: .accentColor)
                .tag(SidebarItem.overview)
            SidebarRow(title: "Disk Map", systemImage: "chart.pie", tint: .accentColor)
                .tag(SidebarItem.diskMap)
            SidebarRow(title: "Apps", systemImage: "square.grid.2x2", tint: .accentColor)
                .tag(SidebarItem.apps)
        }
        if !model.groups.isEmpty {
            Section("Groups") {
                ForEach(model.groups) { group in
                    SidebarRow(title: group.category.shortName, systemImage: group.category.systemImage,
                               tint: group.category.color, trailing: Format.bytes(group.totalBytes))
                        .tag(SidebarItem.group(group.category))
                }
            }
        }
        Section("Cleanup") {
            SidebarRow(title: "Cleanup Basket", systemImage: "basket", tint: .accentColor, trailing: basketBadge)
                .tag(SidebarItem.basket)
            SidebarRow(title: "History", systemImage: "clock.arrow.circlepath", tint: .secondary)
                .tag(SidebarItem.history)
        }
    }

    /// "3 · 18.3 GB" when the basket has something in it.
    private var basketBadge: String? {
        model.basket.isEmpty ? nil : "\(model.basket.count) · \(Format.bytes(model.basketTotal))"
    }
}

private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    var trailing: String? = nil

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}

/// Teal "Cleanup basket · 2 items / 18.3 GB" card from the mockup.
struct BasketTotalCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.selection = .basket
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.mode == .easy ? "Cleanup" : "Cleanup basket") · \(model.basket.count) item\(model.basket.count == 1 ? "" : "s")")
                    .font(.caption)
                    .opacity(0.88)
                Text(Format.bytes(model.basketTotal))
                    .font(.system(size: 20, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Goes to Trash · undo anytime")
                    .font(.caption2)
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: model.basketTotal)
        .help("Open the cleanup list")
    }
}

#Preview("Sidebar · Easy") {
    NavigationSplitView {
        SidebarView()
    } detail: {
        Text("Detail")
    }
    .environment(AppModel.preview(mode: .easy))
    .frame(width: 700, height: 600)
}

#Preview("Sidebar · Advanced") {
    NavigationSplitView {
        SidebarView()
    } detail: {
        Text("Detail")
    }
    .environment(AppModel.preview(mode: .advanced))
    .frame(width: 700, height: 600)
}
