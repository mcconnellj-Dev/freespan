import Foundation
import FreespanKit

/// Realistic sample disk of a busy developer Mac: 460 GB volume, 12 GB free.
/// Drives every `#Preview` and doubles as the Phase 0 mockup data. No real I/O anywhere.
enum SampleData {
    static let home = "/Users/alex"
    static let now = Date(timeIntervalSince1970: 1_791_590_400) // Oct 10 2026
    static let volume = VolumeInfo(name: "Macintosh HD", totalBytes: 460 * gb, availableBytes: 12 * gb)

    static let gb: Int64 = 1_000_000_000
    static let mb: Int64 = 1_000_000

    // MARK: Tree spec

    private struct Spec {
        var name: String
        var path: String?
        var bytes: Int64
        var kind: FileNode.Kind = .directory
        var daysAgo: Double = 20
        var children: [Spec] = []
    }

    private static func dir(_ name: String, _ bytes: Int64, path: String? = nil, days: Double = 20, _ children: [Spec] = []) -> Spec {
        Spec(name: name, path: path, bytes: bytes, kind: .directory, daysAgo: days, children: children)
    }

    private static func file(_ name: String, _ bytes: Int64, days: Double = 60) -> Spec {
        Spec(name: name, bytes: bytes, kind: .file, daysAgo: days)
    }

    private static func package(_ name: String, _ bytes: Int64, days: Double = 30) -> Spec {
        Spec(name: name, bytes: bytes, kind: .package, daysAgo: days)
    }

    private static func g(_ value: Double) -> Int64 { Int64(value * Double(gb)) }
    private static func m(_ value: Double) -> Int64 { Int64(value * Double(mb)) }

    private static let spec: Spec = dir("Macintosh HD", g(240), path: "/System/Volumes/Data", [
        dir("Users", g(178), path: "/Users", [
            dir("alex", g(176), path: home, [
                dir("Library", g(66), [
                    dir("Developer", g(30.6), [
                        dir("Xcode", g(18.6), [
                            dir("iOS DeviceSupport", g(17.0), days: 12, [
                                dir("iOS 26.4 (23E244)", g(4.1), days: 6),
                                dir("iOS 26.3.1 (23D60)", g(3.9), days: 48),
                                dir("iOS 26.2 (23C55)", g(3.6), days: 96),
                                dir("iOS 18.6.2 (22G100)", g(2.9), days: 210),
                                dir("iOS 18.5 (22F76)", g(2.5), days: 260),
                            ]),
                            dir("DerivedData", g(1.3), days: 1, [
                                dir("AtTheShow-bqzhxkpafvjd", m(780), days: 1),
                                dir("Freespan-fkwnyrgxtsle", m(310), days: 0.2),
                                dir("DeckSmith-cmqpzvhudnoe", m(210), days: 9),
                            ]),
                        ]),
                        dir("CoreSimulator", g(11.2), days: 4, [
                            dir("Devices", g(8.9), days: 4, [
                                dir("iPhone 17 Pro (26.4)", g(3.1), days: 4),
                                dir("iPhone 16 (18.6)", g(2.4), days: 140),
                                dir("iPad Pro 13-inch (26.2)", g(1.9), days: 88),
                                dir("Apple Watch Ultra 3 (26.0)", g(1.5), days: 190),
                            ]),
                            dir("Caches", g(2.1), days: 4),
                        ]),
                    ]),
                    dir("Caches", g(15.1), days: 0.5, [
                        dir("com.spotify.client", g(4.2), days: 0.5),
                        dir("com.apple.dt.Xcode", g(3.1), days: 1),
                        dir("Google", g(2.6), days: 0.5),
                        dir("com.microsoft.VSCode.ShipIt", g(1.8), days: 33),
                        dir("Homebrew", g(1.6), days: 15),
                        dir("com.apple.Music", g(0.9), days: 2),
                    ]),
                    dir("Application Support", g(9.4), [
                        dir("Steam", g(3.6), days: 120),
                        dir("Slack", g(1.9), days: 0.3),
                        dir("Code", g(1.2), days: 1),
                    ]),
                    dir("Containers", g(4.4), [
                        dir("com.apple.mail", g(2.2), days: 0.1),
                        dir("com.docker.docker", g(1.7), days: 60),
                    ]),
                    dir("Mail", g(2.3), days: 0.1),
                ]),
                dir("Downloads", g(53.0), days: 2, [
                    package("Install macOS Tahoe 26.4.app", g(14.2), days: 75),
                    file("Xcode_26.1.xip", g(11.8), days: 140),
                    file("Concert-Export-Final.mov", g(8.4), days: 190),
                    file("Photos-Archive-2024.zip", g(6.3), days: 240),
                    dir("AtTheShow-Builds", g(5.1), days: 30),
                    file("Sonos-S2-Controller.dmg", g(1.2), days: 300),
                    file("Figma-Installer.dmg", m(410), days: 55),
                ]),
                dir("Desktop", g(21.0), days: 0.2, [
                    dir("AppDev", g(14.0), days: 0.2, [
                        dir("AtTheShow", g(6.2), days: 0.5, [dir("node_modules", g(1.2), days: 18)]),
                        dir("HomeLibrary", g(4.1), days: 3, [dir("node_modules", m(900), days: 40)]),
                        dir("DeckSmith", g(2.9), days: 1, [dir("node_modules", m(500), days: 9)]),
                    ]),
                    dir("Screenshots", g(3.4), days: 1),
                ]),
                dir("Pictures", g(13.0), days: 3, [
                    package("Photos Library.photoslibrary", g(12.1), days: 0.5),
                ]),
                dir("Documents", g(8.2), days: 1, [
                    dir("Kitchen Renovation", g(3.1), days: 5),
                    dir("Taxes", g(1.2), days: 160),
                ]),
                dir("Movies", g(6.0), days: 400, [
                    dir("2019 Wedding Raw Footage", g(5.4), days: 1300),
                ]),
                dir("Music", g(4.1), days: 90),
                dir(".npm", g(2.5), days: 9, [dir("_cacache", g(2.4), days: 9)]),
            ]),
        ]),
        dir("Applications", g(31.0), path: "/Applications", days: 6, [
            package("Xcode.app", g(12.4), days: 6),
            package("Final Cut Pro.app", g(5.8), days: 50),
            package("Logic Pro.app", g(2.9), days: 200),
            package("Docker.app", g(2.1), days: 60),
            package("Slack.app", m(560), days: 2),
        ]),
        dir("private", g(14.0), path: "/private", days: 0.1, [
            dir("var", g(13.6), path: "/private/var", days: 0.1, [
                dir("vm", g(8.0), path: "/private/var/vm", days: 0.1),
                dir("folders", g(4.1), path: "/private/var/folders", days: 0.1),
            ]),
        ]),
        dir("Library", g(9.0), path: "/Library", days: 30),
    ])

    // MARK: Materialize

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
                                         modified: now.addingTimeInterval(-spec.daysAgo * 86_400), accessed: nil, children: []))
                nextID += 1
            }
            children.sort { $0.size > $1.size }
            let id = nextID
            nextID += 1
            let date = now.addingTimeInterval(-spec.daysAgo * 86_400)
            let size = max(spec.bytes, childBytes)
            let items = spec.kind == .file ? 1 : (children.isEmpty ? max(1, Int(size / 1_500_000)) : children.reduce(0) { $0 + $1.itemCount })
            return FileNode(id: id, name: spec.name, path: path, kind: spec.kind, size: size, itemCount: items,
                            modified: date, accessed: date.addingTimeInterval(3_600), children: spec.kind == .directory ? children : [])
        }
        return make(spec, parentPath: nil)
    }

    static let root: FileNode = build()

    static let scan = ScanResult(
        root: root, volume: volume, scannedAt: now.addingTimeInterval(-120), duration: 94,
        inaccessiblePaths: [home + "/Library/Application Support/MobileSync", home + "/Library/Safari", home + "/.Trash"]
    )

    // MARK: Findings

    private struct Rule {
        let path: String
        let category: CategoryID
        let label: SafetyLabel
        let title: String
        let explanation: String
        var regenerates = false
        var source: ClassificationSource = .rule
        var ruleID: String?
    }

    private static let L = home + "/Library"
    private static let deviceSupport = L + "/Developer/Xcode/iOS DeviceSupport"

    private static let rules: [Rule] = [
        Rule(path: deviceSupport + "/iOS 26.4 (23E244)", category: .developer, label: .review, title: "Debug symbols · iOS 26.4",
             explanation: "Matches the iPhone you use now. Xcode copies it back the next time you plug in, which takes a few minutes.", regenerates: true),
        Rule(path: deviceSupport + "/iOS 26.3.1 (23D60)", category: .developer, label: .safe, title: "Debug symbols · iOS 26.3.1",
             explanation: "For an iOS version your devices no longer run. Xcode re-downloads it if you ever need it.", regenerates: true),
        Rule(path: deviceSupport + "/iOS 26.2 (23C55)", category: .developer, label: .safe, title: "Debug symbols · iOS 26.2",
             explanation: "For an iOS version your devices no longer run. Xcode re-downloads it if you ever need it.", regenerates: true),
        Rule(path: deviceSupport + "/iOS 18.6.2 (22G100)", category: .developer, label: .safe, title: "Debug symbols · iOS 18.6.2",
             explanation: "Left over from an older iPhone. Safe to clear.", regenerates: true),
        Rule(path: deviceSupport + "/iOS 18.5 (22F76)", category: .developer, label: .safe, title: "Debug symbols · iOS 18.5",
             explanation: "Left over from an older iPhone. Safe to clear.", regenerates: true),
        Rule(path: L + "/Developer/Xcode/DerivedData", category: .developer, label: .safe, title: "Xcode build products",
             explanation: "Intermediate build files. Xcode rebuilds them on the next build.", regenerates: true),
        Rule(path: L + "/Developer/CoreSimulator/Devices", category: .developer, label: .review, title: "Simulator devices",
             explanation: "Apps and data inside your iOS simulators. Delete old runtimes from Xcode › Settings › Components if you don't test on them."),
        Rule(path: L + "/Developer/CoreSimulator/Caches", category: .developer, label: .safe, title: "Simulator caches",
             explanation: "Dyld and runtime caches. The simulator rebuilds them at launch.", regenerates: true),
        Rule(path: home + "/Desktop/AppDev/AtTheShow/node_modules", category: .developer, label: .safe, title: "node_modules · AtTheShow",
             explanation: "Installed JavaScript packages. Run npm install to get them back.", regenerates: true),
        Rule(path: home + "/Desktop/AppDev/HomeLibrary/node_modules", category: .developer, label: .safe, title: "node_modules · HomeLibrary",
             explanation: "Installed JavaScript packages. Run npm install to get them back.", regenerates: true),
        Rule(path: home + "/Desktop/AppDev/DeckSmith/node_modules", category: .developer, label: .safe, title: "node_modules · DeckSmith",
             explanation: "Installed JavaScript packages. Run npm install to get them back.", regenerates: true),
        Rule(path: home + "/.npm", category: .developer, label: .safe, title: "npm cache",
             explanation: "Downloaded package tarballs. npm fetches them again when needed.", regenerates: true),
        // Several caches from one rule collapse into an "App caches" group.
        Rule(path: L + "/Caches/com.spotify.client", category: .caches, label: .safe, title: "App cache",
             explanation: "Temporary files an app keeps to work faster. Safe to remove; the app rebuilds what it needs.", regenerates: true, ruleID: "app-cache"),
        Rule(path: L + "/Caches/com.apple.dt.Xcode", category: .caches, label: .safe, title: "Xcode cache",
             explanation: "Documentation and index caches Xcode rebuilds on its own.", regenerates: true),
        Rule(path: L + "/Caches/Google", category: .caches, label: .safe, title: "App cache",
             explanation: "Temporary files an app keeps to work faster. Safe to remove; the app rebuilds what it needs.", regenerates: true, ruleID: "app-cache"),
        Rule(path: L + "/Caches/com.microsoft.VSCode.ShipIt", category: .caches, label: .safe, title: "App cache",
             explanation: "Temporary files an app keeps to work faster. Safe to remove; the app rebuilds what it needs.", regenerates: true, ruleID: "app-cache"),
        Rule(path: L + "/Caches/Homebrew", category: .caches, label: .safe, title: "Homebrew downloads",
             explanation: "Cached bottles from past installs. brew cleanup removes them too.", regenerates: true),
        Rule(path: L + "/Caches/com.apple.Music", category: .caches, label: .safe, title: "App cache",
             explanation: "Temporary files an app keeps to work faster. Safe to remove; the app rebuilds what it needs.", regenerates: true, ruleID: "app-cache"),
        Rule(path: L + "/Mail", category: .media, label: .protected, title: "Mail",
             explanation: "Your mailboxes. Managed by Mail, never touched by Freespan."),
        Rule(path: home + "/Downloads/Install macOS Tahoe 26.4.app", category: .downloads, label: .safe, title: "macOS installer",
             explanation: "You're already on a newer macOS. The App Store can download it again.", regenerates: true),
        Rule(path: home + "/Downloads/Xcode_26.1.xip", category: .downloads, label: .safe, title: "Xcode archive",
             explanation: "An installer archive. Xcode 26.1 is already installed in Applications."),
        Rule(path: home + "/Downloads/Concert-Export-Final.mov", category: .downloads, label: .review, title: "Large video",
             explanation: "An exported video you haven't opened in six months. Check it's backed up first."),
        Rule(path: home + "/Downloads/Photos-Archive-2024.zip", category: .downloads, label: .review, title: "Photo archive",
             explanation: "A zip of photos. Make sure they're in your Photos library before removing."),
        Rule(path: home + "/Downloads/AtTheShow-Builds", category: .downloads, label: .review, title: "Old app builds",
             explanation: "Exported .ipa and archive builds. Keep any you still need to ship."),
        Rule(path: home + "/Downloads/Sonos-S2-Controller.dmg", category: .downloads, label: .safe, title: "Disk image installer",
             explanation: "The app is already installed. The installer can be downloaded again."),
        Rule(path: home + "/Downloads/Figma-Installer.dmg", category: .downloads, label: .safe, title: "Disk image installer",
             explanation: "The app is already installed. The installer can be downloaded again."),
        Rule(path: home + "/Pictures/Photos Library.photoslibrary", category: .media, label: .keep, title: "Photos library",
             explanation: "Your photos. Use Optimize Mac Storage in Photos to save space instead."),
        Rule(path: home + "/Movies/2019 Wedding Raw Footage", category: .largeOld, label: .review, title: "Untouched for 3+ years",
             explanation: "Raw footage nobody has opened since 2023. Move it to an external drive if you want to keep it."),
        Rule(path: "/Applications/Xcode.app", category: .applications, label: .keep, title: "Xcode",
             explanation: "You used it today."),
        Rule(path: "/Applications/Final Cut Pro.app", category: .applications, label: .keep, title: "Final Cut Pro",
             explanation: "Last opened 7 weeks ago."),
        Rule(path: "/Applications/Logic Pro.app", category: .applications, label: .review, title: "Logic Pro",
             explanation: "Not opened in over six months. Re-download any time from the App Store."),
        Rule(path: "/Applications/Docker.app", category: .applications, label: .keep, title: "Docker",
             explanation: "Last opened 2 months ago."),
        Rule(path: "/private/var/vm", category: .system, label: .protected, title: "Swap & sleep image",
             explanation: "Virtual memory managed by macOS."),
        // Named locally (no AI) from the app each folder belongs to.
        Rule(path: L + "/Application Support/Slack", category: .applications, label: .review, title: "Slack data",
             explanation: "Messages cache and settings for Slack, which you use daily. Signing out and back in rebuilds most of it.", source: .heuristic),
        Rule(path: L + "/Application Support/Code", category: .developer, label: .review, title: "Visual Studio Code data",
             explanation: "Editor state, extensions' storage and workspace history for VS Code.", source: .heuristic),
        // Assistant labels for folders nothing else could name.
        Rule(path: L + "/Application Support/Steam", category: .other, label: .review, title: "Steam game data",
             explanation: "Installed games and shader caches. You haven't launched Steam in four months.", source: .ai),
        Rule(path: L + "/Containers/com.docker.docker", category: .developer, label: .review, title: "Docker disk image",
             explanation: "Holds your containers and images. Prune unused images from Docker instead of deleting this.", source: .ai),
    ]

    static let findings: [Finding] = rules.compactMap { rule in
        guard let node = node(at: rule.path) else { return nil }
        let classification = Classification(category: rule.category, label: rule.label, title: rule.title,
                                            explanation: rule.explanation, regenerates: rule.regenerates,
                                            source: rule.source, ruleID: rule.source == .rule ? rule.ruleID ?? rule.title : nil)
        return Finding(node: node, classification: classification)
    }
    .sorted { $0.size > $1.size }

    /// Not explained by rules or local identification; the Steam and Docker folders were named by the assistant.
    static let unknown: [FileNode] = [
        L + "/Application Support/Steam", L + "/Containers/com.docker.docker", home + "/Documents/Kitchen Renovation",
    ].compactMap(node(at:))

    static var analysis: ScanAnalysis { ScanAnalysis(findings: findings, unknown: unknown) }

    /// Extra Safe findings for sheet previews (they aren't in the sample tree): logs and the uv cache.
    static let extraSafeFindings: [Finding] = [
        Finding(path: L + "/Logs", name: "Logs", size: m(324.7), itemCount: 812, modified: nil, accessed: nil, isDirectory: true,
                classification: Classification(category: .caches, label: .safe, title: "Logs",
                                               explanation: "Diagnostic logs and crash reports apps wrote. Safe to remove.",
                                               regenerates: true, source: .rule, ruleID: "user-logs")),
        Finding(path: home + "/.cache/uv", name: "uv", size: g(42.1), itemCount: 90_000, modified: nil, accessed: nil, isDirectory: true,
                classification: Classification(category: .developer, label: .safe, title: "uv Python package cache",
                                               explanation: "Python packages the uv tool downloaded. Safe to remove; uv downloads them again when a project needs them. Your Python environments share files with this cache, so clearing it can free less space than shown.",
                                               regenerates: true, source: .rule, ruleID: "uv-cache")),
    ]

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

    static func summarize(_ findings: [Finding], rootSize: Int64) -> [CategorySummary] {
        var totals: [CategoryID: (bytes: Int64, safe: Int64, count: Int)] = [:]
        for finding in findings {
            var entry = totals[finding.category] ?? (0, 0, 0)
            entry.bytes += finding.size
            entry.safe += finding.label == .safe ? finding.size : 0
            entry.count += 1
            totals[finding.category] = entry
        }
        let matched = totals.values.reduce(0) { $0 + $1.bytes }
        var result = totals.map { CategorySummary(category: $0.key, totalBytes: $0.value.bytes, safeBytes: $0.value.safe, findingCount: $0.value.count) }
        result.append(CategorySummary(category: .other, totalBytes: max(0, rootSize - matched), safeBytes: 0, findingCount: 0))
        return result.sorted { $0.totalBytes > $1.totalBytes }
    }

    // MARK: Chat, plan, history

    static let assistantName = "On-device"

    static let chat: [ChatMessage] = [
        ChatMessage(author: .user, text: "Which simulators can I delete?"),
        ChatMessage(author: .assistant(.onDevice, name: assistantName),
                    text: "You have **4 simulator devices**. iPhone 17 Pro (26.4) is the one your projects use.\n\nThe other 3 haven't been launched since spring:\n- iPhone 15 (18.5) · 2.1 GB\n- iPad Air (18.5) · 1.9 GB\n- Apple Watch (11.5) · 1.8 GB\n\nYou can remove them from **Developer** in Advanced mode."),
    ]

    private static let appCaches = ["com.spotify.client", "Google", "com.microsoft.VSCode.ShipIt", "com.apple.Music"].map { "~/Library/Caches/" + $0 }

    /// What `RulePlanner` builds from the sample findings: free, instant, no assistant.
    static var appCachePaths: [String] { appCaches.map { $0.replacingOccurrences(of: "~", with: home) } }

    static let rulePlan = CleanupPlan(headline: "About 50 GB is Safe to clear. Another 5 GB is worth a look.", steps: [
        .init(title: "Installers you've already used", reasoning: "Installers and disk images for apps that are already installed. They can be downloaded again.",
              paths: ["~/Downloads/Install macOS Tahoe 26.4.app", "~/Downloads/Xcode_26.1.xip", "~/Downloads/Sonos-S2-Controller.dmg", "~/Downloads/Figma-Installer.dmg"],
              estimatedBytes: g(27.6), risk: .safe),
        .init(title: "Old iOS debug symbols", reasoning: "Debug symbols Xcode copies from devices. Xcode copies them again if you need them.",
              paths: [deviceSupport + "/iOS 26.3.1 (23D60)", deviceSupport + "/iOS 26.2 (23C55)", deviceSupport + "/iOS 18.6.2 (22G100)", deviceSupport + "/iOS 18.5 (22F76)"].map { $0.replacingOccurrences(of: home, with: "~") },
              estimatedBytes: g(12.9), risk: .safe),
        .init(title: "App caches", reasoning: "Temporary files apps rebuild on their own.",
              paths: appCaches, estimatedBytes: g(9.5), risk: .safe),
        .init(title: "Untouched for 3+ years", reasoning: "Large folders nobody has opened in years. Copy them to an external drive first if you want to keep them.",
              paths: ["~/Movies/2019 Wedding Raw Footage"], estimatedBytes: g(5.4), risk: .review),
    ])

    /// What Claude returns when asked to refine the plan.
    static let plan = CleanupPlan(headline: "You can safely free about 41 GB today, and another 20 GB after a quick look.", steps: [
        .init(title: "Clear old iOS debug symbols", reasoning: "Four of the five DeviceSupport folders are for iOS versions none of your devices run. Xcode re-downloads if needed.",
              paths: [deviceSupport + "/iOS 26.3.1 (23D60)", deviceSupport + "/iOS 26.2 (23C55)", deviceSupport + "/iOS 18.6.2 (22G100)", deviceSupport + "/iOS 18.5 (22F76)"].map { $0.replacingOccurrences(of: home, with: "~") },
              estimatedBytes: g(12.9), risk: .safe),
        .init(title: "Remove the macOS and Xcode installers", reasoning: "Both are already installed. They're the two biggest files in Downloads.",
              paths: ["~/Downloads/Install macOS Tahoe 26.4.app", "~/Downloads/Xcode_26.1.xip"], estimatedBytes: g(26.0), risk: .safe),
        .init(title: "Empty app caches", reasoning: "Spotify, Chrome and Xcode caches rebuild on their own.",
              paths: ["~/Library/Caches/com.spotify.client", "~/Library/Caches/Google", "~/Library/Caches/com.apple.dt.Xcode"], estimatedBytes: g(9.9), risk: .safe),
        .init(title: "Archive the 2019 wedding footage", reasoning: "5.4 GB untouched for three years. Copy to an external drive, then remove.",
              paths: ["~/Movies/2019 Wedding Raw Footage"], estimatedBytes: g(5.4), risk: .review),
    ])

    static let history: [ActionLogEntry] = [
        ActionLogEntry(originalPath: home + "/Library/Caches/com.tinyspeck.slackmacgap", trashPath: home + "/.Trash/com.tinyspeck.slackmacgap",
                       size: g(1.4), date: now.addingTimeInterval(-3_600 * 5)),
        ActionLogEntry(originalPath: home + "/Downloads/Zoom-Installer.pkg", trashPath: home + "/.Trash/Zoom-Installer.pkg",
                       size: m(180), date: now.addingTimeInterval(-86_400 * 3)),
        ActionLogEntry(originalPath: home + "/Downloads/old-backup.zip", trashPath: home + "/.Trash/old-backup.zip",
                       size: g(2.2), date: now.addingTimeInterval(-86_400 * 9), restored: true),
    ]
}

// MARK: - Preview services

/// Canned answers so the Ask panel can be previewed without a model, key or network.
struct SampleAssistant: AssistantService {
    var displayName: String = SampleData.assistantName
    func label(_ items: [ItemMetadata]) async throws -> [AILabel] {
        items.map { AILabel(path: $0.path, title: "App data", explanation: "Support files for an installed app.",
                            ownerApp: nil, regenerates: false, category: .other, label: .review) }
    }

    func ask(_ question: String, summary: DiskSummary, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let answer = "The quickest win is Downloads: the macOS installer and Xcode archive are 26 GB on their own, and both are already installed. Old iOS debug symbols add another 13 GB."
        return AsyncThrowingStream { continuation in
            let task = Task {
                for word in answer.split(separator: " ") {
                    try? await Task.sleep(for: .milliseconds(35))
                    continuation.yield(String(word) + " ")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func deepCleanPlan(_ summary: DiskSummary) async throws -> CleanupPlan {
        try await Task.sleep(for: .seconds(1))
        return SampleData.plan
    }

    func secondOpinion(_ item: ItemMetadata) async throws -> AILabel {
        AILabel(path: item.path, title: "Probably fine to remove", explanation: "Nothing has opened it in months and it isn't referenced by an installed app.",
                ownerApp: nil, regenerates: false, category: .largeOld, label: .review)
    }
}

/// Which items previews pretend are open, to show each state of the "in use" section.
enum SampleInUse: Sendable {
    /// Google Chrome holds its own cache.
    case chrome
    /// Lots of apps and background tasks hold lots of things (the real-world case that overflowed the sheet).
    case manyApps
    /// Only macOS background tasks hold anything.
    case backgroundOnly
    /// Folders are only partly open: most of each can still go.
    case partial
    case none
}

/// In-memory cleanup that pretends to move items to the Trash.
actor SampleCleanup: CleanupPerforming {
    private var log: [ActionLogEntry] = SampleData.history
    private let scenario: SampleInUse

    init(inUse scenario: SampleInUse = .chrome) {
        self.scenario = scenario
    }

    func moveToTrash(_ findings: [Finding]) async -> CleanupReport {
        let entries = findings.map {
            ActionLogEntry(originalPath: $0.path, trashPath: SampleData.home + "/.Trash/" + $0.name, size: $0.size)
        }
        log.insert(contentsOf: entries, at: 0)
        return CleanupReport(trashed: entries, skipped: [])
    }

    /// Pretends some items are open, per the scenario, so previews show the "in use" section.
    func inUse(_ findings: [Finding]) async -> [String: InUseStatus] {
        func app(_ id: String, _ name: String) -> BlockingApp { BlockingApp(bundleID: id, name: name, pids: [1]) }
        func daemon(_ name: String) -> BlockingApp { BlockingApp(bundleID: nil, name: name, pids: [2]) }
        func full(_ f: Finding, _ apps: [BlockingApp]) -> InUseStatus { InUseStatus(apps: apps, isPartial: false, busyBytes: f.size) }
        func part(_ f: Finding, _ apps: [BlockingApp]) -> InUseStatus { InUseStatus(apps: apps, isPartial: true, busyBytes: f.size / 20) }
        let chrome = app("com.google.Chrome", "Google Chrome")
        let daemons = ["akd", "cloudd", "suggestd", "photoanalysisd", "remindd", "itunescloudd", "node", "python3.13"].map(daemon)
        var out: [String: InUseStatus] = [:]
        switch scenario {
        case .none:
            break
        case .chrome:
            for f in findings where f.path.hasSuffix("/Caches/Google") { out[f.path] = full(f, [chrome]) }
        case .manyApps:
            let apps = [chrome, app("com.apple.Safari", "Safari"), app("com.openai.chat", "ChatGPT"),
                        app("com.anthropic.claudefordesktop", "Claude"), app("com.tinyspeck.slackmacgap", "Slack"),
                        app("com.microsoft.VSCode", "Visual Studio Code"), app("com.figma.Desktop", "Figma"),
                        app("com.spotify.client", "Spotify"), app("com.apple.dt.Xcode", "Xcode")]
            for (i, f) in findings.enumerated() where i % 2 == 0 || f.easyKind == .logs {
                if f.easyKind == .logs { out[f.path] = part(f, daemons); continue }
                out[f.path] = full(f, [apps[(i / 2) % apps.count], daemons[i % daemons.count]])
            }
        case .backgroundOnly:
            for (i, f) in findings.enumerated() where i % 3 == 0 || f.easyKind == .logs {
                out[f.path] = f.isDirectory ? part(f, [daemons[i % daemons.count]]) : full(f, [daemons[i % daemons.count]])
            }
        case .partial:
            for (i, f) in findings.enumerated() where f.isDirectory && (i % 2 == 0 || f.easyKind == .logs) {
                out[f.path] = part(f, f.path.hasSuffix("/Caches/Google") ? [chrome] : [daemons[i % daemons.count]])
            }
        }
        return out
    }

    func undo(_ entry: ActionLogEntry) async throws {
        guard let index = log.firstIndex(where: { $0.id == entry.id }) else { return }
        log[index].restored = true
    }

    func history() async -> [ActionLogEntry] { log }
}

extension FreespanServices {
    static func sample(inUse: SampleInUse = .chrome) -> FreespanServices {
        FreespanServices(
            home: SampleData.home,
            scan: { _, _ in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        for step in 1 ... 20 {
                            try? await Task.sleep(for: .milliseconds(100))
                            continuation.yield(.progress(ScanProgress(filesSeen: step * 48_211, bytesSeen: Int64(step) * 11 * SampleData.gb,
                                                                      currentPath: SampleData.home + "/Library/Developer/CoreSimulator/Devices")))
                        }
                        continuation.yield(.finished(SampleData.scan))
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            privacyProtectedPaths: { home in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map { home + "/" + $0 } },
            hasFullDiskAccess: { false },
            loadCache: { SampleData.scan },
            saveCache: { _ in },
            analyze: { _, _ in SampleData.analysis },
            summarize: { SampleData.summarize($0, rootSize: $1) },
            isProtected: { path in
                ["/System", "/private/var/vm", SampleData.home + "/Library/Mail"].contains { PathUtil.isSameOrDescendant(path, of: $0) }
            },
            isInTrash: { PathUtil.isSameOrDescendant($0, of: SampleData.home + "/.Trash") },
            volumeInfo: { _ in nil },
            itemExists: { _ in true },
            metadata: { node in
                ItemMetadata(path: node.path.replacingOccurrences(of: SampleData.home, with: "~"), sizeBytes: node.size,
                             isDirectory: node.kind != .file, itemCount: node.itemCount, modified: node.modified,
                             accessed: node.accessed, topChildren: node.children.prefix(5).map(\.name))
            },
            diskSummary: { scan, _, _ in DiskSummary(volume: scan.volume, scannedAt: scan.scannedAt, categories: [], topFindings: [], unknownLarge: []) },
            unredact: { $0.hasPrefix("~") ? SampleData.home + $0.dropFirst() : $0 },
            isEligibleForAssistant: { path, home in RuleEngine.isEligibleForAssistant(path: path, home: home) },
            groupTitle: { _ in nil },
            identify: { _, _ in nil },
            rulePlan: { _, _, _ in SampleData.rulePlan },
            makeAssistant: { kind in
                switch kind {
                case .onDevice: SampleAssistant()
                case .claudeSubscription, .claudeAPI: SampleAssistant(displayName: "Claude")
                case .off: nil
                }
            },
            assistantAvailability: { kind in
                kind == .off ? .unavailable("The assistant is off.") : .available
            },
            apiKey: { "sk-ant-preview" },
            setAPIKey: { _ in },
            cleanup: SampleCleanup(inUse: inUse),
            cost: { model in [.haiku: 0.042, .sonnet: 0.31, .opus: 0.52][model] ?? 0 },
            resetUsage: {},
            loadAILabels: { [] },
            saveAILabels: { _ in },
            appInventory: { _, _, _ in SampleApps.inventory },
            spaceTiles: { _, _, _, _ in SampleApps.tiles },
            uninstallItems: { SampleApps.uninstallItems(for: $0) },
            // Previews pretend every non-system app is running.
            canQuitApp: { $0.isQuittableApp }
        )
    }
}

extension AppModel {
    /// A fully populated model for previews.
    /// - Parameters:
    ///   - plan: show the rule plan (as after every scan).
    ///   - refined: also show a Claude-refined plan.
    static func preview(mode: AppMode = .advanced, selection: SidebarItem? = nil, basket: Bool = true, plan: Bool = true,
                        refined: Bool = false, assistant: AssistantKind = .onDevice, hasAPIKey: Bool = true,
                        showKeptItems: Bool = false, inUse: SampleInUse = .chrome) -> AppModel {
        let model = AppModel(services: .sample(inUse: inUse), defaults: UserDefaults(suiteName: "FreespanPreview") ?? .standard)
        let basketPaths = basket ? [
            SampleData.home + "/Downloads/Install macOS Tahoe 26.4.app",
            SampleData.home + "/Library/Developer/Xcode/iOS DeviceSupport/iOS 18.5 (22F76)",
            SampleData.home + "/Movies/2019 Wedding Raw Footage",
        ] + SampleData.appCachePaths : []
        model.seed(scan: SampleData.scan, analysis: SampleData.analysis, scope: .wholeDisk, basketPaths: basketPaths,
                   chat: assistant == .off ? [] : SampleData.chat, plan: plan ? SampleData.rulePlan : nil,
                   refinedPlan: refined ? SampleData.plan : nil, history: SampleData.history,
                   assistant: assistant, hasAPIKey: hasAPIKey)
        model.seedApps(SampleApps.inventory)
        model.mode = mode
        model.showKeptItems = showKeptItems
        model.selection = selection ?? mode.homeItem
        return model
    }
}
