import Foundation
import FreespanKit

enum ScanScope: String, CaseIterable, Identifiable, Sendable {
    case home
    case wholeDisk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home folder"
        case .wholeDisk: "Whole disk"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .wholeDisk: "internaldrive"
        }
    }

    func rootURL(home: String) -> URL {
        switch self {
        case .home: URL(fileURLWithPath: home, isDirectory: true)
        case .wholeDisk: URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        }
    }
}

enum SidebarItem: Hashable {
    /// Easy mode's start screen ("Clean").
    case clean
    /// Easy mode's list of items that need a human decision (reached from Clean › Worth a look › See all).
    case checkFirst
    /// Installed apps, their data, and leftovers (both modes).
    case apps
    /// Advanced mode's start screen.
    case overview
    case diskMap
    case group(CategoryID)
    case basket
    case history
}

enum ScanPhase: Equatable {
    case idle
    /// Decoding the last scan from disk at launch.
    case loadingCache
    case scanning(ScanProgress?)
    case analyzing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .scanning, .analyzing: true
        default: false
        }
    }

    static func == (lhs: ScanPhase, rhs: ScanPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.analyzing, .analyzing), (.loadingCache, .loadingCache): true
        case let (.scanning(a), .scanning(b)): a?.filesSeen == b?.filesSeen && a?.currentPath == b?.currentPath
        case let (.failed(a), .failed(b)): a == b
        default: false
        }
    }
}

enum PlanState: Equatable {
    case idle
    case loading
    case failed(String)
}

/// One bubble in the "Ask Freespan" panel.
struct ChatMessage: Identifiable, Hashable {
    enum Author: Hashable {
        case user
        /// An assistant reply, captioned with the assistant's short name ("On-device", "Claude").
        case assistant(AssistantKind, name: String)
    }

    let id: UUID
    var author: Author
    var text: String
    var isStreaming: Bool
    var isError: Bool
    /// False for one-off exchanges (second opinions) that aren't sent back as chat history.
    var isConversation: Bool

    init(id: UUID = UUID(), author: Author, text: String, isStreaming: Bool = false,
         isError: Bool = false, isConversation: Bool = true) {
        self.id = id
        self.author = author
        self.text = text
        self.isStreaming = isStreaming
        self.isError = isError
        self.isConversation = isConversation
    }

    var isUser: Bool {
        if case .user = author { return true }
        return false
    }
}

/// An assistant label persisted across launches (ai-labels.json). Reused only for the same path, size and assistant.
struct StoredAssistantLabel: Codable, Sendable {
    var label: AILabel
    var size: Int64
    var kind: AssistantKind

    var key: String { Self.key(path: label.path, size: size, kind: kind) }

    static func key(path: String, size: Int64, kind: AssistantKind) -> String {
        "\(kind.rawValue)|\(size)|\(path)"
    }
}

struct Notice: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    let id = UUID()
    var kind: Kind
    var title: String
    var message: String?
}

enum PathUtil {
    /// True when `path` is strictly inside `ancestor`.
    static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.count > prefix.count && path.hasPrefix(prefix)
    }

    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        path == ancestor || isDescendant(path, of: ancestor)
    }

    static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
