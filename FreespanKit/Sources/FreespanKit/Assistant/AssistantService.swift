import Foundation

/// Which engine answers questions and labels unknown items. On-device is the default: free, private, offline.
public enum AssistantKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple's on-device model (Foundation Models, macOS 26 + Apple Intelligence).
    case onDevice
    /// The user's Claude plan, through the `claude` command-line tool.
    case claudeSubscription
    /// Anthropic API key stored in the Keychain (billed per use).
    case claudeAPI
    /// No assistant: rules and local identification only.
    case off

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: "On-device (Apple Intelligence)"
        case .claudeSubscription: "Claude — your subscription"
        case .claudeAPI: "Claude — API key"
        case .off: "Off"
        }
    }
}

public enum AssistantAvailability: Sendable, Equatable {
    case available
    /// Plain-English reason and what the user can do about it.
    case unavailable(String)

    public var isAvailable: Bool { self == .available }
}

/// Everything the app asks of an assistant. Implementations: `OnDeviceAssistant`, `ClaudeCLIAssistant`,
/// `AnthropicClient`. The app depends only on this protocol.
///
/// Safety contract: assistants only ever *describe*. Labels they return are advisory and capped at `.review`
/// (implementations must map `.safe` → `.review` and `.protected` → `.keep`); only built-in rules can mark
/// something Safe, and ProtectedPaths is always checked locally.
public protocol AssistantService: Sendable {
    /// Short name shown on chat bubbles, e.g. "On-device" or "Claude Sonnet".
    var displayName: String { get }
    /// Label a batch of unknown items. Returns one label per input path it could identify (order not guaranteed).
    func label(_ items: [ItemMetadata]) async throws -> [AILabel]
    /// Answer a question about this disk. Streams text deltas.
    func ask(_ question: String, summary: DiskSummary, history: [ChatTurn]) -> AsyncThrowingStream<String, Error>
    /// Whole-disk cleanup plan. (The app's default plan comes from `RulePlanner`, no assistant needed.)
    func deepCleanPlan(_ summary: DiskSummary) async throws -> CleanupPlan
    /// Careful second opinion on one item before the user removes it.
    func secondOpinion(_ item: ItemMetadata) async throws -> AILabel
}

public enum AssistantError: Error, Sendable, Equatable, LocalizedError {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let s): s
        case .failed(let s): s
        }
    }
}
