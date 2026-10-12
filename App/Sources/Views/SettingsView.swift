import FreespanKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Assistant", systemImage: "sparkles") { AssistantSettings() }
        }
        .frame(width: 540)
        .environment(\.appMode, model.mode)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var choosingFolders = false

    /// "Hide items smaller than" choices, in bytes (0 = Off).
    private static let thresholds: [Int64] = [0, 10_000_000, 100_000_000, 1_000_000_000]

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(model.mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                Text("Switch anytime with ⌘1 and ⌘2.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Toggle(isOn: $model.showKeptItems) {
                    Text("Show items Freespan keeps")
                    Text("Things your Mac or your apps need. They're never suggested for removal.")
                }
                LabeledContent {
                    Button("Show All Again") { model.undismissAll() }
                        .disabled(model.dismissedPaths.isEmpty)
                } label: {
                    Text("Hidden items (\(Format.count(model.dismissedPaths.count)))")
                    Text("Things you chose to keep. They're hidden from your lists.")
                }
            }

            Section {
                LabeledContent {
                    if model.hasFullDiskAccess {
                        Label("On", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(SafetyLabel.safe.foreground)
                    } else {
                        Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                    }
                } label: {
                    Text("Full Disk Access")
                    Text(model.hasFullDiskAccess
                         ? "Freespan can measure every folder."
                         : "Needed to measure iPhone backups, Mail, Safari and the Trash.")
                }
            }

            if model.mode == .advanced {
                Section("Scanning") {
                    Picker("Scan", selection: $model.scope) {
                        ForEach(ScanScope.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(model.phase.isBusy)
                    Picker(selection: $model.minimumItemSize) {
                        ForEach(Self.thresholds, id: \.self) { bytes in
                            Text(bytes == 0 ? "Off" : Format.bytes(bytes)).tag(bytes)
                        }
                    } label: {
                        Text("Hide items smaller than")
                        Text("Applies to group tables.")
                    }
                }
                excludedFoldersSection
            }
        }
        .formStyle(.grouped)
        .frame(height: model.mode == .advanced ? 640 : 400)
        .animation(.snappy, value: model.mode)
        .onAppear { model.recheckFullDiskAccess() }
        .fileImporter(isPresented: $choosingFolders, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let added = urls.map(\.path).filter { !model.excludedFolders.contains($0) }
            model.excludedFolders.append(contentsOf: added)
        }
    }

    private var excludedFoldersSection: some View {
        Section {
            if model.excludedFolders.isEmpty {
                Text("No folders are skipped.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.excludedFolders, id: \.self) { path in
                    HStack {
                        Label(Format.displayPath(path, home: model.home), systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            model.excludedFolders.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Stop skipping this folder")
                    }
                }
            }
            HStack {
                Button {
                    choosingFolders = true
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                Spacer()
            }
        } header: {
            Text("Skipped Folders")
        } footer: {
            Text("Takes effect on the next scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AssistantSettings: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var costs: [ClaudeModel: Double] = [:]
    @State private var showMoreOptions = false

    /// Easy mode shows On-device and Off; Claude options appear under "More options" (or when one is chosen).
    private var visibleKinds: [AssistantKind] {
        guard model.mode == .easy, !showMoreOptions, !model.assistantKind.isClaude else { return AssistantKind.allCases }
        return AssistantKind.allCases.filter { !$0.isClaude }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Assistant", selection: $model.assistantKind) {
                    ForEach(visibleKinds) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                if model.mode == .easy {
                    DisclosureGroup("More options", isExpanded: $showMoreOptions) {
                        Text("Claude can answer harder questions using your Claude subscription or an API key. It sees file names, sizes and dates — never file contents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                availabilityRow
                if model.assistantKind == .claudeSubscription {
                    note("Uses your Claude plan through Claude Code — personal use.", systemImage: "person.crop.circle")
                }
                note(model.assistantKind.privacyNote, systemImage: model.assistantKind == .off ? "checkmark.shield" : "lock.shield")
            } footer: {
                Text("The assistant explains unfamiliar folders and answers questions. Only Freespan's built-in rules can mark something Safe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.assistantKind == .claudeAPI {
                apiKeySection
                spendSection
            }
        }
        .formStyle(.grouped)
        .frame(height: model.assistantKind == .claudeAPI ? 600 : 360)
        .animation(.snappy, value: model.assistantKind)
        .animation(.snappy, value: showMoreOptions)
        .onAppear {
            if model.assistantKind.isClaude { showMoreOptions = true }
            refreshCosts()
            model.refreshAssistantAvailability()
        }
    }

    @ViewBuilder private var availabilityRow: some View {
        if model.assistantKind != .off {
            LabeledContent("Status") {
                switch model.assistantAvailability {
                case .available?:
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(SafetyLabel.safe.foreground)
                case .unavailable(let reason)?:
                    Label {
                        Text(reason).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .foregroundStyle(SafetyLabel.review.foreground)
                case nil:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var apiKeySection: some View {
        Section {
            if model.hasAPIKey {
                LabeledContent("Anthropic API key") {
                    HStack(spacing: 8) {
                        Label("Saved in Keychain", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(SafetyLabel.safe.foreground)
                        Button("Remove", role: .destructive) {
                            perform { try model.removeAPIKey() } success: { "Key removed." }
                        }
                    }
                }
            } else {
                SecureField("Anthropic API key", text: $keyDraft, prompt: Text("sk-ant-…"))
                    .onSubmit(save)
                HStack {
                    Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.caption)
                    Spacer()
                    Button("Save", action: save)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Theme.warning : .secondary)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Usage is billed to your API account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var spendSection: some View {
        Section {
            ForEach(ClaudeModel.allCases, id: \.self) { claudeModel in
                LabeledContent {
                    Text(Format.usd(costs[claudeModel] ?? 0)).monospacedDigit()
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(claudeModel.tint).frame(width: 7, height: 7)
                        Text(claudeModel.displayName)
                        Text(role(claudeModel)).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Total") {
                Text(Format.usd(costs.values.reduce(0, +))).monospacedDigit().fontWeight(.semibold)
            }
            HStack {
                Spacer()
                Button("Reset Usage") {
                    model.services.resetUsage()
                    refreshCosts()
                }
            }
        } header: {
            Text("Estimated Spend")
        }
    }

    private func role(_ model: ClaudeModel) -> String {
        switch model {
        case .haiku: "labels"
        case .sonnet: "questions"
        case .opus: "plans"
        }
    }

    private func refreshCosts() {
        costs = Dictionary(uniqueKeysWithValues: ClaudeModel.allCases.map { ($0, model.services.cost($0)) })
    }

    private func save() {
        let key = keyDraft
        perform { try model.saveAPIKey(key) } success: {
            keyDraft = ""
            return "Saved in Keychain."
        }
    }

    private func perform(_ action: () throws -> Void, success: () -> String) {
        do {
            try action()
            status = success()
            statusIsError = false
        } catch {
            status = AppModel.friendly(error)
            statusIsError = true
        }
    }
}

#Preview("Settings · Easy") {
    SettingsView()
        .environment(AppModel.preview(mode: .easy))
}

#Preview("Settings · Advanced") {
    SettingsView()
        .environment(AppModel.preview(mode: .advanced))
}

#Preview("Settings · Assistant · Easy") {
    AssistantSettings()
        .environment(AppModel.preview(mode: .easy))
}

#Preview("Settings · Assistant · Advanced") {
    AssistantSettings()
        .environment(AppModel.preview(mode: .advanced))
}

#Preview("Settings · Claude API") {
    AssistantSettings()
        .environment(AppModel.preview(assistant: .claudeAPI, hasAPIKey: false))
}
