import FreespanKit
import SwiftUI

struct DiskMapView: View {
    @Environment(AppModel.self) private var model
    @State private var segments: [RingSegment] = []
    @State private var hoveredID: String?
    @State private var selectedID: String?

    var body: some View {
        if let focus = model.mapFocus {
            VStack(spacing: 0) {
                BreadcrumbBar(trail: model.mapTrail)
                Divider()
                HStack(spacing: 0) {
                    SunburstChart(focus: focus, segments: segments, hoveredID: $hoveredID,
                                  rootName: displayName(for: focus)) { node in
                        drill(into: node)
                    } goUp: {
                        goUp()
                    }
                    .padding(24)
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    .id(focus.path)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))

                    Divider()

                    ChildList(focus: focus, hoveredID: $hoveredID, selectedID: $selectedID) { node in
                        drill(into: node)
                    }
                    .frame(minWidth: 250, maxWidth: 380)
                }
            }
            .onChange(of: layoutKey(focus), initial: true) {
                segments = RingLayout.segments(
                    focus: focus,
                    inherited: model.coveringFinding(for: focus.path),
                    muteKept: model.mode == .easy,
                    finding: { model.finding(at: $0) }
                )
            }
        } else {
            EmptyStateView(systemImage: "chart.pie", title: "No scan yet", message: "Run a scan to see your disk map.")
        }
    }

    private func layoutKey(_ focus: FileNode) -> String {
        "\(focus.path)|\(focus.size)|\(model.findings.count)|\(model.mode.rawValue)"
    }

    private func displayName(for node: FileNode) -> String {
        if node.path == model.home { return "Home" }
        if node.path == model.mapRoot?.path, model.scannedScope == .wholeDisk { return model.volume?.name ?? node.name }
        return node.name
    }

    private func drill(into node: FileNode) {
        guard node.kind == .directory, node.children.contains(where: { $0.kind != .smallFiles }) else { return }
        withAnimation(.snappy(duration: 0.28)) {
            hoveredID = nil
            selectedID = nil
            model.mapFocusPath = node.path
        }
    }

    private func goUp() {
        let trail = model.mapTrail
        guard trail.count > 1 else { return }
        withAnimation(.snappy(duration: 0.28)) {
            hoveredID = nil
            model.mapFocusPath = trail[trail.count - 2].path
        }
    }
}

// MARK: - Breadcrumbs

private struct BreadcrumbBar: View {
    @Environment(AppModel.self) private var model
    let trail: [FileNode]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(trail.enumerated()), id: \.element.path) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    let isLast = index == trail.count - 1
                    Button {
                        withAnimation(.snappy(duration: 0.28)) {
                            model.mapFocusPath = index == 0 ? nil : node.path
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if index == 0 {
                                Image(systemName: node.path == model.home ? "house" : "internaldrive")
                            }
                            Text(name(node, isRoot: index == 0))
                        }
                        .font(.callout.weight(isLast ? .semibold : .regular))
                        .foregroundStyle(isLast ? .primary : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLast)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
    }

    private func name(_ node: FileNode, isRoot: Bool) -> String {
        guard isRoot else { return node.name }
        if node.path == model.home { return "Home" }
        return model.volume?.name ?? node.name
    }
}

// MARK: - Sunburst

struct SunburstChart: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode
    let segments: [RingSegment]
    @Binding var hoveredID: String?
    let rootName: String
    let drill: (FileNode) -> Void
    let goUp: () -> Void

    @State private var hoverPoint: CGPoint = .zero
    @State private var hoveringHole = false

    private var hovered: RingSegment? {
        hoveredID.flatMap { id in segments.first { $0.id == id } }
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let size = CGSize(width: side, height: side)
            let geometry = RingGeometry(size: size)
            ZStack {
                Canvas { context, _ in
                    let dimOthers = hoveredID != nil
                    for segment in segments {
                        let path = geometry.path(for: segment)
                        let isHovered = segment.id == hoveredID
                        context.fill(path, with: .color(segment.color.opacity(dimOthers && !isHovered ? 0.45 : 1)))
                        context.stroke(path, with: .style(.background), lineWidth: 1)
                    }
                    if let hovered {
                        context.stroke(geometry.path(for: hovered), with: .color(.primary.opacity(0.55)), lineWidth: 1.5)
                    }
                }

                centerLabel
                    .frame(width: geometry.hole * 1.7)
                    .allowsHitTesting(false)

                if let hovered, !hoveringHole {
                    SliceTooltip(segment: hovered)
                        .fixedSize()
                        .position(x: min(max(hoverPoint.x, 90), side - 90), y: max(hoverPoint.y - 34, 20))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    switch geometry.hit(point, in: segments) {
                    case .segment(let segment):
                        hoveringHole = false
                        if hoveredID != segment.id { hoveredID = segment.id }
                    case .hole:
                        hoveringHole = true
                        hoveredID = nil
                    case .none:
                        hoveringHole = false
                        hoveredID = nil
                    }
                case .ended:
                    hoveredID = nil
                    hoveringHole = false
                }
            }
            .onTapGesture { point in
                switch geometry.hit(point, in: segments) {
                case .hole: goUp()
                case .segment(let segment): if let node = segment.node { drill(node) }
                case .none: break
                }
            }
            .contextMenu {
                if let node = hovered?.node {
                    ItemContextMenu(path: node.path, finding: node.kind == .smallFiles ? nil : model.finding(at: node.path)).environment(model)
                }
            }
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .accessibilityElement()
            .accessibilityLabel("Ring chart of \(rootName), \(Format.bytes(focus.size))")
        }
    }

    private var centerLabel: some View {
        VStack(spacing: 2) {
            if hoveringHole, focus.path != model.mapRoot?.path {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Back").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
            } else {
                Text(rootName)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                SizeText(bytes: focus.size, font: .system(size: 22, weight: .bold))
                Text("\(Format.count(focus.itemCount)) files")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

private struct SliceTooltip: View {
    let segment: RingSegment

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(segment.color).frame(width: 8, height: 8)
            Text(segment.name).font(.callout.weight(.medium)).lineLimit(1)
            SizeText(bytes: segment.bytes, font: .callout).foregroundStyle(.secondary)
            if let label = segment.label { LabelPill(label: label, compact: true) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

// MARK: - Child list

private struct ChildList: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode
    @Binding var hoveredID: String?
    @Binding var selectedID: String?
    let drill: (FileNode) -> Void

    private var children: [FileNode] { focus.children.filter { $0.size > 0 } }

    var body: some View {
        let largest = Double(children.first?.size ?? 1)
        List(selection: $selectedID) {
            ForEach(children, id: \.listID) { node in
                ChildRow(node: node, fraction: Double(node.size) / max(largest, 1),
                         highlighted: hoveredID == RingLayout.segmentID(for: node))
                    .onHover { inside in
                        if inside { hoveredID = RingLayout.segmentID(for: node) } else if hoveredID == RingLayout.segmentID(for: node) { hoveredID = nil }
                    }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let node = node(for: id) {
                ItemContextMenu(path: node.path, finding: node.kind == .smallFiles ? nil : model.finding(at: node.path)).environment(model)
            }
        } primaryAction: { ids in
            if let id = ids.first, let node = node(for: id) { drill(node) }
        }
        .onKeyPress(.space) {
            guard let id = selectedID, let node = node(for: id), node.kind != .smallFiles else { return .ignored }
            model.quickLook(node.path)
            return .handled
        }
        .onDeleteCommand {
            guard let id = selectedID, let node = node(for: id) else { return }
            model.addToBasket(node: node)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                EyebrowLabel("\(children.count) item\(children.count == 1 ? "" : "s")")
                Spacer()
                EyebrowLabel("Size")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
    }

    private func node(for id: String) -> FileNode? {
        children.first { $0.listID == id }
    }
}

private extension FileNode {
    var listID: String { RingLayout.segmentID(for: self) }
}

private struct ChildRow: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    let fraction: Double
    let highlighted: Bool

    var body: some View {
        // `.smallFiles` carries its parent's path, so this also inherits correctly for aggregates.
        let covering = model.coveringFinding(for: node.path)
        let inBasket = node.kind != .smallFiles && model.isInBasket(node.path)
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(covering?.category.color ?? .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(node.kind == .smallFiles ? "Smaller files" : node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(node.kind == .smallFiles ? .secondary : .primary)
                    if let covering, model.mode == .advanced || covering.label.canBeCleaned {
                        LabelPill(label: covering.label, compact: true, mode: model.mode)
                    }
                    if inBasket {
                        Image(systemName: "basket.fill").font(.caption2).foregroundStyle(Color.accentColor)
                            .help("In the cleanup basket")
                    }
                    Spacer(minLength: 4)
                    SizeText(bytes: node.size, font: .callout).foregroundStyle(.secondary)
                }
                SizeBar(fraction: fraction, color: covering?.category.color ?? Color.secondary.opacity(0.5))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .background(highlighted ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        switch node.kind {
        case .directory: "folder.fill"
        case .file: "doc.fill"
        case .package: node.name.hasSuffix(".app") ? "app.dashed" : "shippingbox.fill"
        case .smallFiles: "ellipsis.circle"
        }
    }
}

#Preview("Disk Map") {
    DiskMapView()
        .environment(AppModel.preview(selection: .diskMap))
        .frame(width: 1000, height: 640)
}

#Preview("Space Map · Easy") {
    DiskMapView()
        .environment(AppModel.preview(mode: .easy, selection: .diskMap))
        .environment(\.appMode, .easy)
        .frame(width: 760, height: 560)
}

#Preview("Disk Map · Library · dark") {
    let model = AppModel.preview(selection: .diskMap)
    model.mapFocusPath = SampleData.home + "/Library"
    return DiskMapView()
        .environment(model)
        .frame(width: 1000, height: 640)
        .preferredColorScheme(.dark)
}
