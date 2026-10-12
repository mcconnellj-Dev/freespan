import Foundation
import FreespanKit

/// Sample installed apps, leftovers and space tiles for previews. No real I/O.
enum SampleApps {
    private static let home = SampleData.home
    private static let L = SampleData.home + "/Library"
    private static func g(_ value: Double) -> Int64 { Int64(value * Double(SampleData.gb)) }
    private static func m(_ value: Double) -> Int64 { Int64(value * Double(SampleData.mb)) }
    private static func daysAgo(_ days: Double) -> Date { SampleData.now.addingTimeInterval(-days * 86_400) }

    private static func item(_ path: String, _ bytes: Int64, _ label: SafetyLabel, _ title: String, _ why: String,
                             category: CategoryID = .applications, rule: String? = nil, days: Double = 3) -> Finding {
        Finding(path: path, name: (path as NSString).lastPathComponent, size: bytes, itemCount: max(1, Int(bytes / 2_000_000)),
                modified: daysAgo(days), accessed: daysAgo(days), isDirectory: true,
                classification: Classification(category: category, label: label, title: title, explanation: why,
                                               regenerates: label == .safe, source: .rule, ruleID: rule ?? (label == .safe ? "app-cache" : "app-data")))
    }

    private static func app(_ name: String, id: String, version: String, bytes: Int64, opened: Double?,
                            canUninstall: Bool = true, blocked: String? = nil, related: [Finding]) -> InstalledApp {
        InstalledApp(path: "/Applications/\(name).app", name: name, bundleID: id, version: version, appBytes: bytes,
                     lastOpened: opened.map(daysAgo), isAppleApp: id.hasPrefix("com.apple."), canUninstall: canUninstall,
                     uninstallBlockedReason: blocked, related: related)
    }

    static let apps: [InstalledApp] = [
        app("Xcode", id: "com.apple.dt.Xcode", version: "26.4", bytes: g(12.4), opened: 0.1, related: [
            item(L + "/Developer/Xcode/iOS DeviceSupport", g(17.0), .safe, "Xcode device files",
                 "Xcode copies these again when you plug in an iPhone.", category: .developer, rule: "xcode-device-support"),
            item(L + "/Developer/CoreSimulator/Devices", g(8.9), .review, "Simulators",
                 "Test devices for apps. Xcode can make new ones anytime.", category: .developer, rule: "simulator-device"),
            item(L + "/Caches/com.apple.dt.Xcode", g(3.1), .safe, "Xcode cache",
                 "Documentation and index caches Xcode rebuilds on its own.", category: .caches),
            item(L + "/Developer/Xcode/DerivedData", g(1.3), .safe, "Build files",
                 "Rebuilt automatically the next time you build a project.", category: .developer, rule: "xcode-derived-data"),
        ]),
        app("Google Chrome", id: "com.google.Chrome", version: "141.0", bytes: g(1.6), opened: 0.02, related: [
            item(L + "/Application Support/Google/Chrome", g(3.8), .keep, "Chrome profile",
                 "Your bookmarks, history, passwords and extensions."),
            item(L + "/Caches/Google", g(2.6), .safe, "Browser cache", "Websites load these again as you browse.",
                 category: .caches, rule: "browser-cache"),
            item(L + "/Application Support/Google/Chrome/OptGuideOnDeviceModel", g(2.4), .review, "Chrome AI model",
                 "An on-device model Chrome downloads again if it needs it.", rule: "chrome-ai-model"),
        ]),
        app("Microsoft Teams", id: "com.microsoft.teams2", version: "25.2", bytes: g(1.1), opened: 64, related: [
            item(L + "/Containers/com.microsoft.teams2", g(2.9), .review, "Teams data",
                 "Chat history cache and settings. Signing in again rebuilds most of it."),
            item(L + "/Caches/com.microsoft.teams2", m(640), .safe, "App cache", "Apps rebuild these on their own when they need them.",
                 category: .caches),
        ]),
        app("Microsoft Excel", id: "com.microsoft.Excel", version: "16.98", bytes: g(2.3), opened: 21, related: [
            item(L + "/Containers/com.microsoft.Excel", m(820), .review, "Excel data", "Templates, add-ins and recent-file previews."),
            item(L + "/Caches/com.microsoft.Excel", m(210), .safe, "App cache", "Apps rebuild these on their own when they need them.",
                 category: .caches),
        ]),
        app("Claude", id: "com.anthropic.claudefordesktop", version: "1.4", bytes: m(610), opened: 0.01, related: [
            item(L + "/Application Support/Claude", g(1.7), .review, "Claude data", "Conversations cache, settings and extensions."),
            item(L + "/Caches/com.anthropic.claudefordesktop", m(380), .safe, "App cache",
                 "Apps rebuild these on their own when they need them.", category: .caches),
        ]),
        app("Visual Studio Code", id: "com.microsoft.VSCode", version: "1.105", bytes: m(690), opened: 1, related: [
            item(L + "/Caches/com.microsoft.VSCode.ShipIt", g(1.8), .safe, "Update downloads",
                 "Old update files. VS Code downloads new ones when it updates.", category: .caches),
            item(L + "/Application Support/Code", g(1.2), .review, "Visual Studio Code data",
                 "Editor state, extensions' storage and workspace history."),
        ]),
        app("Webex", id: "Cisco-Systems.Spark", version: "45.6", bytes: m(920), opened: 190, related: [
            item(L + "/Application Support/Cisco Spark", m(540), .review, "Webex data", "Meeting cache and settings."),
            item(L + "/Logs/Webex", m(120), .safe, "Logs", "Apps start fresh logs as they run.", category: .caches, rule: "user-logs"),
        ]),
        app("Cotypist", id: "app.cotypist.Cotypist", version: "0.9", bytes: m(180), opened: nil, related: [
            item(L + "/Application Support/app.cotypist.Cotypist", g(1.1), .review, "Cotypist model",
                 "The writing model Cotypist downloaded. It downloads it again if needed."),
        ]),
    ]

    static let leftovers: [Leftover] = [
        Leftover(ownerName: "Zoom", bundleID: "us.zoom.xos", items: [
            item(L + "/Application Support/zoom.us", m(780), .review, "Zoom data", "Left behind when Zoom was removed.", days: 220),
            item(L + "/Caches/us.zoom.xos", m(160), .safe, "App cache", "Left behind when Zoom was removed.", category: .caches, days: 220),
        ]),
        Leftover(ownerName: "Adobe Creative Cloud", bundleID: "com.adobe.acc.AdobeCreativeCloud", items: [
            item(L + "/Application Support/Adobe", g(1.9), .review, "Adobe data", "Left behind when Creative Cloud was removed.", days: 400),
        ]),
    ]

    static let inventory = AppInventoryResult(apps: apps.sorted { $0.totalBytes > $1.totalBytes }, leftovers: leftovers,
                                              builtAt: SampleData.now)

    static func uninstallItems(for app: InstalledApp) -> [Finding] {
        guard app.canUninstall else { return [] }
        let bundle = Finding(path: app.path, name: (app.path as NSString).lastPathComponent, size: app.appBytes, itemCount: 1,
                             modified: app.lastOpened, accessed: app.lastOpened, isDirectory: true,
                             classification: Classification(category: .applications, label: .review, title: app.name,
                                                            explanation: "The app itself.", regenerates: false, source: .rule,
                                                            ruleID: "application"))
        return [bundle] + app.related.filter { $0.label != .protected }
    }

    /// Mirrors the approved mockup: one big tile, a couple of medium ones, the rest small.
    static let tiles: [SpaceTile] = [
        SpaceTile(id: "folder:downloads", title: "Downloads", subtitle: "Installers, videos and old builds",
                  kind: .folder(path: home + "/Downloads"), bytes: g(53.0), safeBytes: g(27.6), checkBytes: g(19.8)),
        SpaceTile(id: "app:xcode", title: "Xcode", subtitle: "The app plus device files and simulators",
                  kind: .app(path: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode"),
                  bytes: g(42.7), safeBytes: g(21.4), checkBytes: g(8.9)),
        SpaceTile(id: "apps", title: "Other apps", subtitle: "23 apps and their data",
                  kind: .apps, bytes: g(28.4), safeBytes: g(6.2), checkBytes: 0),
        SpaceTile(id: "folder:desktop", title: "Desktop", subtitle: "AppDev projects and screenshots",
                  kind: .folder(path: home + "/Desktop"), bytes: g(21.0), safeBytes: g(2.6), checkBytes: 0),
        SpaceTile(id: "category:media", title: "Photos", subtitle: "Photos library",
                  kind: .category(.media), bytes: g(13.0), safeBytes: 0, checkBytes: 0),
        SpaceTile(id: "category:caches", title: "Caches", subtitle: nil,
                  kind: .category(.caches), bytes: g(9.1), safeBytes: g(9.1), checkBytes: 0),
        SpaceTile(id: "folder:documents", title: "Documents", subtitle: nil,
                  kind: .folder(path: home + "/Documents"), bytes: g(8.2), safeBytes: 0, checkBytes: 0),
        SpaceTile(id: "folder:movies", title: "Movies", subtitle: nil,
                  kind: .folder(path: home + "/Movies"), bytes: g(6.0), safeBytes: 0, checkBytes: g(5.4)),
        SpaceTile(id: "other", title: "Everything else", subtitle: "System files and small folders",
                  kind: .other, bytes: g(30.4), safeBytes: 0, checkBytes: 0),
    ]
}
