import Foundation
import FreespanKit

/// What a finding is, in plain words, for Easy mode. Rule IDs and labels never reach the screen;
/// this maps them (or, failing that, the title and category) to a friendly kind.
enum EasyKind: Hashable, Identifiable {
    case deviceFiles
    case buildFiles
    case simulatorCaches
    case toolDownloads
    case toolCaches
    case projectPackages
    case appCaches
    case browserCaches
    case logs
    case mailCopies
    case trash
    case installers
    case oldDownloads
    case recentDownloads
    case phoneBackups
    case simulators
    case appArchives
    case apps
    case bigOldFiles
    case aiModels
    case offlineMedia
    case other(CategoryID)

    var id: String {
        if case .other(let category) = self { return "other-" + category.rawValue }
        return String(describing: self)
    }

    /// Plural name, used for groups and section headers.
    var title: String {
        switch self {
        case .deviceFiles: "Xcode device files"
        case .buildFiles: "Build files"
        case .simulatorCaches: "Simulator caches"
        case .toolDownloads: "Developer tool downloads"
        case .toolCaches: "Tool caches"
        case .projectPackages: "Project packages"
        case .appCaches: "App caches"
        case .browserCaches: "Browser caches"
        case .logs: "Logs and crash reports"
        case .mailCopies: "Mail attachment copies"
        case .trash: "Trash"
        case .installers: "Installers"
        case .oldDownloads: "Old downloads"
        case .recentDownloads: "Recent downloads"
        case .phoneBackups: "iPhone backups"
        case .simulators: "Simulators"
        case .appArchives: "App archives"
        case .apps: "Apps"
        case .bigOldFiles: "Big old files"
        case .aiModels: "AI models"
        case .offlineMedia: "Offline music and videos"
        case .other(let category):
            switch category {
            case .developer: "Developer files"
            case .downloads: "Downloads"
            case .caches: "Caches"
            case .backups: "iPhone backups"
            case .media: "Photos and videos"
            case .applications: "App data"
            case .largeOld: "Big old files"
            case .duplicates: "Duplicates"
            case .system, .other: "Other files"
            }
        }
    }

    /// One short line on why it's fine to remove (Safe) or what to think about (Check first).
    var explanation: String {
        switch self {
        case .deviceFiles: "Xcode downloads these again when you plug in an iPhone."
        case .buildFiles: "Rebuilt automatically the next time you build a project."
        case .simulatorCaches: "The Simulator rebuilds these when it starts."
        case .toolDownloads: "Your coding tools download these again when they need them."
        case .toolCaches: "Data command-line tools keep. Usually fine to remove, but some keep settings here."
        case .projectPackages: "Run npm install in a project to get them back."
        case .appCaches: "Apps rebuild these on their own when they need them."
        case .browserCaches: "Websites load these again as you browse."
        case .logs: "Apps start fresh logs as they run."
        case .mailCopies: "The originals stay safe in your email."
        case .trash: "Things you already deleted. Empty the Trash in Finder to get the space back."
        case .installers: "You can download these again anytime."
        case .oldDownloads: "Things you downloaded a while ago and haven't opened since."
        case .recentDownloads: "Downloaded in the last month, so you might still need them."
        case .phoneBackups: "Fine to remove if your iPhone backs up to iCloud."
        case .simulators: "Test devices for apps. Xcode can make new ones anytime."
        case .appArchives: "Saved builds of apps you shipped. Keep the ones you might need."
        case .apps: "Apps you haven't opened in a long time. You can reinstall them."
        case .bigOldFiles: "Big files you haven't opened in months."
        case .aiModels: "Models you downloaded. You can download them again later."
        case .offlineMedia: "Saved for offline listening or watching. The app can download them again."
        case .other: "Take a quick look before removing these."
        }
    }

    var systemImage: String {
        switch self {
        case .deviceFiles: "iphone.and.arrow.forward"
        case .buildFiles: "hammer"
        case .simulatorCaches, .simulators: "ipad.and.iphone"
        case .toolDownloads: "shippingbox"
        case .toolCaches: "terminal"
        case .projectPackages: "cube.box"
        case .appCaches: "archivebox"
        case .browserCaches: "safari"
        case .logs: "doc.text"
        case .mailCopies: "paperclip"
        case .trash: "trash"
        case .installers: "opticaldiscdrive"
        case .oldDownloads, .recentDownloads: "arrow.down.circle"
        case .phoneBackups: "iphone"
        case .appArchives: "archivebox"
        case .apps: "square.grid.2x2"
        case .bigOldFiles: "clock.arrow.circlepath"
        case .aiModels: "cpu"
        case .offlineMedia: "music.note"
        case .other(let category): category.systemImage
        }
    }

    /// True when the item's own name says more than the rule title ("Figma-Installer.dmg" vs "Installer").
    var prefersItemName: Bool {
        switch self {
        case .installers, .oldDownloads, .recentDownloads, .apps, .bigOldFiles, .appArchives, .other: true
        default: false
        }
    }

    static func of(_ finding: Finding) -> EasyKind {
        let c = finding.classification
        if let ruleID = c.ruleID, let kind = byRuleID[ruleID] { return kind }
        return byTitle(c.title.lowercased(), category: c.category)
    }

    private static let byRuleID: [String: EasyKind] = [
        "xcode-device-support": .deviceFiles,
        "xcode-derived-data": .buildFiles, "xcode-previews": .buildFiles, "swift-build-folder": .buildFiles,
        "simulator-caches": .simulatorCaches,
        "xcode-documentation-cache": .toolDownloads, "swiftpm-cache": .toolDownloads, "cocoapods-cache": .toolDownloads,
        "homebrew-cache": .toolDownloads, "yarn-cache": .toolDownloads, "pnpm-store": .toolDownloads,
        "npm-cache": .toolDownloads, "bun-cache": .toolDownloads, "pip-cache": .toolDownloads, "uv-cache": .toolDownloads,
        "gradle-cache": .toolDownloads, "cargo-registry": .toolDownloads, "browser-automation-cache": .toolDownloads,
        "jetbrains-cache": .toolDownloads, "codex-runtimes": .toolDownloads, "gem-cache": .toolDownloads,
        "pre-commit-cache": .toolDownloads, "node-gyp-cache": .toolDownloads, "go-build-cache": .toolDownloads,
        "bazel-cache": .toolDownloads, "prisma-engines": .toolDownloads, "electron-downloads": .toolDownloads,
        "typescript-cache": .toolDownloads,
        // Only Safe, named tool caches count as downloads; any other ~/.cache folder needs a look first.
        "tool-cache": .toolCaches,
        "node-modules": .projectPackages,
        "app-cache": .appCaches, "sandboxed-app-cache": .appCaches, "electron-app-cache": .appCaches, "editor-cache": .appCaches,
        "browser-cache": .browserCaches, "google-updater-cache": .browserCaches,
        "user-logs": .logs,
        "mail-downloads": .mailCopies,
        "trash": .trash,
        "download-installer": .installers,
        "download-old": .oldDownloads,
        "download-recent": .recentDownloads,
        "iphone-backup": .phoneBackups,
        "simulator-device": .simulators, "android-system-images": .simulators,
        "xcode-archives": .appArchives,
        "application": .apps,
        "large-old-file": .bigOldFiles,
        "ollama-models": .aiModels, "huggingface-cache": .aiModels, "chrome-ai-model": .aiModels,
        "spotify-offline": .offlineMedia,
    ]

    /// Fallback for findings without a known rule ID (assistant and local labels, older rule sets, previews).
    private static func byTitle(_ title: String, category: CategoryID) -> EasyKind {
        func has(_ words: String...) -> Bool { words.contains { title.contains($0) } }
        switch category {
        case .developer:
            if has("debug symbols", "device support") { return .deviceFiles }
            if has("node_modules") { return .projectPackages }
            if has("simulator cache") { return .simulatorCaches }
            if has("simulator", "emulator") { return .simulators }
            if has("build") { return .buildFiles }
            if has("npm", "yarn", "pnpm", "homebrew", "cocoapods", "swift package", "pip", "gradle", "cargo") { return .toolDownloads }
        case .caches:
            if has("browser") { return .browserCaches }
            if has("log") { return .logs }
            if has("homebrew", "npm") { return .toolDownloads }
            if has("cache") { return .appCaches }
        case .downloads:
            if has("installer", "disk image", "xip", "archive") { return .installers }
            if has("recent") { return .recentDownloads }
            return .oldDownloads
        case .backups: return .phoneBackups
        case .applications: return has("data") ? .other(.applications) : .apps
        case .largeOld: return .bigOldFiles
        default: break
        }
        return .other(category)
    }
}

/// Findings of one kind, largest first.
struct EasyGroup: Identifiable, Hashable {
    let kind: EasyKind
    let items: [Finding]
    let size: Int64

    var id: String { kind.id }

    /// Groups findings by kind, largest group first.
    static func make(_ findings: [Finding]) -> [EasyGroup] {
        Dictionary(grouping: findings, by: EasyKind.of)
            .map { kind, items in
                EasyGroup(kind: kind, items: items.sorted { $0.size > $1.size }, size: items.reduce(0) { $0 + $1.size })
            }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.kind.title < $1.kind.title }
    }
}

extension Finding {
    var easyKind: EasyKind { EasyKind.of(self) }

    /// The name shown first in Easy mode: the item's own name when that's what people recognize
    /// (downloads, apps, big files), otherwise the friendly title.
    var easyTitle: String {
        let kind = easyKind
        if classification.source != .rule { return classification.title }
        if classification.ruleID == "simulator-device", let device = SimulatorNames.name(forDevice: path) {
            return "\(device) simulator"
        }
        if kind == .phoneBackups, let date = modified {
            return "iPhone backup from \(date.formatted(.dateTime.month(.wide).year()))"
        }
        guard kind.prefersItemName else { return classification.title }
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// One line on why this needs a look.
    var easyWhy: String {
        let text = classification.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? easyKind.explanation : text
    }
}

/// Reads a simulator's friendly name ("iPhone 17 Pro · iOS 26.4") from its device.plist. Local and cached.
enum SimulatorNames {
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func name(forDevice path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[path] { return cached }
        let plist = URL(fileURLWithPath: path).appendingPathComponent("device.plist")
        var result: String?
        if let data = try? Data(contentsOf: plist),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let name = dict["name"] as? String {
            // runtime looks like "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
            if let runtime = (dict["runtime"] as? String)?.split(separator: ".").last {
                let parts = runtime.split(separator: "-")
                if let os = parts.first, parts.count > 1 {
                    result = "\(name) · \(os) \(parts.dropFirst().joined(separator: "."))"
                } else {
                    result = name
                }
            } else {
                result = name
            }
        }
        cache[path] = result
        return result
    }
}
