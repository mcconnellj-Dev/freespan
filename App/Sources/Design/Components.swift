import FreespanKit
import SwiftUI

/// Small tinted capsule: Safe / Review / Keep / Protected.
/// Easy mode says "Safe to remove" / "Check first" (Keep and Protected are hidden there anyway).
struct LabelPill: View {
    let label: SafetyLabel
    var compact = false
    /// Overrides the environment's mode (for places the environment doesn't reach).
    var mode: AppMode?
    @Environment(\.appMode) private var environmentMode

    private var text: String { label.title(for: mode ?? environmentMode) }

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = label.systemImage, (mode ?? environmentMode) == .advanced {
                Image(systemName: symbol).font(.system(size: compact ? 7 : 8, weight: .bold))
            }
            Text(text)
        }
        .font(.system(size: compact ? 10 : 11, weight: .semibold))
        .foregroundStyle(label.foreground)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .background(label.background, in: Capsule())
        .fixedSize()
        .accessibilityLabel(text)
    }
}

/// Byte count in monospaced digits.
struct SizeText: View {
    let bytes: Int64
    var font: Font = .body

    var body: some View {
        Text(Format.bytes(bytes))
            .font(font)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }
}

/// Category SF Symbol in a soft tinted rounded square.
struct CategoryGlyph: View {
    let category: CategoryID
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: category.systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(category.color)
            .frame(width: size, height: size)
            .background(category.color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Thin horizontal proportion bar.
struct SizeBar: View {
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

/// Uppercase tracking label used for section headers.
struct EyebrowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// The card surface used throughout Overview.
struct CardBackground: ViewModifier {
    var tint: Color?
    var fillHeight = false

    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(tint ?? Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(tint == nil ? Theme.hairline : .clear, lineWidth: 1)
            }
    }
}

extension View {
    func card(tint: Color? = nil, fillHeight: Bool = false) -> some View {
        modifier(CardBackground(tint: tint, fillHeight: fillHeight))
    }
}

/// A slim notice strip shown at the top of the detail column.
struct NoticeBanner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    var message: String?
    var onDismiss: (() -> Void)?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            actions()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Centered empty / placeholder state that still looks designed.
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            actions().padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

#Preview("Pills & glyphs") {
    VStack(alignment: .leading, spacing: 14) {
        HStack { ForEach(SafetyLabel.allCases, id: \.self) { LabelPill(label: $0) } }
        HStack { ForEach(SafetyLabel.allCases, id: \.self) { LabelPill(label: $0, compact: true) } }
        HStack { ForEach([SafetyLabel.safe, .review], id: \.self) { LabelPill(label: $0, mode: .easy) } }
        HStack { ForEach(CategoryID.allCases) { CategoryGlyph(category: $0) } }
        SizeText(bytes: 53_000_000_000, font: .title.weight(.semibold))
        SizeBar(fraction: 0.4).frame(width: 160)
    }
    .padding(24)
}
