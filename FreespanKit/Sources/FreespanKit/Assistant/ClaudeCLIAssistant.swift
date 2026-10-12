import Foundation
import Synchronization

/// `AssistantService` that runs the `claude` command-line tool, so requests use the user's Claude plan
/// instead of API credits. Personal use only.
///
/// Each request is one non-interactive run:
/// `claude -p --model <id> --output-format json --json-schema <schema> --no-session-persistence --safe-mode
///  --tools "" --strict-mcp-config --setting-sources "" --disable-slash-commands --system-prompt <prompt>`
/// with the prompt on stdin, in a scratch directory, and with `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`
/// removed from the environment so the CLI uses the subscription login rather than API billing.
/// Labels are capped at `.review` per the `AssistantService` contract.
public final class ClaudeCLIAssistant: AssistantService {
    let executable: URL
    let runner: any ProcessRunning
    let home: String
    let parentEnvironment: [String: String]
    let workingDirectory: URL

    static let labelTimeout: Duration = .seconds(90)
    static let askTimeout: Duration = .seconds(90)
    static let planTimeout: Duration = .seconds(180)
    static let secondOpinionTimeout: Duration = .seconds(180)
    static let labelChunkSize = 40
    static let maxHistoryTurns = 20

    /// Variables removed from the child environment: with either set, the CLI would bill the API instead of
    /// using the Claude plan.
    static let scrubbedEnvironment: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    public convenience init(executable: URL) {
        self.init(executable: executable, runner: SystemProcessRunner(), home: NSHomeDirectory(),
                  environment: ProcessInfo.processInfo.environment, workingDirectory: Self.scratchDirectory())
    }

    init(executable: URL, runner: any ProcessRunning, home: String, environment: [String: String], workingDirectory: URL) {
        self.executable = executable
        self.runner = runner
        self.home = home
        self.parentEnvironment = environment
        self.workingDirectory = workingDirectory
    }

    public var displayName: String { "Claude" }

    // MARK: - Locating the CLI

    /// Finds the `claude` binary (GUI apps don't inherit the shell PATH).
    public static func locateExecutable() -> URL? {
        if let cached = cachedExecutable.withLock({ $0 }), FileManager.default.isExecutableFile(atPath: cached.path) {
            return cached
        }
        let found = locateExecutable(home: NSHomeDirectory(),
                                     isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                                     shellLookup: shellLookup)
        if let found { cachedExecutable.withLock { $0 = found } }
        return found
    }

    private static let cachedExecutable = Mutex<URL?>(nil)

    /// Well-known install locations, in lookup order.
    static func candidatePaths(home: String) -> [String] {
        [
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    static func locateExecutable(home: String, isExecutable: (String) -> Bool, shellLookup: () -> String?) -> URL? {
        if let path = candidatePaths(home: home).first(where: isExecutable) {
            return URL(fileURLWithPath: path)
        }
        if let path = shellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/"), isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// `/bin/zsh -lc 'command -v claude'`, giving up after 3 seconds.
    static func shellLookup() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        // A login shell may print banners; the answer is the last absolute path.
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init).last { $0.hasPrefix("/") }
    }

    public static var availability: AssistantAvailability {
        locateExecutable() == nil
            ? .unavailable("Install Claude Code and sign in to use your Claude plan.")
            : .available
    }

    static func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FreespanClaude", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Invocation

    /// Builds the CLI arguments. Every tool, MCP server, setting source, slash command and customization is
    /// disabled: the CLI is used purely as a model endpoint on the user's plan.
    static func arguments(model: ClaudeModel, systemPrompt: String, schema: JSONValue?, effort: String?,
                          streaming: Bool) throws -> [String] {
        var args = ["-p", "--model", model.rawValue]
        if streaming {
            args += ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        } else {
            args += ["--output-format", "json"]
        }
        if let schema {
            args += ["--json-schema", String(decoding: try schema.encoded(), as: UTF8.self)]
        }
        if let effort { args += ["--effort", effort] }
        args += [
            "--no-session-persistence",
            "--safe-mode", // no CLAUDE.md, skills, plugins, hooks, MCP servers or custom agents
            "--strict-mcp-config", // and no MCP servers even from other configs
            "--setting-sources", "", // no user/project/local settings
            "--disable-slash-commands",
            "--tools", "", // no tools at all
            "--system-prompt", systemPrompt,
        ]
        return args
    }

    /// The parent environment minus the API credentials.
    static func childEnvironment(_ parent: [String: String]) -> [String: String] {
        parent.filter { !scrubbedEnvironment.contains($0.key) }
    }

    func request(model: ClaudeModel, systemPrompt: String, schema: JSONValue?, effort: String?, streaming: Bool,
                 prompt: String, timeout: Duration) throws -> ProcessRequest {
        ProcessRequest(
            executable: executable,
            arguments: try Self.arguments(model: model, systemPrompt: systemPrompt, schema: schema, effort: effort, streaming: streaming),
            environment: Self.childEnvironment(parentEnvironment),
            currentDirectory: workingDirectory,
            stdin: Data(prompt.utf8),
            timeout: timeout)
    }

    /// Runs the CLI and returns its successful result envelope, mapping every failure to `AssistantError`.
    func run(_ request: ProcessRequest, onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> CLIResultEnvelope {
        let output: ProcessOutput
        do {
            output = try await runner.run(request, onStdoutLine: onStdoutLine)
        } catch ProcessRunnerError.timedOut {
            throw AssistantError.failed("Claude didn't answer within \(request.timeout.components.seconds) seconds. Try again.")
        } catch ProcessRunnerError.launchFailed(let reason) {
            throw AssistantError.unavailable("Couldn't start Claude Code (\(reason)). Reinstall it, or choose another assistant in Settings.")
        }
        guard let envelope = CLIResultEnvelope.parse(output.stdout) else {
            if output.exitCode != 0 {
                let text = String(decoding: output.stderr, as: UTF8.self) + "\n" + String(decoding: output.stdout.suffix(2000), as: UTF8.self)
                throw Self.failure(text, apiStatus: nil)
            }
            throw AssistantError.failed("Claude Code's answer wasn't in the expected format.")
        }
        if envelope.isFailure {
            throw Self.failure(envelope.result ?? envelope.subtype ?? "", apiStatus: envelope.apiErrorStatus)
        }
        if envelope.stopReason == "refusal" { throw AssistantError.failed("Claude declined this request.") }
        return envelope
    }

    /// Maps CLI error text to a readable error.
    static func failure(_ text: String, apiStatus: Int?) -> AssistantError {
        let t = text.lowercased()
        let auth = ["not logged in", "/login", "log in", "login", "authenticat", "invalid api key", "oauth", "unauthorized", "credentials"]
        if apiStatus == 401 || apiStatus == 403 || auth.contains(where: t.contains) {
            return .unavailable("Sign in to Claude Code first: run `claude` in Terminal.")
        }
        let limit = ["usage limit", "rate limit", "limit reached", "rate_limit", "too many requests"]
        if apiStatus == 429 || limit.contains(where: t.contains) {
            return .failed("You've reached your Claude plan's usage limit for now. Try again later.")
        }
        if apiStatus == 529 || t.contains("overloaded") {
            return .failed("Claude is busy right now. Try again shortly.")
        }
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(detail.isEmpty ? "Claude Code failed without saying why." : "Claude Code reported an error: \(String(detail.prefix(300)))")
    }

    private func decode<T: Decodable>(_ type: T.Type, from envelope: CLIResultEnvelope) throws -> T {
        guard let data = envelope.structuredData, let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw AssistantError.failed("Claude's answer wasn't in the expected format.")
        }
        return value
    }

    // MARK: - label (Haiku)

    public func label(_ items: [ItemMetadata]) async throws -> [AILabel] {
        let input = ClaudeTasks.LabelInput(items, home: home)
        var labels: [AILabel] = []
        var firstError: Error?
        for chunk in input.chunks(of: Self.labelChunkSize) {
            try Task.checkCancellation()
            do {
                let req = try request(model: .haiku, systemPrompt: ClaudePrompts.label, schema: ClaudeSchemas.labels,
                                      effort: nil, streaming: false, prompt: try ClaudeTasks.labelPrompt(chunk, home: home),
                                      timeout: Self.labelTimeout)
                labels += try decode(ClaudeTasks.LabelsEnvelope.self, from: try await run(req)).labels
            } catch let error as AssistantError {
                if case .unavailable = error { throw error } // not signed in / can't launch: dooms every chunk
                firstError = firstError ?? error
            }
        }
        // Partial success is still useful; total failure throws.
        if labels.isEmpty, let firstError { throw firstError }
        return input.finalize(labels)
    }

    // MARK: - ask (Sonnet, streamed)

    public func ask(_ question: String, summary: DiskSummary, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = try ClaudeTasks.askTranscript(question, summary: summary, history: history,
                                                               maxTurns: Self.maxHistoryTurns, home: self.home)
                    let req = try self.request(model: .sonnet, systemPrompt: ClaudePrompts.ask, schema: nil, effort: "low",
                                               streaming: true, prompt: prompt, timeout: Self.askTimeout)
                    let parser = Mutex(CLIStreamParser())
                    let envelope = try await self.run(req) { line in
                        for delta in parser.withLock({ $0.feed(line) }) { continuation.yield(delta) }
                    }
                    // CLIs without partial-message support only report the final text.
                    if !parser.withLock({ $0.yieldedText }), let text = envelope.result, !text.isEmpty {
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

    // MARK: - deepCleanPlan (Opus)

    public func deepCleanPlan(_ summary: DiskSummary) async throws -> CleanupPlan {
        let wire = WireSummary(summary, home: home)
        let req = try request(model: .opus, systemPrompt: ClaudePrompts.deepCleanPlan, schema: ClaudeSchemas.cleanupPlan,
                              effort: "high", streaming: false, prompt: try ClaudeTasks.planPrompt(wire), timeout: Self.planTimeout)
        let plan = try decode(CleanupPlan.self, from: try await run(req))
        return ClaudeTasks.validatePlan(plan, wire: wire)
    }

    // MARK: - secondOpinion (Opus)

    public func secondOpinion(_ item: ItemMetadata) async throws -> AILabel {
        let req = try request(model: .opus, systemPrompt: ClaudePrompts.secondOpinion, schema: ClaudeSchemas.aiLabel,
                              effort: "medium", streaming: false, prompt: try ClaudeTasks.secondOpinionPrompt(item, home: home),
                              timeout: Self.secondOpinionTimeout)
        let label = try decode(AILabel.self, from: try await run(req))
        return ClaudeTasks.finalizeSecondOpinion(label, item: item)
    }
}

// MARK: - CLI output

/// The CLI's final `{"type":"result", ...}` object: the whole stdout for `--output-format json`, the last
/// line for `stream-json`. Observed shape (CLI 2.1.280):
/// `{"type":"result","subtype":"success","is_error":false,"result":"<text>","structured_output":{…},
///   "stop_reason":"end_turn","api_error_status":null,"terminal_reason":"completed","session_id":…,
///   "total_cost_usd":…,"usage":{…},"modelUsage":{…},"permission_denials":[],"num_turns":2,…}`
struct CLIResultEnvelope: Equatable {
    var subtype: String?
    var isError: Bool
    var result: String?
    var stopReason: String?
    var apiErrorStatus: Int?
    /// `structured_output` re-serialized, or `result` when it is JSON text.
    var structuredData: Data?

    var isFailure: Bool { isError || (subtype?.hasPrefix("error") ?? false) }

    static func parse(_ stdout: Data) -> CLIResultEnvelope? {
        if let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any], let e = from(object) {
            return e
        }
        // stream-json: one object per line; the result is last.
        let lines = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let e = from(object) {
                return e
            }
        }
        return nil
    }

    static func from(_ o: [String: Any]) -> CLIResultEnvelope? {
        guard o["type"] as? String == "result" else { return nil }
        let result = o["result"] as? String
        var structured: Data?
        if let s = o["structured_output"], !(s is NSNull), JSONSerialization.isValidJSONObject(s) {
            structured = try? JSONSerialization.data(withJSONObject: s)
        } else if let result, result.first == "{" || result.first == "[" {
            structured = Data(result.utf8)
        }
        return CLIResultEnvelope(subtype: o["subtype"] as? String, isError: o["is_error"] as? Bool ?? false,
                                 result: result, stopReason: o["stop_reason"] as? String,
                                 apiErrorStatus: (o["api_error_status"] as? NSNumber)?.intValue,
                                 structuredData: structured)
    }
}

/// Pulls text deltas out of `--output-format stream-json --include-partial-messages` lines:
/// `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}}`.
struct CLIStreamParser {
    private(set) var yieldedText = false

    mutating func feed(_ line: String) -> [String] {
        guard line.contains("text_delta"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "stream_event",
              object["parent_tool_use_id"] == nil || object["parent_tool_use_id"] is NSNull,
              let event = object["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String, !text.isEmpty
        else { return [] }
        yieldedText = true
        return [text]
    }
}
