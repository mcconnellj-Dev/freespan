import Foundation
import Synchronization
import Testing
@testable import FreespanKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Scripted stand-in for the on-device model.
final class FakeOnDeviceEngine: OnDeviceEngine {
    typealias LabelHandler = @Sendable (_ prompt: String, _ itemCount: Int) throws -> [OnDeviceRawLabel]
    private let labelHandler: LabelHandler
    private let opinion: @Sendable (String) throws -> OnDeviceRawLabel
    private let answers: @Sendable (String) -> [Result<String, Error>]
    let calls = Mutex<[String]>([])

    init(label: @escaping LabelHandler = { _, _ in [] },
         opinion: @escaping @Sendable (String) throws -> OnDeviceRawLabel = { _ in throw OnDeviceFailure.failed("unused") },
         answers: @escaping @Sendable (String) -> [Result<String, Error>] = { _ in [] }) {
        labelHandler = label
        self.opinion = opinion
        self.answers = answers
    }

    var prompts: [String] { calls.withLock { $0 } }

    func labelBatch(prompt: String, itemCount: Int) async throws -> [OnDeviceRawLabel] {
        calls.withLock { $0.append(prompt) }
        return try labelHandler(prompt, itemCount)
    }

    func secondOpinion(prompt: String) async throws -> OnDeviceRawLabel {
        calls.withLock { $0.append(prompt) }
        return try opinion(prompt)
    }

    func streamAnswer(prompt: String) -> AsyncThrowingStream<String, Error> {
        calls.withLock { $0.append(prompt) }
        let script = answers(prompt)
        return AsyncThrowingStream { c in
            for step in script {
                switch step {
                case .success(let s): c.yield(s)
                case .failure(let e): c.finish(throwing: e); return
                }
            }
            c.finish()
        }
    }
}

enum OnDeviceFixtures {
    static let home = "/Users/tester"

    static func raw(_ number: Int, label: String = "review", category: String = "caches", owner: String = "") -> OnDeviceRawLabel {
        OnDeviceRawLabel(number: number, title: "Item \(number)", ownerApp: owner, explanation: "Explains \(number).",
                         regenerates: true, category: category, label: label)
    }

    /// Echoes one label per numbered line in the prompt.
    static func echo(_ prompt: String, _ count: Int) -> [OnDeviceRawLabel] {
        (1 ... count).map { raw($0) }
    }

    static func item(_ path: String, children: [String] = ["Default", "Profile 1"]) -> ItemMetadata {
        ItemMetadata(path: path, sizeBytes: 16_000_000_000, isDirectory: true, itemCount: 4200,
                     modified: Date(timeIntervalSince1970: 1_758_000_000), accessed: Date(timeIntervalSince1970: 1_760_000_000),
                     topChildren: children)
    }

    /// The longest metadata an item can realistically carry: 1 KB path, five 255-character child names.
    static func worstCaseItem(_ i: Int) -> ItemMetadata {
        let component = String(repeating: "VeryLongFolderName_", count: 12)
        let path = "\(home)/" + Array(repeating: component, count: 4).joined(separator: "/") + "/item\(i)"
        let child = String(repeating: "w", count: 255)
        return ItemMetadata(path: path, sizeBytes: 999_999_999_999_999, isDirectory: true, itemCount: 999_999_999,
                            modified: Date(), accessed: Date(), topChildren: Array(repeating: child, count: 8))
    }

    static func summary(findings: Int = 3, pathLength: Int = 40) -> DiskSummary {
        let pad = String(repeating: "x", count: max(0, pathLength - 20))
        return DiskSummary(
            volume: VolumeInfo(name: "Macintosh HD", totalBytes: 460_000_000_000, availableBytes: 12_000_000_000),
            scannedAt: Date(timeIntervalSince1970: 1_760_000_000),
            categories: CategoryID.allCases.map { .init(category: $0, bytes: 10_000_000_000, safeBytes: 2_000_000_000) },
            topFindings: (0 ..< findings).map {
                .init(path: "~/Library/Some/\(pad)/finding\($0)", title: "Finding number \($0) with a title",
                      bytes: Int64(20_000_000_000 - $0 * 100_000_000), label: [.safe, .review, .keep][$0 % 3],
                      category: .developer, lastModified: nil)
            },
            unknownLarge: [item("~/Library/Application Support/Mystery")])
    }
}

private typealias F = OnDeviceFixtures

@Suite("On-device assistant")
struct OnDeviceAssistantTests {

    // MARK: Availability

    @Test func availabilityReasonsMapToPlainEnglish() {
        #expect(OnDeviceAssistant.message(for: .appleIntelligenceNotEnabled).contains("System Settings › Apple Intelligence & Siri"))
        #expect(OnDeviceAssistant.message(for: .modelNotReady).contains("still downloading"))
        #expect(OnDeviceAssistant.message(for: .deviceNotEligible).contains("doesn't support Apple Intelligence"))
        #expect(OnDeviceAssistant.message(for: .requiresNewerMacOS).contains("macOS 26"))
        #expect(!OnDeviceAssistant.message(for: .unknown).isEmpty)
        // The live value is either available or one of those messages.
        switch OnDeviceAssistant.availability {
        case .available: break
        case .unavailable(let message): #expect(!message.isEmpty)
        }
    }

    @Test func unavailableEngineSurfacesTheReason() async throws {
        let assistant = OnDeviceAssistant(engine: UnavailableEngine(reason: .appleIntelligenceNotEnabled), home: F.home)
        await #expect(throws: AssistantError.unavailable(OnDeviceAssistant.message(for: .appleIntelligenceNotEnabled))) {
            _ = try await assistant.label([F.item("~/a")])
        }
    }

    // MARK: Prompt budget

    @Test func worstCaseBatchFitsTheContextWindow() {
        let items = (0 ..< 8).map(F.worstCaseItem)
        let batches = OnDevicePrompts.batches(items, home: F.home)
        #expect(batches.count == 1, "eight worst-case items still fit one batch")
        let prompt = OnDevicePrompts.labelPrompt(items, home: F.home)
        let input = OnDevicePrompts.labelInputTokens(prompt)
        #expect(input <= OnDevicePrompts.inputBudget)
        #expect(input <= 3000)
        #expect(input + OnDevicePrompts.labelResponseTokens(items: 8) <= OnDevicePrompts.contextSize)
        #expect(!prompt.contains(F.home), "paths are redacted")
        // Paths and children are shortened; at most five children per item.
        for line in prompt.split(separator: "\n") where line.first?.isNumber == true {
            #expect(line.count < 520)
        }
    }

    @Test func batchesHoldAtMostEightItemsAndEveryBatchFits() {
        let items = (0 ..< 30).map(F.worstCaseItem)
        let batches = OnDevicePrompts.batches(items, home: F.home)
        #expect(batches.map(\.count).reduce(0, +) == 30)
        for batch in batches {
            #expect(batch.count <= OnDevicePrompts.maxItemsPerBatch)
            #expect(OnDevicePrompts.fits(batch, home: F.home))
        }
    }

    @Test func askPromptFitsWithBigSummaryAndLongHistory() {
        let summary = F.summary(findings: 60, pathLength: 400)
        let long = String(repeating: "Why is my disk so full? ", count: 200)
        let history = (0 ..< 10).map { ChatTurn(role: $0 % 2 == 0 ? .user : .assistant, text: long + "\(F.home)/Secret") }
        let prompt = OnDevicePrompts.askPrompt(long, summary: summary, history: history, home: F.home)
        let input = OnDevicePrompts.estimatedTokens(OnDevicePrompts.askInstructions) + OnDevicePrompts.estimatedTokens(prompt)
        #expect(input <= OnDevicePrompts.inputBudget)
        #expect(input + OnDevicePrompts.askResponseTokens <= OnDevicePrompts.contextSize)
        #expect(!prompt.contains(F.home))
        #expect(prompt.components(separatedBy: "\nUser: ").count + prompt.components(separatedBy: "\nAssistant: ").count - 2 <= 2,
                "only the last two turns")
    }

    @Test func askPromptIncludesTotalsCategoriesAndTopTwelve() {
        let prompt = OnDevicePrompts.askPrompt("What's safe to delete?", summary: F.summary(findings: 20), history: [], home: F.home)
        #expect(prompt.contains("460 GB total"))
        #expect(prompt.contains("12.0 GB free"))
        #expect(prompt.contains("Developer 10.0 GB (2.0 GB safe)"))
        #expect(prompt.contains("finding11"))
        #expect(!prompt.contains("finding12"))
        #expect(prompt.hasSuffix("Question: What's safe to delete?"))
    }

    // MARK: Labelling

    @Test func labelsAreCappedAndUnknownNumbersDropped() async throws {
        let engine = FakeOnDeviceEngine(label: { _, _ in
            [F.raw(1, label: "safe", owner: "Google Chrome"), F.raw(2, label: "protected"), F.raw(3, label: "keep"),
             F.raw(2, label: "review"), F.raw(9), F.raw(0)]
        })
        let assistant = OnDeviceAssistant(engine: engine, home: F.home)
        let items = [F.item("\(F.home)/Library/Application Support/Google/Chrome"), F.item("~/b"), F.item("~/c"),
                     F.item("~/b")] // duplicate input path
        let labels = try await assistant.label(items)
        #expect(labels.count == 3)
        #expect(!engine.prompts[0].contains(F.home))
        let chrome = try #require(labels.first { $0.path == items[0].path }, "paths come back in the caller's spelling")
        #expect(chrome.label == .review, "safe is capped to review")
        #expect(chrome.ownerApp == "Google Chrome")
        #expect(labels.first { $0.path == "~/b" }?.label == .keep, "protected is capped to keep")
        #expect(labels.first { $0.path == "~/c" }?.label == .keep)
        #expect(!labels.contains { $0.label == .safe || $0.label == .protected })
    }

    @Test func emptyOwnerBecomesNilAndUnknownCategoryBecomesOther() {
        let label = F.raw(1, category: "nonsense", owner: "  ").aiLabel(path: "~/x")
        #expect(label.ownerApp == nil)
        #expect(label.category == .other)
        #expect(F.raw(1, category: "largeOld").aiLabel(path: "~/x").category == .largeOld)
    }

    @Test func runsBatchesSequentiallyOfAtMostEight() async throws {
        let engine = FakeOnDeviceEngine(label: F.echo)
        let items = (0 ..< 20).map { F.item("~/Library/Caches/app\($0)") }
        let labels = try await OnDeviceAssistant(engine: engine, home: F.home).label(items)
        #expect(labels.count == 20)
        #expect(engine.prompts.count == 3)
    }

    @Test func contextOverflowHalvesTheBatch() async throws {
        // Batches of more than two items "overflow".
        let engine = FakeOnDeviceEngine(label: { prompt, count in
            if count > 2 { throw OnDeviceFailure.contextOverflow }
            return F.echo(prompt, count)
        })
        let items = (0 ..< 8).map { F.item("~/x\($0)") }
        let labels = try await OnDeviceAssistant(engine: engine, home: F.home).label(items)
        #expect(Set(labels.map(\.path)) == Set(items.map(\.path)))
        #expect(engine.prompts.count == 1 + 2 + 4) // 8 → 4+4 → 2+2+2+2
    }

    @Test func refusalSkipsOnlyThatBatch() async throws {
        let engine = FakeOnDeviceEngine(label: { prompt, count in
            if prompt.contains("~/refuse") { throw OnDeviceFailure.refused }
            return F.echo(prompt, count)
        })
        let items = (0 ..< 8).map { F.item("~/refuse\($0)") } + (0 ..< 3).map { F.item("~/ok\($0)") }
        let labels = try await OnDeviceAssistant(engine: engine, home: F.home).label(items)
        #expect(labels.map(\.path).sorted() == ["~/ok0", "~/ok1", "~/ok2"])
    }

    @Test func otherErrorsBecomeAssistantFailed() async throws {
        let engine = FakeOnDeviceEngine(label: { _, _ in throw OnDeviceFailure.failed("The on-device model is busy right now. Try again in a moment.") })
        await #expect(throws: AssistantError.failed("The on-device model is busy right now. Try again in a moment.")) {
            _ = try await OnDeviceAssistant(engine: engine, home: F.home).label([F.item("~/a")])
        }
    }

    @Test func labelHonoursCancellation() async throws {
        let engine = FakeOnDeviceEngine(label: F.echo)
        let assistant = OnDeviceAssistant(engine: engine, home: F.home)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await assistant.label((0 ..< 20).map { F.item("~/c\($0)") })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(engine.prompts.isEmpty)
    }

    // MARK: Ask, plan, second opinion

    @Test func askStreamsDeltasAndRetriesCompactOnOverflow() async throws {
        let engine = FakeOnDeviceEngine(answers: { prompt in
            prompt.contains("Earlier in this chat") ? [.failure(OnDeviceFailure.contextOverflow)] : [.success("You can "), .success("free 17 GB.")]
        })
        let assistant = OnDeviceAssistant(engine: engine, home: F.home)
        var text = ""
        for try await delta in assistant.ask("What's safe?", summary: F.summary(), history: [ChatTurn(role: .user, text: "hi")]) {
            text += delta
        }
        #expect(text == "You can free 17 GB.")
        #expect(engine.prompts.count == 2)
    }

    @Test func askRefusalBecomesReadableError() async throws {
        let engine = FakeOnDeviceEngine(answers: { _ in [.failure(OnDeviceFailure.refused)] })
        let stream = OnDeviceAssistant(engine: engine, home: F.home).ask("?", summary: F.summary(), history: [])
        await #expect(throws: AssistantError.failed("The on-device model declined to answer that.")) {
            for try await _ in stream {}
        }
    }

    @Test func snapshotsBecomeDeltas() {
        var d = SnapshotDeltas()
        #expect(d.next("Hel") == "Hel")
        #expect(d.next("Hello") == "lo")
        #expect(d.next("Hello") == nil)
        #expect(d.next("Hello, world") == ", world")
        #expect(d.next("Help") == nil, "a shorter rewrite emits nothing")
        #expect(d.next("Hello, world!") == "!")
    }

    @Test func deepCleanPlanDefersToRulePlanner() async {
        await #expect(throws: AssistantError.unavailable("The on-device assistant uses Freespan's built-in plan.")) {
            _ = try await OnDeviceAssistant(engine: FakeOnDeviceEngine(), home: F.home).deepCleanPlan(F.summary())
        }
    }

    @Test func secondOpinionIsCappedAndKeepsInputPath() async throws {
        let engine = FakeOnDeviceEngine(opinion: { _ in F.raw(7, label: "safe", category: "backups", owner: "Finder") })
        let item = F.item("\(F.home)/Library/Application Support/MobileSync/Backup/abc")
        let label = try await OnDeviceAssistant(engine: engine, home: F.home).secondOpinion(item)
        #expect(label.path == item.path)
        #expect(label.label == .review)
        #expect(label.category == .backups)
        #expect(!engine.prompts[0].contains(F.home))
    }

    @Test func secondOpinionRetriesWithoutChildrenOnOverflow() async throws {
        let engine = FakeOnDeviceEngine(opinion: { prompt in
            if prompt.contains("largest inside") { throw OnDeviceFailure.contextOverflow }
            return F.raw(1, label: "keep")
        })
        let label = try await OnDeviceAssistant(engine: engine, home: F.home).secondOpinion(F.item("~/a"))
        #expect(label.label == .keep)
        #expect(engine.prompts.count == 2)
    }

    // MARK: Real schema size (no model call)

    #if canImport(FoundationModels)
    @Test func generationSchemasFitTheirAllowance() throws {
        guard #available(macOS 26.0, *) else { return }
        let batch = try JSONEncoder().encode(OnDeviceLabelBatch.generationSchema)
        let single = try JSONEncoder().encode(OnDeviceSingleLabel.generationSchema)
        #expect((batch.count + 3) / 4 <= OnDevicePrompts.labelSchemaTokens, "batch schema is \(batch.count) bytes")
        #expect((single.count + 3) / 4 <= OnDevicePrompts.singleLabelSchemaTokens, "single schema is \(single.count) bytes")
    }
    #endif
}

// MARK: - Live (opt-in, free, local)

/// `FREESPAN_ONDEVICE=1 swift test --filter OnDeviceLive` — runs Apple's on-device model for real.
@Suite("OnDeviceLive", .serialized, .enabled(if: ProcessInfo.processInfo.environment["FREESPAN_ONDEVICE"] == "1"))
struct OnDeviceLiveTests {
    static func meta(_ path: String, _ gb: Double, children: [String], file: Bool = false, items: Int = 500,
                     modifiedDaysAgo: Double = 30) -> ItemMetadata {
        ItemMetadata(path: path, sizeBytes: Int64(gb * 1_000_000_000), isDirectory: !file, itemCount: file ? 1 : items,
                     modified: Date().addingTimeInterval(-modifiedDaysAgo * 86_400),
                     accessed: Date().addingTimeInterval(-modifiedDaysAgo * 43_200), topChildren: children)
    }

    static let items: [ItemMetadata] = [
        meta("~/Library/Application Support/Google/Chrome", 16, children: ["Default", "Profile 1", "Safe Browsing", "component_crx_cache"], items: 48_000, modifiedDaysAgo: 1),
        meta("~/Library/Developer/CoreSimulator/Devices", 11, children: ["8F2C1A7E-0B6D-4C11-9E55-3A1F7D2B9C40", "1D44E0C2-6B7A-4F1E-8C3D-5E9A2B7F0D11"], items: 210_000, modifiedDaysAgo: 40),
        meta("~/work/charter-redshift/exports", 18, children: ["subscribers_2026_q2.csv.gz", "churn_events_2026_08.csv.gz", "billing_2026_07.csv.gz"], items: 64, modifiedDaysAgo: 20),
        meta("~/.ollama/models", 9, children: ["blobs", "manifests"], items: 14, modifiedDaysAgo: 90),
        meta("~/Library/Application Support/Spotify/PersistentCache", 3, children: ["Storage", "Browse"], items: 9_000, modifiedDaysAgo: 2),
        meta("~/Downloads/Xcode_26.xip", 8, children: [], file: true, modifiedDaysAgo: 120),
    ]

    @Test func labelAskAndMeasure() async throws {
        guard OnDeviceAssistant.availability.isAvailable else {
            Issue.record("On-device model unavailable: \(OnDeviceAssistant.availability)")
            return
        }
        let assistant = OnDeviceAssistant()
        let clock = ContinuousClock()

        #if canImport(FoundationModels)
        if #available(macOS 26.4, *) {
            let model = SystemLanguageModel.default
            let worst = OnDevicePrompts.labelPrompt((0 ..< 8).map(OnDeviceFixtures.worstCaseItem), home: OnDeviceFixtures.home)
            let real = try await model.tokenCount(for: Instructions(OnDevicePrompts.labelInstructions))
                + model.tokenCount(for: OnDeviceLabelBatch.generationSchema)
                + model.tokenCount(for: worst)
            print("LIVE tokens: worst-case 8-item label input = \(real) real (estimate \(OnDevicePrompts.labelInputTokens(worst))); context \(model.contextSize)")
            let realPrompt = OnDevicePrompts.labelPrompt(Self.items, home: NSHomeDirectory())
            let realInput = try await model.tokenCount(for: Instructions(OnDevicePrompts.labelInstructions))
                + model.tokenCount(for: OnDeviceLabelBatch.generationSchema)
                + model.tokenCount(for: realPrompt)
            print("LIVE tokens: 6-item sample label input = \(realInput)")
            #expect(real + OnDevicePrompts.labelResponseTokens(items: 8) <= model.contextSize)
        }
        #endif

        var labels: [AILabel] = []
        let labelTime = try await clock.measure { labels = try await assistant.label(Self.items) }
        print("LIVE label: \(labels.count)/\(Self.items.count) items in \(labelTime)")
        for item in Self.items {
            if let l = labels.first(where: { $0.path == item.path }) {
                print("LIVE   \(item.path) → [\(l.label.rawValue)] \(l.category.rawValue) | \(l.title) | owner: \(l.ownerApp ?? "-") | regenerates: \(l.regenerates) | \(l.explanation)")
            } else {
                print("LIVE   \(item.path) → (no label)")
            }
        }
        #expect(!labels.isEmpty)
        #expect(!labels.contains { $0.label == .safe || $0.label == .protected })

        let summary = DiskSummary(
            volume: VolumeInfo(name: "Macintosh HD", totalBytes: 460_000_000_000, availableBytes: 12_000_000_000),
            scannedAt: Date(),
            categories: [.init(category: .developer, bytes: 32_000_000_000, safeBytes: 18_500_000_000),
                         .init(category: .downloads, bytes: 53_000_000_000, safeBytes: 0),
                         .init(category: .caches, bytes: 15_000_000_000, safeBytes: 12_000_000_000),
                         .init(category: .media, bytes: 13_000_000_000, safeBytes: 0)],
            topFindings: [
                .init(path: "~/Library/Developer/Xcode/iOS DeviceSupport", title: "iOS device symbols", bytes: 17_200_000_000, label: .safe, category: .developer, lastModified: nil),
                .init(path: "~/Pictures/Photos Library.photoslibrary", title: "Photos library", bytes: 13_000_000_000, label: .keep, category: .media, lastModified: nil),
                .init(path: "~/Library/Developer/CoreSimulator/Devices", title: "iOS simulators", bytes: 11_000_000_000, label: .review, category: .developer, lastModified: nil),
                .init(path: "~/Downloads/Xcode_26.xip", title: "Xcode installer", bytes: 8_000_000_000, label: .review, category: .downloads, lastModified: nil),
                .init(path: "~/.npm/_cacache", title: "npm cache", bytes: 2_500_000_000, label: .safe, category: .developer, lastModified: nil),
                .init(path: "~/Library/Developer/Xcode/DerivedData", title: "Xcode build products", bytes: 1_300_000_000, label: .safe, category: .developer, lastModified: nil),
            ],
            unknownLarge: [])
        var answer = ""
        var firstDelta: Duration?
        let start = clock.now
        for try await delta in assistant.ask("What's safe to delete?", summary: summary, history: []) {
            if firstDelta == nil { firstDelta = clock.now - start }
            answer += delta
        }
        print("LIVE ask: first text after \(firstDelta.map { "\($0)" } ?? "-"), total \(clock.now - start)")
        print("LIVE answer:\n\(answer)")
        #expect(!answer.isEmpty)
        #expect(!answer.contains("sudo"))
    }
}
