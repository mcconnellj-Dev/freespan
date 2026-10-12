import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why the on-device model can't be used, independent of the FoundationModels SDK.
public enum OnDeviceUnavailableReason: Sendable, Equatable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// macOS older than 26.
    case requiresNewerMacOS
    case unknown
}

/// `AssistantService` backed by Apple's on-device language model (Foundation Models): free, private, offline.
///
/// The model has a 4096-token context, so labelling runs in small sequential batches (fresh session per
/// batch), chat gets a compact summary, and the Deep Clean Plan is left to the rule-based `RulePlanner`.
/// Every label is capped at `.review` per the `AssistantService` contract.
public final class OnDeviceAssistant: AssistantService {
    let engine: any OnDeviceEngine
    let home: String

    public convenience init() {
        self.init(engine: Self.systemEngine(), home: NSHomeDirectory())
    }

    init(engine: any OnDeviceEngine, home: String) {
        self.engine = engine
        self.home = home
    }

    public var displayName: String { "On-device" }

    // MARK: - Availability

    public static var availability: AssistantAvailability {
        guard let reason = unavailableReason else { return .available }
        return .unavailable(message(for: reason))
    }

    static var unavailableReason: OnDeviceUnavailableReason? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .unknown
                }
            }
        }
        return .requiresNewerMacOS
        #else
        return .requiresNewerMacOS
        #endif
    }

    /// Plain-English reason plus what the user can do about it.
    public static func message(for reason: OnDeviceUnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "This Mac doesn't support Apple Intelligence. Choose Claude in Settings › Assistant, or keep using Freespan's built-in rules."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri to use the on-device assistant."
        case .modelNotReady:
            "Apple Intelligence is still downloading its model. Try again later."
        case .requiresNewerMacOS:
            "The on-device assistant needs macOS 26 or later with Apple Intelligence."
        case .unknown:
            "Apple Intelligence isn't available right now. Check System Settings › Apple Intelligence & Siri."
        }
    }

    static func systemEngine() -> any OnDeviceEngine {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationModelsEngine() }
        #endif
        return UnavailableEngine(reason: .requiresNewerMacOS)
    }

    // MARK: - label

    public func label(_ items: [ItemMetadata]) async throws -> [AILabel] {
        let input = ClaudeTasks.LabelInput(items, home: home)
        var labels: [AILabel] = []
        // Sequential: the on-device model is one shared resource.
        for batch in OnDevicePrompts.batches(input.unique, home: home) {
            labels += try await labelBatch(batch)
        }
        return input.finalize(labels)
    }

    /// Labels one batch; halves it on a context overflow, skips it on a refusal. Returned paths are the
    /// batch's own (redacted-or-not) paths; `label` maps them back.
    private func labelBatch(_ batch: [ItemMetadata]) async throws -> [AILabel] {
        try Task.checkCancellation()
        let prompt = OnDevicePrompts.labelPrompt(batch, home: home)
        do {
            let raw = try await engine.labelBatch(prompt: prompt, itemCount: batch.count)
            return Self.labels(from: raw, batch: batch, home: home)
        } catch let failure as OnDeviceFailure {
            switch failure {
            case .contextOverflow:
                guard batch.count > 1 else { return [] } // a single item that doesn't fit: leave it unlabelled
                let mid = batch.count / 2
                return try await labelBatch(Array(batch[..<mid])) + labelBatch(Array(batch[mid...]))
            case .refused:
                return []
            case .unavailable, .failed:
                throw failure.assistantError
            }
        }
    }

    /// Maps numbered model output to the batch's items: unknown numbers and repeats are dropped, labels capped.
    static func labels(from raw: [OnDeviceRawLabel], batch: [ItemMetadata], home: String) -> [AILabel] {
        var seen = Set<Int>()
        return raw.compactMap { r in
            guard (1 ... batch.count).contains(r.number), seen.insert(r.number).inserted else { return nil }
            return r.aiLabel(path: Redactor.redact(batch[r.number - 1].path, home: home))
        }
    }

    // MARK: - ask

    public func ask(_ question: String, summary: DiskSummary, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let engine = engine
        let home = home
        return AsyncThrowingStream { continuation in
            let task = Task {
                var yielded = false
                for compact in [false, true] {
                    let prompt = OnDevicePrompts.askPrompt(question, summary: summary, history: history, home: home, compact: compact)
                    do {
                        for try await delta in engine.streamAnswer(prompt: prompt) {
                            yielded = true
                            continuation.yield(delta)
                        }
                        continuation.finish()
                        return
                    } catch OnDeviceFailure.contextOverflow where !yielded && !compact {
                        continue // retry once with no history and fewer findings
                    } catch let failure as OnDeviceFailure {
                        continuation.finish(throwing: failure.assistantError)
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - deepCleanPlan

    public func deepCleanPlan(_ summary: DiskSummary) async throws -> CleanupPlan {
        throw AssistantError.unavailable("The on-device assistant uses Freespan's built-in plan.")
    }

    // MARK: - secondOpinion

    public func secondOpinion(_ item: ItemMetadata) async throws -> AILabel {
        var candidate = item
        for attempt in 0 ..< 2 {
            do {
                let raw = try await engine.secondOpinion(prompt: OnDevicePrompts.secondOpinionPrompt(candidate, home: home))
                return raw.aiLabel(path: item.path) // path always from the input; capped
            } catch OnDeviceFailure.contextOverflow where attempt == 0 {
                // Retry without the children list, the only unbounded-ish part.
                candidate = ItemMetadata(path: item.path, sizeBytes: item.sizeBytes, isDirectory: item.isDirectory,
                                         itemCount: item.itemCount, modified: item.modified, accessed: item.accessed,
                                         topChildren: [])
            } catch let failure as OnDeviceFailure {
                throw failure.assistantError
            }
        }
        throw OnDeviceFailure.contextOverflow.assistantError
    }
}

// MARK: - Engine seam

/// One item's label as the model produced it, before capping. `category`/`label` are raw strings.
struct OnDeviceRawLabel: Sendable, Equatable {
    var number: Int
    var title: String
    var ownerApp: String
    var explanation: String
    var regenerates: Bool
    var category: String
    var label: String

    func aiLabel(path: String) -> AILabel {
        let owner = ownerApp.trimmingCharacters(in: .whitespacesAndNewlines)
        return AILabel(path: path, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                       explanation: explanation.trimmingCharacters(in: .whitespacesAndNewlines),
                       ownerApp: owner.isEmpty ? nil : owner, regenerates: regenerates,
                       category: CategoryID(rawValue: category) ?? .other,
                       label: AssistantSafety.cap(SafetyLabel(rawValue: label) ?? .review))
    }
}

/// What can go wrong talking to the model, in Freespan's terms.
enum OnDeviceFailure: Error, Equatable {
    case contextOverflow
    /// Guardrail violation or refusal.
    case refused
    case unavailable(String)
    case failed(String)

    var assistantError: AssistantError {
        switch self {
        case .contextOverflow: .failed("That was too much for the on-device model to read at once. Try a shorter question.")
        case .refused: .failed("The on-device model declined to answer that.")
        case .unavailable(let s): .unavailable(s)
        case .failed(let s): .failed(s)
        }
    }
}

/// The model calls `OnDeviceAssistant` makes. Implementations throw `OnDeviceFailure` (or CancellationError).
protocol OnDeviceEngine: Sendable {
    func labelBatch(prompt: String, itemCount: Int) async throws -> [OnDeviceRawLabel]
    func secondOpinion(prompt: String) async throws -> OnDeviceRawLabel
    /// Text deltas.
    func streamAnswer(prompt: String) -> AsyncThrowingStream<String, Error>
}

struct UnavailableEngine: OnDeviceEngine {
    let reason: OnDeviceUnavailableReason
    private var failure: OnDeviceFailure { .unavailable(OnDeviceAssistant.message(for: reason)) }
    func labelBatch(prompt: String, itemCount: Int) async throws -> [OnDeviceRawLabel] { throw failure }
    func secondOpinion(prompt: String) async throws -> OnDeviceRawLabel { throw failure }
    func streamAnswer(prompt: String) -> AsyncThrowingStream<String, Error> {
        let failure = failure
        return AsyncThrowingStream { $0.finish(throwing: failure) }
    }
}

// MARK: - Foundation Models

#if canImport(FoundationModels)

@available(macOS 26.0, *)
@Generable
enum OnDeviceCategoryChoice {
    case developer, downloads, caches, backups, media, applications, largeOld, duplicates, system, other
}

@available(macOS 26.0, *)
@Generable
enum OnDeviceLabelChoice {
    /// Descriptive case names steer the small model better than bare "review"/"keep".
    case rebuildsOrDownloadsAgain
    case usersOwnDataOrAppData

    var safetyLabel: SafetyLabel {
        switch self {
        case .rebuildsOrDownloadsAgain: .review
        case .usersOwnDataOrAppData: .keep
        }
    }
}

@available(macOS 26.0, *)
@Generable
struct OnDeviceItemLabel {
    @Guide(description: "The item's number from the list")
    var number: Int
    @Guide(description: "Short name, at most six words")
    var title: String
    @Guide(description: "App that owns it, or empty")
    var ownerApp: String
    @Guide(description: "One or two plain sentences: what it is and what happens if removed")
    var explanation: String
    @Guide(description: "True only if it comes back on its own after removal")
    var regenerates: Bool
    var category: OnDeviceCategoryChoice
    @Guide(description: "rebuildsOrDownloadsAgain = caches, installers, build output, simulators, downloaded models; usersOwnDataOrAppData = documents, exports, projects, browser profiles, app data")
    var label: OnDeviceLabelChoice

    var raw: OnDeviceRawLabel {
        OnDeviceRawLabel(number: number, title: title, ownerApp: ownerApp, explanation: explanation,
                         regenerates: regenerates, category: String(describing: category),
                         label: label.safetyLabel.rawValue)
    }
}

@available(macOS 26.0, *)
@Generable
struct OnDeviceLabelBatch {
    @Guide(description: "One entry per numbered item", .maximumCount(OnDevicePrompts.maxItemsPerBatch))
    var labels: [OnDeviceItemLabel]
}

@available(macOS 26.0, *)
@Generable
struct OnDeviceSingleLabel {
    @Guide(description: "Short name, at most six words")
    var title: String
    @Guide(description: "App that owns it, or empty")
    var ownerApp: String
    @Guide(description: "One or two plain sentences: what it is and what the user loses if it is removed")
    var explanation: String
    @Guide(description: "True only if it comes back on its own after removal")
    var regenerates: Bool
    var category: OnDeviceCategoryChoice
    @Guide(description: "rebuildsOrDownloadsAgain = caches, installers, build output, simulators, downloaded models; usersOwnDataOrAppData = documents, exports, projects, browser profiles, app data")
    var label: OnDeviceLabelChoice
}

/// Talks to `SystemLanguageModel.default`. A fresh session per request keeps each within the 4k window.
@available(macOS 26.0, *)
struct FoundationModelsEngine: OnDeviceEngine {
    private func checkAvailable() throws {
        if let reason = OnDeviceAssistant.unavailableReason {
            throw OnDeviceFailure.unavailable(OnDeviceAssistant.message(for: reason))
        }
    }

    func labelBatch(prompt: String, itemCount: Int) async throws -> [OnDeviceRawLabel] {
        try checkAvailable()
        let session = LanguageModelSession(instructions: OnDevicePrompts.labelInstructions)
        let options = GenerationOptions(sampling: .greedy,
                                        maximumResponseTokens: OnDevicePrompts.labelResponseTokens(items: itemCount))
        do {
            let response = try await session.respond(to: prompt, generating: OnDeviceLabelBatch.self, options: options)
            return response.content.labels.map(\.raw)
        } catch {
            throw Self.map(error)
        }
    }

    func secondOpinion(prompt: String) async throws -> OnDeviceRawLabel {
        try checkAvailable()
        let session = LanguageModelSession(instructions: OnDevicePrompts.secondOpinionInstructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 300)
        do {
            let l = try await session.respond(to: prompt, generating: OnDeviceSingleLabel.self, options: options).content
            return OnDeviceRawLabel(number: 1, title: l.title, ownerApp: l.ownerApp, explanation: l.explanation,
                                    regenerates: l.regenerates, category: String(describing: l.category),
                                    label: l.label.safetyLabel.rawValue)
        } catch {
            throw Self.map(error)
        }
    }

    func streamAnswer(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try checkAvailable()
                    let session = LanguageModelSession(instructions: OnDevicePrompts.askInstructions)
                    let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: OnDevicePrompts.askResponseTokens)
                    var deltas = SnapshotDeltas()
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        if let delta = deltas.next(snapshot.content) { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func map(_ error: Error) -> Error {
        if error is CancellationError || error is OnDeviceFailure { return error }
        guard let e = error as? LanguageModelSession.GenerationError else {
            return OnDeviceFailure.failed("The on-device model couldn't answer: \(error.localizedDescription)")
        }
        switch e {
        case .exceededContextWindowSize:
            return OnDeviceFailure.contextOverflow
        case .guardrailViolation, .refusal:
            return OnDeviceFailure.refused
        case .assetsUnavailable:
            return OnDeviceFailure.unavailable(OnDeviceAssistant.message(for: .modelNotReady))
        case .rateLimited, .concurrentRequests:
            return OnDeviceFailure.failed("The on-device model is busy right now. Try again in a moment.")
        case .unsupportedLanguageOrLocale:
            return OnDeviceFailure.failed("The on-device model doesn't support this language yet.")
        case .decodingFailure, .unsupportedGuide:
            return OnDeviceFailure.failed("The on-device model gave an answer Freespan couldn't read. Try again.")
        @unknown default:
            return OnDeviceFailure.failed("The on-device model couldn't answer: \(e.localizedDescription)")
        }
    }
}

#endif
