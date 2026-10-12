import Foundation

/// Which Claude model does which job. IDs are exact — never add date suffixes.
public enum ClaudeModel: String, Codable, Sendable, CaseIterable {
    /// Bulk labelling of unknown folders.
    case haiku = "claude-haiku-4-5"
    /// "Ask Freespan" chat and "Explain this".
    case sonnet = "claude-sonnet-5"
    /// Deep Clean Plan and second opinions.
    case opus = "claude-opus-5-5"

    public var displayName: String {
        switch self {
        case .haiku: "Haiku 4.5"
        case .sonnet: "Sonnet 5"
        case .opus: "Opus 5.5"
        }
    }

    /// USD per million tokens (input, output).
    public var pricePerMTok: (input: Double, output: Double) {
        switch self {
        case .haiku: (1, 5)
        case .sonnet: (2, 10)
        case .opus: (4, 20)
        }
    }
}

/// What Claude is allowed to see about one item: metadata only, never file contents.
/// `path` must already be redacted (home directory replaced with `~`).
public struct ItemMetadata: Codable, Sendable, Hashable {
    public let path: String
    public let sizeBytes: Int64
    public let isDirectory: Bool
    public let itemCount: Int
    public let modified: Date?
    public let accessed: Date?
    /// Names of the largest few children, to help identify what a folder is.
    public let topChildren: [String]

    public init(path: String, sizeBytes: Int64, isDirectory: Bool, itemCount: Int, modified: Date?, accessed: Date?, topChildren: [String]) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.itemCount = itemCount
        self.modified = modified
        self.accessed = accessed
        self.topChildren = topChildren
    }
}

/// Haiku's (or Opus's) read on one item.
public struct AILabel: Codable, Sendable, Hashable {
    public let path: String
    /// Short name, e.g. "Spotify offline cache".
    public let title: String
    /// What it is and what happens if removed, 1–2 sentences.
    public let explanation: String
    public let ownerApp: String?
    public let regenerates: Bool
    public let category: CategoryID
    /// Never `.protected` — that is decided locally, not by the model.
    public let label: SafetyLabel

    public init(path: String, title: String, explanation: String, ownerApp: String?, regenerates: Bool, category: CategoryID, label: SafetyLabel) {
        self.path = path
        self.title = title
        self.explanation = explanation
        self.ownerApp = ownerApp
        self.regenerates = regenerates
        self.category = category
        self.label = label
    }
}

/// Compact description of the whole disk handed to Sonnet/Opus as context.
public struct DiskSummary: Codable, Sendable {
    public let volume: VolumeInfo
    public let scannedAt: Date
    public let categories: [CategoryTotal]
    /// Largest classified findings (redacted paths).
    public let topFindings: [SummaryFinding]
    /// Largest things nothing has explained yet.
    public let unknownLarge: [ItemMetadata]

    public struct CategoryTotal: Codable, Sendable {
        public let category: CategoryID
        public let bytes: Int64
        public let safeBytes: Int64
        public init(category: CategoryID, bytes: Int64, safeBytes: Int64) {
            self.category = category; self.bytes = bytes; self.safeBytes = safeBytes
        }
    }

    public struct SummaryFinding: Codable, Sendable {
        public let path: String
        public let title: String
        public let bytes: Int64
        public let label: SafetyLabel
        public let category: CategoryID
        public let lastModified: Date?
        public init(path: String, title: String, bytes: Int64, label: SafetyLabel, category: CategoryID, lastModified: Date?) {
            self.path = path; self.title = title; self.bytes = bytes; self.label = label; self.category = category; self.lastModified = lastModified
        }
    }

    public init(volume: VolumeInfo, scannedAt: Date, categories: [CategoryTotal], topFindings: [SummaryFinding], unknownLarge: [ItemMetadata]) {
        self.volume = volume
        self.scannedAt = scannedAt
        self.categories = categories
        self.topFindings = topFindings
        self.unknownLarge = unknownLarge
    }
}

/// Opus's Deep Clean Plan.
public struct CleanupPlan: Codable, Sendable {
    /// One sentence, e.g. "You can safely free about 38 GB today."
    public let headline: String
    public let steps: [Step]

    public struct Step: Codable, Sendable, Identifiable, Hashable {
        public var id: String { title + "|" + (paths.first ?? "") }
        public let title: String
        public let reasoning: String
        /// Redacted paths (start with `~` or `/`). The app maps them back to findings.
        public let paths: [String]
        public let estimatedBytes: Int64
        public let risk: SafetyLabel
        public init(title: String, reasoning: String, paths: [String], estimatedBytes: Int64, risk: SafetyLabel) {
            self.title = title; self.reasoning = reasoning; self.paths = paths; self.estimatedBytes = estimatedBytes; self.risk = risk
        }
    }

    public init(headline: String, steps: [Step]) {
        self.headline = headline
        self.steps = steps
    }
}

public struct ChatTurn: Codable, Sendable, Identifiable, Hashable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public let text: String
    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}

public enum ClaudeError: Error, Sendable, Equatable, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case refused(String?)
    case truncated
    case badResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your Anthropic API key in Settings to use AI features."
        case .invalidAPIKey: "Your Anthropic API key was rejected. Check it in Settings."
        case .rateLimited: "Claude is rate-limiting requests. Try again in a minute."
        case .overloaded: "Claude is busy right now. Try again shortly."
        case .refused: "Claude declined this request."
        case .truncated: "Claude's answer was cut off. Try a narrower question."
        case .badResponse(let s): "Unexpected response from Claude: \(s)"
        case .network(let s): "Couldn't reach Claude: \(s)"
        }
    }
}

/// Kept so existing call sites compile; new code should use `AssistantService`.
public typealias ClaudeService = AssistantService
