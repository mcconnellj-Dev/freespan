import Darwin
import Foundation
import Testing
@testable import FreespanKit

@Suite("Open files snapshot")
struct OpenFilesTests {
    @Test func findsAFileThisProcessHoldsOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("freespan-openfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("held.db")
        try Data("x".utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let snapshot = OpenFilesSnapshot.capture()
        let users = snapshot.users(of: dir.path)
        #expect(users.contains { $0.pid == getpid() }, "pids: \(users.map(\.pid))")
        #expect(snapshot.users(of: file.path).contains { $0.pid == getpid() })
        // The temp dir lives under /private/var/folders; the /var spelling matches too.
        let varSpelling = dir.path.hasPrefix("/private/") ? String(dir.path.dropFirst("/private".count)) : "/private" + dir.path
        #expect(snapshot.users(of: varSpelling).contains { $0.pid == getpid() })
        #expect(snapshot.stats.inspected > 0 && snapshot.stats.fileDescriptors > 0)

        try handle.close()
        let after = OpenFilesSnapshot.capture()
        #expect(!after.users(of: dir.path).contains { $0.pid == getpid() })
    }

    @Test func pathBoundaries() {
        let snapshot = OpenFilesSnapshot(processes: [
            OpenFileProcess(pid: 10, name: "a", executablePath: nil, openPaths: ["/tmp/a/file"]),
            OpenFileProcess(pid: 11, name: "ab", executablePath: nil, openPaths: ["/tmp/ab"]),
            OpenFileProcess(pid: 12, name: "dash", executablePath: nil, openPaths: ["/tmp/a-b/x"]),
            OpenFileProcess(pid: 13, name: "case", executablePath: nil, openPaths: ["/Users/Me/Library/Caches/Google/Chrome/x"]),
        ])
        #expect(snapshot.pids(using: "/tmp/a") == [10])
        #expect(snapshot.pids(using: "/tmp/a/") == [10])
        #expect(snapshot.pids(using: "/tmp/a/file") == [10])
        #expect(snapshot.pids(using: "/tmp/a/file2").isEmpty)
        #expect(snapshot.pids(using: "/tmp/ab") == [11])
        #expect(snapshot.pids(using: "/tmp/a-b") == [12])
        #expect(snapshot.pids(using: "/tmp") == [10, 11, 12])
        #expect(snapshot.pids(using: "/tmp/b").isEmpty)
        #expect(snapshot.pids(using: "/users/me/library/caches/google") == [13])
        #expect(snapshot.pids(using: "relative/path").isEmpty)
        #expect(snapshot.paths == ["/tmp/a/file", "/tmp/a-b/x", "/tmp/ab", "/Users/Me/Library/Caches/Google/Chrome/x"]
            .sorted { $0.lowercased().utf8.lexicographicallyPrecedes($1.lowercased().utf8) })
    }

    @Test func privateAndDataVolumeAliases() {
        let snapshot = OpenFilesSnapshot(processes: [
            OpenFileProcess(pid: 20, name: "p", executablePath: nil, openPaths: ["/private/var/folders/xy/T/thing"]),
            OpenFileProcess(pid: 21, name: "d", executablePath: nil, openPaths: ["/System/Volumes/Data/Users/me/Library/Caches/x"]),
            OpenFileProcess(pid: 22, name: "t", executablePath: nil, openPaths: ["/tmp/q"]),
        ])
        #expect(snapshot.pids(using: "/var/folders/xy") == [20])
        #expect(snapshot.pids(using: "/private/var/folders/xy/T") == [20])
        #expect(snapshot.pids(using: "/Users/me/Library/Caches") == [21])
        #expect(snapshot.pids(using: "/System/Volumes/Data/Users/me") == [21])
        #expect(snapshot.pids(using: "/private/tmp") == [22])
        #expect(snapshot.pids(using: "/privatefoo").isEmpty)
        #expect(OpenFilesSnapshot.canonical("/private/varnish") == "/private/varnish")
        #expect(OpenFilesSnapshot.canonical("/private/var/../etc/hosts") == "/private/etc/hosts".replacingOccurrences(of: "/private", with: ""))
    }

    @Test func helperResolvesToOuterApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(OpenFilesSnapshot.outermostAppPath(in: helper) == "/Applications/Google Chrome.app")
        #expect(OpenFilesSnapshot.outermostAppPath(in: "/Applications/Slack.app/Contents/MacOS/Slack") == "/Applications/Slack.app")
        #expect(OpenFilesSnapshot.outermostAppPath(in: "/usr/local/bin/node") == nil)
        #expect(OpenFilesSnapshot.outermostAppPath(in: "/Users/me/.app/bin/tool") == nil)
        #expect(OpenFilesSnapshot.outermostAppPath(in: "relative/Foo.app/x") == nil)
    }

    @Test func groupsHelpersUnderTheirApp() {
        let users = [
            OpenFileUser(pid: 3, processName: "Google Chrome Helper (Renderer)", executablePath: nil,
                         appBundleID: "com.google.Chrome", appName: "Google Chrome", appPath: "/Applications/Google Chrome.app"),
            OpenFileUser(pid: 1, processName: "Google Chrome", executablePath: nil,
                         appBundleID: "com.google.Chrome", appName: "Google Chrome", appPath: "/Applications/Google Chrome.app"),
            OpenFileUser(pid: 9, processName: "node", executablePath: nil, appBundleID: nil, appName: nil, appPath: nil),
            OpenFileUser(pid: 5, processName: "Slack", executablePath: nil,
                         appBundleID: "com.tinyspeck.slackmacgap", appName: "Slack", appPath: "/Applications/Slack.app"),
        ]
        let apps = BlockingApp.group(users)
        #expect(apps.map(\.name) == ["Google Chrome", "Slack", "node"])
        #expect(apps[0].pids == [1, 3])
        #expect(apps[2].bundleID == nil && !apps[2].isApp)
    }
}

/// Real snapshot of this Mac. Only runs when FREESPAN_PROBE=1. Read-only: never signals anything.
@Suite("Open files – real probe", .enabled(if: ProcessInfo.processInfo.environment["FREESPAN_PROBE"] == "1"))
struct OpenFilesRealProbe {
    @Test func probe() {
        _ = OpenFilesSnapshot.capture() // warm up
        let snapshot = OpenFilesSnapshot.capture()
        let s = snapshot.stats
        print("PROBE processes=\(s.processes) inspected=\(s.inspected) fds=\(s.fileDescriptors) paths=\(snapshot.paths.count) duration=\(s.duration)")
        let caches = NSHomeDirectory() + "/Library/Caches"
        let apps = BlockingApp.group(snapshot.users(of: caches))
        print("PROBE caches held by: " + apps.map { "\($0.name)\($0.isApp ? "" : " (process)")" }.joined(separator: ", "))
        #expect(s.duration < .seconds(1))
    }
}
