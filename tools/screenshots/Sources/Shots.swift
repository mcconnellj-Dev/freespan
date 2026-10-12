import AppKit
import QuartzCore
import FreespanKit
import SwiftUI

// Renders Freespan's real SwiftUI screens offscreen with MarketingData and writes PNGs.
// No window is ever shown, nothing is scanned, and no screen capture is taken.
//
// Usage: FreespanShots <output-dir>

/// Normally defined in FreespanApp.swift, which this harness leaves out (it has its own @main).
enum MainWindowSize {
    static let minWidth: CGFloat = 900
    static let minHeight: CGFloat = 580
}

@main
@MainActor
enum Shots {
    static let windowSize = CGSize(width: 1440, height: 900)
    static let scale: CGFloat = 2

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let out = URL(fileURLWithPath: args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let only = Set(args.dropFirst(2))
        func wanted(_ name: String) -> Bool { only.isEmpty || only.contains(name) }

        if wanted("clean") {
            write(window(model(.easy, .clean), dark: false), to: out, "clean")
        }
        if wanted("overview-dark") {
            write(window(model(.easy, .clean), dark: true), to: out, "overview-dark")
        }
        if wanted("overview") {
            write(window(model(.advanced, .overview), dark: false), to: out, "overview")
        }
        if wanted("cleanup-sheet") {
            let m = model(.easy, .clean)
            let base = window(m, dark: false)
            let sheet = render(CleanUpSafelySheet(groups: EasyGroup.make(m.easySafeFindings))
                .environment(m).environment(\.appMode, m.mode), dark: false)
            write(composite(base: base, sheet: sheet, dark: false), to: out, "cleanup-sheet")
        }
        if wanted("apps") {
            let m = model(.easy, .apps)
            m.selectedAppPath = "/Applications/Xcode.app"
            write(window(m, dark: false), to: out, "apps")
        }
        if wanted("uninstall-sheet") {
            let m = model(.easy, .apps)
            m.selectedAppPath = "/Applications/GarageBand.app"
            let base = window(m, dark: false)
            let app = MarketingData.inventory.apps.first { $0.name == "GarageBand" }!
            let sheet = render(UninstallSheet(app: app, items: MarketingData.uninstallItems(for: app))
                .environment(m).environment(\.appMode, m.mode), dark: false)
            write(composite(base: base, sheet: sheet, dark: false), to: out, "uninstall-sheet")
        }
        if wanted("explore") {
            write(window(model(.easy, .diskMap), dark: false), to: out, "explore")
        }
        exit(0)
    }

    // MARK: Model

    static func model(_ mode: AppMode, _ selection: SidebarItem) -> AppModel {
        let suite = "com.mcconnelldigital.FreespanShots.state"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(mode.rawValue, forKey: SettingsKey.mode)
        let m = AppModel(services: .marketing(), defaults: defaults)
        m.seed(scan: MarketingData.scan, analysis: MarketingData.analysis, scope: mode == .easy ? .home : .wholeDisk,
               basketPaths: [], chat: [], plan: MarketingData.rulePlan, history: [], assistant: .onDevice)
        m.seedApps(MarketingData.inventory)
        m.recheckFullDiskAccess()
        m.fullDiskAccessDismissed = true
        m.mode = mode
        m.selection = selection
        return m
    }

    // MARK: Rendering

    /// The full main window (title bar, toolbar, sidebar, detail) drawn offscreen.
    static func window(_ model: AppModel, dark: Bool) -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Freespan"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: RootView().environment(model))
        window.contentView = host
        window.setContentSize(windowSize)
        settle(window)
        let frameView = host.superview ?? host
        // Glass picks its content's appearance from what's behind it, which offscreen is nothing (so: light).
        // Pin the title bar to the window's appearance.
        if let titlebar = find(frameView, named: "NSTitlebarContainerView") {
            func pin(_ v: NSView) { v.appearance = window.appearance; v.subviews.forEach(pin) }
            pin(titlebar)
            settle(window, seconds: 0.5)
        }
        if ProcessInfo.processInfo.environment["SHOTS_DUMP"] != nil { dump(frameView, 0) }
        return compose(frameView, windowCorners: true)
    }

    /// A bare SwiftUI view (a sheet) at its fitting size.
    static func render<V: View>(_ view: V, dark: Bool) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        settle(window)
        // Fitting size depends on text wrapping at the final width, so size until it stops changing.
        for _ in 0 ..< 4 {
            let fit = host.fittingSize
            if abs(fit.height - host.bounds.height) < 0.5, abs(fit.width - host.bounds.width) < 0.5 { break }
            window.setContentSize(fit)
            settle(window, seconds: 0.8)
        }
        if ProcessInfo.processInfo.environment["SHOTS_DUMP"] != nil { dump(host, 0) }
        return compose(host, windowCorners: false)
    }

    /// Lets SwiftUI lay out, run onAppear/task work and finish animations.
    static func settle(_ window: NSWindow, seconds: Double = 1.5) {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    static func find(_ v: NSView, named: String) -> NSView? {
        if className(v) == named { return v }
        for s in v.subviews { if let f = find(s, named: named) { return f } }
        return nil
    }

    static func dump(_ v: NSView, _ depth: Int) {
        print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden)")
        for s in v.subviews { dump(s, depth + 1) }
    }

    // MARK: Compositor
    //
    // cacheDisplay draws most of a window, but not what the window server composites: backdrop blurs, Liquid
    // Glass, and (for reasons of its own) anything inside an NSScrollView when captured from above it. So the
    // tree is drawn piecewise: views with such descendants are drawn alone (subviews hidden), then each child
    // in order; everything else is captured whole. Glass surfaces get a flat stand-in fill.

    static func className(_ v: NSView) -> String { "\(type(of: v))" }

    /// Window-server-only views: dropped (the sidebar panel and window background are painted instead).
    static func isServerOnly(_ v: NSView) -> Bool {
        let name = className(v)
        // The SwiftUI layer a glass view draws its own sheen with.
        if let parent = v.superview, isGlass(parent) || className(parent) == "NSGlassContainerView",
           name.hasPrefix("_NSCoreHostingView") { return true }
        // A toolbar platter's content holder paints an aqua fill regardless of appearance.
        if let parent = v.superview, className(parent) == "NSGlassEffectView", name == "ContentHolderView" { return true }
        if let layer = v.layer, "\(type(of: layer))" == "CABackdropLayer" { return true }
        return ["BackdropView", "NSBlurryAlleywayView", "NSScrollPocket", "NSVisualEffectView", "_NSSplitViewShadowView",
                "NSTitlebarBackgroundView", "PocketBlur", "LuminanceAdjustment"].contains { name.hasPrefix($0) }
    }

    /// The window was never key, so its buttons are grey; draw them as an active window's.
    static func trafficLight(_ v: NSView) -> NSColor? {
        switch className(v) {
        case "_NSThemeCloseWidget": NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1)
        case "_NSThemeWidget": NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1)
        case "_NSThemeZoomWidget": NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)
        default: nil
        }
    }

    static func isSwitch(_ v: NSView) -> Bool { v is NSSwitch || className(v) == "PlatformSwitch" }

    static func switchIsOn(_ v: NSView) -> Bool {
        if let s = v as? NSSwitch { return s.state == .on }
        if let n = v.accessibilityValue() as? NSNumber { return n.boolValue }
        return true
    }

    static func isGlass(_ v: NSView) -> Bool { className(v).contains("GlassEffectView") }

    static func needsSplitting(_ v: NSView) -> Bool {
        if v is NSScrollView || isServerOnly(v) || isGlass(v) || isSwitch(v) || v is NSTableView || v is NSClipView && (v as! NSClipView).documentView is NSTableView { return true }
        return v.subviews.contains { !$0.isHidden && needsSplitting($0) }
    }

    static func compose(_ root: NSView, windowCorners: Bool) -> NSBitmapImageRep {
        let size = root.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let appearance = root.window?.effectiveAppearance ?? NSAppearance(named: .aqua)!
        let restore = tintGlassButtons(root.layer, accent: accentColor(appearance))
        defer { restore() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            let bounds = NSRect(origin: .zero, size: size)
            if windowCorners { NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).addClip() }
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            draw(root, in: root, clip: bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static let trace = ProcessInfo.processInfo.environment["SHOTS_TRACE"] != nil

    /// `clip` is the visible area in root coordinates (visibleRect isn't reliable in a window that was never shown).
    static func draw(_ view: NSView, in root: NSView, clip: NSRect) {
        guard !view.isHidden, view.alphaValue > 0.01, !isServerOnly(view) else { return }
        var target = root.convert(view.bounds, from: view)
        if root.isFlipped { target.origin.y = root.bounds.height - target.maxY } // the bitmap is bottom-up
        let visible = target.intersection(clip)
        if trace { print("draw \(className(view).prefix(50)) target=\(target) app=\(view.effectiveAppearance.name.rawValue) own=\(view.appearance?.name.rawValue ?? "-") split=\(needsSplitting(view))") }
        guard visible.width >= 1, visible.height >= 1 else { return }
        if let color = trafficLight(view) {
            color.setFill()
            NSBezierPath(ovalIn: target.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            NSBezierPath(ovalIn: target.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return
        }
        if isSwitch(view) {
            paintSwitch(on: switchIsOn(view), rect: target)
            return
        }
        if isGlass(view) { paintGlass(view, rect: target.intersection(clip)) }
        if !needsSplitting(view) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: visible).setClip()
            stamp(view, rect: view.bounds, at: target)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        // Draw the container's own layers (SwiftUI text and shapes live there) with its subviews' layers hidden
        // at the Core Animation level (hiding the views themselves makes SwiftUI tear its layers down), then
        // each subview on top.
        if !isGlass(view), !(view is NSScrollView), !(view is NSClipView), className(view) != "NSToolbarPlatterView" {
            let layers = view.subviews.compactMap(\.layer).filter { !$0.isHidden }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layers.forEach { $0.isHidden = true }
            CATransaction.commit()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: visible).setClip()
            stamp(view, rect: view.bounds, at: target)
            NSGraphicsContext.restoreGraphicsState()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layers.forEach { $0.isHidden = false }
            CATransaction.commit()
        }
        for sub in view.subviews { draw(sub, in: root, clip: visible) }
    }

    /// Draws one view (with whatever subviews are showing) into the current context at `target`.
    static func stamp(_ view: NSView, rect: NSRect, at target: NSRect) {
        guard let piece = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        let hi = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: piece.colorSpaceName, bytesPerRow: 0, bitsPerPixel: 0) ?? piece
        hi.size = rect.size
        view.cacheDisplay(in: rect, to: hi)
        hi.draw(in: target, from: .zero, operation: .sourceOver, fraction: view.alphaValue, respectFlipped: true, hints: nil)
    }

    /// Flat stand-in for Liquid Glass: the sidebar panel and toolbar platters.
    static func paintGlass(_ view: NSView, rect: NSRect) {
        let radius = min(rect.height / 2, className(view).contains("Concentric") ? 18 : 18)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let dark = (view.window?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.965, alpha: 1)).setFill()
        path.fill()
        (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.08)).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Glass switches take their "on" tint from the window server; draw a flat one.
    static func paintSwitch(on: Bool, rect: NSRect) {
        let track = NSRect(x: rect.midX - 19, y: rect.midY - 11, width: 38, height: 22)
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (on ? NSColor(cgColor: accentColor(NSAppearance.currentDrawing()))! : NSColor(white: dark ? 0.35 : 0.85, alpha: 1)).setFill()
        NSBezierPath(roundedRect: track, xRadius: 11, yRadius: 11).fill()
        let knob = NSRect(x: on ? track.maxX - 20 : track.minX + 2, y: track.minY + 2, width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func accentColor(_ appearance: NSAppearance) -> CGColor {
        var color = NSColor.controlAccentColor.cgColor
        appearance.performAsCurrentDrawingAppearance { color = (NSColor(named: "AccentColor") ?? .controlAccentColor).cgColor }
        return color
    }

    /// Prominent (glass) buttons get their tint from the window server; their layers here are two faint white
    /// washes. Give the first the accent fill while capturing.
    static func tintGlassButtons(_ root: CALayer?, accent: CGColor) -> () -> Void {
        var changed: [(CALayer, CGColor?, CGFloat)] = []
        func isWash(_ l: CALayer, _ alpha: CGFloat) -> Bool {
            guard let c = l.backgroundColor, let comps = c.components, comps.count >= 4 else { return false }
            return comps[0] > 0.99 && comps[1] > 0.99 && comps[2] > 0.99 && abs(comps[3] - alpha) < 0.005
        }
        func walk(_ l: CALayer) {
            let subs = l.sublayers ?? []
            for (i, s) in subs.enumerated() where i + 1 < subs.count {
                let next = subs[i + 1]
                if isWash(s, 0.10), isWash(next, 0.03), s.frame == next.frame {
                    changed.append((s, s.backgroundColor, s.cornerRadius))
                    s.backgroundColor = accent
                    s.cornerRadius = s.frame.height / 2
                }
            }
            subs.forEach(walk)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let root { walk(root) }
        CATransaction.commit()
        return {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (l, c, r) in changed { l.backgroundColor = c; l.cornerRadius = r }
            CATransaction.commit()
        }
    }

    // MARK: Compositing

    /// Window with a sheet on top, macOS style: content dimmed slightly, sheet centered under the toolbar.
    static func composite(base: NSBitmapImageRep, sheet: NSBitmapImageRep, dark: Bool) -> NSBitmapImageRep {
        let size = base.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let full = NSRect(origin: .zero, size: size)
        base.draw(in: full)
        NSColor.black.withAlphaComponent(dark ? 0.25 : 0.12).setFill()
        full.fill(using: .sourceAtop)
        let s = sheet.size
        let rect = NSRect(x: (size.width - s.width) / 2, y: size.height - 64 - s.height, width: s.width, height: s.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 40
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        sheet.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: Output

    static func write(_ rep: NSBitmapImageRep, to dir: URL, _ name: String) {
        let url = dir.appendingPathComponent(name + ".png")
        do {
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            print("wrote \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        } catch {
            print("failed \(name): \(error)")
        }
    }
}
