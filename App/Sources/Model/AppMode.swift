import Foundation

/// Easy is for anyone (a 13-year-old should manage); Advanced shows everything. See tasks/ux-modes.md.
enum AppMode: String, CaseIterable, Identifiable, Sendable {
    case easy
    case advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .easy: "Easy"
        case .advanced: "Advanced"
        }
    }

    var summary: String {
        switch self {
        case .easy: "Shows only what you can safely clean up, in plain words."
        case .advanced: "Shows every group, label and option, including whole-disk scans."
        }
    }
}

/// UserDefaults keys shared by settings and views.
enum SettingsKey {
    static let mode = "appMode"                       // AppMode raw value, default .easy
    static let showKeptItems = "showKeptItems"        // Bool, default false
    static let minimumItemSize = "minimumItemSize"    // Int64 bytes, default 10_000_000 (Advanced tables)
    static let dismissedPaths = "dismissedPaths"      // [String] items the user chose to Keep in Easy mode
    static let excludedFolders = "excludedFolders"    // [String] absolute paths skipped by the next scan (Advanced)
}

extension AppMode {
    /// The screen a mode opens on.
    var homeItem: SidebarItem {
        switch self {
        case .easy: .clean
        case .advanced: .overview
        }
    }
}
