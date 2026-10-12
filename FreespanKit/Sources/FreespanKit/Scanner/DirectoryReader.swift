import Darwin

/// One entry decoded from a `getattrlistbulk(2)` buffer. Only valid inside the `read` callback:
/// `name` points into the reader's buffer.
struct RawDirEntry {
    enum ObjectType { case file, directory, symlink, other }

    var type: ObjectType
    /// UTF-8 bytes of the name, without the trailing NUL.
    var name: UnsafeBufferPointer<UInt8>
    var device: Int32
    var fileID: UInt64
    /// Seconds since 1970, or `-.infinity` when not reported.
    var modified: Double
    var accessed: Double
    var linkCount: UInt32
    /// Allocated bytes across all forks (same as `totalFileAllocatedSize`). 0 for non-files.
    var allocatedSize: Int64

    var nameString: String { String(decoding: name, as: UTF8.self) }
}

/// Reads whole directories with `getattrlistbulk(2)`, which returns name + metadata for many entries per
/// syscall and avoids creating a URL / NSString per entry. One reader per worker thread (owns its buffer).
final class DirectoryReader {
    private static let capacity = 256 * 1024
    private let buffer: UnsafeMutableRawPointer
    private var attrs: attrlist

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.capacity, alignment: 16)
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(
            UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_DEVID)
                | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_ACCTIME)
                | UInt32(ATTR_CMN_FILEID) | UInt32(ATTR_CMN_ERROR)
        )
        list.fileattr = attrgroup_t(UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE))
        attrs = list
    }

    deinit { buffer.deallocate() }

    /// Calls `body` for every entry of the open directory `fd`. Returns 0, or the `errno` that stopped reading
    /// (entries delivered before the error are still valid). `shouldStop` is polled between batches.
    func read(fd: Int32, shouldStop: () -> Bool, _ body: (inout RawDirEntry) -> Void) -> Int32 {
        let cmnError = UInt32(ATTR_CMN_ERROR)
        let cmnName = UInt32(ATTR_CMN_NAME)
        let cmnDev = UInt32(ATTR_CMN_DEVID)
        let cmnType = UInt32(ATTR_CMN_OBJTYPE)
        let cmnMod = UInt32(ATTR_CMN_MODTIME)
        let cmnAcc = UInt32(ATTR_CMN_ACCTIME)
        let cmnFileID = UInt32(ATTR_CMN_FILEID)
        let fileLinks = UInt32(ATTR_FILE_LINKCOUNT)
        let fileAlloc = UInt32(ATTR_FILE_ALLOCSIZE)
        let timespecSize = MemoryLayout<timespec>.size

        while true {
            if shouldStop() { return 0 }
            let count = getattrlistbulk(fd, &attrs, buffer, Self.capacity, 0)
            if count < 0 {
                if errno == EINTR { continue }
                return errno
            }
            if count == 0 { return 0 }

            var entryStart = buffer
            for _ in 0..<count {
                let length = Int(entryStart.load(as: UInt32.self))
                defer { entryStart += length }
                var p = entryStart + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size
                let common = UInt32(returned.commonattr)
                let fileGroup = UInt32(returned.fileattr)

                // ATTR_CMN_ERROR is packed right after the returned-attrs set, not in bit order.
                if common & cmnError != 0 {
                    let err = p.loadUnaligned(as: UInt32.self)
                    p += 4
                    if err != 0 { continue }
                }
                guard common & cmnName != 0 else { continue }
                let nameOffset = Int(p.loadUnaligned(as: Int32.self))
                let nameLength = Int(p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                let namePtr = (p + nameOffset).assumingMemoryBound(to: UInt8.self)
                p += MemoryLayout<attrreference_t>.size

                var entry = RawDirEntry(
                    type: .other,
                    name: UnsafeBufferPointer(start: namePtr, count: max(0, nameLength - 1)),
                    device: 0, fileID: 0, modified: -.infinity, accessed: -.infinity,
                    linkCount: 1, allocatedSize: 0
                )
                if common & cmnDev != 0 {
                    entry.device = p.loadUnaligned(as: Int32.self)
                    p += 4
                }
                if common & cmnType != 0 {
                    switch p.loadUnaligned(as: UInt32.self) {
                    case 1: entry.type = .file // VREG
                    case 2: entry.type = .directory // VDIR
                    case 5: entry.type = .symlink // VLNK
                    default: entry.type = .other
                    }
                    p += 4
                }
                if common & cmnMod != 0 {
                    let ts = p.loadUnaligned(as: timespec.self)
                    entry.modified = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
                    p += timespecSize
                }
                if common & cmnAcc != 0 {
                    let ts = p.loadUnaligned(as: timespec.self)
                    entry.accessed = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
                    p += timespecSize
                }
                if common & cmnFileID != 0 {
                    entry.fileID = p.loadUnaligned(as: UInt64.self)
                    p += 8
                }
                if fileGroup & fileLinks != 0 {
                    entry.linkCount = p.loadUnaligned(as: UInt32.self)
                    p += 4
                }
                if fileGroup & fileAlloc != 0 {
                    entry.allocatedSize = p.loadUnaligned(as: Int64.self)
                    p += 8
                }
                body(&entry)
            }
        }
    }
}
