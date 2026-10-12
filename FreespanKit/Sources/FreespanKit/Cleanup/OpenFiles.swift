import AppKit
import Darwin
import Foundation

/// A process that has a file open, with the app it belongs to (helpers resolve to their outer app).
public struct OpenFileUser: Sendable, Hashable {
    public let pid: Int32
    /// The executable's file name ("Google Chrome Helper (Renderer)", "node").
    public let processName: String
    public let executablePath: String?
    /// The outermost app bundle this process belongs to, when there is one.
    public let appBundleID: String?
    public let appName: String?
    public let appPath: String?

    public init(pid: Int32, processName: String, executablePath: String?,
                appBundleID: String?, appName: String?, appPath: String?) {
        self.pid = pid
        self.processName = processName
        self.executablePath = executablePath
        self.appBundleID = appBundleID
        self.appName = appName
        self.appPath = appPath
    }
}

/// An app (or background process) holding files open inside something Freespan wants to move to the Trash.
public struct BlockingApp: Sendable, Hashable, Identifiable {
    public let bundleID: String?
    public let name: String
    public let pids: [Int32]

    public var id: String { bundleID ?? "process:\(name)" }
    /// True when this is a real app bundle (not a bare command-line or background process).
    public var isApp: Bool { bundleID != nil }
    /// An app the person could reasonably quit: an app bundle that isn't part of macOS itself. Apple's own
    /// bundles only count when they're everyday apps (Safari, Mail, Music, Photos, …), never Finder, System
    /// Settings, Spotlight or the many `com.apple.*` helpers and agents. The app layer additionally requires the
    /// app to be running as a regular (Dock) app.
    public var isQuittableApp: Bool {
        guard let id = bundleID?.lowercased(), !Self.systemBundleIDs.contains(id) else { return false }
        return !id.hasPrefix("com.apple.") || Self.userFacingAppleBundleIDs.contains(id)
    }

    /// macOS components Freespan never suggests quitting (lowercased bundle IDs).
    public static let systemBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.windowserver", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.spotlight", "com.apple.wallpaper.agent", "com.apple.coreservices.uiagent",
        "com.apple.systempreferences",
    ]

    /// Apple apps people open and quit themselves (lowercased bundle IDs). Every other `com.apple.*` bundle is
    /// treated as part of macOS.
    public static let userFacingAppleBundleIDs: Set<String> = [
        "com.apple.safari", "com.apple.mail", "com.apple.music", "com.apple.photos", "com.apple.preview",
        "com.apple.notes", "com.apple.ical", "com.apple.reminders", "com.apple.maps", "com.apple.tv",
        "com.apple.podcasts", "com.apple.ibooksx", "com.apple.mobilesms", "com.apple.facetime",
        "com.apple.textedit", "com.apple.quicktimeplayerx", "com.apple.terminal", "com.apple.dt.xcode",
        "com.apple.iwork.pages", "com.apple.iwork.numbers", "com.apple.iwork.keynote", "com.apple.imovieapp",
        "com.apple.garageband10", "com.apple.finalcut", "com.apple.logic10", "com.apple.freeform",
        "com.apple.iphonesimulator", "com.apple.dt.instruments",
    ]

    public init(bundleID: String?, name: String, pids: [Int32]) {
        self.bundleID = bundleID
        self.name = name
        self.pids = pids
    }

    /// Groups processes by the app they belong to. Apps first, then background processes, each by name.
    public static func group(_ users: [OpenFileUser]) -> [BlockingApp] {
        var order: [String] = []
        var byKey: [String: (bundleID: String?, name: String, pids: Set<Int32>)] = [:]
        for user in users {
            let key = user.appBundleID ?? user.appPath ?? "process:\(user.processName)"
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = (user.appBundleID, user.appName ?? user.processName, [])
            }
            byKey[key]?.pids.insert(user.pid)
        }
        return order.compactMap { key in
            byKey[key].map { BlockingApp(bundleID: $0.bundleID, name: $0.name, pids: $0.pids.sorted()) }
        }
        .sorted { a, b in
            if a.isApp != b.isApp { return a.isApp }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// What is holding a finding open, and how much of it has to stay behind.
public struct InUseStatus: Sendable, Hashable {
    /// Apps and processes with files open inside the finding.
    public let apps: [BlockingApp]
    /// True when only some files inside a folder are open: the rest can still go to the Trash.
    public let isPartial: Bool
    /// Bytes that stay behind because they're open (the whole item when not partial).
    public let busyBytes: Int64

    public init(apps: [BlockingApp], isPartial: Bool, busyBytes: Int64) {
        self.apps = apps
        self.isPartial = isPartial
        self.busyBytes = busyBytes
    }
}

/// One process's open files, as captured from the kernel (or built by hand in tests).
public struct OpenFileProcess: Sendable, Hashable {
    public let pid: Int32
    public let name: String
    public let executablePath: String?
    /// Open vnode paths, the working directory, and the executable itself.
    public let openPaths: [String]

    public init(pid: Int32, name: String, executablePath: String?, openPaths: [String]) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.openPaths = openPaths
    }
}

/// Which of the current user's processes have files open, and where. Take one per cleanup, not per item.
///
/// Lookups are path-boundary aware (`/tmp/a` doesn't match `/tmp/ab`), case-insensitive, and treat
/// `/private/var` ≡ `/var`, `/private/tmp` ≡ `/tmp` and `/System/Volumes/Data/x` ≡ `/x`.
public struct OpenFilesSnapshot: Sendable {
    public struct Stats: Sendable {
        /// Processes owned by the user.
        public var processes = 0
        /// Processes whose files could be listed.
        public var inspected = 0
        /// Open vnode file descriptors seen.
        public var fileDescriptors = 0
        public var duration: Duration = .zero
    }

    private struct Entry: Sendable {
        let key: String
        let path: String
        let pid: Int32
    }

    private let entries: [Entry]
    private let processes: [Int32: OpenFileProcess]
    public private(set) var stats = Stats()

    /// Every open path (canonical form), sorted, without duplicates.
    public var paths: [String] {
        var out: [String] = []
        var last: String?
        for e in entries where e.key != last {
            out.append(e.path)
            last = e.key
        }
        return out
    }

    public static let empty = OpenFilesSnapshot(processes: [])

    public init(processes: [OpenFileProcess]) {
        var entries: [Entry] = []
        var byPID: [Int32: OpenFileProcess] = [:]
        for process in processes {
            byPID[process.pid] = process
            for raw in process.openPaths {
                guard let (path, key) = Self.canonicalWithKey(raw) else { continue }
                entries.append(Entry(key: key, path: path, pid: process.pid))
            }
        }
        entries.sort { $0.key < $1.key }
        self.entries = entries
        self.processes = byPID
    }

    /// The processes with something open at `path` or inside it, one per process, with their apps resolved.
    public func users(of path: String) -> [OpenFileUser] {
        pids(using: path).compactMap { pid in processes[pid].map(Self.resolve) }
    }

    /// Process IDs with something open at or inside `path`, sorted.
    public func pids(using path: String) -> [Int32] {
        guard let key = Self.canonicalWithKey(path)?.key else { return [] }
        let isRoot = key == "/"
        let inside = key + "/"
        // Lower bound: first entry whose key is >= `key`. Every entry with `key` as a prefix follows it.
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].key < key { low = mid + 1 } else { high = mid }
        }
        var found: Set<Int32> = []
        var i = low
        while i < entries.count {
            let candidate = entries[i].key
            guard candidate.hasPrefix(key) else { break }
            // Same path, or inside it ("/tmp/a/x" but not "/tmp/ab").
            if isRoot || candidate == key || candidate.hasPrefix(inside) {
                found.insert(entries[i].pid)
            }
            i += 1
        }
        return found.sorted()
    }

    // MARK: - Path normalization

    /// Absolute, `.`/`..`-free path with the firmlink and `/private` aliases folded. Nil for relative paths.
    public static func canonical(_ path: String) -> String? {
        canonicalWithKey(path)?.path
    }

    /// `canonical(path)` and its match key: lowercased, precomposed (APFS keeps whatever Unicode form a name was
    /// created with). Keys are Strings so sorting and comparing run in the compiled standard library.
    static func canonicalWithKey(_ path: String) -> (path: String, key: String)? {
        guard let normalized = ProtectedPaths.normalize(path) else { return nil }
        let lower = normalized.precomposedStringWithCanonicalMapping.lowercased()
        var drop = 0
        if hasPathPrefix(lower, "/system/volumes/data") { drop = 20 }
        let rest = lower.dropFirst(drop)
        if hasPathPrefix(rest, "/private/var") || hasPathPrefix(rest, "/private/tmp") || hasPathPrefix(rest, "/private/etc") {
            drop += 8 // "/private"
        }
        guard drop > 0 else { return (normalized, lower) }
        let key = String(lower.dropFirst(drop))
        let display = String(normalized.dropFirst(drop)) // the dropped prefixes are ASCII: same length either way
        return key.isEmpty ? ("/", "/") : (display, key)
    }

    /// Path-boundary-aware prefix test on an already-lowercased path.
    private static func hasPathPrefix(_ path: Substring, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    private static func hasPathPrefix(_ path: String, _ prefix: String) -> Bool {
        hasPathPrefix(path[...], prefix)
    }

    // MARK: - App resolution

    /// The outermost `.app` bundle in a path ("…/Google Chrome.app/…/Helper (Renderer).app/…" → Google Chrome.app).
    public static func outermostAppPath(in path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var built = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            built += "/" + component
            if component.count > 4, component.lowercased().hasSuffix(".app") { return built }
        }
        return nil
    }

    static func resolve(_ process: OpenFileProcess) -> OpenFileUser {
        let running = NSRunningApplication(processIdentifier: process.pid)
        let candidate = running?.bundleURL?.path ?? process.executablePath
        if let appPath = candidate.flatMap(outermostAppPath(in:)), let bundle = Bundle(path: appPath) {
            return OpenFileUser(pid: process.pid, processName: process.name, executablePath: process.executablePath,
                                appBundleID: bundle.bundleIdentifier, appName: displayName(ofApp: appPath),
                                appPath: appPath)
        }
        if let running, let id = running.bundleIdentifier {
            return OpenFileUser(pid: process.pid, processName: process.name, executablePath: process.executablePath,
                                appBundleID: id, appName: running.localizedName ?? process.name,
                                appPath: running.bundleURL?.path)
        }
        return OpenFileUser(pid: process.pid, processName: process.name, executablePath: process.executablePath,
                            appBundleID: nil, appName: nil, appPath: nil)
    }

    /// The name Finder shows ("Visual Studio Code", not its CFBundleName "Code").
    static func displayName(ofApp path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: - Capture

    /// Lists every process the current user owns and what each has open. Processes that can't be inspected
    /// (another user's, or ones that exited mid-scan) are skipped silently.
    public static func capture() -> OpenFilesSnapshot {
        let clock = ContinuousClock()
        let start = clock.now
        var stats = Stats()
        var captured: [OpenFileProcess] = []

        let pids = userPIDs()
        stats.processes = pids.count
        var fds: [proc_fdinfo] = []
        var vnodeInfo = vnode_fdinfowithpath()
        let vnodeInfoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

        for pid in pids where pid > 0 {
            var paths: [String] = []

            // Executable: an app running from a folder keeps that folder in use.
            let exeLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let executable: String? = exeLength > 0 ? decode(pathBuffer, length: Int(exeLength)) : nil
            if let executable { paths.append(executable) }

            // Working directory.
            var cwd = proc_vnodepathinfo()
            let cwdSize = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, cwdSize) == cwdSize,
               let dir = string(fromPath: &cwd.pvi_cdir.vip_path), !dir.isEmpty {
                paths.append(dir)
            }

            // Open file descriptors.
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if needed <= 0 {
                if executable == nil { continue } // couldn't inspect at all
            } else {
                let capacity = Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16
                if fds.count < capacity { fds = Array(repeating: proc_fdinfo(), count: capacity) }
                let bytes = fds.withUnsafeMutableBytes { raw in
                    proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
                }
                let count = bytes > 0 ? Int(bytes) / MemoryLayout<proc_fdinfo>.stride : 0
                for i in 0 ..< count where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                    guard proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO,
                                         &vnodeInfo, vnodeInfoSize) == vnodeInfoSize else { continue }
                    // Event-only watches (O_EVTONLY, used by file watchers) don't keep anything in use.
                    if vnodeInfo.pfi.fi_openflags & UInt32(O_EVTONLY) != 0 { continue }
                    stats.fileDescriptors += 1
                    if let path = string(fromPath: &vnodeInfo.pvip.vip_path), !path.isEmpty { paths.append(path) }
                }
            }
            stats.inspected += 1
            let name = executable.map { ($0 as NSString).lastPathComponent } ?? processName(pid)
            captured.append(OpenFileProcess(pid: pid, name: name, executablePath: executable, openPaths: paths))
        }

        var snapshot = OpenFilesSnapshot(processes: captured)
        stats.duration = clock.now - start
        snapshot.stats = stats
        return snapshot
    }

    private static func userPIDs() -> [Int32] {
        let uid = getuid()
        for _ in 0 ..< 3 {
            let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
            guard needed > 0 else { return [] }
            var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.stride + 64)
            let bytes = pids.withUnsafeMutableBytes { raw in
                proc_listpids(UInt32(PROC_UID_ONLY), uid, raw.baseAddress, Int32(raw.count))
            }
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / MemoryLayout<Int32>.stride
            if count < pids.count { return Array(pids.prefix(count)).filter { $0 > 0 } }
        }
        return []
    }

    private static func processName(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? decode(buffer, length: Int(length)) : "pid \(pid)"
    }

    private static func decode(_ buffer: [CChar], length: Int) -> String {
        buffer.withUnsafeBytes { raw in
            String(decoding: UnsafeRawBufferPointer(rebasing: raw.prefix(min(length, raw.count))), as: UTF8.self)
        }
    }

    /// Reads a fixed-size C path buffer (imported as a tuple) up to its NUL.
    private static func string<T>(fromPath tuple: inout T) -> String? {
        withUnsafeBytes(of: &tuple) { raw in
            guard let base = raw.baseAddress else { return nil }
            let length = strnlen(base.assumingMemoryBound(to: CChar.self), raw.count)
            return String(decoding: UnsafeRawBufferPointer(start: base, count: length), as: UTF8.self)
        }
    }
}
