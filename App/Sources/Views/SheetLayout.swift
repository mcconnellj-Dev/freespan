import AppKit
import FreespanKit
import SwiftUI

// MARK: - Sheet frame

enum SheetMetrics {
    /// Every confirmation sheet has the same width.
    static let width: CGFloat = 540

    /// Never taller than 640 pt or the screen's usable height minus some room, so the buttons stay on screen.
    @MainActor static var maxHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 800
        return max(320, min(640, visible - 120))
    }
}

/// A fixed-width sheet whose header and button bar are pinned; only the middle scrolls, and only once the
/// whole sheet would be taller than `SheetMetrics.maxHeight`. Short content hugs its height.
struct PinnedSheet<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        let listMax = max(120, SheetMetrics.maxHeight - headerHeight - footerHeight - 2)
        VStack(spacing: 0) {
            header
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            Divider()
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: listMax)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: SheetMetrics.width)
    }
}

// MARK: - App chips

/// Up to `limit` app icons with names as wrapping chips, then "+N more" (the rest in its tooltip).
struct AppChips: View {
    let apps: [BlockingApp]
    var limit = 6

    var body: some View {
        let shown = apps.prefix(limit)
        let rest = apps.dropFirst(limit)
        FlowLayout(spacing: 6) {
            ForEach(shown) { app in
                HStack(spacing: 5) {
                    Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                    Text(app.name).font(.callout).lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.background.opacity(0.7), in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
            }
            if !rest.isEmpty {
                Text("+\(rest.count) more")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .help(rest.map(\.name).joined(separator: ", "))
            }
        }
    }
}

// MARK: - In use

/// What the in-use check found, compactly: one row of apps the person can quit ("Quit these apps to clean up
/// 1.2 GB more", app chips, Quit Apps with its confirmation built in) and one quiet line for whatever only macOS
/// background tasks hold. Background process names never appear, except in Advanced mode's tooltip.
/// Used by Clean Up Safely and the Move to Trash confirmation.
struct InUseSection: View {
    @Environment(AppModel.self) private var model
    let summary: InUseSummary
    /// Re-runs the in-use check after apps quit.
    let recheck: () async -> Void

    @State private var confirming = false
    @State private var quitting = false
    @State private var refused: [BlockingApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !summary.apps.isEmpty { appsRow }
            if summary.backgroundBytes > 0 { backgroundLine }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: confirming)
        .animation(.snappy, value: quitting)
    }

    private var appsRow: some View {
        let apps = summary.apps
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Quit \(apps.count == 1 ? "this app" : "these apps") to clean up \(Format.bytes(summary.appBytes)) more",
                      systemImage: "macwindow.on.rectangle")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: 8)
                if !confirming && !quitting {
                    Button(apps.count == 1 ? "Quit \(apps[0].name)" : "Quit Apps") { confirming = true }
                        .controlSize(.small)
                }
            }
            AppChips(apps: apps)
            if quitting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for apps to quit…").font(.caption).foregroundStyle(.secondary)
                }
            } else if confirming {
                HStack(spacing: 8) {
                    Text("Quit \(BlockingApp.list(apps.map(\.name)))? \(apps.count == 1 ? "It" : "They") may ask you to save first.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Cancel") { confirming = false }
                    Button(apps.count == 1 ? "Quit" : "Quit \(apps.count) Apps") { Task { await quit(apps) } }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            if !refused.isEmpty && !quitting {
                HStack(spacing: 8) {
                    Text("\(BlockingApp.list(refused.map(\.name))) didn't quit. It may be waiting for you to save something.")
                        .font(.caption)
                        .foregroundStyle(SafetyLabel.review.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Check Again") { Task { await recheck() } }.controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var backgroundLine: some View {
        Label("\(Format.bytes(summary.backgroundBytes)) is busy with macOS background tasks right now — Freespan will skip it.",
              systemImage: "gearshape.2")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .help(model.mode == .advanced && !summary.backgroundNames.isEmpty
                  ? "In use by " + summary.backgroundNames.joined(separator: ", ") : "")
    }

    private func quit(_ apps: [BlockingApp]) async {
        confirming = false
        quitting = true
        let stillRunning = await model.quitApps(apps)
        refused = stillRunning.filter(model.canQuit)
        await recheck()
        quitting = false
    }
}

#Preview("In use · many apps") {
    let model = AppModel.easyPreview(inUse: .manyApps)
    let apps = ["Google Chrome", "Safari", "ChatGPT", "Claude", "Slack", "Visual Studio Code", "Figma", "Spotify", "Xcode"]
        .map { BlockingApp(bundleID: "preview." + $0, name: $0, pids: [1]) }
    return InUseSection(summary: InUseSummary(apps: apps, appBytes: 8_620_000_000, backgroundBytes: 1_200_000_000,
                                              backgroundNames: ["akd", "cloudd"], partialCount: 1),
                        recheck: {})
        .padding(20)
        .frame(width: SheetMetrics.width)
        .environment(model)
}
