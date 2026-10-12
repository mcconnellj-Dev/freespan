import FreespanKit
import SwiftUI

@main
struct FreespanApp: App {
    @State private var model = AppModel(services: .live())

    var body: some Scene {
        Window("Freespan", id: "main") {
            RootView()
                .environment(model)
        }
        // First launch: fit the screen it opens on. After that macOS restores the user's own frame.
        .defaultWindowPlacement { _, context in
            let visible = context.defaultDisplay.visibleRect
            let size = MainWindowSize.ideal(for: visible.size)
            return WindowPlacement(.center, size: size)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.phase.isBusy)
                Button("Stop Scan") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.phase.isBusy)
                if model.mode == .advanced {
                    Divider()
                    Picker("Scope", selection: Binding(get: { model.scope }, set: { scope in
                        guard scope != model.scope else { return }
                        model.scope = scope
                        model.rescan()
                    })) {
                        ForEach(ScanScope.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(model.phase.isBusy)
                }
            }
            CommandGroup(before: .sidebar) {
                Toggle("Easy Mode", isOn: modeBinding(.easy))
                    .keyboardShortcut("1")
                Toggle("Advanced Mode", isOn: modeBinding(.advanced))
                    .keyboardShortcut("2")
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? "Hide Ask Freespan" : "Show Ask Freespan") {
                    model.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    private func modeBinding(_ mode: AppMode) -> Binding<Bool> {
        Binding(get: { model.mode == mode }, set: { isOn in if isOn { model.mode = mode } })
    }
}

/// The main window's sizes. Minimums keep a 1280×800 screen comfortable with the sidebar showing.
enum MainWindowSize {
    static let minWidth: CGFloat = 900
    static let minHeight: CGFloat = 580
    static let maxDefault = CGSize(width: 1500, height: 960)

    /// About 88% of the visible screen, clamped between the minimum and a sensible maximum.
    static func ideal(for screen: CGSize) -> CGSize {
        CGSize(width: min(max(screen.width * 0.88, minWidth), maxDefault.width, screen.width),
               height: min(max(screen.height * 0.88, minHeight), maxDefault.height, screen.height))
    }
}
