import AppKit
import FreespanKit
import SwiftUI
import UniformTypeIdentifiers

/// An app's real Finder icon, or the generic app icon when the bundle isn't there (previews, just uninstalled).
struct AppIcon: View {
    let path: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: ItemIconCache.icon(for: path) ?? AppIcon.generic)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @MainActor static let generic = NSWorkspace.shared.icon(for: .applicationBundle)
}

extension InstalledApp {
    /// "last opened 3 weeks ago", or nil when Spotlight doesn't know.
    var lastOpenedText: String? {
        guard let lastOpened else { return nil }
        if Calendar.current.isDateInToday(lastOpened) { return "last opened today" }
        return "last opened " + lastOpened.formatted(.relative(presentation: .named))
    }
}
