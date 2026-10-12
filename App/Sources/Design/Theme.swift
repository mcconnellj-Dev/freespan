import AppKit
import FreespanKit
import SwiftUI

// MARK: - Color helpers

extension NSColor {
    /// `#RRGGBB` or `RRGGBB`. Falls back to gray on malformed input.
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self.init(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            return
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }

    /// A color that follows the effective appearance (light / dark).
    init(light: String, dark: String) {
        let lightColor = NSColor(hex: light)
        let darkColor = NSColor(hex: dark)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

/// Design tokens, mirroring the approved mockup palette.
enum Theme {
    static let accent = Color.accentColor
    static let accentSoft = Color(light: "#D5EAE8", dark: "#163536")
    static let warning = Color(light: "#B23B3B", dark: "#F08080")
    static let freeSpace = Color(light: "#E3E6E1", dark: "#2B3134")
    static let hairline = Color(light: "#D8DCD7", dark: "#2C3337")
    static let surface = Color(light: "#FFFFFF", dark: "#1F2427")

    static let cornerRadius: CGFloat = 12
}

// MARK: - Categories & labels

extension CategoryID {
    var color: Color {
        switch self {
        case .applications: Color(light: "#7E888C", dark: "#8D979B")
        case .other: Color(light: "#B5BCBE", dark: "#59626A")
        default: Color(hex: colorHex)
        }
    }

    /// Shorter name for tight places like the sidebar.
    var shortName: String {
        switch self {
        case .downloads: "Downloads"
        case .caches: "Caches"
        default: displayName
        }
    }
}

extension SafetyLabel {
    var foreground: Color {
        switch self {
        case .safe: Color(light: "#2E8B57", dark: "#6FD39A")
        case .review: Color(light: "#A86A00", dark: "#E6B04D")
        case .keep: Color(light: "#B23B3B", dark: "#F08080")
        case .protected: .secondary
        }
    }

    var background: Color {
        switch self {
        case .safe: Color(light: "#DDF0E3", dark: "#183526")
        case .review: Color(light: "#F7EACB", dark: "#3A2E14")
        case .keep: Color(light: "#F6DCDC", dark: "#3D1C1C")
        case .protected: Color(light: "#E9EBE7", dark: "#262C2F")
        }
    }

    var systemImage: String? {
        self == .protected ? "lock.fill" : nil
    }

    var canBeCleaned: Bool { self == .safe || self == .review }
}

extension SafetyLabel {
    /// Plain words in Easy mode ("Safe to remove", "Check first"); the short label names in Advanced.
    func title(for mode: AppMode) -> String {
        guard mode == .easy else { return displayName }
        switch self {
        case .safe: return "Safe to remove"
        case .review: return "Check first"
        case .keep, .protected: return "Keep"
        }
    }
}

extension EnvironmentValues {
    /// The app's mode, injected at the root so shared components (LabelPill) can pick their wording.
    @Entry var appMode: AppMode = .advanced
}

extension ClaudeModel {
    var tint: Color {
        switch self {
        case .haiku: CategoryID.media.color
        case .sonnet: CategoryID.downloads.color
        case .opus: CategoryID.caches.color
        }
    }
}

extension AssistantKind {
    /// Compact name for status text and fallbacks: "On-device", "Claude", "Off".
    var shortName: String {
        switch self {
        case .onDevice: "On-device"
        case .claudeSubscription, .claudeAPI: "Claude"
        case .off: "Assistant"
        }
    }

    var isClaude: Bool { self == .claudeSubscription || self == .claudeAPI }

    var tint: Color {
        switch self {
        case .onDevice: .accentColor
        case .claudeSubscription, .claudeAPI: CategoryID.developer.color
        case .off: .secondary
        }
    }

    /// One line on what leaves the Mac.
    var privacyNote: String {
        switch self {
        case .onDevice: "Nothing leaves your Mac."
        case .claudeSubscription, .claudeAPI: "Sends file names, sizes and dates — never file contents."
        case .off: "Freespan still sorts and names everything with its built-in rules."
        }
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func relative(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "—" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 ? 3 : 2)))
    }

    /// Replaces the home directory with `~` for display.
    static func displayPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

extension Finding {
    /// Best guess at "last used": access date, then modification date.
    var lastUsed: Date? { accessed ?? modified }
    var lastUsedSortKey: Date { lastUsed ?? .distantPast }
    var label: SafetyLabel { classification.label }
    var category: CategoryID { classification.category }
}
