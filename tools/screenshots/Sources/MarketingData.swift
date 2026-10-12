import Foundation
import FreespanKit

/// Fabricated disk for marketing screenshots: a 500 GB Mac belonging to "alex", nearly full.
/// Nothing here comes from a real disk, and nothing reads one.
enum MarketingData {
    static let home = "/Users/alex"
    static let now = Date()
    static let gb: Int64 = 1_000_000_000
    static let mb: Int64 = 1_000_000
    static let volume = VolumeInfo(name: "Macintosh HD", totalBytes: 500 * gb, availableBytes: 58 * gb)

    private static func g(_ v: Double) -> Int64 { Int64(v * Double(gb)) }
    private static func m(_ v: Double) -> Int64 { Int64(v * Double(mb)) }
    private static func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    // MARK: Tree

    private struct Spec {
        var name: String
        var path: String?
        var bytes: Int64
        var kind: FileNode.Kind = .directory
        var days: Double = 20
        var children: [Spec] = []
    }

    private static func dir(_ name: String, _ bytes: Int64, path: String? = nil, days: Double = 20, _ children: [Spec] = []) -> Spec {
        Spec(name: name, path: path, bytes: bytes, kind: .directory, days: days, children: children)
    }
    private static func file(_ name: String, _ bytes: Int64, days: Double = 60) -> Spec {
        Spec(name: name, bytes: bytes, kind: .file, days: days)
    }
    private static func pkg(_ name: String, _ bytes: Int64, days: Double = 30) -> Spec {
        Spec(name: name, bytes: bytes, kind: .package, days: days)
    }

    private static let spec: Spec = dir("Macintosh HD", g(408), path: "/System/Volumes/Data", [
        dir("Users", g(322), path: "/Users", [
            dir("alex", g(320), path: home, [
                dir("Library", g(131), [
                    dir("Developer", g(64.5), [
                        dir("Xcode", g(43.5), [
                            dir("DerivedData", g(38.0), days: 1, [
                                dir("Trailhead-bqzhxkpafvjd", g(14.2), days: 1),
                                dir("Pantry-fkwnyrgxtsle", g(9.8), days: 3),
                                dir("Lumen-cmqpzvhudnoe", g(7.6), days: 12),
                                dir("Fieldnotes-awhtrbnlqzke", g(6.4), days: 40),
                            ]),
                            dir("iOS DeviceSupport", g(5.5), days: 8, [
                                dir("iOS 26.4 (23E244)", g(2.9), days: 8),
                                dir("iOS 18.6.2 (22G100)", g(2.6), days: 230),
                            ]),
                        ]),
                        dir("CoreSimulator", g(21.0), days: 4, [
                            dir("Devices", g(18.4), days: 4),
                            dir("Caches", g(2.6), days: 4),
                        ]),
                    ]),
                    dir("Application Support", g(36.0), [
                        dir("MobileSync", g(19.6), days: 90, [
                            dir("Backup", g(19.6), days: 90, [
                                dir("00008110-001A2C3E0E8B801E", g(11.2), days: 410),
                                dir("00008030-000C59D23C02402E", g(8.4), days: 720),
                            ]),
                        ]),
                        dir("GarageBand", g(6.8), days: 260),
                        dir("Spotify", g(3.4), days: 2, [dir("PersistentCache", g(3.2), days: 2)]),
                        dir("Microsoft Teams", g(2.2), days: 1),
                    ]),
                    dir("Containers", g(15.6), [
                        dir("com.docker.docker", g(14.0), days: 45),
                        dir("com.apple.mail", g(1.2), days: 0.1),
                    ]),
                    dir("Caches", g(9.0), days: 0.5, [
                        dir("com.spotify.client", g(2.3), days: 0.5),
                        dir("Google", g(2.0), days: 0.3),
                        dir("com.microsoft.teams2", g(1.4), days: 1),
                        dir("Homebrew", g(1.2), days: 15),
                        dir("com.apple.dt.Xcode", g(1.1), days: 1),
                        dir("com.microsoft.VSCode.ShipIt", m(600), days: 33),
                    ]),
                    dir("Logs", m(900), days: 0.2),
                    dir("Mail", g(3.4), days: 0.1),
                ]),
                dir("Pictures", g(52.0), days: 2, [
                    pkg("Photos Library.photoslibrary", g(50.8), days: 0.5),
                ]),
                dir("Movies", g(34.0), days: 30, [
                    pkg("iMovie Library.imovielibrary", g(21.3), days: 30),
                    dir("Iceland Trip 2021 (Raw)", g(9.1), days: 1_150),
                ]),
                dir("Documents", g(26.0), days: 1, [
                    dir("Client Work", g(11.0), days: 2),
                    dir("Taxes", g(1.4), days: 160),
                ]),
                dir("Downloads", g(12.1), days: 2, [
                    pkg("Install macOS Tahoe.app", g(5.1), days: 80),
                    file("Xcode_26.1.xip", g(3.0), days: 140),
                    file("Product-Demo-Final.mov", g(2.2), days: 190),
                    file("Font-Collection.zip", m(900), days: 300),
                    file("Obsidian-1.9.dmg", m(400), days: 55),
                ]),
                dir("Music", g(8.0), days: 90),
                dir("Desktop", g(7.5), days: 0.2, [
                    dir("Projects", g(6.8), days: 0.2, [
                        dir("trailhead-web", g(3.4), days: 0.5, [dir("node_modules", g(1.1), days: 18)]),
                        dir("pantry-site", g(2.2), days: 6, [dir("node_modules", m(900), days: 40)]),
                    ]),
                ]),
                dir(".npm", g(1.8), days: 9),
            ]),
        ]),
        dir("Applications", g(46.0), path: "/Applications", days: 6, [
            pkg("Xcode.app", g(12.4), days: 1),
            pkg("Microsoft Word.app", g(2.6), days: 3),
            pkg("Microsoft Excel.app", g(2.4), days: 12),
            pkg("Microsoft PowerPoint.app", g(2.1), days: 30),
            pkg("Microsoft Teams.app", g(1.1), days: 1),
            pkg("Google Chrome.app", g(1.6), days: 0.1),
            pkg("GarageBand.app", g(1.4), days: 260),
            pkg("iMovie.app", g(3.2), days: 30),
            pkg("Visual Studio Code.app", m(690), days: 1),
            pkg("Spotify.app", m(420), days: 0.5),
            pkg("Webex.app", m(920), days: 210),
            pkg("Obsidian.app", m(380), days: 4),
        ]),
        dir("Library", g(22.0), path: "/Library", days: 30),
        dir("private", g(16.0), path: "/private", days: 0.1, [
            dir("var", g(15.6), path: "/private/var", days: 0.1, [
                dir("vm", g(9.0), path: "/private/var/vm", days: 0.1),
                dir("folders", g(5.0), path: "/private/var/folders", days: 0.1),
            ]),
        ]),
    ])

    private static func build() -> FileNode {
        var nextID: UInt64 = 1
        func make(_ spec: Spec, parentPath: String?) -> FileNode {
            let path = spec.path ?? ((parentPath ?? "") + "/" + spec.name)
            var children = spec.children.map { make($0, parentPath: path) }
            let childBytes = children.reduce(0) { $0 + $1.size }
            if spec.kind == .directory, spec.bytes > childBytes {
                let rest = spec.bytes - childBytes
                children.append(FileNode(id: nextID, name: children.isEmpty ? "Files" : "Other files", path: path, kind: .smallFiles,
                                         size: rest, itemCount: max(1, Int(rest / 2_000_000)),
                                         modified: ago(spec.days), accessed: nil, children: []))
                nextID += 1
            }
            children.sort { $0.size > $1.size }
            let id = nextID
            nextID += 1
            let size = max(spec.bytes, childBytes)
            let items = spec.kind == .file ? 1 : (children.isEmpty ? max(1, Int(size / 1_500_000)) : children.reduce(0) { $0 + $1.itemCount })
            return FileNode(id: id, name: spec.name, path: path, kind: spec.kind, size: size, itemCount: items,
                            modified: ago(spec.days), accessed: ago(spec.days).addingTimeInterval(3_600),
                            children: spec.kind == .directory ? children : [])
        }
        return make(spec, parentPath: nil)
    }

    static let root: FileNode = build()

    static let scan = ScanResult(root: root, volume: volume, scannedAt: now.addingTimeInterval(-180), duration: 71,
                                 inaccessiblePaths: [])

    // MARK: Findings

    private struct Rule {
        let path: String
        let category: CategoryID
        let label: SafetyLabel
        let title: String
        let why: String
        var ruleID: String?
        var source: ClassificationSource = .rule
    }

    private static let L = home + "/Library"
    private static let ds = L + "/Developer/Xcode/iOS DeviceSupport"

    private static let rules: [Rule] = [
        // Safe
        Rule(path: L + "/Developer/Xcode/DerivedData", category: .developer, label: .safe, title: "Xcode build files",
             why: "Intermediate build products. Xcode rebuilds them the next time you build.", ruleID: "xcode-derived-data"),
        Rule(path: ds + "/iOS 18.6.2 (22G100)", category: .developer, label: .safe, title: "Debug symbols · iOS 18.6.2",
             why: "Left over from an iPhone you no longer use. Xcode copies them again if needed.", ruleID: "xcode-device-support"),
        Rule(path: L + "/Developer/CoreSimulator/Caches", category: .developer, label: .safe, title: "Simulator caches",
             why: "The Simulator rebuilds these when it starts.", ruleID: "simulator-caches"),
        Rule(path: L + "/Caches/com.spotify.client", category: .caches, label: .safe, title: "Spotify cache",
             why: "Temporary files Spotify rebuilds on its own.", ruleID: "app-cache"),
        Rule(path: L + "/Caches/Google", category: .caches, label: .safe, title: "Chrome cache",
             why: "Websites load these again as you browse.", ruleID: "browser-cache"),
        Rule(path: L + "/Caches/com.microsoft.teams2", category: .caches, label: .safe, title: "Teams cache",
             why: "Temporary files Teams rebuilds on its own.", ruleID: "app-cache"),
        Rule(path: L + "/Caches/com.apple.dt.Xcode", category: .caches, label: .safe, title: "Xcode cache",
             why: "Documentation and index caches Xcode rebuilds on its own.", ruleID: "app-cache"),
        Rule(path: L + "/Caches/com.microsoft.VSCode.ShipIt", category: .caches, label: .safe, title: "VS Code update files",
             why: "Old update downloads. VS Code fetches new ones when it updates.", ruleID: "app-cache"),
        Rule(path: L + "/Caches/Homebrew", category: .caches, label: .safe, title: "Homebrew downloads",
             why: "Cached bottles from past installs.", ruleID: "homebrew-cache"),
        Rule(path: home + "/.npm", category: .developer, label: .safe, title: "npm cache",
             why: "Downloaded packages. npm fetches them again when needed.", ruleID: "npm-cache"),
        Rule(path: home + "/Desktop/Projects/trailhead-web/node_modules", category: .developer, label: .safe, title: "node_modules · trailhead-web",
             why: "Installed JavaScript packages. Run npm install to get them back.", ruleID: "node-modules"),
        Rule(path: home + "/Desktop/Projects/pantry-site/node_modules", category: .developer, label: .safe, title: "node_modules · pantry-site",
             why: "Installed JavaScript packages. Run npm install to get them back.", ruleID: "node-modules"),
        Rule(path: L + "/Logs", category: .caches, label: .safe, title: "Logs",
             why: "Diagnostic logs and crash reports apps wrote.", ruleID: "user-logs"),
        Rule(path: home + "/Downloads/Install macOS Tahoe.app", category: .downloads, label: .safe, title: "macOS installer",
             why: "You're already on this version. The App Store can download it again.", ruleID: "download-installer"),
        Rule(path: home + "/Downloads/Xcode_26.1.xip", category: .downloads, label: .safe, title: "Xcode archive",
             why: "Xcode is already installed in Applications.", ruleID: "download-installer"),
        Rule(path: home + "/Downloads/Obsidian-1.9.dmg", category: .downloads, label: .safe, title: "Disk image installer",
             why: "Obsidian is already installed.", ruleID: "download-installer"),
        // Worth a look
        Rule(path: home + "/Library/Application Support/MobileSync/Backup/00008110-001A2C3E0E8B801E", category: .backups, label: .review,
             title: "iPhone backup", why: "An iPhone 13 backup from last summer. Fine to remove if your iPhone backs up to iCloud.",
             ruleID: "iphone-backup"),
        Rule(path: L + "/Developer/CoreSimulator/Devices", category: .developer, label: .review, title: "iOS Simulators",
             why: "Test devices for apps. Xcode can make new ones anytime.", ruleID: "simulator-device"),
        Rule(path: L + "/Containers/com.docker.docker", category: .developer, label: .review, title: "Docker disk image",
             why: "Holds your containers and images. Prune unused images in Docker instead of deleting this.", source: .ai),
        Rule(path: home + "/Movies/Iceland Trip 2021 (Raw)", category: .largeOld, label: .review, title: "Untouched for 3+ years",
             why: "Raw footage nobody has opened since 2022. Move it to an external drive if you want to keep it.",
             ruleID: "large-old-file"),
        Rule(path: home + "/Library/Application Support/MobileSync/Backup/00008030-000C59D23C02402E", category: .backups, label: .review,
             title: "iPhone backup", why: "An iPhone 11 backup from two years ago.", ruleID: "iphone-backup"),
        Rule(path: home + "/Library/Application Support/GarageBand", category: .applications, label: .review, title: "GarageBand sound library",
             why: "Instruments and loops. GarageBand downloads them again if you open it.", source: .heuristic),
        Rule(path: L + "/Application Support/Spotify/PersistentCache", category: .media, label: .review, title: "Offline music",
             why: "Songs saved for offline listening. Spotify can download them again.", ruleID: "spotify-offline"),
        Rule(path: ds + "/iOS 26.4 (23E244)", category: .developer, label: .review, title: "Debug symbols · iOS 26.4",
             why: "Matches the iPhone you use now. Xcode copies it back the next time you plug in.", ruleID: "xcode-device-support"),
        Rule(path: home + "/Downloads/Product-Demo-Final.mov", category: .downloads, label: .review, title: "Large video",
             why: "An exported video you haven't opened in six months. Check it's backed up first.", ruleID: "download-old"),
        Rule(path: home + "/Downloads/Font-Collection.zip", category: .downloads, label: .review, title: "Old download",
             why: "Downloaded ten months ago and never opened since.", ruleID: "download-old"),
        Rule(path: "/Applications/Webex.app", category: .applications, label: .review, title: "Webex",
             why: "Not opened in seven months. You can reinstall it anytime.", ruleID: "application"),
        // Keep / protected
        Rule(path: home + "/Pictures/Photos Library.photoslibrary", category: .media, label: .keep, title: "Photos library",
             why: "Your photos. Use Optimize Mac Storage in Photos to save space instead.", ruleID: "photos-library"),
        Rule(path: home + "/Movies/iMovie Library.imovielibrary", category: .media, label: .keep, title: "iMovie library",
             why: "Your iMovie projects and media.", ruleID: "imovie-library"),
        Rule(path: L + "/Mail", category: .media, label: .protected, title: "Mail",
             why: "Your mailboxes. Managed by Mail, never touched by Freespan."),
        Rule(path: "/Applications/Xcode.app", category: .applications, label: .keep, title: "Xcode", why: "You used it yesterday.",
             ruleID: "application"),
        Rule(path: "/private/var/vm", category: .system, label: .protected, title: "Swap & sleep image",
             why: "Virtual memory managed by macOS."),
    ]

    static let findings: [Finding] = rules.compactMap { rule in
        guard let node = node(at: rule.path) else { return nil }
        let c = Classification(category: rule.category, label: rule.label, title: rule.title, explanation: rule.why,
                               regenerates: rule.label == .safe, source: rule.source,
                               ruleID: rule.source == .rule ? rule.ruleID ?? rule.title : nil)
        return Finding(node: node, classification: c)
    }
    .sorted { $0.size > $1.size }

    static let unknown: [FileNode] = [L + "/Containers/com.docker.docker"].compactMap(node(at:))

    static var analysis: ScanAnalysis { ScanAnalysis(findings: findings, unknown: unknown) }

    static func node(at path: String) -> FileNode? {
        var current = root
        while current.path != path {
            guard let next = current.children.first(where: {
                $0.kind != .smallFiles && PathUtil.isSameOrDescendant(path, of: $0.path)
            }) else { return nil }
            current = next
        }
        return current
    }

    static func finding(_ path: String) -> Finding? { findings.first { $0.path == path } }

    // MARK: Plan

    static let rulePlan = CleanupPlan(headline: "About 66 GB is Safe to clear. Another 50 GB is worth a look.", steps: [
        .init(title: "Xcode build files", reasoning: "Intermediate build products for four projects. Xcode rebuilds them on the next build.",
              paths: ["~/Library/Developer/Xcode/DerivedData"], estimatedBytes: g(38.0), risk: .safe),
        .init(title: "App and browser caches", reasoning: "Temporary files apps rebuild on their own.",
              paths: ["~/Library/Caches/com.spotify.client", "~/Library/Caches/Google", "~/Library/Caches/com.microsoft.teams2",
                      "~/Library/Caches/com.apple.dt.Xcode"], estimatedBytes: g(6.8), risk: .safe),
        .init(title: "Installers you've already used", reasoning: "Installers for apps that are already installed. They can be downloaded again.",
              paths: ["~/Downloads/Install macOS Tahoe.app", "~/Downloads/Xcode_26.1.xip", "~/Downloads/Obsidian-1.9.dmg"],
              estimatedBytes: g(8.5), risk: .safe),
        .init(title: "Old iPhone backups", reasoning: "Two backups of iPhones you no longer use. Keep them if they're your only copy.",
              paths: ["~/Library/Application Support/MobileSync/Backup/00008110-001A2C3E0E8B801E",
                      "~/Library/Application Support/MobileSync/Backup/00008030-000C59D23C02402E"],
              estimatedBytes: g(19.6), risk: .review),
    ])

    // MARK: Apps

    private static func item(_ path: String, _ bytes: Int64, _ label: SafetyLabel, _ title: String, _ why: String,
                             category: CategoryID = .applications, rule: String? = nil, days: Double = 3) -> Finding {
        Finding(path: path, name: (path as NSString).lastPathComponent, size: bytes, itemCount: max(1, Int(bytes / 2_000_000)),
                modified: ago(days), accessed: ago(days), isDirectory: true,
                classification: Classification(category: category, label: label, title: title, explanation: why,
                                               regenerates: label == .safe, source: .rule,
                                               ruleID: rule ?? (label == .safe ? "app-cache" : "app-data")))
    }

    private static func app(_ name: String, id: String, version: String, bytes: Int64, opened: Double?,
                            related: [Finding]) -> InstalledApp {
        InstalledApp(path: "/Applications/\(name).app", name: name, bundleID: id, version: version, appBytes: bytes,
                     lastOpened: opened.map(ago), isAppleApp: id.hasPrefix("com.apple."), canUninstall: true,
                     uninstallBlockedReason: nil, related: related)
    }

    static let apps: [InstalledApp] = [
        app("Xcode", id: "com.apple.dt.Xcode", version: "26.4", bytes: g(12.4), opened: 1, related: [
            item(L + "/Developer/Xcode/DerivedData", g(38.0), .safe, "Build files",
                 "Rebuilt automatically the next time you build a project.", category: .developer, rule: "xcode-derived-data"),
            item(L + "/Developer/CoreSimulator/Devices", g(18.4), .review, "Simulators",
                 "Test devices for apps. Xcode can make new ones anytime.", category: .developer, rule: "simulator-device"),
            item(ds, g(5.5), .safe, "Xcode device files",
                 "Xcode copies these again when you plug in an iPhone.", category: .developer, rule: "xcode-device-support"),
            item(L + "/Developer/CoreSimulator/Caches", g(2.6), .safe, "Simulator caches",
                 "The Simulator rebuilds these when it starts.", category: .developer, rule: "simulator-caches"),
            item(L + "/Caches/com.apple.dt.Xcode", g(1.1), .safe, "Xcode cache",
                 "Documentation and index caches Xcode rebuilds on its own.", category: .caches),
        ]),
        app("GarageBand", id: "com.apple.garageband10", version: "10.4.12", bytes: g(1.4), opened: 260, related: [
            item(L + "/Application Support/GarageBand", g(6.8), .review, "Sound library",
                 "Instruments and loops. GarageBand downloads them again if you open it."),
        ]),
        app("Spotify", id: "com.spotify.client", version: "1.2.71", bytes: m(420), opened: 0.5, related: [
            item(L + "/Application Support/Spotify/PersistentCache", g(3.2), .review, "Offline music",
                 "Songs saved for offline listening. Spotify can download them again.", category: .media, rule: "spotify-offline"),
            item(L + "/Caches/com.spotify.client", g(2.3), .safe, "App cache",
                 "Apps rebuild these on their own when they need them.", category: .caches),
        ]),
        app("Google Chrome", id: "com.google.Chrome", version: "141.0", bytes: g(1.6), opened: 0.1, related: [
            item(L + "/Application Support/Google/Chrome", g(3.1), .keep, "Chrome profile",
                 "Your bookmarks, history, passwords and extensions."),
            item(L + "/Caches/Google", g(2.0), .safe, "Browser cache", "Websites load these again as you browse.",
                 category: .caches, rule: "browser-cache"),
        ]),
        app("Microsoft Teams", id: "com.microsoft.teams2", version: "25.2", bytes: g(1.1), opened: 1, related: [
            item(L + "/Application Support/Microsoft Teams", g(2.2), .review, "Teams data",
                 "Chat history cache and settings. Signing in again rebuilds most of it."),
            item(L + "/Caches/com.microsoft.teams2", g(1.4), .safe, "App cache",
                 "Apps rebuild these on their own when they need them.", category: .caches),
        ]),
        app("iMovie", id: "com.apple.iMovieApp", version: "10.4.3", bytes: g(3.2), opened: 30, related: [
            item(L + "/Containers/com.apple.iMovieApp", m(840), .review, "iMovie data", "Render files and settings."),
        ]),
        app("Microsoft Word", id: "com.microsoft.Word", version: "16.98", bytes: g(2.6), opened: 3, related: [
            item(L + "/Containers/com.microsoft.Word", m(620), .review, "Word data", "Templates, add-ins and recent-file previews."),
        ]),
        app("Microsoft Excel", id: "com.microsoft.Excel", version: "16.98", bytes: g(2.4), opened: 12, related: [
            item(L + "/Containers/com.microsoft.Excel", m(510), .review, "Excel data", "Templates, add-ins and recent-file previews."),
        ]),
        app("Microsoft PowerPoint", id: "com.microsoft.Powerpoint", version: "16.98", bytes: g(2.1), opened: 30, related: [
            item(L + "/Containers/com.microsoft.Powerpoint", m(460), .review, "PowerPoint data", "Themes and recent-file previews."),
        ]),
        app("Webex", id: "Cisco-Systems.Spark", version: "45.6", bytes: m(920), opened: 210, related: [
            item(L + "/Application Support/Cisco Spark", m(540), .review, "Webex data", "Meeting cache and settings."),
            item(L + "/Logs/Webex", m(120), .safe, "Logs", "Apps start fresh logs as they run.", category: .caches, rule: "user-logs"),
        ]),
        app("Visual Studio Code", id: "com.microsoft.VSCode", version: "1.105", bytes: m(690), opened: 1, related: [
            item(L + "/Caches/com.microsoft.VSCode.ShipIt", m(600), .safe, "Update downloads",
                 "Old update files. VS Code downloads new ones when it updates.", category: .caches),
            item(L + "/Application Support/Code", m(480), .review, "Visual Studio Code data",
                 "Editor state, extensions' storage and workspace history."),
        ]),
        app("Obsidian", id: "md.obsidian", version: "1.9.12", bytes: m(380), opened: 4, related: [
            item(L + "/Application Support/obsidian", m(160), .review, "Obsidian data", "Settings and plugin data."),
        ]),
    ]

    static let leftovers: [Leftover] = [
        Leftover(ownerName: "Adobe Photoshop 2024", bundleID: "com.adobe.Photoshop", items: [
            item(L + "/Application Support/Adobe", g(2.3), .review, "Adobe data", "Left behind when Photoshop was removed.", days: 400),
            item(L + "/Caches/Adobe", m(410), .safe, "App cache", "Left behind when Photoshop was removed.", category: .caches, days: 400),
        ]),
        Leftover(ownerName: "Zoom", bundleID: "us.zoom.xos", items: [
            item(L + "/Application Support/zoom.us", m(780), .review, "Zoom data", "Left behind when Zoom was removed.", days: 220),
        ]),
    ]

    static let inventory = AppInventoryResult(apps: apps.sorted { $0.totalBytes > $1.totalBytes }, leftovers: leftovers, builtAt: now)

    static func uninstallItems(for app: InstalledApp) -> [Finding] {
        let bundle = Finding(path: app.path, name: (app.path as NSString).lastPathComponent, size: app.appBytes, itemCount: 1,
                             modified: app.lastOpened, accessed: app.lastOpened, isDirectory: true,
                             classification: Classification(category: .applications, label: .review, title: app.name,
                                                            explanation: "The app itself.", regenerates: false, source: .rule,
                                                            ruleID: "application"))
        return [bundle] + app.related.filter { $0.label != .protected }
    }

    // MARK: Tiles

    static let tiles: [SpaceTile] = [
        SpaceTile(id: "app:xcode", title: "Xcode", subtitle: "The app plus device files and simulators",
                  kind: .app(path: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode"),
                  bytes: g(78.0), safeBytes: g(47.2), checkBytes: g(21.3)),
        SpaceTile(id: "photos", title: "Photos", subtitle: "Photos library",
                  kind: .category(.media), bytes: g(50.8), safeBytes: 0, checkBytes: 0),
        SpaceTile(id: "apps", title: "Other apps", subtitle: "11 apps and their data",
                  kind: .apps, bytes: g(36.4), safeBytes: g(4.8), checkBytes: g(11.9)),
        SpaceTile(id: "folder:movies", title: "Movies", subtitle: "iMovie library and raw footage",
                  kind: .folder(path: home + "/Movies"), bytes: g(34.0), safeBytes: 0, checkBytes: g(9.1)),
        SpaceTile(id: "folder:documents", title: "Documents", subtitle: nil,
                  kind: .folder(path: home + "/Documents"), bytes: g(26.0), safeBytes: 0, checkBytes: 0),
        SpaceTile(id: "category:backups", title: "iPhone backups", subtitle: nil,
                  kind: .category(.backups), bytes: g(19.6), safeBytes: 0, checkBytes: g(19.6)),
        SpaceTile(id: "docker", title: "Docker", subtitle: nil,
                  kind: .category(.developer), bytes: g(14.0), safeBytes: 0, checkBytes: g(14.0)),
        SpaceTile(id: "folder:downloads", title: "Downloads", subtitle: nil,
                  kind: .folder(path: home + "/Downloads"), bytes: g(12.1), safeBytes: g(8.5), checkBytes: g(3.1)),
        SpaceTile(id: "category:caches", title: "Caches", subtitle: nil,
                  kind: .category(.caches), bytes: g(9.0), safeBytes: g(9.0), checkBytes: 0),
        SpaceTile(id: "other", title: "Everything else", subtitle: "System files and small folders",
                  kind: .other, bytes: g(40.1), safeBytes: 0, checkBytes: 0),
    ]
}

// MARK: - Services

/// In-memory cleanup: nothing in use, empty history.
actor MarketingCleanup: CleanupPerforming {
    func moveToTrash(_ findings: [Finding]) async -> CleanupReport {
        CleanupReport(trashed: findings.map {
            ActionLogEntry(originalPath: $0.path, trashPath: MarketingData.home + "/.Trash/" + $0.name, size: $0.size)
        }, skipped: [])
    }
    func inUse(_ findings: [Finding]) async -> [String: InUseStatus] { [:] }
    func undo(_ entry: ActionLogEntry) async throws {}
    func history() async -> [ActionLogEntry] { [] }
}

extension FreespanServices {
    /// Starts from the preview services (no I/O) and swaps in the marketing disk.
    static func marketing() -> FreespanServices {
        var s = FreespanServices.sample(inUse: .none)
        s.home = MarketingData.home
        s.scan = { _, _ in AsyncThrowingStream { $0.yield(.finished(MarketingData.scan)); $0.finish() } }
        s.hasFullDiskAccess = { true }
        s.loadCache = { MarketingData.scan }
        s.analyze = { _, _ in MarketingData.analysis }
        s.isProtected = { path in
            ["/System", "/private/var/vm", MarketingData.home + "/Library/Mail"].contains { PathUtil.isSameOrDescendant(path, of: $0) }
        }
        s.isInTrash = { PathUtil.isSameOrDescendant($0, of: MarketingData.home + "/.Trash") }
        s.itemExists = { _ in false }
        s.metadata = { node in
            ItemMetadata(path: node.path.replacingOccurrences(of: MarketingData.home, with: "~"), sizeBytes: node.size,
                         isDirectory: node.kind != .file, itemCount: node.itemCount, modified: node.modified,
                         accessed: node.accessed, topChildren: node.children.prefix(5).map(\.name))
        }
        s.unredact = { $0.hasPrefix("~") ? MarketingData.home + $0.dropFirst() : $0 }
        s.rulePlan = { _, _, _ in MarketingData.rulePlan }
        s.cleanup = MarketingCleanup()
        s.appInventory = { _, _, _ in MarketingData.inventory }
        s.spaceTiles = { _, _, _, _ in MarketingData.tiles }
        s.uninstallItems = { MarketingData.uninstallItems(for: $0) }
        s.canQuitApp = { _ in false }
        return s
    }
}
