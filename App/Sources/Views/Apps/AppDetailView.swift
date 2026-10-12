import FreespanKit
import SwiftUI

/// One app: what it and its data use, Remove Extras, and Uninstall.
struct AppDetailView: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp
    /// Opens the uninstall sheet. The Apps screen owns it, so it stays up after the app leaves the list.
    var uninstall: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                breakdown
                actions
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.top)
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppIcon(path: app.path, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(2)
                Text(["\(Format.bytes(app.totalBytes)) in total", app.lastOpenedText].compactMap { $0 }.joined(separator: " · "))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let version = app.version {
                    Text("Version \(version)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            BreakdownRow(title: "The app itself", why: Format.displayPath(app.path, home: model.home), label: nil,
                         bytes: app.appBytes, color: AppSizeBar.appColor, path: app.path)
            ForEach(app.related.sorted { $0.size > $1.size }) { item in
                Divider().padding(.leading, 30)
                BreakdownRow(title: item.classification.title, why: item.easyWhy, label: item.label,
                             bytes: item.size, color: AppSizeBar.dataColor, path: item.path)
            }
            if app.related.isEmpty {
                Divider().padding(.leading, 30)
                Text("Freespan didn't find any data for this app outside the app itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                    .padding(.leading, 30)
            }
        }
        .card()
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.removeExtras(of: app) }
                } label: {
                    Text(app.extras.isEmpty ? "Remove Extras" : "Remove Extras · \(Format.bytes(app.extrasBytes))")
                        .monospacedDigit()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(app.extras.isEmpty || model.isCleaning)
                .help(app.extras.isEmpty
                      ? "Nothing to clear: this app has no caches or files that come back on their own."
                      : "Moves caches and files that come back on their own to the Trash. The app keeps working.")

                Button(role: .destructive) {
                    uninstall()
                } label: {
                    Text("Uninstall \(app.name)…")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
                .disabled(!app.canUninstall || model.isCleaning)
                .help(app.canUninstall ? "Moves the app and its data to the Trash" : (app.uninstallBlockedReason ?? "Freespan can't remove this app."))
            }
            if !app.canUninstall {
                Label(app.uninstallBlockedReason ?? "Freespan can't remove this app.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !app.extras.isEmpty {
                Text("Extras are caches and files that come back on their own. Everything goes to the Trash first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One line of the breakdown card: colored dot, friendly title, one-line why, label pill, size.
private struct BreakdownRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let why: String
    let label: SafetyLabel?
    let bytes: Int64
    let color: Color
    let path: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5).padding(.horizontal, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if let label { LabelPill(label: label, compact: true) }
            SizeText(bytes: bytes, font: .callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .help(Format.displayPath(path, home: model.home))
        .contextMenu {
            Button("Show in Finder") { model.revealInFinder(path) }
            Button("Quick Look") { model.quickLook(path) }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("App detail · Xcode") {
    let model = AppModel.preview(mode: .easy, selection: .apps)
    return AppDetailView(app: SampleApps.apps[0])
        .environment(model)
        .environment(\.appMode, .easy)
        .frame(width: 620, height: 640)
}

#Preview("App detail · can't uninstall") {
    let model = AppModel.preview(mode: .advanced, selection: .apps)
    let safari = InstalledApp(path: "/Applications/Safari.app", name: "Safari", bundleID: "com.apple.Safari", version: "26.4",
                              appBytes: 30_000_000, lastOpened: SampleData.now, isAppleApp: true, canUninstall: false,
                              uninstallBlockedReason: "Safari comes with macOS, so Freespan leaves it alone.", related: [])
    return AppDetailView(app: safari)
        .environment(model)
        .frame(width: 620, height: 420)
}
