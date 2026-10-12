import FreespanKit
import SwiftUI

/// Apps (both modes): installed apps by size or last opened, with their data, plus leftovers of removed apps.
/// The selected app's breakdown, Remove Extras and Uninstall are on the right.
struct AppsView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size"
        case lastOpened = "Last opened"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var sort: Sort = .size
    @State private var query = ""
    @State private var leftoverToRemove: Leftover?
    @State private var uninstallTarget: InstalledApp?

    var body: some View {
        screen
            // Owned here (not by the detail view) so the result and Undo stay up after the app leaves the list.
            .sheet(item: $uninstallTarget) { app in
                UninstallSheet(app: app, items: model.uninstallItems(for: app))
                    .environment(model)
                    .environment(\.appMode, model.mode)
            }
    }

    @ViewBuilder private var screen: some View {
        if let result = model.apps {
            if result.apps.isEmpty && result.leftovers.isEmpty {
                if model.appsLoading { loading } else { empty }
            } else {
                content(result)
            }
        } else if model.appsLoading || model.phase.isBusy || model.phase == .loadingCache {
            loading
        } else {
            EmptyStateView(systemImage: "square.grid.2x2", title: "See your apps",
                           message: "Freespan can list your apps with how much space each one and its data use.") {
                Button("Look at My Apps") { model.scheduleAppsRefresh() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Looking at your apps…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        EmptyStateView(systemImage: "square.grid.2x2", title: "No apps to show",
                       message: "Freespan didn't find any apps in Applications. Apps that come with macOS aren't listed.") {
            Button("Look Again") { model.scheduleAppsRefresh() }
        }
    }

    private func content(_ result: AppInventoryResult) -> some View {
        let apps = sorted(filtered(result.apps))
        let leftovers = filteredLeftovers(result.leftovers)
        let maxTotal = result.apps.map(\.totalBytes).max() ?? 1
        return GeometryReader { geo in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    listHeader(result)
                    Divider()
                    list(apps: apps, leftovers: leftovers, maxTotal: maxTotal)
                }
                .frame(width: min(470, max(300, geo.size.width * 0.5)))
                Divider()
                detail(for: result)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selectFirstIfNeeded(apps) }
        .onChange(of: apps.map(\.path)) { _, _ in selectFirstIfNeeded(apps) }
        .confirmationDialog(leftoverToRemove.map { "Move what \($0.ownerName) left behind to the Trash?" } ?? "",
                            isPresented: Binding(get: { leftoverToRemove != nil }, set: { if !$0 { leftoverToRemove = nil } }),
                            presenting: leftoverToRemove) { leftover in
            Button("Move \(Format.bytes(leftover.bytes)) to the Trash") {
                Task { await model.removeLeftover(leftover) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { leftover in
            Text("\(leftover.items.count) item\(leftover.items.count == 1 ? "" : "s"). \(leftover.ownerName) isn't installed anymore. Everything goes to the Trash, so you can put it back.")
        }
    }

    // MARK: List

    private func listHeader(_ result: AppInventoryResult) -> some View {
        let total = result.apps.reduce(0) { $0 + $1.totalBytes }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(result.apps.count) app\(result.apps.count == 1 ? "" : "s") · \(Format.bytes(total))")
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                if model.appsLoading { ProgressView().controlSize(.small).help("Updating…") }
            }
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear search")
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Picker("Sort by", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func list(apps: [InstalledApp], leftovers: [Leftover], maxTotal: Int64) -> some View {
        @Bindable var model = model
        return List(selection: $model.selectedAppPath) {
            Section {
                if apps.isEmpty {
                    Text(query.isEmpty ? "No apps found." : "No apps match “\(query)”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(apps) { app in
                    AppRow(app: app, maxTotal: maxTotal)
                        .tag(app.path as String?)
                        .contextMenu {
                            Button("Show in Finder") { model.revealInFinder(app.path) }
                            if !app.extras.isEmpty {
                                Button("Remove Extras · \(Format.bytes(app.extrasBytes))") {
                                    Task { await model.removeExtras(of: app) }
                                }
                                .disabled(model.isCleaning)
                            }
                        }
                }
            }
            if !leftovers.isEmpty {
                Section {
                    ForEach(leftovers) { leftover in
                        LeftoverRow(leftover: leftover) { leftoverToRemove = leftover }
                            .selectionDisabled()
                    }
                } header: {
                    Text("Leftovers from apps you removed")
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func detail(for result: AppInventoryResult) -> some View {
        if let path = model.selectedAppPath, let app = result.apps.first(where: { $0.path == path }) {
            AppDetailView(app: app) { uninstallTarget = app }.id(app.path)
        } else {
            EmptyStateView(systemImage: "square.grid.2x2", title: "Choose an app",
                           message: "See how much space it and its data use, clear its extras, or uninstall it.")
        }
    }

    // MARK: Filtering & sorting

    private func filtered(_ apps: [InstalledApp]) -> [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(q) }
    }

    private func filteredLeftovers(_ leftovers: [Leftover]) -> [Leftover] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = leftovers.filter { $0.bytes > 0 }
        guard !q.isEmpty else { return shown.sorted { $0.bytes > $1.bytes } }
        return shown.filter { $0.ownerName.localizedCaseInsensitiveContains(q) }.sorted { $0.bytes > $1.bytes }
    }

    /// Size: largest first. Last opened: longest unused first, unknown dates last.
    private func sorted(_ apps: [InstalledApp]) -> [InstalledApp] {
        switch sort {
        case .size:
            apps.sorted { $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.name < $1.name }
        case .lastOpened:
            apps.sorted { a, b in
                switch (a.lastOpened, b.lastOpened) {
                case let (x?, y?): x != y ? x < y : a.name < b.name
                case (.some, .none): true
                case (.none, .some): false
                case (.none, .none): a.name < b.name
                }
            }
        }
    }

    private func selectFirstIfNeeded(_ apps: [InstalledApp]) {
        if let selected = model.selectedAppPath, model.installedApp(at: selected) != nil { return }
        model.selectedAppPath = apps.first?.path
    }
}

// MARK: - Rows

/// Icon, name, "last opened …", a two-part bar (grey app, orange data) and the total.
private struct AppRow: View {
    let app: InstalledApp
    let maxTotal: Int64

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.path, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    SizeText(bytes: app.totalBytes, font: .callout.weight(.medium))
                }
                AppSizeBar(appBytes: app.appBytes, dataBytes: app.dataBytes, scale: maxTotal)
                if let opened = app.lastOpenedText {
                    Text(opened).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([app.name, "\(Format.bytes(app.totalBytes)) in total",
                             "app \(Format.bytes(app.appBytes)), data \(Format.bytes(app.dataBytes))",
                             app.lastOpenedText].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Grey for the app itself, orange for its data, scaled against the biggest app.
struct AppSizeBar: View {
    let appBytes: Int64
    let dataBytes: Int64
    let scale: Int64
    var height: CGFloat = 5

    static let appColor = Color(light: "#A9B1B5", dark: "#69737A")
    static let dataColor = Color(light: "#E08A2E", dark: "#F0A050")

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(scale), 1)
            let appWidth = geo.size.width * Double(max(appBytes, 0)) / total
            let dataWidth = geo.size.width * Double(max(dataBytes, 0)) / total
            HStack(spacing: 1) {
                Capsule().fill(Self.appColor).frame(width: max(appBytes > 0 ? 2 : 0, appWidth))
                if dataBytes > 0 {
                    Capsule().fill(Self.dataColor).frame(width: max(2, dataWidth))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct LeftoverRow: View {
    let leftover: Leftover
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppSizeBar.dataColor)
                .frame(width: 30, height: 30)
                .background(AppSizeBar.dataColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(leftover.ownerName).font(.body.weight(.medium)).lineLimit(1)
                Text("\(leftover.items.count) item\(leftover.items.count == 1 ? "" : "s") left behind")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SizeText(bytes: leftover.bytes, font: .callout).foregroundStyle(.secondary)
            Button("Remove…", action: remove)
                .controlSize(.small)
                .help("Move what \(leftover.ownerName) left behind to the Trash")
        }
        .padding(.vertical, 3)
        .help(leftover.items.map(\.path).joined(separator: "\n"))
    }
}

// MARK: - Previews

#Preview("Apps") {
    let model = AppModel.preview(mode: .easy, selection: .apps)
    return AppsView()
        .environment(model)
        .environment(\.appMode, .easy)
        .frame(width: 1080, height: 720)
}

#Preview("Apps · Advanced · dark") {
    let model = AppModel.preview(mode: .advanced, selection: .apps)
    model.selectedAppPath = "/Applications/Google Chrome.app"
    return AppsView()
        .environment(model)
        .frame(width: 1080, height: 720)
        .preferredColorScheme(.dark)
}

#Preview("Apps · loading") {
    let model = AppModel.preview(mode: .easy, selection: .apps)
    model.seedApps(nil, loading: true)
    return AppsView()
        .environment(model)
        .frame(width: 900, height: 600)
}

#Preview("Apps · empty") {
    let model = AppModel.preview(mode: .easy, selection: .apps)
    model.seedApps(AppInventoryResult(apps: [], leftovers: [], builtAt: SampleData.now))
    return AppsView()
        .environment(model)
        .frame(width: 900, height: 600)
}
