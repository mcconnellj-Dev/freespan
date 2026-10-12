import Foundation
import Synchronization

/// One child-process invocation.
struct ProcessRequest: Sendable, Equatable {
    var executable: URL
    var arguments: [String]
    /// The complete child environment (not merged with the parent's).
    var environment: [String: String]
    var currentDirectory: URL
    var stdin: Data
    var timeout: Duration
}

struct ProcessOutput: Sendable, Equatable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
}

enum ProcessRunnerError: Error, Equatable {
    case launchFailed(String)
    /// The process ran past its timeout and was killed.
    case timedOut
}

/// Runs a child process. Injectable so tests never start the real `claude` binary.
protocol ProcessRunning: Sendable {
    /// Runs to completion. `onStdoutLine` gets each stdout line (without its newline) as it arrives.
    /// Throws `ProcessRunnerError.timedOut` or `CancellationError` after killing the process.
    func run(_ request: ProcessRequest, onStdoutLine: (@Sendable (String) -> Void)?) async throws -> ProcessOutput
}

/// `Process`-based runner. Reads stdout and stderr concurrently (no pipe-buffer deadlocks with large outputs),
/// writes stdin from a background queue, and kills the child on timeout or task cancellation.
struct SystemProcessRunner: ProcessRunning {
    /// Stop buffering output beyond this (the child keeps running; the excess is discarded).
    static let maxOutputBytes = 32 * 1024 * 1024
    /// After the child exits, how long to wait for its pipes to drain (a grandchild may hold them open).
    static let drainGrace: TimeInterval = 1

    func run(_ request: ProcessRequest, onStdoutLine: (@Sendable (String) -> Void)?) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectory
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Writing to a pipe whose reader exited must not raise SIGPIPE in the app.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let run = RunState(onStdoutLine: onStdoutLine)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            run.received(data, stream: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            run.received(data, stream: .stderr)
        }
        process.terminationHandler = { p in
            run.exited(p.terminationStatus)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGrace) { run.finishAfterGrace() }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                guard run.attach(continuation) else { return } // cancelled before we started
                do {
                    try process.run()
                } catch {
                    run.fail(ProcessRunnerError.launchFailed(error.localizedDescription))
                    return
                }
                let writer = stdinPipe.fileHandleForWriting
                let input = request.stdin
                DispatchQueue.global().async {
                    try? writer.write(contentsOf: input)
                    try? writer.close()
                }
                let seconds = Double(request.timeout.components.seconds) + Double(request.timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    if run.fail(ProcessRunnerError.timedOut) { Self.kill(process) }
                }
            }
        } onCancel: {
            if run.fail(CancellationError()) { Self.kill(process) }
        }
    }

    /// SIGTERM, then SIGKILL if it hasn't exited two seconds later.
    static func kill(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }
}

/// Shared state between the pipe handlers, the termination handler, the timeout and cancellation.
/// Resumes the continuation exactly once.
private final class RunState: Sendable {
    enum Stream { case stdout, stderr }

    private struct State {
        var continuation: CheckedContinuation<ProcessOutput, Error>?
        var done = false
        var pendingError: Error?
        var stdout = Data()
        var stderr = Data()
        var lineBuffer = Data()
        var stdoutEOF = false
        var stderrEOF = false
        var exitCode: Int32?
    }

    private let state = Mutex(State())
    private let onStdoutLine: (@Sendable (String) -> Void)?

    init(onStdoutLine: (@Sendable (String) -> Void)?) {
        self.onStdoutLine = onStdoutLine
    }

    /// Returns false (after resuming with the pending error) if the run was already failed/cancelled.
    func attach(_ continuation: CheckedContinuation<ProcessOutput, Error>) -> Bool {
        let pending: Error? = state.withLock { s in
            if s.done { return s.pendingError ?? CancellationError() }
            s.continuation = continuation
            return nil
        }
        if let pending {
            continuation.resume(throwing: pending)
            return false
        }
        return true
    }

    func received(_ data: Data, stream: Stream) {
        let lines: [String] = state.withLock { s in
            switch stream {
            case .stderr:
                if data.isEmpty { s.stderrEOF = true } else if s.stderr.count < SystemProcessRunner.maxOutputBytes { s.stderr.append(data) }
                return []
            case .stdout:
                if data.isEmpty {
                    s.stdoutEOF = true
                    defer { s.lineBuffer.removeAll() }
                    return s.lineBuffer.isEmpty ? [] : [String(decoding: s.lineBuffer, as: UTF8.self)]
                }
                guard s.stdout.count < SystemProcessRunner.maxOutputBytes else { return [] }
                s.stdout.append(data)
                guard onStdoutLine != nil else { return [] }
                s.lineBuffer.append(data)
                var lines: [String] = []
                while let newline = s.lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    var line = s.lineBuffer[s.lineBuffer.startIndex ..< newline]
                    if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                    lines.append(String(decoding: line, as: UTF8.self))
                    s.lineBuffer.removeSubrange(s.lineBuffer.startIndex ... newline)
                }
                return lines
            }
        }
        if let onStdoutLine { for line in lines { onStdoutLine(line) } }
        finishIfComplete()
    }

    func exited(_ code: Int32) {
        state.withLock { $0.exitCode = code }
        finishIfComplete()
    }

    /// Finishes with whatever output arrived if the pipes still haven't closed after the grace period.
    func finishAfterGrace() {
        let (continuation, output) = state.withLock { s -> (CheckedContinuation<ProcessOutput, Error>?, ProcessOutput?) in
            guard !s.done, let code = s.exitCode else { return (nil, nil) }
            s.done = true
            defer { s.continuation = nil }
            return (s.continuation, ProcessOutput(exitCode: code, stdout: s.stdout, stderr: s.stderr))
        }
        if let continuation, let output { continuation.resume(returning: output) }
    }

    private func finishIfComplete() {
        let (continuation, output) = state.withLock { s -> (CheckedContinuation<ProcessOutput, Error>?, ProcessOutput?) in
            guard !s.done, let code = s.exitCode, s.stdoutEOF, s.stderrEOF else { return (nil, nil) }
            s.done = true
            defer { s.continuation = nil }
            return (s.continuation, ProcessOutput(exitCode: code, stdout: s.stdout, stderr: s.stderr))
        }
        if let continuation, let output { continuation.resume(returning: output) }
    }

    /// Fails the run if it hasn't finished. Returns true if this call failed it (caller should kill the child).
    @discardableResult
    func fail(_ error: Error) -> Bool {
        let (won, continuation) = state.withLock { s -> (Bool, CheckedContinuation<ProcessOutput, Error>?) in
            guard !s.done else { return (false, nil) }
            s.done = true
            s.pendingError = error
            defer { s.continuation = nil }
            return (true, s.continuation)
        }
        continuation?.resume(throwing: error)
        return won
    }
}
