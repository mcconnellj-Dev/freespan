import Foundation

/// How safe it is to remove something.
public enum SafetyLabel: String, Codable, Sendable, CaseIterable, Comparable {
    /// Regenerates on its own or is plainly disposable (caches, build products).
    case safe
    /// Probably removable, but the user should look first (old downloads, simulators).
    case review
    /// User data or something an app depends on. Shown, never suggested for removal.
    case keep
    /// System or protected path. Cannot be added to the cleanup basket.
    case protected

    public var displayName: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .keep: "Keep"
        case .protected: "Protected"
        }
    }

    private var order: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .keep: 2
        case .protected: 3
        }
    }

    public static func < (lhs: SafetyLabel, rhs: SafetyLabel) -> Bool { lhs.order < rhs.order }
}

public enum CategoryID: String, Codable, Sendable, CaseIterable, Identifiable {
    case developer
    case downloads
    case caches
    case backups
    case media
    case applications
    case largeOld
    case duplicates
    case system
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .developer: "Developer"
        case .downloads: "Downloads & installers"
        case .caches: "Caches & logs"
        case .backups: "iPhone backups"
        case .media: "Photos & media"
        case .applications: "Applications"
        case .largeOld: "Large & old"
        case .duplicates: "Duplicates"
        case .system: "System"
        case .other: "Everything else"
        }
    }

    /// SF Symbol name.
    public var systemImage: String {
        switch self {
        case .developer: "hammer"
        case .downloads: "arrow.down.circle"
        case .caches: "archivebox"
        case .backups: "iphone"
        case .media: "photo.on.rectangle"
        case .applications: "square.grid.2x2"
        case .largeOld: "clock.arrow.circlepath"
        case .duplicates: "doc.on.doc"
        case .system: "gearshape"
        case .other: "folder"
        }
    }

    /// Category color as a hex string, matching the project page palette.
    public var colorHex: String {
        switch self {
        case .developer: "#D9822B"
        case .downloads: "#3B6FD4"
        case .caches: "#8A5CC7"
        case .backups: "#C2557A"
        case .media: "#2E9E6A"
        case .applications: "#7E888C"
        case .largeOld: "#B08D2E"
        case .duplicates: "#4A9BB0"
        case .system: "#5C666A"
        case .other: "#B5BCBE"
        }
    }
}

/// Where a classification came from.
public enum ClassificationSource: String, Codable, Sendable {
    case rule
    case ai
    /// Identified locally without AI (app-ID lookup, Spotlight metadata, file type).
    case heuristic
}

public struct Classification: Sendable, Codable, Hashable {
    public let category: CategoryID
    public let label: SafetyLabel
    /// Short human name, e.g. "Xcode build products".
    public let title: String
    /// One or two plain-English sentences: what this is and what happens if removed.
    public let explanation: String
    /// True when the item comes back on its own after deletion.
    public let regenerates: Bool
    public let source: ClassificationSource
    /// Rule id when `source == .rule`.
    public let ruleID: String?

    public init(
        category: CategoryID,
        label: SafetyLabel,
        title: String,
        explanation: String,
        regenerates: Bool,
        source: ClassificationSource,
        ruleID: String? = nil
    ) {
        self.category = category
        self.label = label
        self.title = title
        self.explanation = explanation
        self.regenerates = regenerates
        self.source = source
        self.ruleID = ruleID
    }
}

/// A node from the scan paired with what we know about it. This is what the UI lists and the basket holds.
public struct Finding: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let size: Int64
    public let itemCount: Int
    public let modified: Date?
    public let accessed: Date?
    public let isDirectory: Bool
    public var classification: Classification

    public init(node: FileNode, classification: Classification) {
        self.path = node.path
        self.name = node.name
        self.size = node.size
        self.itemCount = node.itemCount
        self.modified = node.modified
        self.accessed = node.accessed
        self.isDirectory = node.kind != .file
        self.classification = classification
    }

    public init(
        path: String, name: String, size: Int64, itemCount: Int,
        modified: Date?, accessed: Date?, isDirectory: Bool, classification: Classification
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.itemCount = itemCount
        self.modified = modified
        self.accessed = accessed
        self.isDirectory = isDirectory
        self.classification = classification
    }

    public static func == (lhs: Finding, rhs: Finding) -> Bool { lhs.path == rhs.path }
    public func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

public struct CategorySummary: Sendable, Identifiable, Hashable {
    public var id: CategoryID { category }
    public let category: CategoryID
    public let totalBytes: Int64
    /// Bytes in this category labeled `.safe`.
    public let safeBytes: Int64
    public let findingCount: Int

    public init(category: CategoryID, totalBytes: Int64, safeBytes: Int64, findingCount: Int) {
        self.category = category
        self.totalBytes = totalBytes
        self.safeBytes = safeBytes
        self.findingCount = findingCount
    }
}
