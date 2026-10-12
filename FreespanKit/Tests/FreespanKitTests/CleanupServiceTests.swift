import Foundation
import Testing
@testable import FreespanKit

/// Every test runs in its own temp folder with a fake home and a fake Trash. The real Trash is never used.
@Suite("CleanupService")
struct CleanupServiceTests {
    final class Sandbox {
        let base: URL
        let home: URL
        let fakeTrash: URL
        let logURL: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("freespan-cleanup-\(UUID().uuidString)")
            home = base.appendingPathComponent("home")
            fakeTrash = base.appendingPathComponent("FakeTrash")
            logURL = base.appendingPathComponent("log/actions.json")
            for d in [home, fakeTrash, home.appendingPathComponent("Downloads"), home.appendingPathComponent(".Trash")] {
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            }
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        func service(failing: Bool = false) -> CleanupService {
            let trash = fakeTrash
            return CleanupService(logURL: logURL, home: home.path) { url in
                if failing { throw CocoaError(.fileWriteNoPermission) }
                let dest = trash.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }
        }

        @discardableResult
        func makeFile(_ rel: String, bytes: Int = 16) throws -> String {
            let url = home.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
            return url.path
        }

        func finding(_ path: String, label: SafetyLabel = .safe, size: Int64 = 16) -> Finding {
            Finding(path: path, name: (path as NSString).lastPathComponent, size: size, itemCount: 1,
                    modified: nil, accessed: nil, isDirectory: false,
                    classification: Classification(category: .downloads, label: label, title: "t", explanation: "e",
                                                   regenerates: false, source: .rule, ruleID: "r"))
        }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    }

    @Test func movesToTrashAndLogs() async throws {
        let sb = try Sandbox()
        let a = try sb.makeFile("Downloads/a.dmg", bytes: 100)
        let b = try sb.makeFile("Desktop/AppDev/site/node_modules/x.js")
        let service = sb.service()
        let report = await service.moveToTrash([sb.finding(a, size: 100), sb.finding(b, size: 16)])
        #expect(report.skipped.isEmpty, "\(report.skipped)")
        #expect(report.trashed.count == 2)
        #expect(report.bytesFreed == 116)
        #expect(!sb.exists(a) && !sb.exists(b))
        for e in report.trashed {
            #expect(sb.exists(e.trashPath))
            #expect(e.trashPath.hasPrefix(sb.fakeTrash.path))
            #expect(!e.restored)
        }
        #expect(sb.exists(sb.logURL.path))
    }

    @Test func skipsProtectedKeepAndProtectedLabels() async throws {
        let sb = try Sandbox()
        let lib = sb.home.appendingPathComponent("Library").path
        try FileManager.default.createDirectory(atPath: lib, withIntermediateDirectories: true)
        let ssh = try sb.makeFile(".ssh/id_ed25519")
        let keep = try sb.makeFile("Documents/thesis.pages")
        let prot = try sb.makeFile("Downloads/system-ish")
        let service = sb.service()
        let report = await service.moveToTrash([
            sb.finding(lib), sb.finding(ssh), sb.finding(sb.home.path),
            sb.finding(keep, label: .keep), sb.finding(prot, label: .protected),
            sb.finding("/System/Library/Kernels/kernel"), sb.finding("relative/path"),
        ])
        #expect(report.trashed.isEmpty)
        #expect(report.skipped.count == 7)
        #expect(sb.exists(lib) && sb.exists(ssh) && sb.exists(keep) && sb.exists(prot))
        let reasons = Dictionary(uniqueKeysWithValues: report.skipped.map { ($0.path, $0.reason) })
        #expect(reasons[keep]?.contains("Keep") == true)
        #expect(reasons[prot]?.contains("Protected") == true)
        #expect(reasons[lib]?.contains("Protected location") == true)
        #expect(await service.history().isEmpty)
    }

    @Test func skipsMissing() async throws {
        let sb = try Sandbox()
        let gone = sb.home.appendingPathComponent("Downloads/gone.zip").path
        let report = await sb.service().moveToTrash([sb.finding(gone)])
        #expect(report.trashed.isEmpty)
        #expect(report.skipped.first?.reason.contains("No longer there") == true)
    }

    @Test func skipsItemsAlreadyInTrash() async throws {
        let sb = try Sandbox()
        let inTrash = try sb.makeFile(".Trash/old.zip")
        let trashFolder = sb.home.appendingPathComponent(".Trash").path
        let report = await sb.service().moveToTrash([sb.finding(inTrash), sb.finding(trashFolder, label: .review)])
        #expect(report.trashed.isEmpty)
        #expect(report.skipped.count == 2)
        #expect(report.skipped.allSatisfy { $0.reason == "Already in the Trash — empty the Trash in Finder to free this space" })
        #expect(sb.exists(inTrash))
    }

    @Test func symlinkIntoProtectedFolderIsSkipped() async throws {
        let sb = try Sandbox()
        let secret = try sb.makeFile(".ssh/key")
        let link = sb.home.appendingPathComponent("Downloads/linkdir")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sb.home.appendingPathComponent(".ssh"))
        let viaLink = link.appendingPathComponent("key").path
        let report = await sb.service().moveToTrash([sb.finding(viaLink)])
        #expect(report.trashed.isEmpty)
        #expect(report.skipped.first?.reason.contains("Protected") == true)
        #expect(sb.exists(secret))
    }

    @Test func trashFailureIsReportedReadably() async throws {
        let sb = try Sandbox()
        let a = try sb.makeFile("Downloads/a.dmg")
        let report = await sb.service(failing: true).moveToTrash([sb.finding(a)])
        #expect(report.trashed.isEmpty)
        #expect(report.skipped.first?.reason.contains("permission") == true)
        #expect(sb.exists(a))
        #expect(!sb.exists(sb.logURL.path))
    }

    @Test func logPersistsAndReloadsNewestFirst() async throws {
        let sb = try Sandbox()
        let a = try sb.makeFile("Downloads/first.zip")
        let first = await sb.service().moveToTrash([sb.finding(a)])
        try await Task.sleep(for: .milliseconds(1100)) // ISO-8601 dates have 1s resolution
        let b = try sb.makeFile("Downloads/second.zip")
        let second = await sb.service().moveToTrash([sb.finding(b)])

        let reloaded = await sb.service().history()
        #expect(reloaded.map(\.id) == [second.trashed[0].id, first.trashed[0].id])
        #expect(reloaded.map(\.originalPath) == [b, a])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode([ActionLogEntry].self, from: Data(contentsOf: sb.logURL)) // plain JSON array
        #expect(raw.count == 2)
    }

    @Test func undoRestoresAndRecreatesParents() async throws {
        let sb = try Sandbox()
        let a = try sb.makeFile("Desktop/Project/build/out.bin", bytes: 64)
        let service = sb.service()
        let report = await service.moveToTrash([sb.finding(a, size: 64)])
        let entry = try #require(report.trashed.first)
        try FileManager.default.removeItem(at: sb.home.appendingPathComponent("Desktop/Project"))

        try await service.undo(entry)
        #expect(sb.exists(a))
        #expect(!sb.exists(entry.trashPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: a)).count == 64)

        // Restored state is persisted.
        let history = await sb.service().history()
        #expect(history.first?.restored == true)

        // A second undo of the same entry is rejected.
        await #expect(throws: CleanupError.alreadyRestored(a)) { try await service.undo(entry) }
    }

    @Test func undoConflicts() async throws {
        let sb = try Sandbox()
        let a = try sb.makeFile("Downloads/a.zip")
        let b = try sb.makeFile("Downloads/b.zip")
        let service = sb.service()
        let report = await service.moveToTrash([sb.finding(a), sb.finding(b)])
        #expect(report.trashed.count == 2)
        let ea = try #require(report.trashed.first { $0.originalPath == a })
        let eb = try #require(report.trashed.first { $0.originalPath == b })

        // Something new now sits at the original path.
        try sb.makeFile("Downloads/a.zip")
        await #expect(throws: CleanupError.originalPathOccupied(a)) { try await service.undo(ea) }
        #expect(sb.exists(ea.trashPath))

        // The trashed copy was emptied from the Trash.
        try FileManager.default.removeItem(atPath: eb.trashPath)
        await #expect(throws: CleanupError.trashItemMissing(b)) { try await service.undo(eb) }

        // Errors read like sentences.
        #expect(CleanupError.trashItemMissing(b).errorDescription?.contains("b.zip") == true)
        #expect(await service.history().allSatisfy { !$0.restored })
    }
}

@Suite("CleanupService – build folder markers")
struct CleanupMarkerTests {
    typealias Sandbox = CleanupServiceTests.Sandbox

    func finding(_ path: String, rule: String) -> Finding {
        Finding(path: path, name: (path as NSString).lastPathComponent, size: 16, itemCount: 1,
                modified: nil, accessed: nil, isDirectory: true,
                classification: Classification(category: .developer, label: .safe, title: "t", explanation: "e",
                                               regenerates: true, source: .rule, ruleID: rule))
    }

    @Test func nodeModulesNeedsSiblingPackageJSON() async throws {
        let sb = try Sandbox()
        try sb.makeFile("Desktop/site/package.json")
        try sb.makeFile("Desktop/site/node_modules/react/index.js")
        try sb.makeFile("Desktop/notes/node_modules/my-notes.txt")
        let real = sb.home.appendingPathComponent("Desktop/site/node_modules").path
        let fake = sb.home.appendingPathComponent("Desktop/notes/node_modules").path
        let report = await sb.service().moveToTrash([finding(real, rule: "node-modules"), finding(fake, rule: "node-modules")])
        #expect(report.trashed.map(\.originalPath) == [real])
        #expect(report.skipped.map(\.path) == [fake])
        #expect(report.skipped.first?.reason == "This folder isn't next to a package.json, so it may not be a real npm install — remove it manually if you're sure.")
        #expect(sb.exists(fake) && !sb.exists(real))
    }

    @Test func swiftBuildNeedsSiblingPackageSwift() async throws {
        let sb = try Sandbox()
        try sb.makeFile("Desktop/Pkg/Package.swift")
        try sb.makeFile("Desktop/Pkg/.build/debug/x.o")
        try sb.makeFile("Desktop/Thing/.build/important.txt")
        // A folder named Package.swift doesn't count.
        try FileManager.default.createDirectory(at: sb.home.appendingPathComponent("Desktop/Odd/Package.swift"), withIntermediateDirectories: true)
        try sb.makeFile("Desktop/Odd/.build/y")
        let real = sb.home.appendingPathComponent("Desktop/Pkg/.build").path
        let fake = sb.home.appendingPathComponent("Desktop/Thing/.build").path
        let odd = sb.home.appendingPathComponent("Desktop/Odd/.build").path
        let report = await sb.service().moveToTrash([
            finding(real, rule: "swift-build-folder"), finding(fake, rule: "swift-build-folder"), finding(odd, rule: "swift-build-folder"),
        ])
        #expect(report.trashed.map(\.originalPath) == [real])
        #expect(Set(report.skipped.map(\.path)) == [fake, odd])
        #expect(report.skipped.allSatisfy { $0.reason == "This folder isn't next to a Package.swift, so it may not be a real Swift build folder — remove it manually if you're sure." })
        #expect(sb.exists(fake) && sb.exists(odd))
    }

    @Test func otherRulesDontNeedMarkers() async throws {
        let sb = try Sandbox()
        let a = try sb.makeFile("Downloads/old.zip")
        let report = await sb.service().moveToTrash([finding(a, rule: "download-installer")])
        #expect(report.trashed.count == 1)
    }
}

@Suite("CleanupService – items in use")
struct CleanupInUseTests {
    typealias Sandbox = CleanupServiceTests.Sandbox

    static let chrome = OpenFileUser(pid: 900_001, processName: "Google Chrome Helper (Renderer)", executablePath: nil,
                                     appBundleID: "com.google.Chrome", appName: "Google Chrome",
                                     appPath: "/Applications/Google Chrome.app")

    func service(_ sb: Sandbox, holding paths: [String], calls: Counter? = nil) -> CleanupService {
        let trash = sb.fakeTrash
        let processes = [
            // Built by hand so app resolution doesn't depend on what's running; pid is fake.
            OpenFileProcess(pid: 900_001, name: "Google Chrome Helper (Renderer)",
                            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/x.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
                            openPaths: paths),
            // Freespan's own open files never block it.
            OpenFileProcess(pid: getpid(), name: "self", executablePath: nil, openPaths: [sb.home.path]),
        ]
        return CleanupService(logURL: sb.logURL, home: sb.home.path, trashOperation: { url in
            let dest = trash.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }, openFiles: {
            calls?.increment()
            return OpenFilesSnapshot(processes: processes)
        })
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test func skipsInUseAndTrashesTheRest() async throws {
        let sb = try Sandbox()
        let held = try sb.makeFile("Library/Caches/Google/Chrome/Default/Cache/data_1")
        let chromeCache = sb.home.appendingPathComponent("Library/Caches/Google").path
        let free = try sb.makeFile("Library/Caches/com.example.idle/blob")
        let freeDir = sb.home.appendingPathComponent("Library/Caches/com.example.idle").path
        let calls = Counter()
        let service = service(sb, holding: [held], calls: calls)

        let report = await service.moveToTrash([sb.finding(chromeCache), sb.finding(freeDir)])
        #expect(report.trashed.map(\.originalPath) == [freeDir])
        #expect(!sb.exists(free))
        #expect(sb.exists(held))
        let skip = try #require(report.skipped.first)
        #expect(report.skipped.count == 1)
        #expect(skip.path == chromeCache)
        #expect(skip.reason == "Google Chrome is using this right now. Quit Google Chrome, then try again.")
        let apps = try #require(skip.blockingApps)
        #expect(apps.count == 1)
        #expect(apps[0].name == "Google Chrome")
        #expect(apps[0].pids == [900_001])
        #expect(calls.count == 1) // one snapshot per cleanup, not per item
    }

    @Test func inUseReportsOnlyBlockedPaths() async throws {
        let sb = try Sandbox()
        let held = try sb.makeFile("Library/Caches/Google/Chrome/x")
        let other = try sb.makeFile("Library/Caches/Other/y")
        let map = await service(sb, holding: [held]).inUse([sb.finding(held), sb.finding(other)])
        #expect(Array(map.keys) == [held])
        #expect(map[held]?.apps.first?.bundleID != nil)
        #expect(map[held]?.isPartial == false)
    }

    @Test func reasonWording() {
        func app(_ name: String) -> BlockingApp { BlockingApp(bundleID: "id.\(name)", name: name, pids: [1]) }
        #expect(CleanupService.inUseReason([app("Slack"), app("Code")])
            == "Slack and Code are using this right now. Quit Slack and Code, then try again.")
        #expect(CleanupService.inUseReason([app("A"), app("B"), app("C")])
            == "A, B and others are using this right now. Quit them, then try again.")
        #expect(CleanupService.inUseReason([BlockingApp(bundleID: nil, name: "cloudd", pids: [2])])
            .hasPrefix("A background process (cloudd) is using this right now."))
        // Never tells people to quit Finder.
        #expect(CleanupService.inUseReason([BlockingApp(bundleID: "com.apple.finder", name: "Finder", pids: [3])])
            == "Finder is using this right now. Try again in a little while, or after restarting your Mac.")
    }

    // MARK: Partly open folders

    @Test func partlyOpenFolderMovesTheFreePartsOnly() async throws {
        let sb = try Sandbox()
        let held = try sb.makeFile("Library/Logs/app.log", bytes: 5000)
        let free = try sb.makeFile("Library/Logs/old.log", bytes: 5000)
        let freeDir = sb.home.appendingPathComponent("Library/Logs/DiagnosticReports").path
        try sb.makeFile("Library/Logs/DiagnosticReports/crash.ips", bytes: 5000)
        let heldDeep = try sb.makeFile("Library/Logs/Mixed/live.log", bytes: 5000)
        let freeDeep = try sb.makeFile("Library/Logs/Mixed/rotated.log", bytes: 5000)
        let logs = sb.home.appendingPathComponent("Library/Logs").path
        let service = service(sb, holding: [held, heldDeep])

        let report = await service.moveToTrash([sb.finding(logs, size: 25_000)])
        #expect(report.skipped.isEmpty, "\(report.skipped)")
        #expect(Set(report.trashed.map(\.originalPath)) == [free, freeDir, freeDeep])
        #expect(report.trashed.allSatisfy { $0.trashPath.hasPrefix(sb.fakeTrash.path) })
        #expect(sb.exists(logs) && sb.exists(held) && sb.exists(heldDeep))
        #expect(!sb.exists(free) && !sb.exists(freeDir) && !sb.exists(freeDeep))

        let part = try #require(report.partial.first)
        #expect(report.partial.count == 1)
        #expect(part.path == logs)
        #expect(part.movedBytes == report.bytesFreed && part.movedBytes > 0)
        #expect(part.skippedBytes > 0 && report.bytesLeftInUse == part.skippedBytes)
        #expect(part.blockingApps.first?.name == "Google Chrome")

        // Each moved part is its own log entry, so Undo puts it back.
        #expect(await service.history().count == 3)
        let entry = try #require(report.trashed.first { $0.originalPath == freeDeep })
        try await service.undo(entry)
        #expect(sb.exists(freeDeep))
    }

    @Test func partlyOpenFolderStopsAtTheDepthLimit() async throws {
        let sb = try Sandbox()
        let held = try sb.makeFile("Library/Caches/tool/a/b/c/d/held.bin")
        let deepSibling = try sb.makeFile("Library/Caches/tool/a/b/c/d/free.bin")
        let freeTop = try sb.makeFile("Library/Caches/tool/free.bin")
        let freeLevel2 = try sb.makeFile("Library/Caches/tool/a/b/free.bin")
        let tool = sb.home.appendingPathComponent("Library/Caches/tool").path
        let c = sb.home.appendingPathComponent("Library/Caches/tool/a/b/c").path
        let service = service(sb, holding: [held])

        let status = try #require(await service.inUse([sb.finding(tool, size: 1_000_000)])[tool])
        #expect(status.isPartial)
        #expect(status.busyBytes > 0 && status.busyBytes < 1_000_000)

        let report = await service.moveToTrash([sb.finding(tool)])
        #expect(Set(report.trashed.map(\.originalPath)) == [freeTop, freeLevel2])
        // `c` is three levels down: the whole thing stays, including the free file below it.
        #expect(sb.exists(c) && sb.exists(held) && sb.exists(deepSibling) && sb.exists(tool))
    }

    @Test func fullyOpenItemsAreStillSkipped() async throws {
        let sb = try Sandbox()
        let file = try sb.makeFile("Library/Caches/one.db")
        let onlyChild = try sb.makeFile("Library/Caches/solo/data")
        let solo = sb.home.appendingPathComponent("Library/Caches/solo").path
        let service = service(sb, holding: [file, onlyChild])

        let map = await service.inUse([sb.finding(file, size: 10), sb.finding(solo, size: 20)])
        #expect(map[file] == InUseStatus(apps: map[file]!.apps, isPartial: false, busyBytes: 10))
        #expect(map[solo]?.isPartial == false && map[solo]?.busyBytes == 20)

        let report = await service.moveToTrash([sb.finding(file), sb.finding(solo)])
        #expect(report.trashed.isEmpty && report.partial.isEmpty)
        #expect(Set(report.skipped.map(\.path)) == [file, solo])
        #expect(sb.exists(file) && sb.exists(onlyChild))
    }

    @Test func packagesAreNeverSplit() async throws {
        let sb = try Sandbox()
        let held = try sb.makeFile("Applications/Tool.app/Contents/MacOS/Tool")
        let free = try sb.makeFile("Applications/Tool.app/Contents/Resources/icon.icns")
        let app = sb.home.appendingPathComponent("Applications/Tool.app").path
        let report = await service(sb, holding: [held]).moveToTrash([sb.finding(app)])
        #expect(report.trashed.isEmpty && report.partial.isEmpty)
        #expect(report.skipped.first?.blockingApps != nil)
        #expect(sb.exists(free))
    }

    @Test func folderHeldOnlyAsWorkingDirectoryIsEmptiedButKept() async throws {
        let sb = try Sandbox()
        let a = try sb.makeFile("Library/Caches/cwd/a")
        let dir = sb.home.appendingPathComponent("Library/Caches/cwd").path
        let report = await service(sb, holding: [dir]).moveToTrash([sb.finding(dir)])
        #expect(report.trashed.map(\.originalPath) == [a])
        #expect(report.partial.first?.skippedBytes == 0)
        #expect(sb.exists(dir) && !sb.exists(a))
    }

    @Test func quittableAppsExcludeMacOSParts() {
        func app(_ id: String?) -> BlockingApp { BlockingApp(bundleID: id, name: "x", pids: [1]) }
        #expect(app("com.google.Chrome").isQuittableApp)
        #expect(app("com.apple.Safari").isQuittableApp)
        #expect(app("com.apple.mail").isQuittableApp)
        #expect(!app("com.apple.finder").isQuittableApp)
        #expect(!app("com.apple.Spotlight").isQuittableApp)
        #expect(!app("com.apple.systempreferences").isQuittableApp)
        #expect(!app("com.apple.WebKit.Networking").isQuittableApp)
        #expect(!app("com.apple.geod").isQuittableApp)
        #expect(!app(nil).isQuittableApp)
    }

    @Test func otherSkipReasonsNeedNoSnapshot() async throws {
        let sb = try Sandbox()
        let calls = Counter()
        let gone = sb.home.appendingPathComponent("Downloads/gone.zip").path
        let report = await service(sb, holding: [], calls: calls).moveToTrash([sb.finding(gone)])
        #expect(report.skipped.first?.blockingApps == nil)
        #expect(calls.count == 0)
    }
}
