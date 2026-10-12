import Foundation

/// `ClaudeService` backed by the Anthropic Messages API over URLSession (there is no official Swift SDK).
/// OWNER: claude agent.
///
/// Request shapes (see the claude-api skill docs; the API changed in 2025-26):
/// - Haiku 4.5 (label): no `thinking`, no `effort` (Haiku rejects it); structured output via
///   `output_config.format` json_schema.
/// - Sonnet 5 (ask): streamed; `thinking: adaptive` + `effort: low` — the docs recommend adaptive+low over
///   disabling thinking for latency-sensitive chat: the model skips thinking on simple questions and keeps
///   it for multi-step ones, while time-to-first-token stays short.
/// - Opus 5.5 (plan, second opinion): thinking can't be disabled — `thinking` is omitted; effort is always
///   set explicitly (its default is `medium`). The plan streams because max_tokens is above ~16K.
/// Every request caches its system prompt (`cache_control: ephemeral`). Prefill is never used.
public final class AnthropicClient: ClaudeService {
    public var displayName: String { "Claude" }
    private let apiKeyProvider: @Sendable () -> String?
    private let session: URLSession
    private let usage: UsageMeter
    private let home: String
    private let retryBaseDelay: Duration

    /// HTTP retries for 408/5xx/529 on top of the first attempt.
    static let maxRetries = 2
    static let labelChunkSize = 40
    static let labelConcurrency = 3
    static let maxHistoryTurns = 20

    public convenience init(apiKeyProvider: @escaping @Sendable () -> String?, session: URLSession = .shared, usage: UsageMeter = .shared) {
        self.init(apiKeyProvider: apiKeyProvider, session: session, usage: usage, home: NSHomeDirectory(), retryBaseDelay: .seconds(1))
    }

    /// Designated initializer; `home` and `retryBaseDelay` are injectable for tests.
    init(apiKeyProvider: @escaping @Sendable () -> String?, session: URLSession, usage: UsageMeter, home: String, retryBaseDelay: Duration) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.usage = usage
        self.home = home
        self.retryBaseDelay = retryBaseDelay
    }

    // MARK: - label (Haiku)

    public func label(_ items: [ItemMetadata]) async throws -> [AILabel] {
        let key = try apiKey()
        guard !items.isEmpty else { return [] }

        let input = ClaudeTasks.LabelInput(items, home: home)
        let chunks = input.chunks(of: Self.labelChunkSize)

        var results: [[AILabel]] = []
        var firstError: Error?
        try await withThrowingTaskGroup(of: Result<[AILabel], Error>.self) { group in
            var next = 0
            func addNext() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask {
                    do { return .success(try await self.labelChunkWithRetry(chunk, key: key)) } catch { return .failure(error) }
                }
            }
            for _ in 0 ..< Self.labelConcurrency { addNext() }
            while let result = try await group.next() {
                switch result {
                case .success(let labels): results.append(labels)
                case .failure(let error):
                    // Credentials problems doom every chunk: stop now.
                    if let e = error as? ClaudeError, e == .invalidAPIKey || e == .missingAPIKey {
                        group.cancelAll()
                        throw e
                    }
                    if error is CancellationError { throw error }
                    firstError = firstError ?? error
                }
                addNext()
            }
        }
        // Partial success is still useful (unlabelled items simply stay unknown); total failure throws.
        if results.isEmpty, let firstError { throw firstError }

        // Unknown paths dropped, paths mapped back to the caller's spelling, labels capped at review.
        return input.finalize(results.joined())
    }

    private func labelChunkWithRetry(_ chunk: [ItemMetadata], key: String) async throws -> [AILabel] {
        do {
            return try await labelChunk(chunk, key: key)
        } catch let error as ClaudeError {
            switch error {
            case .badResponse, .network, .overloaded, .truncated:
                try Task.checkCancellation()
                return try await labelChunk(chunk, key: key) // one more try for transient failures
            default:
                throw error
            }
        }
    }

    private func labelChunk(_ chunk: [ItemMetadata], key: String) async throws -> [AILabel] {
        let prompt = try ClaudeTasks.labelPrompt(chunk, home: home)
        let body: JSONValue = [
            "model": .string(ClaudeModel.haiku.rawValue),
            "max_tokens": 8192,
            "system": MessagesAPI.system(ClaudePrompts.label),
            "messages": [["role": "user", "content": [MessagesAPI.textBlock(prompt)]]],
            "output_config": ["format": MessagesAPI.jsonSchemaFormat(ClaudeSchemas.labels)],
        ]
        let message = try await send(body, model: .haiku, key: key, timeout: 120)
        return try decodeJSON(ClaudeTasks.LabelsEnvelope.self, from: message.text).labels
    }

    // MARK: - ask (Sonnet, streaming)

    public func ask(_ question: String, summary: DiskSummary, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = try self.apiKey()
                    let body = try self.askBody(question, summary: summary, history: history)
                    try await self.stream(body, model: .sonnet, key: key, timeout: 120) { text in
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func askBody(_ question: String, summary: DiskSummary, history: [ChatTurn]) throws -> JSONValue {
        let summaryJSON = try compactJSON(WireSummary(summary, home: home))
        let summaryBlock = MessagesAPI.textBlock("<disk_summary>\n\(summaryJSON)\n</disk_summary>", cached: true)

        // Turns: recent history + the new question, merged so roles alternate and the first is "user".
        var turns: [(role: ChatTurn.Role, text: String)] = []
        let recent = history.suffix(Self.maxHistoryTurns)
        for turn in recent + [ChatTurn(role: .user, text: question)] {
            let text = Redactor.redactText(turn.text.trimmingCharacters(in: .whitespacesAndNewlines), home: home)
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.role == turn.role {
                turns[turns.count - 1].text += "\n\n" + text
            } else {
                turns.append((turn.role, text))
            }
        }
        if turns.isEmpty { throw ClaudeError.badResponse("Empty question") }

        var messages: [JSONValue] = []
        if turns[0].role == .assistant { messages.append(["role": "user", "content": [summaryBlock]]) }
        for (index, turn) in turns.enumerated() {
            var content: [JSONValue] = []
            if index == 0, turn.role == .user { content.append(summaryBlock) }
            // Cache the conversation so far: the next turn re-reads this prefix.
            content.append(MessagesAPI.textBlock(turn.text, cached: index == turns.count - 1))
            messages.append(["role": .string(turn.role.rawValue), "content": .array(content)])
        }
        return [
            "model": .string(ClaudeModel.sonnet.rawValue),
            "max_tokens": 8000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "low"],
            "system": MessagesAPI.system(ClaudePrompts.ask),
            "messages": .array(messages),
        ]
    }

    // MARK: - deepCleanPlan (Opus, streaming)

    public func deepCleanPlan(_ summary: DiskSummary) async throws -> CleanupPlan {
        let key = try apiKey()
        let wire = WireSummary(summary, home: home)
        let prompt = try ClaudeTasks.planPrompt(wire)
        let body: JSONValue = [
            "model": .string(ClaudeModel.opus.rawValue),
            "max_tokens": 32000, // room for thinking at high effort; above ~16K, so streamed
            "stream": true,
            "output_config": ["effort": "high", "format": MessagesAPI.jsonSchemaFormat(ClaudeSchemas.cleanupPlan)],
            "system": MessagesAPI.system(ClaudePrompts.deepCleanPlan),
            "messages": [["role": "user", "content": [MessagesAPI.textBlock(prompt)]]],
        ]
        var text = ""
        try await stream(body, model: .opus, key: key, timeout: 600) { text += $0 }
        let plan = try decodeJSON(CleanupPlan.self, from: text)
        // Keep only paths that are in the summary; never let a "keep"/protected item into a plan.
        return ClaudeTasks.validatePlan(plan, wire: wire)
    }

    // MARK: - secondOpinion (Opus)

    public func secondOpinion(_ item: ItemMetadata) async throws -> AILabel {
        let key = try apiKey()
        let prompt = try ClaudeTasks.secondOpinionPrompt(item, home: home)
        let body: JSONValue = [
            "model": .string(ClaudeModel.opus.rawValue),
            "max_tokens": 8000,
            "output_config": ["effort": "medium", "format": MessagesAPI.jsonSchemaFormat(ClaudeSchemas.aiLabel)],
            "system": MessagesAPI.system(ClaudePrompts.secondOpinion),
            "messages": [["role": "user", "content": [MessagesAPI.textBlock(prompt)]]],
        ]
        let message = try await send(body, model: .opus, key: key, timeout: 300)
        let label = try decodeJSON(AILabel.self, from: message.text)
        return ClaudeTasks.finalizeSecondOpinion(label, item: item) // path from the input; capped at review
    }

    // MARK: - Transport

    private func apiKey() throws -> String {
        guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ClaudeError.missingAPIKey
        }
        return key
    }

    /// A non-2xx HTTP response, before mapping to `ClaudeError`.
    private struct HTTPFailure: Error {
        let status: Int
        let retryAfter: TimeInterval?
        let errorType: String?
        let message: String?

        init(status: Int, headers: HTTPURLResponse, body: Data) {
            self.status = status
            retryAfter = headers.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: body)
            errorType = envelope?.error?.type
            message = envelope?.error?.message
        }

        var isRetryable: Bool { status == 408 || status == 529 || (500 ... 599).contains(status) || errorType == "overloaded_error" }

        var mapped: ClaudeError {
            switch status {
            case 401: return .invalidAPIKey
            case 429: return .rateLimited(retryAfter: retryAfter)
            case 503, 529: return .overloaded
            default:
                if errorType == "overloaded_error" { return .overloaded }
                return .badResponse("HTTP \(status)" + (message.map { ": \($0)" } ?? ""))
            }
        }
    }

    /// Runs `attempt`, retrying retryable HTTP failures with exponential backoff, and maps errors.
    private func withRetries<T>(_ attempt: () async throws -> T) async throws -> T {
        var retries = 0
        while true {
            do {
                return try await attempt()
            } catch let failure as HTTPFailure {
                guard failure.isRetryable, retries < Self.maxRetries else { throw failure.mapped }
                var delay = retryBaseDelay * (1 << retries)
                if let after = failure.retryAfter { delay = max(delay, .seconds(min(after, 30))) }
                retries += 1
                try await Task.sleep(for: delay)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw ClaudeError.network(error.localizedDescription)
            }
        }
    }

    /// Non-streaming request. Checks stop_reason before returning; records usage.
    private func send(_ body: JSONValue, model: ClaudeModel, key: String, timeout: TimeInterval) async throws -> APIMessage {
        let request = MessagesAPI.urlRequest(body: try body.encoded(), apiKey: key, timeout: timeout)
        let message: APIMessage = try await withRetries {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse("Not an HTTP response") }
            guard http.statusCode == 200 else { throw HTTPFailure(status: http.statusCode, headers: http, body: data) }
            do {
                return try JSONDecoder().decode(APIMessage.self, from: data)
            } catch {
                throw ClaudeError.badResponse("Couldn't read the response")
            }
        }
        record(message.usage, model: model)
        try checkStopReason(message.stop_reason, details: message.stop_details)
        return message
    }

    /// Streaming request: calls `onText` for each text delta. Retries only before the stream opens.
    /// Throws on `error` events and on refusal / max_tokens stop reasons; records usage either way.
    private func stream(_ body: JSONValue, model: ClaudeModel, key: String, timeout: TimeInterval,
                        onText: (String) -> Void) async throws {
        let request = MessagesAPI.urlRequest(body: try body.encoded(), apiKey: key, timeout: timeout)
        let bytes: URLSession.AsyncBytes = try await withRetries {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse("Not an HTTP response") }
            guard http.statusCode == 200 else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 64_000 { break }
                }
                throw HTTPFailure(status: http.statusCode, headers: http, body: data)
            }
            return bytes
        }

        var accumulator = StreamAccumulator()
        defer { if accumulator.sawMessageStart { record(accumulator.usage, model: model) } }
        do {
            try await consumeSSE(bytes, into: &accumulator, onText: onText)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ClaudeError.network(error.localizedDescription)
        }
        try checkStopReason(accumulator.stopReason, details: accumulator.stopDetails)
        guard accumulator.finished || accumulator.stopReason != nil else {
            throw ClaudeError.network("The connection closed before Claude finished.")
        }
    }

    private func record(_ u: APIUsage?, model: ClaudeModel) {
        guard let u else { return }
        usage.record(model: model, inputTokens: u.input_tokens ?? 0, outputTokens: u.output_tokens ?? 0,
                     cacheReadTokens: u.cache_read_input_tokens ?? 0, cacheWriteTokens: u.cache_creation_input_tokens ?? 0)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw ClaudeError.badResponse("Claude's answer wasn't in the expected format.")
        }
    }
}

/// Feeds a byte stream through the SSE parser into the accumulator.
func consumeSSE<S: AsyncSequence>(_ bytes: S, into accumulator: inout StreamAccumulator,
                                  onText: (String) -> Void) async throws where S.Element == UInt8 {
    var splitter = LineSplitter()
    var parser = SSEParser()
    for try await byte in bytes {
        guard let line = splitter.append(byte) else { continue }
        if let message = parser.feed(line: line), let text = try accumulator.handle(message) { onText(text) }
        if accumulator.finished { break }
    }
    if let line = splitter.finish(), let message = parser.feed(line: line), let text = try accumulator.handle(message) {
        onText(text)
    }
    if let message = parser.finish(), let text = try accumulator.handle(message) { onText(text) }
}
