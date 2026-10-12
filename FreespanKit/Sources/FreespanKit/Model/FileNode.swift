import Foundation

/// One node in a scanned disk tree. Immutable once built; the scanner builds trees bottom-up.
///
/// To keep memory bounded on multi-million-file disks, the scanner does not keep a node for every file:
/// files smaller than `ScanOptions.individualFileThreshold` are rolled into a single `.smallFiles`
/// child per directory, and bundles (`.app`, `.photoslibrary`, …) are measured but kept as leaves.
public final class FileNode: Identifiable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        case directory
        case file
        /// A macOS package/bundle (e.g. `.app`, `.photoslibrary`). Sized fully, children not kept.
        case package
        /// Aggregate of every small file directly inside the parent directory.
        case smallFiles
    }

    /// Unique within one scan.
    public let id: UInt64
    public let name: String
    /// Absolute path. For `.smallFiles` this is the parent directory's path.
    public let path: String
    public let kind: Kind
    /// Allocated bytes on disk, including all descendants, with hard links / clones counted once.
    public let size: Int64
    /// Number of regular files at or beneath this node (1 for a file).
    public let itemCount: Int
    public let modified: Date?
    public let accessed: Date?
    /// Sorted by `size`, largest first. Empty for non-directories.
    public let children: [FileNode]

    public init(
        id: UInt64,
        name: String,
        path: String,
        kind: Kind,
        size: Int64,
        itemCount: Int,
        modified: Date?,
        accessed: Date?,
        children: [FileNode]
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.itemCount = itemCount
        self.modified = modified
        self.accessed = accessed
        self.children = children
    }

    public var isContainer: Bool { kind == .directory }
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct VolumeInfo: Sendable, Codable, Hashable {
    public let name: String
    public let totalBytes: Int64
    /// What Finder reports as available (includes purgeable space).
    public let availableBytes: Int64
    public var usedBytes: Int64 { totalBytes - availableBytes }

    public init(name: String, totalBytes: Int64, availableBytes: Int64) {
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

public struct ScanResult: Sendable, Codable {
    public let root: FileNode
    public let volume: VolumeInfo
    public let scannedAt: Date
    public let duration: TimeInterval
    /// Directories that could not be read (usually missing Full Disk Access).
    public let inaccessiblePaths: [String]

    public init(root: FileNode, volume: VolumeInfo, scannedAt: Date, duration: TimeInterval, inaccessiblePaths: [String]) {
        self.root = root
        self.volume = volume
        self.scannedAt = scannedAt
        self.duration = duration
        self.inaccessiblePaths = inaccessiblePaths
    }
}

public struct ScanOptions: Sendable {
    /// Files at or above this size get their own node; smaller ones are aggregated.
    public var individualFileThreshold: Int64 = 1_000_000
    /// Never cross onto other volumes (external drives, network mounts, /System/Volumes/*).
    public var stayOnVolume: Bool = true
    /// Absolute path prefixes to skip entirely.
    public var excludedPaths: [String] = []

    public init() {}
}

public struct ScanProgress: Sendable {
    public let filesSeen: Int
    public let bytesSeen: Int64
    public let currentPath: String

    public init(filesSeen: Int, bytesSeen: Int64, currentPath: String) {
        self.filesSeen = filesSeen
        self.bytesSeen = bytesSeen
        self.currentPath = currentPath
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case finished(ScanResult)
}
