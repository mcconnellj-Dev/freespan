import AppKit
import FreespanKit
import SwiftUI

/// "What's using your space": a bento grid of `SpaceTile`s. Bigger tile, more space; click one to see inside.
struct SpaceBreakdownSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What's using your space")
                    .font(.title3.weight(.semibold))
                Text("Bigger tile, more space. Click one to see inside.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.tiles.isEmpty {
                placeholder
            } else {
                SpaceTileGrid(tiles: model.tiles) { open($0) }
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        HStack(spacing: 10) {
            if model.tilesLoading || model.appsLoading || model.phase.isBusy {
                ProgressView().controlSize(.small)
                Text("Adding up what's on your Mac…")
            } else {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.tertiary)
                Text("Freespan shows a breakdown here after the next scan.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func open(_ tile: SpaceTile) {
        switch tile.kind {
        case .apps:
            model.selectedAppPath = nil
            model.selection = .apps
        case .app(let path, _):
            model.showApp(path: path)
        case .folder(let path):
            model.explore(path: path)
        case .category(let category):
            if model.mode == .advanced, model.groups.contains(where: { $0.category == category }) {
                model.selection = .group(category)
            } else if model.mode == .easy, model.easyCheckFirstFindings.contains(where: { $0.category == category }) {
                model.selection = .checkFirst
            } else {
                model.explore(path: nil)
            }
        case .other:
            model.explore(path: nil)
        }
    }
}

/// The grid itself, separate from the model so previews and the layout check can use any tiles.
struct SpaceTileGrid: View {
    let tiles: [SpaceTile]
    var open: (SpaceTile) -> Void = { _ in }

    var body: some View {
        let slots = BentoGrid.layout(tiles.map(\.bytes))
        BentoLayout(slots: slots) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                let slot = index < slots.count ? slots[index] : BentoSlot(column: 0, row: 0, width: 1, height: 1)
                SpaceTileView(tile: tile, style: .init(slot)) { open(tile) }
            }
        }
        .animation(.snappy, value: tiles.map(\.id))
    }
}

/// One tile: soft tint by kind, icon, title, big size, optional subtitle, and a "to check" / "safe" capsule.
struct SpaceTileView: View {
    enum Style {
        case large, wide, small

        init(_ slot: BentoSlot) {
            if slot.height >= 2 { self = .large } else if slot.width >= 2 { self = .wide } else { self = .small }
        }
    }

    let tile: SpaceTile
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(style == .small ? 11 : 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(tile.tint.opacity(hovering ? 0.16 : 0.11),
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(tile.tint.opacity(hovering ? 0.35 : 0.18)))
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 8, y: 3)
        .offset(y: hovering ? -2 : 0)
        .animation(.snappy(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .help(tile.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.accessibilityText)
        .accessibilityHint("Shows what's inside")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .large:
            // Rows have a fixed height, so the tile can't grow: step down until the content fits.
            ViewThatFits(in: .vertical) {
                large(iconSize: 44, spacing: 8, subtitleLines: 2)
                large(iconSize: 30, spacing: 4, subtitleLines: 1)
                large(iconSize: 30, spacing: 4, subtitleLines: 0)
            }
        case .wide:
            HStack(alignment: .top, spacing: 10) {
                SpaceTileIcon(tile: tile, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.title).font(.callout.weight(.semibold)).lineLimit(1)
                    SizeText(bytes: tile.bytes, font: .system(size: 20, weight: .bold, design: .rounded))
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        badge
                        if let subtitle = tile.subtitle, tile.badgeText == nil {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        case .small:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    SpaceTileIcon(tile: tile, size: 22)
                    Text(tile.title).font(.caption.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                SizeText(bytes: tile.bytes, font: .system(size: 17, weight: .bold, design: .rounded))
                badge
            }
        }
    }

    /// The large tile's stack; `subtitleLines: 0` leaves the subtitle out.
    private func large(iconSize: CGFloat, spacing: CGFloat, subtitleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            SpaceTileIcon(tile: tile, size: iconSize)
            Spacer(minLength: 4)
            Text(tile.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            SizeText(bytes: tile.bytes, font: .system(size: 32, weight: .bold, design: .rounded))
            if let subtitle = tile.subtitle, subtitleLines > 0 {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(subtitleLines)
            }
            badge
        }
    }

    @ViewBuilder private var badge: some View {
        if let text = tile.badgeText {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tile.badgeLabel.foreground)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tile.badgeLabel.background, in: Capsule())
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
    }
}

/// A real app icon for app tiles; otherwise the kind's symbol in a tinted rounded square.
struct SpaceTileIcon: View {
    let tile: SpaceTile
    var size: CGFloat = 30

    var body: some View {
        switch tile.kind {
        case .app(let path, _):
            AppIcon(path: path, size: size * 1.1)
        default:
            Image(systemName: tile.symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tile.tint)
                .frame(width: size, height: size)
                .background(tile.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

extension SpaceTile {
    var tint: Color {
        switch kind {
        case .apps: Color(light: "#5B6CC9", dark: "#8C9BEA")
        case .app: Color(light: "#6A7A86", dark: "#9AA8B2")
        case .folder(let path):
            switch (path as NSString).lastPathComponent.lowercased() {
            case "downloads": CategoryID.downloads.color
            case "pictures", "movies": CategoryID.media.color
            case "music": CategoryID.backups.color
            case "library": CategoryID.caches.color
            default: Color.accentColor
            }
        case .category(let category): category.color
        case .other: CategoryID.other.color
        }
    }

    var symbol: String {
        switch kind {
        case .apps: "square.grid.2x2"
        case .app: "app"
        case .folder(let path):
            switch (path as NSString).lastPathComponent.lowercased() {
            case "downloads": "arrow.down.circle"
            case "desktop": "menubar.dock.rectangle"
            case "documents": "doc.text"
            case "pictures": "photo"
            case "movies": "film"
            case "music": "music.note"
            case "library": "building.columns"
            case "developer": "hammer"
            default: "folder"
            }
        case .category(let category): category.systemImage
        case .other: "ellipsis.circle"
        }
    }

    /// Amber "8.9 GB to check" first; otherwise green "1.2 GB safe".
    var badgeText: String? {
        if checkBytes > 0 { return "\(Format.bytes(checkBytes)) to check" }
        if safeBytes > 0 { return "\(Format.bytes(safeBytes)) safe" }
        return nil
    }

    var badgeLabel: SafetyLabel { checkBytes > 0 ? .review : .safe }

    var accessibilityText: String {
        [title, Format.bytes(bytes), subtitle, badgeText].compactMap { $0 }.joined(separator: ", ")
    }

    var helpText: String {
        switch kind {
        case .apps: "See all your apps"
        case .app: "See \(title) and its data"
        case .folder: "Explore \(title)"
        case .category: "See \(title)"
        case .other: "Explore everything else"
        }
    }
}

// MARK: - Previews

#Preview("Space tiles") {
    ScrollView {
        SpaceTileGrid(tiles: SampleApps.tiles)
            .padding(24)
    }
    .frame(width: 860, height: 480)
}

#Preview("Space tiles · few · dark") {
    SpaceTileGrid(tiles: Array(SampleApps.tiles.prefix(4)))
        .padding(24)
        .frame(width: 760)
        .preferredColorScheme(.dark)
}
