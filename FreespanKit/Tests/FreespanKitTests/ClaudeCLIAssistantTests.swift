import Foundation
import Synchronization
import Testing
@testable import FreespanKit

/// Canned process runner: records each request and replays scripted output. Never starts a process.
final class FakeProcessRunner: ProcessRunning {
    typealias Script = @Sendable (ProcessRequest, Int) throws -> ProcessOutput
    private let script: Script
    private let recorded = Mutex<[ProcessRequest]>([])

    init(_ script: @escaping Script) { self.script = script }

    var requests: [ProcessRequest] { recorded.withLock { $0 } }

    func run(_ request: ProcessRequest, onStdoutLine: (@Sendable (String) -> Void)?) async throws -> ProcessOutput {
        let index = recorded.withLock { $0.append(request); return $0.count - 1 }
        let output = try script(request, index)
        if let onStdoutLine {
            for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") { onStdoutLine(String(line)) }
        }
        return output
    }
}

enum CLIFixtures {
    static let home = "/Users/tester"
    static let workDir = URL(fileURLWithPath: "/tmp/freespan-cli-tests")
    static let env = ["PATH": "/usr/bin:/bin", "HOME": home, "ANTHROPIC_API_KEY": "sk-ant-secret",
                      "ANTHROPIC_AUTH_TOKEN": "tok-secret", "LANG": "en_US.UTF-8"]

    static func assistant(_ runner: FakeProcessRunner) -> ClaudeCLIAssistant {
        ClaudeCLIAssistant(executable: URL(fileURLWithPath: "/Users/tester/.local/bin/claude"), runner: runner,
                           home: home, environment: env, workingDirectory: workDir)
    }

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// A `--output-format json` result envelope as observed from CLI 2.1.280.
    static func envelope(structured: Any? = nil, result: String = "", isError: Bool = false, subtype: String = "success",
                         stopReason: String = "end_turn", apiStatus: Any = NSNull()) -> String {
        var o: [String: Any] = [
            "type": "result", "subtype": subtype, "is_error": isError, "result": result, "stop_reason": stopReason,
            "session_id": "bb39e0f9", "total_cost_usd": 0.0016, "num_turns": 2, "api_error_status": apiStatus,
            "terminal_reason": "completed", "permission_denials": [] as [Any],
            "usage": ["input_tokens": 1132, "output_tokens": 106],
        ]
        if let structured { o["structured_output"] = structured }
        return json(o)
    }

    static func ok(_ stdout: String) -> ProcessOutput { ProcessOutput(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data()) }

    static func labels(_ paths: [String], label: String = "safe") -> [String: Any] {
        ["labels": paths.map {
            ["path": $0, "title": "Cache", "explanation": "Regenerates.", "ownerApp": NSNull(), "regenerates": true,
             "category": "caches", "label": label] as [String: Any]
        }]
    }

    static func item(_ path: String) -> ItemMetadata {
        ItemMetadata(path: path, sizeBytes: 3_000_000_000, isDirectory: true, itemCount: 900, modified: nil, accessed: nil,
                     topChildren: ["Storage"])
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Paths in the `<items>` JSON of a label prompt.
    static func promptPaths(_ request: ProcessRequest) -> [String] {
        let prompt = String(decoding: request.stdin, as: UTF8.self)
        guard let start = prompt.range(of: "<items>\n"), let end = prompt.range(of: "\n</items>"),
              let array = try? JSONSerialization.jsonObject(with: Data(prompt[start.upperBound ..< end.lowerBound].utf8)) as? [[String: Any]]
        else { return [] }
        return array.compactMap { $0["path"] as? String }
    }
}

private typealias C = CLIFixtures

@Suite("Claude CLI assistant")
struct ClaudeCLIAssistantTests {

    // MARK: Arguments and environment

    @Test func labelInvocationShape() async throws {
        let runner = FakeProcessRunner { req, _ in C.ok(C.envelope(structured: C.labels(C.promptPaths(req)))) }
        _ = try await C.assistant(runner).label([C.item("\(C.home)/Library/Caches/com.example.mysteryapp")])

        let req = try #require(runner.requests.first)
        let args = req.arguments
        #expect(req.executable.path == "/Users/tester/.local/bin/claude")
        #expect(args.first == "-p")
        #expect(C.value(after: "--model", in: args) == "claude-haiku-4-5")
        #expect(C.value(after: "--output-format", in: args) == "json")
        #expect(args.contains("--no-session-persistence"))
        // Tools, MCP servers, settings and customizations all off.
        #expect(C.value(after: "--tools", in: args) == "")
        #expect(args.contains("--strict-mcp-config"))
        #expect(C.value(after: "--setting-sources", in: args) == "")
        #expect(args.contains("--safe-mode"))
        #expect(args.contains("--disable-slash-commands"))
        #expect(!args.contains("--effort"), "Haiku rejects effort")
        #expect(!args.contains { $0.contains("dangerously") || $0 == "--bare" })
        #expect(C.value(after: "--system-prompt", in: args) == ClaudePrompts.label)
        let schemaText = try #require(C.value(after: "--json-schema", in: args))
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(schemaText.utf8)) as? [String: Any])
        #expect((schema["required"] as? [String]) == ["labels"])
        // Prompt goes on stdin (never argv), redacted.
        let stdin = String(decoding: req.stdin, as: UTF8.self)
        #expect(stdin.contains("~/Library/Caches/com.example.mysteryapp"))
        #expect(!stdin.contains(C.home))
        #expect(!args.contains { $0.contains("mysteryapp") })
        #expect(req.currentDirectory == C.workDir)
        #expect(req.timeout == .seconds(90))
    }

    @Test func childEnvironmentDropsAPICredentials() async throws {
        let runner = FakeProcessRunner { req, _ in C.ok(C.envelope(structured: C.labels(C.promptPaths(req)))) }
        _ = try await C.assistant(runner).label([C.item("~/a")])
        let env = try #require(runner.requests.first).environment
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["HOME"] == C.home)
        #expect(env.count == C.env.count - 2)
    }

    @Test func modelsEffortsAndTimeoutsPerTask() throws {
        let a = try ClaudeCLIAssistant.arguments(model: .opus, systemPrompt: "s", schema: ClaudeSchemas.cleanupPlan, effort: "high", streaming: false)
        #expect(C.value(after: "--model", in: a) == "claude-opus-5-5")
        #expect(C.value(after: "--effort", in: a) == "high")
        let s = try ClaudeCLIAssistant.arguments(model: .sonnet, systemPrompt: "s", schema: nil, effort: "low", streaming: true)
        #expect(C.value(after: "--output-format", in: s) == "stream-json")
        #expect(s.contains("--include-partial-messages") && s.contains("--verbose"))
        #expect(!s.contains("--json-schema"))
        #expect(ClaudeCLIAssistant.planTimeout == .seconds(180))
        #expect(ClaudeCLIAssistant.askTimeout == .seconds(90))
    }

    // MARK: Post-processing

    @Test func labelsAreCappedAndInventedPathsDropped() async throws {
        let runner = FakeProcessRunner { req, _ in
            var labels = C.labels(C.promptPaths(req))["labels"] as! [[String: Any]]
            labels[1]["label"] = "protected"
            labels.append(["path": "~/Invented", "title": "x", "explanation": "x", "ownerApp": NSNull(),
                           "regenerates": false, "category": "other", "label": "keep"])
            return C.ok(C.envelope(structured: ["labels": labels]))
        }
        let items = [C.item("\(C.home)/Library/Caches/Google/Chrome"), C.item("~/b")]
        let labels = try await C.assistant(runner).label(items)
        #expect(labels.count == 2)
        #expect(labels.first { $0.path == items[0].path }?.label == .review, "safe capped to review, caller's spelling kept")
        #expect(labels.first { $0.path == "~/b" }?.label == .keep, "protected capped to keep")
    }

    @Test func labelChunksAndKeepsPartialResults() async throws {
        let runner = FakeProcessRunner { req, index in
            if index == 1 { return C.ok(C.envelope(result: "API Error: 500 Internal server error", isError: true, apiStatus: 500)) }
            return C.ok(C.envelope(structured: C.labels(C.promptPaths(req), label: "review")))
        }
        let items = (0 ..< 100).map { C.item("~/Library/Caches/app\($0)") }
        let labels = try await C.assistant(runner).label(items)
        #expect(runner.requests.count == 3)
        #expect(labels.count == 60)
    }

    @Test func secondOpinionUsesOpusAndIsCapped() async throws {
        let label: [String: Any] = ["path": "~/whatever", "title": "Old iPhone backup", "explanation": "A Finder backup.",
                                    "ownerApp": "Finder", "regenerates": false, "category": "backups", "label": "safe"]
        let stdout = C.envelope(structured: label)
        let runner = FakeProcessRunner { _, _ in C.ok(stdout) }
        let item = C.item("~/Library/Application Support/MobileSync/Backup/abc")
        let result = try await C.assistant(runner).secondOpinion(item)
        let req = try #require(runner.requests.first)
        #expect(C.value(after: "--model", in: req.arguments) == "claude-opus-5-5")
        #expect(C.value(after: "--effort", in: req.arguments) == "medium")
        #expect(result.path == item.path)
        #expect(result.label == .review)
        #expect(result.ownerApp == "Finder")
    }

    @Test func deepCleanPlanIsValidatedAgainstTheSummary() async throws {
        let plan: [String: Any] = [
            "headline": "You can safely free about 17 GB today.",
            "steps": [
                ["title": "Photos", "reasoning": "r", "paths": ["~/Pictures/Photos Library.photoslibrary"], "estimatedBytes": 13_000_000_000, "risk": "safe"],
                ["title": "Simulators", "reasoning": "r", "paths": ["~/Library/Developer/CoreSimulator/Devices"], "estimatedBytes": 11_000_000_000, "risk": "review"],
                ["title": "Device symbols", "reasoning": "r", "paths": ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Made/Up"], "estimatedBytes": 99_000_000_000, "risk": "safe"],
            ],
        ]
        let stdout = C.envelope(structured: plan)
        let runner = FakeProcessRunner { _, _ in C.ok(stdout) }
        let result = try await C.assistant(runner).deepCleanPlan(ClaudeFixtures.summary())
        let req = try #require(runner.requests.first)
        #expect(C.value(after: "--model", in: req.arguments) == "claude-opus-5-5")
        #expect(req.timeout == .seconds(180))
        #expect(result.steps.map(\.title) == ["Device symbols", "Simulators"])
        #expect(result.steps[0].estimatedBytes == 17_200_000_000)
        #expect(result.steps[0].paths == ["~/Library/Developer/Xcode/iOS DeviceSupport"])
    }

    // MARK: ask (streaming)

    @Test func askStreamsPartialMessages() async throws {
        func event(_ text: String) -> String {
            C.json(["type": "stream_event", "event": ["type": "content_block_delta", "index": 1,
                                                       "delta": ["type": "text_delta", "text": text]],
                    "session_id": "s", "parent_tool_use_id": NSNull()])
        }
        let lines = [
            C.json(["type": "system", "subtype": "init", "tools": [] as [Any], "mcp_servers": [] as [Any], "apiKeySource": "none"]),
            C.json(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "hmm"]]]),
            event("About 17 GB "), event("is safe."),
            C.json(["type": "assistant", "message": ["content": [["type": "text", "text": "About 17 GB is safe."]]]]),
            C.envelope(result: "About 17 GB is safe."),
        ]
        let runner = FakeProcessRunner { _, _ in C.ok(lines.joined(separator: "\n") + "\n") }
        var text = ""
        let history = [ChatTurn(role: .user, text: "Hi from \(C.home)/Secret"), ChatTurn(role: .assistant, text: "Hello")]
        for try await delta in C.assistant(runner).ask("What's safe to delete?", summary: ClaudeFixtures.summary(), history: history) {
            text += delta
        }
        #expect(text == "About 17 GB is safe.", "deltas only, not the duplicate final text")
        let req = try #require(runner.requests.first)
        #expect(C.value(after: "--model", in: req.arguments) == "claude-sonnet-5")
        #expect(C.value(after: "--system-prompt", in: req.arguments) == ClaudePrompts.ask)
        let stdin = String(decoding: req.stdin, as: UTF8.self)
        #expect(stdin.contains("<disk_summary>"))
        #expect(stdin.contains("User: Hi from ~/Secret"))
        #expect(stdin.hasSuffix("What's safe to delete?"))
        #expect(!stdin.contains(C.home))
    }

    @Test func askFallsBackToFinalResultWithoutPartials() async throws {
        let runner = FakeProcessRunner { _, _ in C.ok(C.envelope(result: "Whole answer.") + "\n") }
        var text = ""
        for try await delta in C.assistant(runner).ask("?", summary: ClaudeFixtures.summary(), history: []) { text += delta }
        #expect(text == "Whole answer.")
    }

    // MARK: Envelope and error mapping

    @Test func parsesTheObservedEnvelope() throws {
        let stdout = #"{"duration_api_ms":1286,"stop_reason":"tool_use","session_id":"bb39","total_cost_usd":0.00166,"usage":{"input_tokens":1132},"permission_denials":[],"terminal_reason":"completed","is_error":false,"num_turns":2,"subtype":"success","api_error_status":null,"result":"{\"word\":\"ok\"}","structured_output":{"word":"ok"},"type":"result"}"#
        let e = try #require(CLIResultEnvelope.parse(Data(stdout.utf8)))
        #expect(!e.isFailure)
        #expect(e.result == #"{"word":"ok"}"#)
        let structured = try #require(e.structuredData)
        #expect((try JSONSerialization.jsonObject(with: structured) as? [String: String]) == ["word": "ok"])
    }

    @Test func notSignedInMapsToSignInMessage() async throws {
        let runner = FakeProcessRunner { _, _ in
            C.ok(C.envelope(result: "Not logged in · Please run /login", isError: true))
        }
        await #expect(throws: AssistantError.unavailable("Sign in to Claude Code first: run `claude` in Terminal.")) {
            _ = try await C.assistant(runner).secondOpinion(C.item("~/a"))
        }
        // Sign-in problems stop labelling immediately instead of trying every chunk.
        let items = (0 ..< 100).map { C.item("~/x\($0)") }
        await #expect(throws: AssistantError.unavailable("Sign in to Claude Code first: run `claude` in Terminal.")) {
            _ = try await C.assistant(runner).label(items)
        }
        #expect(runner.requests.count == 2)
    }

    @Test func errorTextMapping() {
        #expect(ClaudeCLIAssistant.failure("Invalid API key · Please run /login", apiStatus: nil)
            == .unavailable("Sign in to Claude Code first: run `claude` in Terminal."))
        #expect(ClaudeCLIAssistant.failure("whatever", apiStatus: 401)
            == .unavailable("Sign in to Claude Code first: run `claude` in Terminal."))
        #expect(ClaudeCLIAssistant.failure("Claude AI usage limit reached|1791669600", apiStatus: nil)
            == .failed("You've reached your Claude plan's usage limit for now. Try again later."))
        #expect(ClaudeCLIAssistant.failure("API Error: 529 Overloaded", apiStatus: 529) == .failed("Claude is busy right now. Try again shortly."))
        #expect(ClaudeCLIAssistant.failure("boom", apiStatus: 500) == .failed("Claude Code reported an error: boom"))
    }

    @Test func malformedOutputIsReported() async throws {
        let runner = FakeProcessRunner { _, _ in C.ok("this is not json") }
        await #expect(throws: AssistantError.failed("Claude Code's answer wasn't in the expected format.")) {
            _ = try await C.assistant(runner).secondOpinion(C.item("~/a"))
        }
        // A success envelope whose structured output doesn't match the schema.
        let wrong = FakeProcessRunner { _, _ in C.ok(C.envelope(structured: ["word": "ok"])) }
        await #expect(throws: AssistantError.failed("Claude's answer wasn't in the expected format.")) {
            _ = try await C.assistant(wrong).secondOpinion(C.item("~/a"))
        }
        // Non-zero exit with only stderr.
        let crashed = FakeProcessRunner { _, _ in ProcessOutput(exitCode: 1, stdout: Data(), stderr: Data("Error: unknown option '--frobnicate'".utf8)) }
        await #expect(throws: AssistantError.failed("Claude Code reported an error: Error: unknown option '--frobnicate'")) {
            _ = try await C.assistant(crashed).secondOpinion(C.item("~/a"))
        }
    }

    @Test func errorSubtypeAndRefusalAreFailures() async throws {
        let maxTurns = FakeProcessRunner { _, _ in C.ok(C.envelope(subtype: "error_max_turns")) }
        await #expect(throws: AssistantError.self) { _ = try await C.assistant(maxTurns).secondOpinion(C.item("~/a")) }
        let refusal = FakeProcessRunner { _, _ in C.ok(C.envelope(structured: [:] as [String: Any], stopReason: "refusal")) }
        await #expect(throws: AssistantError.failed("Claude declined this request.")) {
            _ = try await C.assistant(refusal).secondOpinion(C.item("~/a"))
        }
    }

    @Test func runnerTimeoutBecomesReadableError() async throws {
        let runner = FakeProcessRunner { _, _ in throw ProcessRunnerError.timedOut }
        await #expect(throws: AssistantError.failed("Claude didn't answer within 180 seconds. Try again.")) {
            _ = try await C.assistant(runner).secondOpinion(C.item("~/a"))
        }
        let missing = FakeProcessRunner { _, _ in throw ProcessRunnerError.launchFailed("file not found") }
        await #expect(throws: AssistantError.self) { _ = try await C.assistant(missing).deepCleanPlan(ClaudeFixtures.summary()) }
    }

    // MARK: Locating the executable

    @Test func executableLookupOrder() {
        let home = "/Users/tester"
        #expect(ClaudeCLIAssistant.candidatePaths(home: home) == [
            "/Users/tester/.local/bin/claude", "/Users/tester/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ])
        func find(_ present: Set<String>, shell: String? = nil) -> String? {
            ClaudeCLIAssistant.locateExecutable(home: home, isExecutable: { present.contains($0) }, shellLookup: { shell })?.path
        }
        #expect(find(["/usr/local/bin/claude", "/Users/tester/.local/bin/claude"]) == "/Users/tester/.local/bin/claude")
        #expect(find(["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]) == "/opt/homebrew/bin/claude")
        #expect(find(["/Users/tester/.claude/local/claude", "/opt/homebrew/bin/claude"]) == "/Users/tester/.claude/local/claude")
        #expect(find(["/nix/bin/claude"], shell: "/nix/bin/claude\n") == "/nix/bin/claude", "falls back to the login shell")
        #expect(find([], shell: "claude not found") == nil)
        #expect(find([], shell: "/nix/bin/claude") == nil, "shell answer must be executable")
        var shellCalled = false
        _ = ClaudeCLIAssistant.locateExecutable(home: home, isExecutable: { $0 == "/usr/local/bin/claude" },
                                                shellLookup: { shellCalled = true; return nil })
        #expect(!shellCalled, "the shell is only consulted when no known location has the binary")
    }
}

// MARK: - The real process runner (local shell commands only; never `claude`)

@Suite("Process runner")
struct ProcessRunnerTests {
    static let scratch = FileManager.default.temporaryDirectory

    static func request(_ script: String, stdin: Data = Data(), timeout: Duration = .seconds(10)) -> ProcessRequest {
        ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                       environment: ["PATH": "/usr/bin:/bin"], currentDirectory: scratch, stdin: stdin, timeout: timeout)
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    static func waitForPID(_ file: URL) async throws -> Int32 {
        for _ in 0 ..< 100 {
            if let s = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    @Test func largeOutputStdinAndLinesWithoutDeadlock() async throws {
        let input = Data(String(repeating: "abcdefghij\n", count: 50_000).utf8) // 550 KB through stdin
        let lines = Mutex(0)
        let output = try await SystemProcessRunner().run(
            Self.request("cat; head -c 3000000 /dev/zero | tr '\\0' 'z'; echo; echo oops >&2", stdin: input),
            onStdoutLine: { _ in lines.withLock { $0 += 1 } })
        #expect(output.exitCode == 0)
        #expect(output.stdout.count == input.count + 3_000_001)
        #expect(String(decoding: output.stderr, as: UTF8.self) == "oops\n")
        #expect(lines.withLock { $0 } == 50_001)
    }

    @Test func nonZeroExitIsReturnedNotThrown() async throws {
        let output = try await SystemProcessRunner().run(Self.request("echo bad >&2; exit 3"), onStdoutLine: nil)
        #expect(output.exitCode == 3)
        #expect(String(decoding: output.stderr, as: UTF8.self) == "bad\n")
    }

    @Test func timeoutKillsTheProcess() async throws {
        let pidFile = Self.scratch.appendingPathComponent("freespan-timeout-\(UUID()).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ProcessRunnerError.timedOut) {
            _ = try await SystemProcessRunner().run(
                Self.request("echo $$ > '\(pidFile.path)'; exec sleep 30", timeout: .milliseconds(500)), onStdoutLine: nil)
        }
        #expect(clock.now - start < .seconds(5))
        let pid = try await Self.waitForPID(pidFile)
        var alive = true
        for _ in 0 ..< 150 where alive {
            alive = Self.isAlive(pid)
            if alive { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(!alive, "the timed-out process was killed")
    }

    @Test func cancellationKillsTheProcess() async throws {
        let pidFile = Self.scratch.appendingPathComponent("freespan-cancel-\(UUID()).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task {
            try await SystemProcessRunner().run(Self.request("echo $$ > '\(pidFile.path)'; exec sleep 30", timeout: .seconds(60)),
                                                onStdoutLine: nil)
        }
        let pid = try await Self.waitForPID(pidFile)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        var alive = true
        for _ in 0 ..< 150 where alive {
            alive = Self.isAlive(pid)
            if alive { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(!alive)
    }

    @Test func missingExecutableThrowsLaunchFailed() async {
        var req = Self.request("true")
        req.executable = URL(fileURLWithPath: "/nonexistent/claude")
        await #expect(throws: ProcessRunnerError.self) { _ = try await SystemProcessRunner().run(req, onStdoutLine: nil) }
    }
}
