import Testing
@testable import FreespanKit

@Test func safetyLabelOrdering() {
    #expect(SafetyLabel.safe < SafetyLabel.review)
    #expect(SafetyLabel.keep < SafetyLabel.protected)
}
