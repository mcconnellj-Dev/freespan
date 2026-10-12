import FreespanKit
import SwiftUI

/// One wedge of the sunburst. Angles are radians clockwise from 12 o'clock.
struct RingSegment: Identifiable {
    let id: String
    /// nil for a merged "Other" wedge.
    let node: FileNode?
    let name: String
    let bytes: Int64
    let depth: Int
    let start: Double
    let end: Double
    let color: Color
    let label: SafetyLabel?

    var span: Double { end - start }
    var isDrillable: Bool { node.map { $0.kind == .directory && $0.children.contains { $0.kind != .smallFiles } } ?? false }
}

enum RingLayout {
    static let ringCount = 3
    static let minimumSpan = Double.pi / 180 // 1°

    /// Gentle hues for folders no rule has classified, so classified groups stand out.
    private static let neutralHues: [Color] = [
        Color(light: "#7B8FA6", dark: "#6E8299"),
        Color(light: "#8BA394", dark: "#748C7D"),
        Color(light: "#B09C80", dark: "#958369"),
        Color(light: "#9A8AAB", dark: "#837493"),
        Color(light: "#A88A80", dark: "#8F7369"),
        Color(light: "#7E9DA6", dark: "#68868F"),
    ]

    static func segmentID(for node: FileNode) -> String {
        node.kind == .smallFiles ? node.path + "#files" : node.path
    }

    /// Builds up to three rings of descendants around `focus`.
    /// `finding` returns the finding exactly at a path; classification is inherited downward.
    /// `muteKept` (Easy mode) draws Keep/Protected slices in a quiet gray with no label.
    static func segments(focus: FileNode, inherited: Finding?, muteKept: Bool = false,
                         finding: (String) -> Finding?) -> [RingSegment] {
        guard focus.size > 0 else { return [] }
        var result: [RingSegment] = []
        let total = Double(focus.size)

        func visit(_ parent: FileNode, depth: Int, start: Double, span: Double, parentFinding: Finding?, hue: Color?) {
            guard depth <= ringCount, parent.size > 0 else { return }
            var cursor = start
            var otherBytes: Int64 = 0
            var otherStart: Double?
            for (index, child) in parent.children.enumerated() where child.size > 0 {
                let childSpan = span * Double(child.size) / Double(parent.size)
                if childSpan < minimumSpan {
                    otherStart = otherStart ?? cursor
                    otherBytes += child.size
                    cursor += childSpan
                    continue
                }
                let own = child.kind == .smallFiles ? nil : finding(child.path)
                let classified = own ?? parentFinding
                let baseHue = hue ?? neutralHues[index % neutralHues.count]
                let isMuted = muteKept && (classified?.label == .keep || classified?.label == .protected)
                let color: Color
                if isMuted {
                    color = CategoryID.system.color.opacity(0.35 * depthOpacity(depth))
                } else if child.kind == .smallFiles {
                    color = CategoryID.other.color.opacity(0.7)
                } else if let classified {
                    color = classified.category.color.opacity(depthOpacity(depth))
                } else {
                    color = baseHue.opacity(depthOpacity(depth))
                }
                result.append(RingSegment(
                    id: segmentID(for: child), node: child,
                    name: child.kind == .smallFiles ? "Smaller files" : child.name,
                    bytes: child.size, depth: depth, start: cursor, end: cursor + childSpan,
                    color: color, label: isMuted ? nil : classified?.label
                ))
                if child.kind == .directory {
                    visit(child, depth: depth + 1, start: cursor, span: childSpan, parentFinding: classified, hue: baseHue)
                }
                cursor += childSpan
            }
            if let otherStart, otherBytes > 0 {
                result.append(RingSegment(
                    id: parent.path + "#other", node: nil, name: "Other", bytes: otherBytes, depth: depth,
                    start: otherStart, end: cursor, color: CategoryID.other.color.opacity(0.55), label: nil
                ))
            }
        }

        visit(focus, depth: 1, start: 0, span: 2 * .pi * Double(focus.size) / total, parentFinding: inherited, hue: nil)
        return result
    }

    private static func depthOpacity(_ depth: Int) -> Double {
        switch depth {
        case 1: 1
        case 2: 0.78
        default: 0.6
        }
    }
}

/// Ring radii for a given chart size.
struct RingGeometry {
    let center: CGPoint
    let hole: CGFloat
    let ringWidth: CGFloat

    init(size: CGSize) {
        let radius = min(size.width, size.height) / 2
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        hole = radius * 0.36
        ringWidth = (radius - hole) / CGFloat(RingLayout.ringCount)
    }

    func inner(_ depth: Int) -> CGFloat { hole + CGFloat(depth - 1) * ringWidth + 1.5 }
    func outer(_ depth: Int) -> CGFloat { hole + CGFloat(depth) * ringWidth }

    func path(for segment: RingSegment) -> Path {
        var path = Path()
        let start = Angle(radians: segment.start - .pi / 2)
        let end = Angle(radians: segment.end - .pi / 2)
        path.addArc(center: center, radius: outer(segment.depth), startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: inner(segment.depth), startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    enum Hit { case hole, segment(RingSegment), none }

    func hit(_ point: CGPoint, in segments: [RingSegment]) -> Hit {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        if distance < hole { return .hole }
        let depth = Int((distance - hole) / ringWidth) + 1
        guard depth >= 1, depth <= RingLayout.ringCount else { return .none }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        if let match = segments.first(where: { $0.depth == depth && angle >= $0.start && angle < $0.end }) {
            return .segment(match)
        }
        return .none
    }
}
