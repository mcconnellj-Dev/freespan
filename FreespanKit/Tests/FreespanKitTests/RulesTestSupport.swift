import Foundation
@testable import FreespanKit

/// Synthetic scan trees for rule tests. No real files are touched.
enum RT {
    static let home = "/Users/test"
    static let now = Date(timeIntervalSince1970: 1_790_000_000) // fixed clock (2026)
    static let recent = now.addingTimeInterval(-86_400)
    static let old = now.addingTimeInterval(-400 * 86_400)
    static let MB: Int64 = 1_000_000
    static let GB: Int64 = 1_000_000_000

    struct Item: Sendable {
        var path: String
        var size: Int64
        var kind: FileNode.Kind = .file
        var modified: Date? = RT.recent
        var accessed: Date? = RT.recent
    }

    /// Expands a leading `~` to the test home.
    static func p(_ path: String) -> String {
        path.hasPrefix("~") ? home + path.dropFirst() : path
    }

    static func file(_ path: String, _ size: Int64, old isOld: Bool = false) -> Item {
        Item(path: p(path), size: size, kind: .file, modified: isOld ? old : recent, accessed: isOld ? old : recent)
    }

    static func dir(_ path: String, _ size: Int64, old isOld: Bool = false) -> Item {
        Item(path: p(path), size: size, kind: .directory, modified: isOld ? old : recent, accessed: isOld ? old : recent)
    }

    static func pkg(_ path: String, _ size: Int64) -> Item {
        Item(path: p(path), size: size, kind: .package)
    }

    static func small(in dirPath: String, _ size: Int64) -> Item {
        Item(path: p(dirPath) + "/<small>", size: size, kind: .smallFiles)
    }

    /// A single standalone node (for `classify`).
    static func node(_ item: Item) -> FileNode {
        let name = (item.path as NSString).lastPathComponent
        return FileNode(id: 1, name: name, path: item.path, kind: item.kind, size: item.size,
                        itemCount: 1, modified: item.modified, accessed: item.accessed, children: [])
    }

    /// Builds a tree rooted at `root` from leaf items; intermediate folders are created and sized as the sum
    /// of their children. A `.smallFiles` item's path is `<dir>/<small>` and becomes that dir's aggregate child.
    static func tree(_ items: [Item], root: String = "/") -> FileNode {
        final class Box {
            var children: [String: Box] = [:]
            var item: Item?
        }
        let top = Box()
        let rootComps = root.split(separator: "/").map(String.init)
        for item in items {
            var comps = item.path.split(separator: "/").map(String.init)
            precondition(Array(comps.prefix(rootComps.count)) == rootComps, "\(item.path) not under \(root)")
            comps.removeFirst(rootComps.count)
            var box = top
            for c in comps {
                if box.children[c] == nil { box.children[c] = Box() }
                box = box.children[c]!
            }
            box.item = item
        }
        var nextID: UInt64 = 0
        func build(_ box: Box, name: String, path: String) -> FileNode {
            nextID += 1
            let id = nextID
            if let item = box.item, box.children.isEmpty {
                let nodePath = item.kind == .smallFiles ? (path as NSString).deletingLastPathComponent : path
                return FileNode(id: id, name: item.kind == .smallFiles ? "Small files" : name, path: nodePath,
                                kind: item.kind, size: item.size, itemCount: item.kind == .file ? 1 : 10,
                                modified: item.modified, accessed: item.accessed, children: [])
            }
            let kids = box.children.map { key, child in
                build(child, name: key, path: path == "/" ? "/" + key : path + "/" + key)
            }.sorted { $0.size > $1.size }
            return FileNode(id: id, name: name, path: path, kind: .directory,
                            size: kids.reduce(0) { $0 + $1.size }, itemCount: kids.reduce(0) { $0 + $1.itemCount },
                            modified: box.item?.modified ?? recent, accessed: box.item?.accessed ?? recent, children: kids)
        }
        return build(top, name: (root as NSString).lastPathComponent, path: root)
    }

    static func engine() throws -> RuleEngine { try RuleEngine.bundled() }
}

extension FileNode {
    /// Depth-first search by path (tests only).
    func find(_ path: String) -> FileNode? {
        if self.path == path && kind != .smallFiles { return self }
        for c in children { if let f = c.find(path) { return f } }
        return nil
    }
}
