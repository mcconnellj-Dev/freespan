import Foundation
import Testing
@testable import FreespanKit

/// All tests that drive `AnthropicClient` through the URLProtocol mock. Serialized: the mock is global.
@Suite("Claude network", .serialized)
struct ClaudeNetworkTests {
    typealias Mock = ClaudeMockURLProtocol
    typealias F = ClaudeFixtures

    // MARK: Helpers

    static func labelsBody(for paths: [String], label: String = "safe") -> Data {
        let labels = paths.map {
            ["path": $0, "title": "Cache", "explanation": "Regenerates.", "ownerApp": NSNull(),
             "regenerates": true, "category": "caches", "label": label] as [String: Any]
        }
        return F.message(text: F.json(["labels": labels]))
    }

    /// Echo handler for label requests: labels every path found in the request's <items> block.
    static let echoLabels: @Sendable (Mock.Captured, Int) -> Mock.Reply = { captured, _ in
        F.ok(labelsBody(for: itemPaths(in: captured)))
    }

    static func userText(_ c: Mock.Captured) -> String {
        let messages = c.json["messages"] as? [[String: Any]] ?? []
        return messages.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func itemObjects(in c: Mock.Captured) -> [[String: Any]] {
        let text = userText(c)
        guard let start = text.range(of: "<items>\n"), let end = text.range(of: "\n</items>") else { return [] }
        let json = Data(text[start.upperBound ..< end.lowerBound].utf8)
        return (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] ?? []
    }

    static func itemPaths(in c: Mock.Captured) -> [String] { itemObjects(in: c).compactMap { $0["path"] as? String } }

    static func expectCommonHeaders(_ c: Mock.Captured) {
        #expect(c.request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(c.request.httpMethod == "POST")
        #expect(c.request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(c.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(c.request.value(forHTTPHeaderField: "content-type") == "application/json")
        let system = c.json["system"] as? [[String: Any]]
        #expect((system?.first?["cache_control"] as? [String: String])?["type"] == "ephemeral")
        #expect(c.json["temperature"] == nil)
    }

    // MARK: label (Haiku)

    @Test func labelRequestShapeAndParsing() async throws {
        Mock.install { captured, _ in
            let paths = Self.itemPaths(in: captured)
            // Model output: one protected (must clamp to keep) and one invented path (must be dropped).
            var labels = paths.map {
                ["path": $0, "title": "Chrome cache", "explanation": "Browser cache; regenerates.", "ownerApp": "Google Chrome",
                 "regenerates": true, "category": "caches", "label": "safe"] as [String: Any]
            }
            labels[1]["label"] = "protected"
            labels.append(["path": "~/Invented", "title": "x", "explanation": "x", "ownerApp": NSNull(),
                           "regenerates": false, "category": "other", "label": "safe"])
            return F.ok(F.message(text: F.json(["labels": labels]), cacheRead: 4500, cacheWrite: 0))
        }
        let usage = UsageMeter(suiteName: "claude-tests-\(UUID())")
        let client = F.client(usage: usage)
        let items = [
            F.item("\(F.home)/Library/Caches/Google/Chrome"), // unredacted on purpose: client must redact
            F.item("~/Library/Caches/com.spotify.client"),
        ]
        let labels = try await client.label(items)

        let c = try #require(Mock.requests.first)
        Self.expectCommonHeaders(c)
        #expect(Mock.requests.count == 1)
        #expect(c.json["model"] as? String == "claude-haiku-4-5")
        #expect(c.json["thinking"] == nil)
        #expect(c.json["stream"] == nil)
        let outputConfig = try #require(c.json["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] == nil, "Haiku 4.5 rejects effort")
        let format = try #require(outputConfig["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["schema"] != nil)
        // Redaction: no home path anywhere in the body.
        #expect(!c.bodyString.contains(F.home))
        #expect(Self.itemPaths(in: c) == ["~/Library/Caches/Google/Chrome", "~/Library/Caches/com.spotify.client"])
        // Metadata only: exactly the allowed keys, sizes human-readable too, dates ISO-8601.
        let allowed: Set = ["path", "size", "bytes", "kind", "itemCount", "modified", "accessed", "topChildren"]
        for object in Self.itemObjects(in: c) { #expect(Set(object.keys).isSubset(of: allowed)) }
        #expect(Self.itemObjects(in: c).first?["size"] as? String == "2.0 GB")
        #expect(Self.itemObjects(in: c).first?["modified"] as? String == "2023-11-14T22:13:20Z")

        // Parsing: paths mapped back to the caller's spelling, protected clamped, invented dropped.
        #expect(labels.count == 2)
        #expect(Set(labels.map(\.path)) == Set(items.map(\.path)))
        #expect(labels.first { $0.path.hasSuffix("spotify.client") }?.label == .keep)
        #expect(labels.first { $0.path.hasSuffix("Chrome") }?.label == .review, "assistant labels are capped at review")
        #expect(labels.first?.ownerApp == "Google Chrome")
        #expect(!labels.contains { $0.label == .protected })

        let u = usage.usage(for: .haiku)
        #expect(u.inputTokens == 100 && u.outputTokens == 50 && u.cacheReadTokens == 4500 && u.requests == 1)
    }

    @Test func labelChunks100ItemsInto3Requests() async throws {
        Mock.install(Self.echoLabels)
        let items = (0 ..< 100).map { F.item("~/Library/Caches/app\($0)") }
        let labels = try await F.client().label(items)
        #expect(Mock.requests.count == 3)
        #expect(Mock.requests.map { Self.itemPaths(in: $0).count }.sorted() == [20, 40, 40])
        #expect(labels.count == 100)
        #expect(Set(labels.map(\.path)) == Set(items.map(\.path)))
    }

    @Test func labelRetriesAFailedChunkOnce() async throws {
        // First attempt returns unparseable text; the chunk-level retry succeeds.
        Mock.install { captured, index in
            index == 0 ? F.ok(F.message(text: "not json")) : Self.echoLabels(captured, index)
        }
        let labels = try await F.client().label([F.item("~/Library/Caches/a")])
        #expect(Mock.requests.count == 2)
        #expect(labels.map(\.path) == ["~/Library/Caches/a"])
    }

    @Test func labelInvalidKeyStopsImmediately() async throws {
        Mock.install { _, _ in F.error(401, type: "authentication_error") }
        await #expect(throws: ClaudeError.invalidAPIKey) { try await F.client().label([F.item("~/a")]) }
        #expect(Mock.requests.count == 1)
    }

    // MARK: ask (Sonnet, streaming)

    @Test func askRequestShapeAndStreaming() async throws {
        Mock.install { _, _ in F.sseReply(F.sse(["You have ", "about 17 GB ", "of device symbols. ✅"]), chunkSize: 23) }
        let usage = UsageMeter(suiteName: "claude-tests-\(UUID())")
        let client = F.client(usage: usage)
        let history = [ChatTurn(role: .user, text: "Hi"), ChatTurn(role: .assistant, text: "Hello! Ask me anything.")]
        var text = ""
        for try await delta in client.ask("What's in \(F.home)/Library?", summary: F.summary(), history: history) {
            text += delta
        }
        #expect(text == "You have about 17 GB of device symbols. ✅")

        let c = try #require(Mock.requests.first)
        Self.expectCommonHeaders(c)
        #expect(c.json["model"] as? String == "claude-sonnet-5")
        #expect(c.json["stream"] as? Bool == true)
        #expect((c.json["thinking"] as? [String: String])?["type"] == "adaptive")
        #expect((c.json["output_config"] as? [String: Any])?["effort"] as? String == "low")
        let messages = try #require(c.json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let first = try #require(messages[0]["content"] as? [[String: Any]])
        let summaryText = try #require(first[0]["text"] as? String)
        #expect(summaryText.hasPrefix("<disk_summary>"))
        #expect(summaryText.contains(#""size":"17.2 GB""#))
        #expect((first[0]["cache_control"] as? [String: String])?["type"] == "ephemeral")
        #expect(Self.userText(c).contains("What's in ~/Library?"))
        #expect(!c.bodyString.contains(F.home))

        let u = usage.usage(for: .sonnet)
        #expect(u.inputTokens == 1200 && u.outputTokens == 321 && u.cacheReadTokens == 4000 && u.cacheWriteTokens == 300)
    }

    @Test func askStreamErrorEventThrows() async throws {
        let error = #"event: error"# + "\n" + #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        Mock.install { _, _ in F.sseReply(F.sse(["Partial"], extraEvents: [error])) }
        var received: [String] = []
        await #expect(throws: ClaudeError.overloaded) {
            for try await delta in F.client().ask("Q", summary: F.summary(), history: []) { received.append(delta) }
        }
        #expect(received == ["Partial"])
    }

    @Test func askRefusalAndTruncation() async throws {
        Mock.install { _, _ in F.sseReply(F.sse(["Sorry"], stopReason: "refusal")) }
        await #expect(throws: ClaudeError.refused(nil)) {
            for try await _ in F.client().ask("Q", summary: F.summary(), history: []) {}
        }
        Mock.install { _, _ in F.sseReply(F.sse(["Long"], stopReason: "max_tokens")) }
        await #expect(throws: ClaudeError.truncated) {
            for try await _ in F.client().ask("Q", summary: F.summary(), history: []) {}
        }
    }

    @Test func askHTTPErrorBeforeStreamMapsAndRetries() async throws {
        Mock.install { _, index in index == 0 ? F.error(500, type: "api_error") : F.sseReply(F.sse(["ok"])) }
        var text = ""
        for try await delta in F.client().ask("Q", summary: F.summary(), history: []) { text += delta }
        #expect(text == "ok")
        #expect(Mock.requests.count == 2)
    }

    // MARK: deepCleanPlan (Opus 5.5)

    @Test func deepCleanPlanRequestShapeAndValidation() async throws {
        let plan: [String: Any] = [
            "headline": "You can safely free about 17 GB today.",
            "steps": [
                ["title": "Remove old simulators", "reasoning": "Regenerable.", "paths": ["~/Library/Developer/CoreSimulator/Devices"],
                 "estimatedBytes": 11_000_000_000, "risk": "review"],
                ["title": "Clear device symbols", "reasoning": "Xcode re-copies them.",
                 "paths": ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Made/Up"], "estimatedBytes": 99_000_000_000, "risk": "safe"],
                ["title": "Delete photos", "reasoning": "Bad idea.", "paths": ["~/Pictures/Photos Library.photoslibrary"],
                 "estimatedBytes": 13_000_000_000, "risk": "safe"],
            ],
        ]
        let jsonText = F.json(plan)
        let split = jsonText.index(jsonText.startIndex, offsetBy: jsonText.count / 2)
        Mock.install { _, _ in F.sseReply(F.sse([String(jsonText[..<split]), String(jsonText[split...])])) }
        let usage = UsageMeter(suiteName: "claude-tests-\(UUID())")
        let result = try await F.client(usage: usage).deepCleanPlan(F.summary())

        let c = try #require(Mock.requests.first)
        Self.expectCommonHeaders(c)
        #expect(c.json["model"] as? String == "claude-opus-5-5")
        #expect(c.json["thinking"] == nil, "Opus 5.5: thinking can't be disabled; omit it")
        #expect(c.json["tool_choice"] == nil)
        #expect(c.json["stream"] as? Bool == true)
        #expect((c.json["max_tokens"] as? Int ?? 0) > 16_000)
        let outputConfig = try #require(c.json["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "high")
        #expect((outputConfig["format"] as? [String: Any])?["type"] as? String == "json_schema")

        #expect(result.headline == "You can safely free about 17 GB today.")
        // Photos step dropped (keep item), invented path dropped, bytes clamped, safe before review.
        #expect(result.steps.map(\.title) == ["Clear device symbols", "Remove old simulators"])
        #expect(result.steps[0].paths == ["~/Library/Developer/Xcode/iOS DeviceSupport"])
        #expect(result.steps[0].estimatedBytes == 17_200_000_000)
        #expect(result.steps[0].risk == .safe)
        #expect(usage.usage(for: .opus).outputTokens == 321)
    }

    // MARK: secondOpinion (Opus 5.5)

    @Test func secondOpinionRequestShapeAndParsing() async throws {
        let label: [String: Any] = ["path": "~/whatever", "title": "Old iPhone backup", "explanation": "A Finder backup.",
                                    "ownerApp": "Finder", "regenerates": false, "category": "backups", "label": "review"]
        let labelJSON = F.json(label)
        Mock.install { _, _ in F.ok(F.message(text: labelJSON)) }
        let item = F.item("~/Library/Application Support/MobileSync/Backup/abc")
        let result = try await F.client().secondOpinion(item)

        let c = try #require(Mock.requests.first)
        Self.expectCommonHeaders(c)
        #expect(c.json["model"] as? String == "claude-opus-5-5")
        #expect(c.json["thinking"] == nil)
        #expect(c.json["stream"] == nil)
        let outputConfig = try #require(c.json["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "medium")
        #expect((outputConfig["format"] as? [String: Any])?["type"] as? String == "json_schema")

        #expect(result.path == item.path, "path always comes from the input")
        #expect(result.label == .review && result.category == .backups && result.ownerApp == "Finder")
    }

    @Test func refusalStopReasonThrowsRefused() async throws {
        Mock.install { _, _ in F.ok(F.message(text: "", stopReason: "refusal", stopDetails: "cyber")) }
        await #expect(throws: ClaudeError.refused("cyber")) { try await F.client().secondOpinion(F.item("~/a")) }
        Mock.install { _, _ in F.ok(F.message(text: "{\"path\":", stopReason: "max_tokens")) }
        await #expect(throws: ClaudeError.truncated) { try await F.client().secondOpinion(F.item("~/a")) }
    }

    // MARK: Error mapping and retries

    @Test func status401MapsToInvalidKeyWithoutRetry() async throws {
        Mock.install { _, _ in F.error(401, type: "authentication_error") }
        await #expect(throws: ClaudeError.invalidAPIKey) { try await F.client().secondOpinion(F.item("~/a")) }
        #expect(Mock.requests.count == 1)
    }

    @Test func status429MapsToRateLimitedWithRetryAfter() async throws {
        Mock.install { _, _ in F.error(429, type: "rate_limit_error", headers: ["retry-after": "7"]) }
        await #expect(throws: ClaudeError.rateLimited(retryAfter: 7)) { try await F.client().secondOpinion(F.item("~/a")) }
        #expect(Mock.requests.count == 1)
    }

    @Test func status529RetriesTwiceThenOverloaded() async throws {
        Mock.install { _, _ in F.error(529, type: "overloaded_error") }
        await #expect(throws: ClaudeError.overloaded) { try await F.client().secondOpinion(F.item("~/a")) }
        #expect(Mock.requests.count == 3)
    }

    @Test func status500RetriesTwiceThenBadResponse() async throws {
        Mock.install { _, _ in F.error(500, type: "api_error") }
        await #expect(throws: ClaudeError.badResponse("HTTP 500: test api_error")) {
            try await F.client().secondOpinion(F.item("~/a"))
        }
        #expect(Mock.requests.count == 3)
    }

    @Test func transientFailureRecoversOnRetry() async throws {
        let label: [String: Any] = ["path": "~/a", "title": "t", "explanation": "e", "ownerApp": NSNull(),
                                    "regenerates": true, "category": "caches", "label": "safe"]
        let labelJSON = F.json(label)
        Mock.install { _, index in index < 2 ? F.error(408, type: "timeout_error") : F.ok(F.message(text: labelJSON)) }
        let result = try await F.client().secondOpinion(F.item("~/a"))
        #expect(result.label == .review, "model said safe; assistant labels are capped at review")
        #expect(Mock.requests.count == 3)
    }

    @Test func urlErrorMapsToNetwork() async throws {
        Mock.install { _, _ in .failure(URLError(.notConnectedToInternet)) }
        do {
            _ = try await F.client().secondOpinion(F.item("~/a"))
            Issue.record("expected an error")
        } catch let error as ClaudeError {
            guard case .network = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test func missingKeyShortCircuitsWithZeroRequests() async throws {
        Mock.install { _, _ in Issue.record("no request expected"); return F.error(500, type: "api_error") }
        for key in [nil, "", "  \n"] as [String?] {
            let client = F.client(key: key)
            await #expect(throws: ClaudeError.missingAPIKey) { try await client.label([F.item("~/a")]) }
            await #expect(throws: ClaudeError.missingAPIKey) { try await client.deepCleanPlan(F.summary()) }
            await #expect(throws: ClaudeError.missingAPIKey) { try await client.secondOpinion(F.item("~/a")) }
            await #expect(throws: ClaudeError.missingAPIKey) {
                for try await _ in client.ask("Q", summary: F.summary(), history: []) {}
            }
        }
        #expect(Mock.requests.isEmpty)
    }
}
