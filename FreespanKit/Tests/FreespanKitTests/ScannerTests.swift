import Foundation
import Testing
@testable import FreespanKit

@Suite("Scanner", .serialized)
struct ScannerTests {
    // MARK: Fixture

    /// ~6 MB tree in the temp dir. Deleted by `cleanup()`.
    struct Fixture {
        let root: URL

        static func make() throws -> Fixture {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appending(path: "freespan-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
            func write(_ rel: String, bytes: Int) throws {
                let url = root.appending(path: rel)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Non-zero, non-repeating-ish content so nothing is sparse or trivially compressible.
                var data = Data(count: bytes)
                data.withUnsafeMutableBytes { buf in
                    var x: UInt32 = 2_463_534_242
                    for i in 0..<buf.count {
                        x ^= x << 13; x ^= x >> 17; x ^= x << 5
                        buf[i] = UInt8(truncatingIfNeeded: x)
                    }
                }
                try data.write(to: url)
            }
            try write("big.bin", bytes: 2_000_000)
            try write("readme.txt", bytes: 1_000)
            for name in ["a", "b", "c", "d", "e"] { try write("small/\(name).txt", bytes: 3_000) }
            try write("links/orig.bin", bytes: 1_500_000)
            try fm.createDirectory(at: root.appending(path: "links2"), withIntermediateDirectories: true)
            try fm.linkItem(at: root.appending(path: "links/orig.bin"), to: root.appending(path: "links2/hard.bin"))
            try fm.createSymbolicLink(at: root.appending(path: "big-link"), withDestinationURL: root.appending(path: "big.bin"))
            try fm.createSymbolicLink(at: root.appending(path: "dir-link"), withDestinationURL: root.appending(path: "nested"))
            try write("Foo.app/Contents/Info.plist", bytes: 500)
            try write("Foo.app/Contents/MacOS/Foo", bytes: 1_200_000)
            try write("nested/deeper/x.bin", bytes: 1_100_000)
            try fm.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
            return Fixture(root: root)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func scanResult(_ root: URL, options: ScanOptions = ScanOptions()) async throws -> (ScanResult, [ScanEvent]) {
        var events: [ScanEvent] = []
        for try await event in DiskScanner(options: options).scan(root: root) { events.append(event) }
        guard case .finished(let result)? = events.last else {
            Issue.record("last event was not .finished")
            throw CancellationError()
        }
        return (result, events)
    }

    static func allNodes(_ node: FileNode) -> [FileNode] {
        var out: [FileNode] = []
        var stack = [node]
        while let n = stack.popLast() {
            out.append(n)
            stack.append(contentsOf: n.children)
        }
        return out
    }

    static func duBytes(_ url: URL) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let kb = Int64(text.split(separator: "\t").first ?? "0") ?? 0
        return kb * 1024
    }

    // MARK: Tests

    @Test func treeSizesMatchDuAndStructure() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        let (result, _) = try await Self.scanResult(fixture.root)
        let root = result.root
        let nodes = Self.allNodes(root)
        let du = try Self.duBytes(fixture.root)

        // Total matches du (du also counts hard links once and doesn't follow symlinks).
        #expect(abs(root.size - du) <= 64 * 1024, "scanner \(root.size) vs du \(du)")
        // Sum of top-level children equals the root.
        #expect(root.children.reduce(0) { $0 + $1.size } == root.size)

        // Hard link pair counted once: exactly one of the two names is a big file node.
        let linkNodes = nodes.filter { $0.kind == .file && ($0.name == "orig.bin" || $0.name == "hard.bin") }
        #expect(linkNodes.count == 1)
        #expect(root.size < 2_000_000 + 1_500_000 * 2 + 1_200_000 + 1_100_000)

        // Small files aggregated.
        let small = try #require(root.children.first { $0.name == "small" })
        #expect(small.kind == .directory)
        #expect(small.children.count == 1)
        let agg = try #require(small.children.first)
        #expect(agg.kind == .smallFiles)
        #expect(agg.name == "Small files")
        #expect(agg.itemCount == 5)
        #expect(agg.path == small.path)
        #expect(agg.size >= 5 * 3_000)

        // Root-level small file also aggregated; big file gets its own node.
        let big = try #require(root.children.first { $0.name == "big.bin" })
        #expect(big.kind == .file)
        #expect(big.size >= 2_000_000)
        #expect(big.path == fixture.root.appending(path: "big.bin").path)
        #expect(root.children.contains { $0.kind == .smallFiles && $0.itemCount == 1 })

        // Package leaf.
        let app = try #require(root.children.first { $0.name == "Foo.app" })
        #expect(app.kind == .package)
        #expect(app.children.isEmpty)
        #expect(app.itemCount == 2)
        #expect(app.size >= 1_200_000)

        // Symlinks are neither nodes nor counted.
        #expect(!nodes.contains { $0.name == "big-link" || $0.name == "dir-link" })
        #expect(root.itemCount == 1 + 1 + 5 + 2 + 2 + 1) // big, readme, small×5, links×2, app×2, x.bin

        // Nested big file, and directory dates are the max of descendants.
        let nested = try #require(root.children.first { $0.name == "nested" })
        let x = try #require(Self.allNodes(nested).first { $0.name == "x.bin" })
        #expect(nested.modified == x.modified)

        // Empty dir kept, size 0, dates from itself.
        let empty = try #require(root.children.first { $0.name == "empty" })
        #expect(empty.size == 0 && empty.children.isEmpty && empty.modified != nil)

        // Every directory's children sorted by size descending.
        for node in nodes where !node.children.isEmpty {
            #expect(zip(node.children, node.children.dropFirst()).allSatisfy { $0.size >= $1.size })
        }
        // Unique IDs.
        #expect(Set(nodes.map(\.id)).count == nodes.count)
        #expect(result.volume.totalBytes > 0)
        #expect(result.inaccessiblePaths.isEmpty)
    }

    @Test func thresholdControlsIndividualNodes() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        var options = ScanOptions()
        options.individualFileThreshold = 1_000
        let (result, _) = try await Self.scanResult(fixture.root, options: options)
        let small = try #require(result.root.children.first { $0.name == "small" })
        #expect(small.children.count == 5)
        #expect(small.children.allSatisfy { $0.kind == .file })
    }

    @Test func excludedPathsAreSkipped() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        var options = ScanOptions()
        options.excludedPaths = [fixture.root.appending(path: "nested").path, fixture.root.appending(path: "big.bin").path]
        let (result, _) = try await Self.scanResult(fixture.root, options: options)
        #expect(!result.root.children.contains { $0.name == "nested" || $0.name == "big.bin" })
    }

    @Test func unreadableDirectoryIsRecordedAndScanContinues() async throws {
        let fixture = try Fixture.make()
        let locked = fixture.root.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 10).write(to: locked.appending(path: "secret"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            fixture.cleanup()
        }
        let (result, _) = try await Self.scanResult(fixture.root)
        #expect(result.inaccessiblePaths == [locked.path])
        #expect(result.root.children.contains { $0.name == "big.bin" })
    }

    @Test func missingRootThrows() async {
        let missing = FileManager.default.temporaryDirectory.appending(path: "freespan-missing-\(UUID().uuidString)")
        await #expect(throws: (any Error).self) {
            for try await _ in DiskScanner().scan(root: missing) {}
        }
    }

    @Test func progressThenExactlyOneFinished() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let (_, events) = try await Self.scanResult(fixture.root)
        let finishedCount = events.filter { if case .finished = $0 { true } else { false } }.count
        #expect(finishedCount == 1)
        #expect(events.dropLast().allSatisfy { if case .progress = $0 { true } else { false } })
        #expect(events.count >= 2, "expected at least one progress event")
    }

    @Test func cancellationStopsPromptly() async throws {
        // A big, always-readable tree that takes well over a second to walk.
        let root = URL(fileURLWithPath: "/System/Library")
        let start = ContinuousClock.now
        let task = Task { () -> (sawProgress: Bool, sawFinished: Bool) in
            var sawProgress = false
            var sawFinished = false
            for try await event in DiskScanner().scan(root: root) {
                switch event {
                case .progress: sawProgress = true
                case .finished: sawFinished = true
                }
                if sawProgress { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return (sawProgress, sawFinished)
        }
        let outcome = try await task.value
        #expect(outcome.sawProgress)
        #expect(!outcome.sawFinished)
        // Worker threads exit shortly after.
        let deadline = ContinuousClock.now + .seconds(3)
        while ScanEngine.liveWorkers.load(ordering: .relaxed) > 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ScanEngine.liveWorkers.load(ordering: .relaxed) == 0)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func wholeDiskPathMapping() {
        #expect(ScanPaths.displayPath(forReal: "/System/Volumes/Data") == "/")
        #expect(ScanPaths.displayPath(forReal: "/System/Volumes/Data/") == "/")
        #expect(ScanPaths.displayPath(forReal: "/System/Volumes/Data/Users/alex") == "/Users/alex")
        #expect(ScanPaths.displayPath(forReal: "/System/Volumes/DataX/foo") == "/System/Volumes/DataX/foo")
        #expect(ScanPaths.displayPath(forReal: "/Users/alex") == "/Users/alex")
        #expect(ScanPaths.isWholeDisk("/System/Volumes/Data"))
        #expect(!ScanPaths.isWholeDisk("/Users/alex"))
        #expect(ScanPaths.join("/", "Users") == "/Users")
        #expect(ScanPaths.join("/Users", "alex") == "/Users/alex")
        let ex = ExclusionList(["/Users/alex/Library/"])
        #expect(ex.contains("/Users/alex/Library"))
        #expect(ex.contains("/Users/alex/Library/Caches"))
        #expect(!ex.contains("/Users/alex/LibraryX"))
    }

    @Test func volumeInfoForHome() throws {
        let info = try DiskScanner.volumeInfo(for: URL(fileURLWithPath: NSHomeDirectory()))
        #expect(info.totalBytes > 0)
        #expect(info.availableBytes > 0 && info.availableBytes < info.totalBytes)
        #expect(!info.name.isEmpty)
    }

    @Test func cacheRoundTripAndGarbage() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let dir = FileManager.default.temporaryDirectory.appending(path: "freespan-cache-\(UUID().uuidString)/nested")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let cache = ScanCache(directory: dir)

        #expect(try cache.load() == nil)
        let (result, _) = try await Self.scanResult(fixture.root)
        try cache.save(result)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "last-scan.json.lzfse").path))
        let loaded = try #require(try cache.load())
        #expect(loaded.root.size == result.root.size)
        #expect(Self.allNodes(loaded.root).map(\.path) == Self.allNodes(result.root).map(\.path))
        #expect(Self.allNodes(loaded.root).map(\.id) == Self.allNodes(result.root).map(\.id))
        #expect(loaded.volume == result.volume)
        #expect(loaded.scannedAt == result.scannedAt)

        try Data("not a scan".utf8).write(to: dir.appending(path: "last-scan.json.lzfse"))
        #expect(try cache.load() == nil)
        // Valid LZFSE, wrong JSON shape.
        let wrong = try (Data(#"{"hello":1}"#.utf8) as NSData).compressed(using: .lzfse) as Data
        try wrong.write(to: dir.appending(path: "last-scan.json.lzfse"))
        #expect(try cache.load() == nil)

        try cache.clear()
        try cache.clear() // idempotent
        #expect(try cache.load() == nil)
    }
}

@Suite("Scanner perf")
struct ScannerPerfTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FREESPAN_PERF"] != nil))
    func perfHome() async throws {
        let path = ProcessInfo.processInfo.environment["FREESPAN_PERF_ROOT"] ?? NSHomeDirectory()
        var progressEvents = 0
        var result: ScanResult?
        for try await event in DiskScanner().scan(root: URL(fileURLWithPath: path)) {
            switch event {
            case .progress: progressEvents += 1
            case .finished(let r): result = r
            }
        }
        let r = try #require(result)
        var nodes = 0
        var stack = [r.root]
        while let n = stack.popLast() { nodes += 1; stack.append(contentsOf: n.children) }
        let gb = Double(r.root.size) / 1e9
        print("""
        PERF root=\(path) files=\(r.root.itemCount) total=\(r.root.size) (\(String(format: "%.2f", gb)) GB) \
        duration=\(String(format: "%.2f", r.duration))s nodes=\(nodes) inaccessible=\(r.inaccessiblePaths.count) \
        progressEvents=\(progressEvents)
        """)
        for p in r.inaccessiblePaths.prefix(10) { print("PERF inaccessible: \(p)") }
        for c in r.root.children.prefix(8) { print("PERF child \(c.name) \(c.size)") }
    }
}
