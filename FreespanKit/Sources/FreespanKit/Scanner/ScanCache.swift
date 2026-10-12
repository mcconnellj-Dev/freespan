import Foundation

/// Persists the last scan so the app opens instantly. OWNER: scanner agent.
/// Stored as LZFSE-compressed JSON in `directory/last-scan.json.lzfse`.
public struct ScanCache: Sendable {
    public let directory: URL

    /// Defaults to ~/Library/Application Support/Freespan.
    public init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "Freespan", directoryHint: .isDirectory)
    }

    public var fileURL: URL { directory.appending(path: "last-scan.json.lzfse", directoryHint: .notDirectory) }

    public func save(_ result: ScanResult) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = try JSONEncoder().encode(result)
        let compressed = try (json as NSData).compressed(using: .lzfse) as Data
        try compressed.write(to: fileURL, options: .atomic)
    }

    /// Nil if there is no cache or it can't be decoded (e.g. written by an older format).
    public func load() throws -> ScanResult? {
        guard let compressed = try? Data(contentsOf: fileURL) else { return nil }
        guard let json = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(ScanResult.self, from: json)
    }

    public func clear() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Already clear.
        }
    }
}
