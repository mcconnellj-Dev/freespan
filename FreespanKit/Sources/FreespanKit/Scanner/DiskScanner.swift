import Foundation

/// Walks a directory tree and produces a `FileNode` tree with accurate on-disk sizes.
/// OWNER: scanner agent. Public signatures are a contract — do not change without updating callers.
///
/// Pass `/System/Volumes/Data` as the root for a whole-disk scan: node paths are then reported without that
/// prefix (`/Users/alex`, root `/` named after the boot volume) so path rules match. See `ScanEngine` for
/// the sizing rules (allocated bytes, hard links once, APFS clones not de-duplicated).
public struct DiskScanner: Sendable {
    public let options: ScanOptions

    /// Root to pass for a whole-disk scan.
    public static let wholeDiskRoot = URL(fileURLWithPath: ScanPaths.dataVolumeRoot, isDirectory: true)

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Streams progress roughly every 100 ms, then exactly one `.finished`. Cancelling the consuming task stops the scan.
    /// Throws only if the root itself cannot be opened/read; unreadable subdirectories end up in
    /// `ScanResult.inaccessiblePaths`.
    public func scan(root: URL) -> AsyncThrowingStream<ScanEvent, Error> {
        let options = options
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            do {
                let engine = try ScanEngine(root: root, options: options, continuation: continuation)
                continuation.onTermination = { _ in engine.cancel() }
                engine.start()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Capacity / available space of the volume containing `url`.
    public static func volumeInfo(for url: URL) throws -> VolumeInfo {
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeLocalizedNameKey,
        ])
        guard let total = values.volumeTotalCapacity else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        var available = values.volumeAvailableCapacityForImportantUsage ?? 0
        if available <= 0 { available = Int64(values.volumeAvailableCapacity ?? 0) }
        return VolumeInfo(
            name: values.volumeLocalizedName ?? ScanPaths.wholeDiskName,
            totalBytes: Int64(total),
            availableBytes: available
        )
    }
}
