import Foundation
import Testing
@testable import FreespanKit

/// macOS's own data under ~/Library, assistant eligibility, titles and zero-byte findings.
@Suite("Rules – macOS data, assistant eligibility & titles")
struct RulesMacOSDataTests {
    let engine: RuleEngine

    init() throws { engine = try RT.engine() }

    func classify(_ item: RT.Item) -> Classification? {
        engine.classify(RT.node(item), home: RT.home, now: RT.now)
    }

    // MARK: - macOS internals are System / Keep

    static let macOSData: [(String, String)] = [
        ("~/Library/Metadata/CoreSpotlight", "spotlight-index"),
        ("~/Library/Biome", "biome"),
        ("~/Library/DuetExpertCenter", "apple-intelligence-data"),
        ("~/Library/Trial", "apple-intelligence-data"),
        ("~/Library/IntelligencePlatform", "apple-intelligence-data"),
        ("~/Library/Assistant", "apple-intelligence-data"),
        ("~/Library/Suggestions", "apple-intelligence-data"),
        ("~/Library/PersonalizationPortrait", "apple-intelligence-data"),
        ("~/Library/Daemon Containers", "background-service-data"),
        ("~/Library/Sharing", "macos-user-data"),
        ("~/Library/StatusKit", "macos-user-data"),
        ("~/Library/Weather", "macos-user-data"),
        ("~/Library/HomeKit", "macos-user-data"),
        ("~/Library/FrontBoard", "macos-user-data"),
        ("~/Library/CoreFollowUp", "macos-user-data"),
        ("~/Library/Metadata", "macos-user-data"),
        ("~/Library/IdentityServices", "account-data"),
        ("~/Library/Accounts", "account-data"),
        ("~/Library/Calendars", "calendar-reminders-data"),
        ("~/Library/Reminders", "calendar-reminders-data"),
        ("~/Library/Messages", "messages-data"),
        ("~/Library/Mail", "mail-data"),
        ("~/Library/Safari", "safari-data"),
        ("~/Library/Cookies", "website-data"),
        ("~/Library/HTTPStorages/com.apple.Safari", "website-data"),
        ("~/Library/Containers/com.apple.mediaanalysisd", "apple-app-data"),
        ("~/Library/Group Containers/group.com.apple.notes", "apple-app-data"),
        ("~/Library/Application Support/com.apple.sharedfilelist", "apple-app-data"),
        ("~/Library/Application Support/AddressBook", "apple-app-data"),
        ("~/Library/Keychains", "keychains"),
        ("~/Library/Autosave Information", "autosave-information"),
        ("~/Library/Saved Application State", "saved-window-state"),
    ]

    @Test(arguments: macOSData)
    func macOSDataIsSystemKeep(_ path: String, _ ruleID: String) throws {
        let c = try #require(classify(RT.dir(path, 5 * RT.GB)), "\(path)")
        #expect(c.ruleID == ruleID, "\(path)")
        #expect(c.category == .system && c.label == .keep, "\(path)")
    }

    @Test func spotlightAndBiomeHaveFriendlyText() throws {
        let spotlight = try #require(classify(RT.dir("~/Library/Metadata/CoreSpotlight", 4_760 * RT.MB)))
        #expect(spotlight.title == "Spotlight search index")
        #expect(spotlight.explanation.contains("rebuilds"))
        let biome = try #require(classify(RT.dir("~/Library/Biome", 647 * RT.MB)))
        #expect(!biome.title.lowercased().contains("icloud") && !biome.explanation.lowercased().contains("icloud"))
    }

    /// Crash reports stay Safe: ~/Library/Logs (including DiagnosticReports) is one Safe finding.
    @Test func diagnosticReportsStaySafeViaLogs() {
        let root = RT.tree([RT.dir("~/Library/Logs/DiagnosticReports", 2 * RT.GB), RT.dir("~/Library/Logs/Other", RT.GB)])
        let f = engine.findings(in: root, home: RT.home, now: RT.now)
        #expect(f.map(\.path) == [RT.p("~/Library/Logs")])
        #expect(f.first?.classification.label == .safe)
    }

    // MARK: - Broad Keep rules don't hide removable caches inside them

    @Test func appleContainersYieldToNestedCaches() {
        let root = RT.tree([
            RT.dir("~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches", 3 * RT.GB),
            RT.dir("~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Application Support", 1 * RT.GB),
            RT.dir("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", 2 * RT.GB),
            RT.dir("~/Library/Containers/com.apple.mail/Data/Library/Other", 500 * RT.MB),
            RT.dir("~/Library/Metadata/CoreSpotlight", 4 * RT.GB),
            RT.dir("~/Library/Metadata/Other", 100 * RT.MB),
            // A container whose only content is a cache: no zero-byte remainder row.
            RT.dir("~/Library/Containers/com.apple.Safari/Data/Library/Caches", RT.GB),
        ])
        let f = engine.findings(in: root, home: RT.home, now: RT.now)
        let byPath = Dictionary(uniqueKeysWithValues: f.map { ($0.path, ($0.classification.ruleID ?? "", $0.size)) })
        #expect(byPath[RT.p("~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches")]! == ("sandboxed-app-cache", 3 * RT.GB))
        #expect(byPath[RT.p("~/Library/Containers/com.apple.mediaanalysisd")]! == ("apple-app-data", 1 * RT.GB))
        #expect(byPath[RT.p("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]! == ("mail-downloads", 2 * RT.GB))
        #expect(byPath[RT.p("~/Library/Containers/com.apple.mail")]! == ("apple-app-data", 500 * RT.MB))
        #expect(byPath[RT.p("~/Library/Metadata/CoreSpotlight")]! == ("spotlight-index", 4 * RT.GB))
        #expect(byPath[RT.p("~/Library/Metadata")]! == ("macos-user-data", 100 * RT.MB))
        #expect(byPath[RT.p("~/Library/Containers/com.apple.Safari")] == nil)
        // Nothing is counted twice.
        #expect(f.reduce(0) { $0 + $1.size } == root.size)
        // And none of it is left over as "unknown".
        #expect(engine.unknownLargeItems(in: root, home: RT.home, minSize: 1).isEmpty)
    }

    // MARK: - Zero-byte findings

    @Test func zeroByteFindingsAreDropped() {
        let root = RT.tree([
            RT.dir("/Users/alex-work", 0),
            RT.dir("/Users/other", 3 * RT.GB),
            RT.dir("~/Library/Caches/com.empty.app", 0),
            RT.dir("~/Library/Caches/com.full.app", RT.GB),
        ])
        let f = engine.findings(in: root, home: RT.home, now: RT.now)
        #expect(f.map(\.path) == ["/Users/other", RT.p("~/Library/Caches/com.full.app")])
        #expect(f.allSatisfy { $0.size > 0 })
    }

    // MARK: - Titles

    @Test func otherUsersAreNamed() throws {
        let c = try #require(classify(RT.dir("/Users/alex-work", RT.GB)))
        #expect(c.title == "Other user: alex-work")
        let root = RT.tree([RT.dir("/Users/alex-work/Documents", RT.GB), RT.dir("/Users/Shared/Stuff", RT.GB)])
        let titles = engine.findings(in: root, home: RT.home, now: RT.now).map(\.classification.title).sorted()
        #expect(titles == ["Other user: alex-work", "Shared folder"])
        #expect(engine.pluralTitle(forRuleID: "other-users") == "Other users")
    }

    @Test func systemRowsHaveFriendlyTitles() throws {
        #expect(classify(RT.dir("/private/var/folders", RT.GB))?.title == "System temporary files")
        #expect(classify(RT.dir("/private/var/vm", RT.GB))?.title == "Virtual memory & sleep image")
        #expect(classify(RT.dir("/private/var/db", RT.GB))?.title == "macOS system data")
    }

    @Test func everyRuleHasAPluralTitle() throws {
        let rules = try RuleEngine.bundledRules()
        for r in rules {
            let plural = try #require(r.pluralTitle, "\(r.id) has no pluralTitle")
            #expect(!plural.isEmpty && !plural.contains(Rule.namePlaceholder), "\(r.id)")
            #expect(r.groupTitle == plural)
        }
        #expect(engine.pluralTitle(forRuleID: "app-cache") == "App caches")
        #expect(engine.pluralTitle(forRuleID: "sandboxed-app-cache") == "App caches")
        #expect(engine.pluralTitle(forRuleID: "system-private") == "macOS system data")
        #expect(engine.pluralTitle(forRuleID: "nope") == nil)
        let bare = Rule(id: "x", title: "Other user: {name}", explanation: "e", category: .system, label: .keep,
                        regenerates: false, match: RuleMatch(paths: ["/Users/*"]))
        #expect(bare.groupTitle == "Other user:")
    }

    @Test func newRuleFieldsDecodeAndDefault() throws {
        let json = """
        [{"id":"x","title":"X","explanation":"E","category":"system","label":"keep","regenerates":false,
          "match":{"paths":["~/A"]}}]
        """
        let r = try #require(try JSONDecoder().decode([Rule].self, from: Data(json.utf8)).first)
        #expect(r.pluralTitle == nil && r.yieldsToNested == nil)
        #expect(r.groupTitle == "X")
    }

    // MARK: - Unknown items and assistant eligibility

    @Test func unknownItemsSkipMacOSLibraryData() throws {
        let root = RT.tree([
            RT.dir("~/Library/Mystery/x", 3 * RT.GB),                                 // plain, unnamed → never handed on
            RT.dir("~/Library/Application Support/CrashReporter/x", 2 * RT.GB),       // macOS folder in an app root
            RT.dir("~/Library/Containers/com.apple.newd/Data/x", 2 * RT.GB),          // matched (Apple app data)
            RT.dir("~/Library/Application Support/com.vendor.tool/x", 4 * RT.GB),     // third-party → returned
            RT.dir("~/Library/Group Containers/ABCDE12345.com.vendor.shared/x", 2 * RT.GB),
            RT.dir("~/Library/Android/sdk/platforms", 5 * RT.GB),                     // vendor folder named by the table
            RT.dir("~/Documents/Big/x", 6 * RT.GB),
            RT.dir("~/.mytool/data", 2 * RT.GB),
        ])
        let unknown = engine.unknownLargeItems(in: root, home: RT.home)
        #expect(Set(unknown.map(\.path)) == Set([
            RT.p("~/Documents/Big/x"), RT.p("~/Library/Android/sdk/platforms"),
            RT.p("~/Library/Application Support/com.vendor.tool/x"),
            RT.p("~/Library/Group Containers/ABCDE12345.com.vendor.shared/x"), RT.p("~/.mytool/data"),
        ]))
        // ~/Library items are named locally and never reach an assistant.
        let identifier = ItemIdentifier()
        for node in unknown where node.path.hasPrefix(RT.p("~/Library/")) {
            #expect(!RuleEngine.isEligibleForAssistant(path: node.path, home: RT.home), "\(node.path)")
            #expect(identifier.identify(node, home: RT.home) != nil, "\(node.path)")
        }
        #expect(RuleEngine.isEligibleForAssistant(path: RT.p("~/Documents/Big"), home: RT.home))
    }

    static let eligible: [String] = [
        "/Users/test/Documents/Big", "/Users/test/Desktop/AppDev/site", "/Users/test/Downloads/a.bin",
        "/Users/test/Projects/x", "/Users/test/.cache/something", "/Users/test/.ollama/models",
        "/Applications/Slack.app", "/Applications/Vendor/Thing.app", "/Users/test/Applications/Chrome App.app",
    ]

    static let ineligible: [String] = [
        "/Users/test/Library/Metadata/CoreSpotlight", "/Users/test/Library/Biome",
        "/Users/test/Library/Application Support/com.vendor.tool", "/Users/test/Library/Caches/x",
        "/Users/test/Library", "/Users/test", "/Users/test/Documents", "/Users/test/.ssh", "/Users/test/.docker",
        "/Users/other/Documents", "/Users/Shared/x", "/private/var/folders", "/private/var/vm", "/System/Library",
        "/Library/Application Support/x", "/opt/homebrew", "/Applications", "/Applications/Safari.app",
        "/Applications/Xcode.app/Contents/Developer", "/Users/test/Pictures/Photos Library.photoslibrary",
        "relative/path", "/Users/test/Downloads/../Library/Biome",
    ]

    @Test(arguments: eligible)
    func eligibleForAssistant(_ path: String) {
        #expect(RuleEngine.isEligibleForAssistant(path: path, home: RT.home), "\(path)")
    }

    @Test(arguments: ineligible)
    func ineligibleForAssistant(_ path: String) {
        #expect(!RuleEngine.isEligibleForAssistant(path: path, home: RT.home), "\(path)")
    }

    @Test func eligibilityFailsClosedOnBadHome() {
        #expect(!RuleEngine.isEligibleForAssistant(path: "/Users/test/Documents/x", home: ""))
        #expect(!RuleEngine.isEligibleForAssistant(path: "/Users/test/Documents/x", home: "relative"))
    }
}
