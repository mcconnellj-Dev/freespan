import Foundation

/// Path and scan-tree helpers shared by `AppInventory` and `SpaceBreakdown`.
enum AppPaths {
    /// True when `path` is `ancestor` or inside it (lexical, case-sensitive like the scan tree).
    static func isInside(_ path: String, _ ancestor: String) -> Bool {
        if path == ancestor { return true }
        if ancestor == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(ancestor) && path.dropFirst(ancestor.count).first == "/"
    }

    /// True when `path` is strictly inside `ancestor`.
    static func isStrictlyInside(_ path: String, _ ancestor: String) -> Bool {
        path != ancestor && isInside(path, ancestor)
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    /// The node at `path` in the tree rooted at `root`, or nil when the tree doesn't reach it.
    static func node(at path: String, in root: FileNode) -> FileNode? {
        guard let target = ProtectedPaths.normalize(path) else { return nil }
        if target == root.path { return root }
        guard isStrictlyInside(target, root.path) else { return nil }
        let rest = root.path == "/" ? target.dropFirst() : target.dropFirst(root.path.count + 1)
        var node = root
        for comp in rest.split(separator: "/", omittingEmptySubsequences: true) {
            guard node.kind == .directory else { return nil }
            let name = String(comp)
            let expected = join(node.path, name)
            guard let next = node.children.first(where: { $0.kind != .smallFiles && $0.path == expected })
                ?? node.children.first(where: { $0.kind != .smallFiles && $0.path.lowercased() == expected.lowercased() })
            else { return nil }
            node = next
        }
        return node
    }

    /// Children of `node` keyed by lowercased name (no `.smallFiles`).
    static func childIndex(_ node: FileNode?) -> [String: FileNode] {
        guard let node else { return [:] }
        var out: [String: FileNode] = [:]
        for c in node.children where c.kind != .smallFiles {
            out[(c.path as NSString).lastPathComponent.lowercased()] = c
        }
        return out
    }

    /// Outermost paths of `items` (path, bytes), with nested items' bytes added to their outermost ancestor.
    static func outermost(_ items: [(path: String, bytes: Int64)]) -> [(path: String, bytes: Int64)] {
        let sorted = items.sorted { $0.path.count < $1.path.count }
        var roots: [(path: String, bytes: Int64)] = []
        for item in sorted {
            if let i = roots.firstIndex(where: { isInside(item.path, $0.path) }) {
                roots[i].bytes += item.bytes
            } else {
                roots.append(item)
            }
        }
        return roots
    }
}

/// Findings sorted by path, for "everything inside this folder" queries.
struct FindingIndex {
    let sorted: [Finding]

    init(_ findings: [Finding]) {
        sorted = findings.sorted { $0.path < $1.path }
    }

    /// Findings at `path` or inside it.
    func within(_ path: String) -> [Finding] {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].path < path { lo = mid + 1 } else { hi = mid }
        }
        var out: [Finding] = []
        var i = lo
        while i < sorted.count, sorted[i].path.hasPrefix(path) {
            if AppPaths.isInside(sorted[i].path, path) { out.append(sorted[i]) }
            i += 1
        }
        return out
    }

    func exact(_ path: String) -> Finding? {
        within(path).first { $0.path == path }
    }

    /// Bytes each finding holds on its own: rule findings never overlap, so they count as-is; identified
    /// (heuristic/AI) folders can contain rule findings, whose bytes are subtracted.
    func exclusiveBytes(_ f: Finding) -> Int64 {
        guard f.classification.source != .rule else { return f.size }
        let inner = within(f.path).filter { $0.path != f.path && $0.classification.source == .rule }
        return max(0, f.size - inner.reduce(0) { $0 + $1.size })
    }
}
