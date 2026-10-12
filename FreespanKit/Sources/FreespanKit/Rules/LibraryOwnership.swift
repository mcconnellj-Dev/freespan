import Foundation

/// Who owns what inside ~/Library: macOS itself or a third-party app. Shared by `RuleEngine` (which items may be
/// handed on as "unknown") and `ItemIdentifier` (naming). All names are compared lowercased.
enum LibraryOwnership {
    /// ~/Library children where apps keep per-app folders (`<root>/<app folder>/...`).
    static let appRoots: Set<String> = [
        "application support", "containers", "group containers", "caches", "httpstorages", "webkit",
        "saved application state", "logs",
    ]

    /// Plain-named folders that belong to macOS, directly in ~/Library or inside one of the app roots.
    static let appleFolders: Set<String> = [
        // Directly in ~/Library
        "metadata", "biome", "duetexpertcenter", "trial", "intelligenceplatform", "assistant", "suggestions",
        "personalizationportrait", "daemon containers", "sharing", "statuskit", "weather", "identityservices",
        "homekit", "accounts", "calendars", "reminders", "messages", "mail", "safari", "cookies", "frontboard",
        "corefollowup", "keychains", "autosave information", "preferences", "keyboard services", "spelling",
        "languagemodeling", "passes", "photos", "translation", "news", "stocks", "shortcuts",
        "contacts", "finance", "appleintelligenceplatform", "studentkit", "usernotifications", "sounds",
        "colorpickers", "colors", "compositions", "favorites", "fontcollections", "fonts", "input methods",
        "internet plug-ins", "keyboard layouts", "launchagents", "printers", "pdf services", "screen savers",
        "services", "voices", "audio", "componentregistry", "dictionaries", "groups", "ubiquitous keychain",
        "managed preferences", "coredata", "accessibility",
        // Inside Application Support and friends
        "addressbook", "callhistorydb", "callhistorytransactions", "clouddocs", "fileprovider", "knowledge",
        "icloud", "dock", "crashreporter", "diskimages", "syncservices", "animoji", "coreparsec",
        "familycircle", "networkserviceproxy", "contextstoreagent", "siri", "cloudkit", "geoservices",
        "homeenergyd", "mobilesync", "photosearch", "sharedfilelists", "spotlight", "diagnosticreports",
    ]

    /// True for `com.apple.*`, `group.com.apple.*` (optionally team-prefixed) and the plain macOS folder names.
    static func isAppleOwned(_ folder: String) -> Bool {
        let name = folder.lowercased()
        if appleFolders.contains(name) { return true }
        let core = BundleID.stripPrefixes(name).name
        return core.hasPrefix("com.apple.") || core == "com.apple"
    }

    /// For lowercased path components below home (`rel[0] == "library"`): true when the item belongs to a
    /// third-party app or tool, i.e. a non-Apple folder in one of the app roots, or a vendor folder in ~/Library
    /// that Freespan's known-locations table names (Android SDK, Unity, cloud-storage folders, ...).
    static func isThirdParty(rel: [String], segments: [String], homeSegments: [String]) -> Bool {
        guard rel.count >= 2, rel[0] == "library" else { return false }
        if rel.count >= 3, appRoots.contains(rel[1]) { return !isAppleOwned(rel[2]) }
        if isAppleOwned(rel[1]) { return false }
        return KnownLocationCatalog.bundled.location(for: segments, home: homeSegments) != nil
    }
}
