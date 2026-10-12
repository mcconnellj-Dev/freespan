import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// The parallel walker behind `DiskScanner.scan(root:)`.
///
/// Design:
/// - A fixed pool of worker threads (2× active cores, since the work is mostly blocking syscalls) pulls
///   directories from a shared LIFO stack. LIFO keeps the walk roughly depth-first, so few directories are
///   in flight at once and memory stays small.
/// - Each directory is read with one `getattrlistbulk` loop (see `DirectoryReader`). Small files never
///   allocate anything: only directories and files ≥ the threshold get a name `String` and a `FileNode`.
/// - The tree is assembled bottom-up: a `DirState` counts outstanding subdirectories; the worker that
///   finishes the last child finalizes the parent (iteratively, no recursion), all the way to the root.
///
/// Sizing notes:
/// - Sizes are allocated bytes (`ATTR_FILE_ALLOCSIZE`, i.e. `totalFileAllocatedSize`, all forks).
/// - Hard links (link count > 1) are counted once per (device, inode) across the whole scan; later
///   sightings still count as items but add 0 bytes.
/// - LIMITATION: APFS clones (`cp -c`, Finder duplicate) share blocks but have distinct inodes, and there is
///   no cheap per-file API to detect shared extents, so cloned data is counted once per clone. Totals can
///   therefore exceed the volume's real usage when many clones exist (same as `du`).
/// - Symlinks are never followed and contribute nothing.
final class ScanEngine: Sendable {
    /// Number of worker threads currently alive across all engines (for tests).
    static let liveWorkers = Atomic<Int>(0)

    private let rootReal: String
    private let rootURL: URL
    private let rootDevice: Int32
    private let rootState: DirState
    private let threshold: Int64
    private let stayOnVolume: Bool
    private let exclusions: ExclusionList
    private let continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation
    private let workerCount: Int
    private let startedAt: Date
    private let startNanos: UInt64

    private let stack = Mutex<[DirState]>([])
    private let available = DispatchSemaphore(value: 0)
    private let stopped = Atomic<Bool>(false)
    private let nextID = Atomic<UInt64>(1)
    private let filesSeen = Atomic<Int>(0)
    private let bytesSeen = Atomic<Int64>(0)
    private let lastProgressNanos = Atomic<UInt64>(0)
    private let hardLinks = Mutex<Set<InodeKey>>([])
    private let inaccessible = Mutex<[String]>([])
    private let packageExtensions = Mutex<[String: Bool]>([:])

    static let maxInaccessible = 1000
    static let progressIntervalNanos: UInt64 = 100_000_000

    init(root: URL, options: ScanOptions, continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation) throws {
        let real = ScanPaths.normalize(root.path(percentEncoded: false))
        let fd = open(real, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var st = stat()
        let statResult = fstat(fd, &st)
        let statErrno = errno
        close(fd)
        guard statResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: statErrno) ?? .EIO) }

        let display = ScanPaths.displayPath(forReal: real)
        let name: String
        if display == "/" {
            name = ScanPaths.isWholeDisk(real)
                ? ((try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? nil)
                    ?? ScanPaths.wholeDiskName
                : "/"
        } else {
            name = (display as NSString).lastPathComponent
        }

        rootReal = real
        rootURL = URL(fileURLWithPath: real, isDirectory: true)
        rootDevice = st.st_dev
        threshold = max(1, options.individualFileThreshold)
        stayOnVolume = options.stayOnVolume
        exclusions = ExclusionList(options.excludedPaths)
        self.continuation = continuation
        workerCount = min(64, max(4, ProcessInfo.processInfo.activeProcessorCount * 2))
        startedAt = Date()
        startNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        rootState = DirState(
            parent: nil, realPath: real, displayPath: display, name: name,
            kind: .directory, collapsed: false,
            ownModified: Self.seconds(st.st_mtimespec), ownAccessed: Self.seconds(st.st_atimespec)
        )
    }

    // MARK: Lifecycle

    func start() {
        push([rootState])
        for i in 0..<workerCount {
            let thread = Thread { [self] in
                Self.liveWorkers.add(1, ordering: .relaxed)
                defer { Self.liveWorkers.subtract(1, ordering: .relaxed) }
                workerLoop()
            }
            thread.name = "Freespan scanner \(i)"
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// Stops all work promptly. Safe to call more than once and after completion.
    func cancel() {
        guard stopWorkers() else { return }
        continuation.finish()
    }

    /// Returns true if this call performed the stop.
    private func stopWorkers() -> Bool {
        guard stopped.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged
        else { return false }
        stack.withLock { $0.removeAll() }
        for _ in 0..<workerCount { available.signal() }
        return true
    }

    private var isStopped: Bool { stopped.load(ordering: .relaxed) }

    private func push(_ dirs: [DirState]) {
        stack.withLock { $0.append(contentsOf: dirs) }
        for _ in dirs { available.signal() }
    }

    private func workerLoop() {
        let reader = DirectoryReader()
        while true {
            available.wait()
            if isStopped { return }
            guard let dir = stack.withLock({ $0.popLast() }) else { continue }
            process(dir, reader: reader)
        }
    }

    // MARK: Per-directory work

    private func process(_ dir: DirState, reader: DirectoryReader) {
        if isStopped { return }
        let isRoot = dir.parent == nil
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (isRoot ? 0 : O_NOFOLLOW)
        let fd = open(dir.realPath, flags)
        if fd < 0 {
            let err = errno
            if isRoot { fail(err); return }
            recordInaccessible(dir.displayPath, errno: err)
            complete(dir, outcome: .dropped)
            return
        }
        if stayOnVolume && !isRoot {
            var st = stat()
            if fstat(fd, &st) == 0 && st.st_dev != rootDevice {
                close(fd)
                complete(dir, outcome: .dropped)
                return
            }
        }

        var size: Int64 = 0
        var itemCount = 0
        var maxModified = -Double.infinity
        var maxAccessed = -Double.infinity
        var smallSize: Int64 = 0
        var smallCount = 0
        var smallModified = -Double.infinity
        var smallAccessed = -Double.infinity
        var fileNodes: [FileNode] = []
        var subdirs: [DirState] = []
        let collapsed = dir.collapsed
        let threshold = threshold

        let readError = reader.read(fd: fd, shouldStop: { self.isStopped }) { entry in
            switch entry.type {
            case .file:
                if !exclusions.isEmpty {
                    let name = entry.nameString
                    if exclusions.contains(ScanPaths.join(dir.realPath, name))
                        || exclusions.contains(ScanPaths.join(dir.displayPath, name)) { return }
                }
                var bytes = entry.allocatedSize
                if entry.linkCount > 1 {
                    let key = InodeKey(device: entry.device, inode: entry.fileID)
                    let isNew = hardLinks.withLock { $0.insert(key).inserted }
                    if !isNew { bytes = 0 }
                }
                size += bytes
                itemCount += 1
                maxModified = max(maxModified, entry.modified)
                maxAccessed = max(maxAccessed, entry.accessed)
                if !collapsed && bytes >= threshold {
                    let name = entry.nameString
                    fileNodes.append(FileNode(
                        id: makeID(), name: name, path: ScanPaths.join(dir.displayPath, name), kind: .file,
                        size: bytes, itemCount: 1,
                        modified: Self.date(entry.modified), accessed: Self.date(entry.accessed), children: []
                    ))
                } else {
                    smallSize += bytes
                    smallCount += 1
                    smallModified = max(smallModified, entry.modified)
                    smallAccessed = max(smallAccessed, entry.accessed)
                }
            case .directory:
                let name = entry.nameString
                let childReal = ScanPaths.join(dir.realPath, name)
                let childDisplay = ScanPaths.join(dir.displayPath, name)
                if !exclusions.isEmpty && (exclusions.contains(childReal) || exclusions.contains(childDisplay)) {
                    return
                }
                let isPackage = !collapsed && isPackageName(entry.name)
                subdirs.append(DirState(
                    parent: dir, realPath: childReal, displayPath: childDisplay, name: name,
                    kind: isPackage ? .package : .directory, collapsed: collapsed || isPackage,
                    ownModified: entry.modified, ownAccessed: entry.accessed
                ))
            case .symlink, .other:
                break
            }
        }
        close(fd)

        if readError != 0 {
            if isRoot && itemCount == 0 && subdirs.isEmpty { fail(readError); return }
            recordInaccessible(dir.displayPath, errno: readError)
        }
        if isStopped { return }

        filesSeen.add(itemCount, ordering: .relaxed)
        bytesSeen.add(size, ordering: .relaxed)
        // Emit before handing children to other workers so no progress can follow `.finished`.
        maybeEmitProgress(path: dir.displayPath)

        let pending = subdirs.count
        dir.acc.withLock { acc in
            acc.size += size
            acc.itemCount += itemCount
            acc.maxModified = max(acc.maxModified, maxModified)
            acc.maxAccessed = max(acc.maxAccessed, maxAccessed)
            acc.smallSize = smallSize
            acc.smallCount = smallCount
            acc.smallModified = smallModified
            acc.smallAccessed = smallAccessed
            acc.children.append(contentsOf: fileNodes)
            acc.pending = pending
        }
        if pending == 0 {
            complete(dir, outcome: .finished)
        } else {
            push(subdirs)
        }
    }

    // MARK: Bottom-up assembly

    private enum Outcome { case finished, dropped }

    private struct Summary {
        var node: FileNode?
        var size: Int64
        var itemCount: Int
        var maxModified: Double
        var maxAccessed: Double
    }

    /// Finalizes `dir` and walks up while each parent's last outstanding child has just finished.
    private func complete(_ dir: DirState, outcome: Outcome) {
        var current = dir
        var summary: Summary? = outcome == .finished ? finalize(dir) : nil
        while true {
            if isStopped { return }
            guard let parent = current.parent else {
                if let node = summary?.node { finish(root: node) }
                return
            }
            let parentDone = parent.acc.withLock { acc -> Bool in
                if let s = summary {
                    acc.size += s.size
                    acc.itemCount += s.itemCount
                    acc.maxModified = max(acc.maxModified, s.maxModified)
                    acc.maxAccessed = max(acc.maxAccessed, s.maxAccessed)
                    if let node = s.node { acc.children.append(node) }
                }
                acc.pending -= 1
                return acc.pending == 0
            }
            guard parentDone else { return }
            current = parent
            summary = finalize(parent)
        }
    }

    private func finalize(_ dir: DirState) -> Summary {
        var acc = dir.acc.withLock { acc -> Accumulator in
            let snapshot = acc
            acc.children = [] // release; the node now owns them
            return snapshot
        }
        let modified = acc.maxModified > -.infinity ? acc.maxModified : dir.ownModified
        let accessed = acc.maxAccessed > -.infinity ? acc.maxAccessed : dir.ownAccessed

        let node: FileNode?
        switch (dir.kind, dir.collapsed) {
        case (.package, _):
            node = FileNode(
                id: makeID(), name: dir.name, path: dir.displayPath, kind: .package,
                size: acc.size, itemCount: acc.itemCount,
                modified: Self.date(modified), accessed: Self.date(accessed), children: []
            )
        case (_, true):
            node = nil // inside a package: only totals propagate
        default:
            if acc.smallCount > 0 {
                acc.children.append(FileNode(
                    id: makeID(), name: "Small files", path: dir.displayPath, kind: .smallFiles,
                    size: acc.smallSize, itemCount: acc.smallCount,
                    modified: Self.date(acc.smallModified), accessed: Self.date(acc.smallAccessed), children: []
                ))
            }
            acc.children.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
            node = FileNode(
                id: makeID(), name: dir.name, path: dir.displayPath, kind: .directory,
                size: acc.size, itemCount: acc.itemCount,
                modified: Self.date(modified), accessed: Self.date(accessed), children: acc.children
            )
        }
        return Summary(node: node, size: acc.size, itemCount: acc.itemCount, maxModified: modified, maxAccessed: accessed)
    }

    private func finish(root: FileNode) {
        guard stopWorkers() else { return }
        let volume = (try? DiskScanner.volumeInfo(for: rootURL))
            ?? VolumeInfo(name: root.name, totalBytes: 0, availableBytes: 0)
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startNanos) / 1e9
        let result = ScanResult(
            root: root, volume: volume, scannedAt: startedAt, duration: elapsed,
            inaccessiblePaths: inaccessible.withLock { $0 }
        )
        continuation.yield(.finished(result))
        continuation.finish()
    }

    private func fail(_ err: Int32) {
        guard stopWorkers() else { return }
        continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO))
    }

    // MARK: Helpers

    private func maybeEmitProgress(path: String) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let last = lastProgressNanos.load(ordering: .relaxed)
        guard last == 0 || now &- last >= Self.progressIntervalNanos else { return }
        guard lastProgressNanos.compareExchange(expected: last, desired: now, ordering: .relaxed).exchanged else { return }
        continuation.yield(.progress(ScanProgress(
            filesSeen: filesSeen.load(ordering: .relaxed),
            bytesSeen: bytesSeen.load(ordering: .relaxed),
            currentPath: path
        )))
    }

    private func recordInaccessible(_ path: String, errno err: Int32) {
        inaccessible.withLock { list in
            if list.count < Self.maxInaccessible { list.append(path) }
        }
    }

    @inline(__always)
    private func makeID() -> UInt64 {
        nextID.add(1, ordering: .relaxed).oldValue
    }

    /// Package-ness is decided by the extension's declared type (what Finder/`URL.isPackage` use), cached per
    /// extension so LaunchServices is consulted once per distinct extension.
    private func isPackageName(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < name.count - 1 else { return false }
        let ext = String(decoding: UnsafeBufferPointer(rebasing: name[(dot + 1)...]), as: UTF8.self).lowercased()
        if let cached = packageExtensions.withLock({ $0[ext] }) { return cached }
        let result = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        packageExtensions.withLock { $0[ext] = result }
        return result
    }

    private static func seconds(_ ts: timespec) -> Double {
        Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    private static func date(_ seconds: Double) -> Date? {
        seconds > -.infinity ? Date(timeIntervalSince1970: seconds) : nil
    }
}

struct InodeKey: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

struct Accumulator: Sendable {
    var size: Int64 = 0
    var itemCount = 0
    var maxModified = -Double.infinity
    var maxAccessed = -Double.infinity
    var smallSize: Int64 = 0
    var smallCount = 0
    var smallModified = -Double.infinity
    var smallAccessed = -Double.infinity
    var children: [FileNode] = []
    var pending = 0
}

/// A directory that has been discovered but whose subtree is not finished yet.
final class DirState: Sendable {
    let parent: DirState?
    let realPath: String
    let displayPath: String
    let name: String
    /// `.directory` or `.package`.
    let kind: FileNode.Kind
    /// True for a package and everything inside it: sizes propagate, nodes are not kept.
    let collapsed: Bool
    let ownModified: Double
    let ownAccessed: Double
    let acc = Mutex(Accumulator())

    init(
        parent: DirState?, realPath: String, displayPath: String, name: String,
        kind: FileNode.Kind, collapsed: Bool, ownModified: Double, ownAccessed: Double
    ) {
        self.parent = parent
        self.realPath = realPath
        self.displayPath = displayPath
        self.name = name
        self.kind = kind
        self.collapsed = collapsed
        self.ownModified = ownModified
        self.ownAccessed = ownAccessed
    }
}
