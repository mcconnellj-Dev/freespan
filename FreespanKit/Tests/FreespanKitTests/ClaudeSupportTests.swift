import Foundation
import Testing
@testable import FreespanKit

@Suite("Claude SSE parsing")
struct ClaudeSSETests {
    struct Bytes: AsyncSequence {
        typealias Element = UInt8
        let data: [UInt8]
        struct Iterator: AsyncIteratorProtocol {
            var data: [UInt8]
            var i = 0
            mutating func next() async -> UInt8? {
                guard i < data.count else { return nil }
                defer { i += 1 }
                return data[i]
            }
        }
        func makeAsyncIterator() -> Iterator { Iterator(data: data) }
    }

    @Test func parserHandlesFieldsCommentsAndMultilineData() {
        var p = SSEParser()
        #expect(p.feed(line: ": keep-alive") == nil)
        #expect(p.feed(line: "event: message_start") == nil)
        #expect(p.feed(line: "data: {\"a\":") == nil)
        #expect(p.feed(line: "data:1}") == nil)
        #expect(p.feed(line: "") == SSEMessage(event: "message_start", data: "{\"a\":\n1}"))
        #expect(p.feed(line: "") == nil, "blank line with nothing pending dispatches nothing")
        #expect(p.feed(line: "data: tail") == nil)
        #expect(p.finish() == SSEMessage(event: nil, data: "tail"))
    }

    @Test func lineSplitterHandlesCRLFAndKeepsBlankLines() {
        var s = LineSplitter()
        var lines: [String] = []
        for b in Array("a\r\n\r\nb\nc".utf8) { if let l = s.append(b) { lines.append(l) } }
        if let l = s.finish() { lines.append(l) }
        #expect(lines == ["a", "", "b", "c"])
    }

    @Test func streamSplitAcrossArbitraryBoundariesYieldsSameText() async throws {
        let sse = ClaudeFixtures.sse(["Hel", "lo, ", "wörld 🌍"])
        var acc = StreamAccumulator()
        var text = ""
        try await consumeSSE(Bytes(data: Array(sse.utf8)), into: &acc) { text += $0 }
        #expect(text == "Hello, wörld 🌍")
        #expect(acc.stopReason == "end_turn")
        #expect(acc.usage.input_tokens == 1200 && acc.usage.output_tokens == 321)
        #expect(acc.usage.cache_read_input_tokens == 4000 && acc.usage.cache_creation_input_tokens == 300)
    }

    @Test func errorEventThrowsMappedError() async throws {
        let sse = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}\n\n"
        var acc = StreamAccumulator()
        await #expect(throws: ClaudeError.rateLimited(retryAfter: nil)) {
            try await consumeSSE(Bytes(data: Array(sse.utf8)), into: &acc) { _ in }
        }
    }
}

@Suite("Claude Redactor")
struct ClaudeRedactorTests {
    let home = "/Users/alex"

    @Test func redactsOnlyAtPathBoundaries() {
        #expect(Redactor.redact("/Users/alex", home: home) == "~")
        #expect(Redactor.redact("/Users/alex/Library/Caches", home: home) == "~/Library/Caches")
        #expect(Redactor.redact("/Users/alex2/Library", home: home) == "/Users/alex2/Library")
        #expect(Redactor.redact("/Users/jessеx", home: home) == "/Users/jessеx")
        #expect(Redactor.redact("/Applications/Xcode.app", home: home) == "/Applications/Xcode.app")
        #expect(Redactor.redact("/Volumes/X/Users/alex/a", home: home) == "/Volumes/X/Users/alex/a")
        #expect(Redactor.redact("/Users/alex/a", home: "/Users/alex/") == "~/a", "trailing slash on home")
        #expect(Redactor.redact("~/a", home: home) == "~/a", "idempotent")
    }

    @Test func unredactReverses() {
        for path in ["/Users/alex", "/Users/alex/Library/Caches", "/Users/alex2/x", "/tmp/x", "/Users/alex/~/odd"] {
            #expect(Redactor.unredact(Redactor.redact(path, home: home), home: home) == path)
        }
        #expect(Redactor.unredact("~", home: home) == "/Users/alex")
        #expect(Redactor.unredact("~other/x", home: home) == "~other/x")
    }

    @Test func redactTextReplacesEmbeddedPaths() {
        #expect(Redactor.redactText("Is /Users/alex/Downloads safe?", home: home) == "Is ~/Downloads safe?")
        #expect(Redactor.redactText("\"/Users/alex\" and /Users/alex2/x", home: home) == "\"~\" and /Users/alex2/x")
        #expect(Redactor.redactText("/Volumes/B/Users/alex/x", home: home) == "/Volumes/B/Users/alex/x")
        #expect(Redactor.redactText("no paths", home: home) == "no paths")
    }
}

@Suite("Claude UsageMeter")
struct ClaudeUsageMeterTests {
    @Test func costMathIncludesCacheReadsAndWrites() {
        let meter = UsageMeter(suiteName: "claude-usage-\(UUID())")
        meter.record(model: .sonnet, inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000)
        // Sonnet 5: $2 in, $10 out, reads 0.1× = $0.20, writes 1.25× = $2.50
        #expect(abs(meter.costUSD(for: .sonnet) - 14.70) < 1e-9)

        meter.record(model: .opus, inputTokens: 0, outputTokens: 0, cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000)
        // Opus 5.5 reads $0.20/MTok (0.05×), writes $5 (1.25×)
        #expect(abs(meter.costUSD(for: .opus) - 5.20) < 1e-9)

        meter.record(model: .haiku, inputTokens: 500_000, outputTokens: 100_000, cacheReadTokens: 0, cacheWriteTokens: 0)
        #expect(abs(meter.costUSD(for: .haiku) - 1.0) < 1e-9) // 0.5 + 0.5
        #expect(abs(meter.totalCostUSD() - 20.90) < 1e-9)
        #expect(meter.usage(for: .haiku).requests == 1)
    }

    @Test func persistsAcrossInstancesAndResets() {
        let suite = "claude-usage-\(UUID())"
        let a = UsageMeter(suiteName: suite)
        a.record(model: .haiku, inputTokens: 10, outputTokens: 20, cacheReadTokens: 30, cacheWriteTokens: 40)
        a.record(model: .haiku, inputTokens: 1, outputTokens: 1, cacheReadTokens: 1, cacheWriteTokens: 1)
        let b = UsageMeter(suiteName: suite)
        #expect(b.usage(for: .haiku).inputTokens == 11)
        #expect(b.usage(for: .haiku).cacheWriteTokens == 41)
        #expect(b.usage(for: .haiku).requests == 2)
        b.reset()
        #expect(b.totalCostUSD() == 0)
        #expect(UsageMeter(suiteName: suite).totalCostUSD() == 0)
    }

    @Test func concurrentRecordingIsConsistent() async {
        let meter = UsageMeter(suiteName: "claude-usage-\(UUID())")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 200 {
                group.addTask { meter.record(model: .opus, inputTokens: 1, outputTokens: 2, cacheReadTokens: 0, cacheWriteTokens: 0) }
            }
        }
        #expect(meter.usage(for: .opus).inputTokens == 200)
        #expect(meter.usage(for: .opus).outputTokens == 400)
    }
}

@Suite("Claude SummaryBuilder")
struct ClaudeSummaryBuilderTests {
    let home = "/Users/tester"
    var id: UInt64 = 0

    func node(_ path: String, size: Int64, kind: FileNode.Kind = .directory, children: [FileNode] = []) -> FileNode {
        FileNode(id: UInt64.random(in: 1 ... .max), name: (path as NSString).lastPathComponent, path: path, kind: kind, size: size,
                 itemCount: 10, modified: nil, accessed: nil, children: children)
    }

    func finding(_ path: String, size: Int64, category: CategoryID, label: SafetyLabel) -> Finding {
        Finding(node: node(path, size: size), classification: Classification(
            category: category, label: label, title: "T", explanation: "E", regenerates: label == .safe, source: .rule))
    }

    func scan(rootSize: Int64) -> ScanResult {
        ScanResult(root: node("/", size: rootSize), volume: VolumeInfo(name: "HD", totalBytes: 500, availableBytes: 100),
                   scannedAt: Date(timeIntervalSince1970: 0), duration: 1, inaccessiblePaths: [])
    }

    @Test func categoriesCountNestedFindingsOnceAndAddOther() {
        let findings = [
            finding("\(home)/Library/Developer/Xcode/DerivedData", size: 100, category: .developer, label: .safe),
            finding("\(home)/Library/Developer/Xcode/DerivedData/App-abc", size: 60, category: .developer, label: .safe), // nested
            finding("\(home)/Library/Developer/CoreSimulator", size: 50, category: .developer, label: .review),
            finding("\(home)/Library/Developer/CoreSimulator 2", size: 5, category: .developer, label: .review), // sibling, not nested
            finding("\(home)/Library/Caches", size: 40, category: .caches, label: .safe),
        ]
        let s = SummaryBuilder.summary(scan: scan(rootSize: 400), findings: findings, unknown: [], home: home)
        let byCategory = Dictionary(uniqueKeysWithValues: s.categories.map { ($0.category, $0) })
        #expect(byCategory[.developer]?.bytes == 155)
        #expect(byCategory[.developer]?.safeBytes == 100)
        #expect(byCategory[.caches]?.bytes == 40)
        #expect(byCategory[.other]?.bytes == 205)
        #expect(s.categories.first?.category == .other, "sorted by size")
        #expect(s.topFindings.first?.path == "~/Library/Developer/Xcode/DerivedData")
        #expect(s.topFindings.allSatisfy { $0.path.hasPrefix("~/") })
    }

    @Test func limitsAndRedaction() {
        let findings = (0 ..< 100).map { finding("\(home)/f\($0)", size: Int64($0), category: .caches, label: .safe) }
            + [finding("/System/Library", size: 10_000, category: .system, label: .protected)]
        let unknown = (0 ..< 80).map { node("\(home)/u\($0)", size: Int64($0)) }
        let s = SummaryBuilder.summary(scan: scan(rootSize: 0), findings: findings, unknown: unknown, home: home)
        #expect(s.topFindings.count == 60)
        #expect(s.topFindings.first?.path == "~/f99")
        #expect(!s.topFindings.contains { $0.label == .protected })
        #expect(s.unknownLarge.count == 40)
        #expect(s.unknownLarge.first?.path == "~/u79")
        #expect(!s.categories.contains { $0.category == .other }, "no other when nothing is unexplained")
    }

    @Test func metadataHasRedactedPathAndTop5ChildNames() {
        let children = (1 ... 8).map { node("\(home)/x/c\($0)", size: Int64($0)) }
            + [node("\(home)/x", size: 1_000, kind: .smallFiles)]
        let m = SummaryBuilder.metadata(for: node("\(home)/x", size: 5_000, children: children), home: home)
        #expect(m.path == "~/x")
        #expect(m.topChildren == ["c8", "c7", "c6", "c5", "c4"])
        #expect(m.isDirectory)
    }

    @Test func fullPayloadStaysCompact() throws {
        let longTitle = "Xcode iOS device support symbols"
        let findings = (0 ..< 200).map {
            Finding(node: node("\(home)/Library/Application Support/Some Vendor/Some App/Folder \($0)", size: Int64($0) * 1_000_000_000),
                    classification: Classification(category: .applications, label: .review, title: longTitle,
                                                   explanation: "E", regenerates: false, source: .rule))
        }
        let unknown = (0 ..< 100).map { i in
            node("\(home)/Library/Containers/com.example.app\(i)/Data/Library/Application Support/Store", size: Int64(i) * 1_000_000,
                 children: (0 ..< 8).map { node("\(home)/c/child-folder-name-\($0)", size: Int64($0)) })
        }
        let s = SummaryBuilder.summary(scan: scan(rootSize: 1), findings: findings, unknown: unknown, home: home)
        let json = try compactJSON(WireSummary(s, home: home))
        // ~4 characters per token for JSON-ish text; target < 15k tokens.
        #expect(json.count / 4 < 15_000, "payload ≈ \(json.count / 4) tokens")
        #expect(!json.contains(home))
    }
}

@Suite("Claude prompts and wire format")
struct ClaudeWireTests {
    @Test func humanSizesAreDecimalLikeFinder() {
        #expect(humanSize(0) == "0 bytes")
        #expect(humanSize(999) == "999 bytes")
        #expect(humanSize(1_500) == "1.5 KB")
        #expect(humanSize(17_200_000_000) == "17.2 GB")
        #expect(humanSize(460_000_000_000) == "460 GB")
    }

    @Test func systemPromptsAreLongEnoughToCache() {
        // Haiku 4.5 caches only prefixes ≥ 4096 tokens; ~4 chars/token is a conservative estimate for this text.
        #expect(ClaudePrompts.label.count / 4 > 4_096 + 300)
        for prompt in [ClaudePrompts.ask, ClaudePrompts.deepCleanPlan, ClaudePrompts.secondOpinion] {
            #expect(prompt.count / 4 > 1_024)
        }
    }

    @Test func schemasCloseEveryObject() throws {
        func check(_ v: JSONValue) {
            switch v {
            case .object(let o):
                if o["type"] == .string("object") { #expect(o["additionalProperties"] == .bool(false)) }
                o.values.forEach(check)
            case .array(let a): a.forEach(check)
            default: break
            }
        }
        check(ClaudeSchemas.labels)
        check(ClaudeSchemas.cleanupPlan)
        let encoded = String(decoding: try ClaudeSchemas.labels.encoded(), as: UTF8.self)
        #expect(!encoded.contains("protected"))
        for c in CategoryID.allCases { #expect(encoded.contains("\"\(c.rawValue)\"")) }
    }
}

/// Touches the real login Keychain (may show a prompt), so it only runs with FREESPAN_KEYCHAIN_TESTS=1.
@Suite("Claude Keychain", .enabled(if: ProcessInfo.processInfo.environment["FREESPAN_KEYCHAIN_TESTS"] == "1"))
struct ClaudeKeychainTests {
    @Test func roundTripTrimAndDelete() throws {
        let service = "com.mcconnelldigital.Freespan.tests.\(UUID())"
        defer { try? KeychainStore.setAPIKey(nil, service: service) }
        #expect(KeychainStore.apiKey(service: service) == nil)
        try KeychainStore.setAPIKey("  sk-ant-one \n", service: service)
        #expect(KeychainStore.apiKey(service: service) == "sk-ant-one")
        try KeychainStore.setAPIKey("sk-ant-two", service: service)
        #expect(KeychainStore.apiKey(service: service) == "sk-ant-two")
        try KeychainStore.setAPIKey(nil, service: service)
        #expect(KeychainStore.apiKey(service: service) == nil)
        try KeychainStore.setAPIKey("   ", service: service) // blank deletes; deleting nothing is fine
    }
}
