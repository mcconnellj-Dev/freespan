import AppKit
import FreespanKit
import SwiftUI

// MARK: - Item icon

/// Finder icons for files and packages, cached per path. Misses are cached too, so a missing file is
/// only checked once.
@MainActor
enum ItemIconCache {
    private static var icons: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func icon(for path: String) -> NSImage? {
        if let hit = icons[path] { return hit }
        if misses.contains(path) { return nil }
        guard FileManager.default.fileExists(atPath: path) else {
            misses.insert(path)
            return nil
        }
        if icons.count > 400 { icons.removeAll(keepingCapacity: true) }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }
}

/// The item's Finder icon (apps, installers, documents), or the kind's symbol for folders like caches and
/// backups, where a plain folder icon would say nothing.
struct ItemIcon: View {
    let finding: Finding
    var size: CGFloat = 32

    private var wantsFinderIcon: Bool {
        !finding.isDirectory || !(finding.path as NSString).pathExtension.isEmpty
    }

    var body: some View {
        if wantsFinderIcon, let image = ItemIconCache.icon(for: finding.path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            KindGlyph(kind: finding.easyKind, color: finding.category.color, size: size)
        }
    }
}

/// A kind's SF Symbol in a soft tinted rounded square (like `CategoryGlyph`, with friendlier symbols).
struct KindGlyph: View {
    let kind: EasyKind
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension EasyGroup {
    var color: Color { items.first?.category.color ?? .accentColor }

    /// The kind's line, or the rule's own explanation for kinds without one.
    var explanation: String {
        if case .other = kind, let first = items.first { return first.easyWhy }
        return kind.explanation
    }
}

// MARK: - Toast

/// A short confirmation that floats at the bottom of a screen, with an optional Undo.
struct EasyToast: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String?
    var systemImage = "checkmark.circle.fill"
    var undo: (@MainActor () -> Void)?

    static func == (lhs: EasyToast, rhs: EasyToast) -> Bool { lhs.id == rhs.id }
}

private struct EasyToastModifier: ViewModifier {
    @Binding var toast: EasyToast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let current = toast {
                    EasyToastView(toast: current) { toast = nil }
                        .padding(.bottom, 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: current.id) {
                            try? await Task.sleep(for: .seconds(4))
                            if toast?.id == current.id { withAnimation(.snappy) { toast = nil } }
                        }
                }
            }
            .animation(.snappy, value: toast)
    }
}

private struct EasyToastView: View {
    let toast: EasyToast
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SafetyLabel.safe.foreground)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.callout.weight(.semibold))
                if let message = toast.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let undo = toast.undo {
                Button("Undo") {
                    undo()
                    close()
                }
                .buttonStyle(.borderless)
                .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func easyToast(_ toast: Binding<EasyToast?>) -> some View {
        modifier(EasyToastModifier(toast: toast))
    }
}

// MARK: - Remove / Keep

/// The two decisions Easy mode offers for an item that needs a look.
@MainActor
enum EasyItemActions {
    /// Puts the item in Cleanup. Returns a toast, or nil if it couldn't be added (the model shows why).
    static func remove(_ finding: Finding, model: AppModel) -> EasyToast? {
        guard model.addToBasket(finding) else { return nil }
        return EasyToast(title: "Added to Cleanup",
                         message: "Nothing is deleted until you move it to the Trash.",
                         undo: { model.removeFromBasket(finding.path) })
    }

    /// Hides the item from Easy mode from now on.
    static func keep(_ finding: Finding, model: AppModel) -> EasyToast {
        model.dismiss(finding.path)
        return EasyToast(title: "Freespan will leave this alone",
                         message: "“\(finding.easyTitle)” won't be suggested again.",
                         systemImage: "hand.thumbsup.fill",
                         undo: { model.undismiss(finding.path) })
    }
}

// MARK: - Item row

/// Icon, friendly name, one-line why, size, and Remove / Keep. Clicking the row opens Quick Look.
struct EasyItemRow: View {
    @Environment(AppModel.self) private var model
    let finding: Finding
    let remove: () -> Void
    let keep: () -> Void
    @State private var hovering = false

    var body: some View {
        let inCleanup = model.isInBasket(finding.path)
        HStack(spacing: 12) {
            ItemIcon(finding: finding)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.easyTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(finding.easyWhy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            SizeText(bytes: finding.size, font: .callout)
                .foregroundStyle(.secondary)
            actions(inCleanup: inCleanup)
                .frame(width: 136, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.045) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.quickLook(finding.path) }
        .onHover { hovering = $0 }
        .help(Format.displayPath(finding.path, home: model.home))
        .contextMenu {
            Button("Quick Look") { model.quickLook(finding.path) }
            Button("Show in Finder") { model.revealInFinder(finding.path) }
            Divider()
            if inCleanup {
                Button("Take Out of Cleanup") { model.removeFromBasket(finding.path) }
            } else {
                Button("Remove") { remove() }
                Button("Keep") { keep() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(finding.easyTitle), \(Format.bytes(finding.size))")
        .accessibilityAction(named: "Quick Look") { model.quickLook(finding.path) }
    }

    @ViewBuilder private func actions(inCleanup: Bool) -> some View {
        if inCleanup {
            HStack(spacing: 8) {
                Label("In Cleanup", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SafetyLabel.safe.foreground)
                    .labelStyle(.titleAndIcon)
                Button("Undo") { model.removeFromBasket(finding.path) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(model.basket[finding.path] == nil)
                    .help("Take it out of Cleanup")
            }
        } else {
            HStack(spacing: 6) {
                Button("Remove", action: remove)
                    .help("Put it in Cleanup. Nothing is deleted until you move it to the Trash.")
                Button("Keep", action: keep)
                    .help("Hide it. Freespan won't suggest it again.")
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Gauge

/// A calm 270° ring showing how full the disk is.
struct UsageGauge: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 12
    /// Point size of the percentage in the middle.
    var percentSize: CGFloat = 26
    /// Shows "used" under the percentage.
    var showsCaption = true

    private let span = 0.75

    var body: some View {
        ZStack {
            arc(to: span).stroke(Theme.freeSpace, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            arc(to: span * min(max(fraction, 0), 1))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            VStack(spacing: 0) {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: percentSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if showsCaption {
                    Text("used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .offset(y: showsCaption ? 2 : 0)
        }
        .padding(lineWidth / 2)
        .animation(.smooth(duration: 0.6), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk usage")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))) + " full")
    }

    private func arc(to end: Double) -> some Shape {
        Circle().trim(from: 0, to: end).rotation(.degrees(135))
    }
}
