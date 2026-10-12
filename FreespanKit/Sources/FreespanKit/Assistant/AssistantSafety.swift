import Foundation

/// Enforces the `AssistantService` safety contract: assistant labels are advisory and capped at `.review`.
/// Only built-in rules may mark something Safe, and only ProtectedPaths may mark something Protected.
public enum AssistantSafety {
    /// `.safe` → `.review`, `.protected` → `.keep`; `.review` and `.keep` pass through.
    public static func cap(_ label: SafetyLabel) -> SafetyLabel {
        switch label {
        case .safe: .review
        case .protected: .keep
        case .review, .keep: label
        }
    }

    /// The same label with its path replaced by `path` (the caller's spelling) and its safety label capped.
    public static func capped(_ label: AILabel, path: String) -> AILabel {
        AILabel(path: path, title: label.title, explanation: label.explanation, ownerApp: label.ownerApp,
                regenerates: label.regenerates, category: label.category, label: cap(label.label))
    }
}
