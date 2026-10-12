import SwiftUI

/// Where one tile sits in the bento grid, in grid cells.
struct BentoSlot: Equatable {
    var column: Int
    var row: Int
    var width: Int
    var height: Int
}

/// Deterministic bento packing: bigger share, bigger tile, and every row filled edge to edge.
///
/// - The largest tile is 2×2 (when there are enough tiles to sit beside it), the next one starts 2 wide,
///   tiles with at least 10% of the total start 2 wide, the rest 1 wide; every other tile is 1 row high.
/// - Tiles go into rows in order (rows beside the 2×2 tile have 4 free columns, the rest have all of them).
///   When the next tile doesn't fit, the row is closed and its tiles are widened, largest first, until it's full.
///   So there are never holes, and the order (largest first) reads left to right, top to bottom.
enum BentoGrid {
    static func layout(_ weights: [Int64], columns: Int = 6) -> [BentoSlot] {
        guard !weights.isEmpty, columns >= 2 else { return [] }
        if weights.count == 1 { return [BentoSlot(column: 0, row: 0, width: columns, height: 2)] }
        let total = max(weights.reduce(0) { $0 + max($1, 0) }, 1)
        let base = weights.enumerated().map { index, bytes -> Int in
            if index <= 1 { return 2 }
            return Double(max(bytes, 0)) / Double(total) >= 0.10 ? 2 : 1
        }
        if weights.count == 2 {
            let share = Double(max(weights[0], 0)) / Double(total)
            let first = min(max(Int((share * Double(columns)).rounded()), 2), columns - 2)
            return [BentoSlot(column: 0, row: 0, width: first, height: 2),
                    BentoSlot(column: first, row: 0, width: columns - first, height: 2)]
        }
        // Big tile 2×2 if the tiles after it fill at least the two rows beside it; otherwise everything is one row high.
        let rest = Array(base.dropFirst())
        let besideRows = rows(rest, capacities: { $0 < 2 ? columns - 2 : columns }, sizes: Array(weights.dropFirst()))
        if besideRows.count >= 2 {
            var slots = [BentoSlot(column: 0, row: 0, width: 2, height: 2)]
            for (rowIndex, row) in besideRows.enumerated() {
                var x = rowIndex < 2 ? 2 : 0
                for (_, width) in row {
                    slots.append(BentoSlot(column: x, row: rowIndex, width: width, height: 1))
                    x += width
                }
            }
            return slots
        }
        let flat = rows(base, capacities: { _ in columns }, sizes: weights)
        var slots: [BentoSlot] = []
        for (rowIndex, row) in flat.enumerated() {
            var x = 0
            for (_, width) in row {
                slots.append(BentoSlot(column: x, row: rowIndex, width: width, height: 1))
                x += width
            }
        }
        return slots
    }

    /// Breaks tiles (in order) into rows, then widens each row's tiles (largest first) until it is full.
    /// Returns rows of (tile index, width).
    private static func rows(_ widths: [Int], capacities: (Int) -> Int, sizes: [Int64]) -> [[(Int, Int)]] {
        var result: [[(Int, Int)]] = []
        var current: [(Int, Int)] = []
        var used = 0
        func close() {
            guard !current.isEmpty else { return }
            let capacity = capacities(result.count)
            var extra = capacity - used
            // Widen largest first, at most to 3 columns, round-robin; then anyone if still short.
            let order = current.indices.sorted { sizes[current[$0].0] != sizes[current[$1].0]
                ? sizes[current[$0].0] > sizes[current[$1].0] : $0 < $1 }
            var limit = 3
            while extra > 0 {
                var grew = false
                for position in order where extra > 0 && current[position].1 < limit {
                    current[position].1 += 1
                    extra -= 1
                    grew = true
                }
                if !grew { limit += 1 }
            }
            result.append(current)
            current = []
            used = 0
        }
        for (index, width) in widths.enumerated() {
            let capacity = capacities(result.count)
            let fitted = min(width, capacity)
            if used + fitted > capacity { close() }
            let placed = min(fitted, capacities(result.count))
            current.append((index, placed))
            used += placed
        }
        close()
        return result
    }

    /// True when the slots tile a `columns`-wide grid with no gaps or overlaps. Used by the preview check.
    static func isTight(_ slots: [BentoSlot], columns: Int = 6) -> Bool {
        guard !slots.isEmpty else { return true }
        let rows = slots.map { $0.row + $0.height }.max() ?? 0
        var grid = Array(repeating: Array(repeating: 0, count: columns), count: rows)
        for slot in slots {
            guard slot.column >= 0, slot.column + slot.width <= columns else { return false }
            for r in slot.row ..< slot.row + slot.height {
                for c in slot.column ..< slot.column + slot.width { grid[r][c] += 1 }
            }
        }
        return grid.allSatisfy { $0.allSatisfy { $0 == 1 } }
    }
}

/// Places subviews (in order) at the given bento slots. Rows are `rowHeight` tall.
struct BentoLayout: Layout {
    var slots: [BentoSlot]
    var columns = 6
    var rowHeight: CGFloat = 92
    var spacing: CGFloat = 10

    private var rowCount: Int { slots.map { $0.row + $0.height }.max() ?? 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = CGFloat(rowCount)
        let height = rows > 0 ? rows * rowHeight + (rows - 1) * spacing : 0
        return CGSize(width: proposal.width ?? 600, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        for (index, subview) in subviews.enumerated() {
            guard index < slots.count else {
                subview.place(at: bounds.origin, proposal: .zero)
                continue
            }
            let slot = slots[index]
            let x = bounds.minX + CGFloat(slot.column) * (cell + spacing)
            let y = bounds.minY + CGFloat(slot.row) * (rowHeight + spacing)
            let width = CGFloat(slot.width) * cell + CGFloat(slot.width - 1) * spacing
            let height = CGFloat(slot.height) * rowHeight + CGFloat(slot.height - 1) * spacing
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: height))
        }
    }
}

// MARK: - Preview check

/// Lays out 1…12 tiles with a few size mixes and checks every layout fills its rows exactly.
#Preview("Bento layout check") {
    let mixes: [[Int64]] = [
        [53, 42, 28, 21, 13, 9, 8, 6, 30],
        [90, 5, 3, 1, 1],
        [30, 29, 28, 27, 26, 25, 24, 23],
        [100, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
    ] + (1 ... 8).map { n in (0 ..< n).map { Int64(100 - $0 * 9) } }
    let results = mixes.map { ($0, BentoGrid.layout($0)) }
    let allTight = results.allSatisfy { BentoGrid.isTight($0.1) && $0.1.count == $0.0.count }
    return ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Label(allTight ? "All \(results.count) layouts fill their rows" : "A layout has a gap or overlap",
                  systemImage: allTight ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(allTight ? .green : .red)
                .font(.headline)
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.0.map(String.init).joined(separator: " · ") + (BentoGrid.isTight(result.1) ? "" : "  ✗"))
                        .font(.caption.monospaced())
                    BentoLayout(slots: result.1, rowHeight: 26, spacing: 4) {
                        ForEach(Array(result.0.enumerated()), id: \.offset) { index, _ in
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.accentColor.opacity(0.15 + 0.07 * Double(index % 8)))
                                .overlay(Text("\(index + 1)").font(.caption2.bold()))
                        }
                    }
                }
            }
        }
        .padding(20)
    }
    .frame(width: 520, height: 900)
}
