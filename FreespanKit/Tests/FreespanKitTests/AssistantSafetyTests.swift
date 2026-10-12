import Foundation
import Testing
@testable import FreespanKit

@Suite("Assistant safety cap")
struct AssistantSafetyTests {
    @Test func capsSafeAndProtected() {
        #expect(AssistantSafety.cap(.safe) == .review)
        #expect(AssistantSafety.cap(.review) == .review)
        #expect(AssistantSafety.cap(.keep) == .keep)
        #expect(AssistantSafety.cap(.protected) == .keep)
        for label in SafetyLabel.allCases { #expect(AssistantSafety.cap(label) >= .review) }
    }

    @Test func cappedReplacesPathAndKeepsDescription() {
        let label = AILabel(path: "~/x", title: "t", explanation: "e", ownerApp: "App", regenerates: true, category: .caches, label: .safe)
        let capped = AssistantSafety.capped(label, path: "/Users/tester/x")
        #expect(capped.path == "/Users/tester/x")
        #expect(capped.label == .review)
        #expect(capped.title == "t" && capped.ownerApp == "App" && capped.category == .caches && capped.regenerates)
    }
}
