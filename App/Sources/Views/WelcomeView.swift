import FreespanKit
import SwiftUI

/// First launch (no cached scan): explains Freespan, asks for Full Disk Access once, and lets the user start.
/// Nothing is scanned until the user clicks Start Scan.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("Welcome to Freespan")
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.4)
                    Text("See what's taking space, understand it in plain English, and clear it safely.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    pillar("chart.pie", "See", "An interactive map of every folder, sized accurately.")
                    pillar("square.grid.2x2", "Organize", model.mode == .easy
                           ? "Sorted into what's safe to remove and what to check first."
                           : "Grouped by what things are, each marked Safe, Review or Keep.")
                    pillar("basket", "Clean", "Pick items, see the total, move them to the Trash. Undo anytime.")
                }

                FullDiskAccessStep()

                VStack(alignment: .leading, spacing: 12) {
                    if model.mode == .advanced {
                        Picker("Scan", selection: $model.scope) {
                            ForEach(ScanScope.allCases) { scope in
                                Text(scope.title).tag(scope)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                    }

                    HStack(spacing: 14) {
                        Button {
                            model.rescan()
                        } label: {
                            Text("Start Scan").frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)

                        Text(model.hasFullDiskAccess
                             ? "Freespan only reads names, sizes and dates. Nothing is changed."
                             : "Without Full Disk Access, protected folders like Desktop, Documents and Downloads are skipped.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
    }

    private func pillar(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FullDiskAccessStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Label("Full Disk Access", systemImage: "lock.shield")
                    .font(.headline)
                Spacer()
                status
            }
            Text("macOS asks separately for Desktop, Documents, Downloads, Photos and data from other apps. Granting Full Disk Access once lets Freespan measure everything, including iPhone backups and Mail, without a stream of prompts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.hasFullDiskAccess {
                HStack(spacing: 12) {
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                    Text("Turn on Freespan, then come back. If it still says Not granted, quit and reopen Freespan.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card(tint: model.hasFullDiskAccess ? nil : Theme.accentSoft)
        .animation(.snappy, value: model.hasFullDiskAccess)
    }

    @ViewBuilder private var status: some View {
        if model.hasFullDiskAccess {
            Label("Access granted", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(SafetyLabel.safe.foreground)
        } else {
            Label("Not granted", systemImage: "circle.dashed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Welcome") {
    WelcomeView()
        .environment(AppModel(services: .sample(), defaults: UserDefaults(suiteName: "FreespanPreview")!))
        .frame(width: 820, height: 760)
}

#Preview("Welcome · dark") {
    WelcomeView()
        .environment(AppModel(services: .sample(), defaults: UserDefaults(suiteName: "FreespanPreview")!))
        .frame(width: 820, height: 760)
        .preferredColorScheme(.dark)
}
