import FreespanKit
import SwiftUI

/// Shown in the detail column before there's any scan to display: Welcome, live counter, or failure.
struct ScanStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .scanning(let progress):
            ScanningView(progress: progress, scope: model.effectiveScope, home: model.home)
        case .analyzing:
            ScanningView(progress: nil, scope: model.effectiveScope, home: model.home, analyzing: true)
        case .failed(let message):
            EmptyStateView(systemImage: "exclamationmark.magnifyingglass", title: "The scan didn't finish", message: message) {
                HStack {
                    Button("Try Again") { model.rescan() }
                        .buttonStyle(.borderedProminent)
                    if model.effectiveScope == .wholeDisk {
                        Button("Scan Home Folder") { model.scope = .home; model.rescan() }
                    }
                }
            }
        case .loadingCache:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Opening your last scan…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle:
            WelcomeView()
        }
    }
}

struct ScanningView: View {
    let progress: ScanProgress?
    let scope: ScanScope
    let home: String
    var analyzing = false

    var body: some View {
        VStack(spacing: 22) {
            ScanningRing()
                .frame(width: 120, height: 120)
            VStack(spacing: 6) {
                Text(analyzing ? "Sorting into groups" : "Scanning your \(scope == .home ? "home folder" : "disk")")
                    .font(.title3.weight(.semibold))
                Text(Format.count(progress?.filesSeen ?? 0) + " files")
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: progress?.filesSeen)
                if let progress {
                    Text(Format.bytes(progress.bytesSeen) + " measured")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(progress.map { Format.displayPath($0.currentPath, home: home) } ?? " ")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
            Text("Your files stay on this Mac. Nothing is changed while scanning.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A quiet rotating arc, echoing the ring chart.
private struct ScanningRing: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.accentColor.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360))
                Circle()
                    .trim(from: 0, to: 0.12)
                    .stroke(CategoryID.developer.color.opacity(0.8), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .padding(18)
                    .rotationEffect(.degrees(-t.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360))
            }
        }
    }
}

#Preview("Scanning") {
    let model = AppModel(services: .sample(), defaults: UserDefaults(suiteName: "FreespanPreview")!)
    model.seedScanning(ScanProgress(filesSeen: 1_284_311, bytesSeen: 182_000_000_000,
                                    currentPath: "/Users/alex/Library/Developer/CoreSimulator/Devices/7A1C/data/Containers"))
    return ScanStatusView().environment(model).frame(width: 700, height: 520)
}

#Preview("Scan failed") {
    let model = AppModel(services: .sample(), defaults: UserDefaults(suiteName: "FreespanPreview")!)
    model.seedFailure("Freespan couldn't finish scanning. The operation couldn't be completed.")
    return ScanStatusView().environment(model).frame(width: 700, height: 520)
}
