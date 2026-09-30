/// Coherence increments, UUID byte ordering, and literal search identities.
import Foundation
import Testing
@testable import HistoryCore

// MARK: - Identity coherence values (docs/architecture.md)

@Test func coherenceTokensAdvanceOnceAndRejectOverflow() {
    #expect(ContentVersion.initial.rawValue == 1)
    #expect(ContentVersion.initial.successor() == ContentVersion(rawValue: 2))
    #expect(ContentVersion(rawValue: UInt64.max).successor() == nil)

    #expect(ChangePosition.zero.rawValue == 0)
    #expect(ChangePosition.zero.successor() == ChangePosition(rawValue: 1))
    #expect(ChangePosition(rawValue: UInt64.max).successor() == nil)
}

@Test func identityOrderingUsesCanonicalUUIDBytesAndIsTrichotomous() {
    let firstByteLow = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let firstByteHigh = UUID(uuidString: "01000000-0000-0000-0000-000000000000")!
    let lastByteHigh = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    let itemLow = HistoryItemID(rawValue: firstByteLow)
    let itemFirstHigh = HistoryItemID(rawValue: firstByteHigh)
    let itemLastHigh = HistoryItemID(rawValue: lastByteHigh)
    #expect(itemLow < itemFirstHigh)
    #expect(itemLow < itemLastHigh)
    #expect(!(itemLow < itemLow))
    #expect(!(itemFirstHigh < itemLow))

    let revisionLow = RevisionID(rawValue: firstByteLow)
    let revisionFirstHigh = RevisionID(rawValue: firstByteHigh)
    let revisionLastHigh = RevisionID(rawValue: lastByteHigh)
    #expect(revisionLow < revisionFirstHigh)
    #expect(revisionLow < revisionLastHigh)
    #expect(!(revisionLow < revisionLow))
    #expect(!(revisionFirstHigh < revisionLow))
}

@Test(arguments: [SearchMode.exact, .fuzzy, .regexp, .expression])
func searchQueryIdentityPreservesTheOriginalScalarSequence(mode: SearchMode) {
    let composed = HistoryBrowseKind.search(text: "\u{e9}", mode: mode)
    let decomposed = HistoryBrowseKind.search(text: "e\u{301}", mode: mode)

    #expect(composed != decomposed)
    #expect(Set([composed, decomposed]).count == 2)
    #expect(composed == .search(text: "\u{e9}", mode: mode))
    #expect(Set([composed, .search(text: "\u{e9}", mode: mode)]).count == 1)
    #expect(HistoryBrowseRequest(kind: composed, limit: 10) != HistoryBrowseRequest(kind: decomposed, limit: 10))
    #expect(HistoryObservationRequest(kind: composed, limit: 10) != HistoryObservationRequest(kind: decomposed, limit: 10))
}

@Test(arguments: [SearchMode.exact, .fuzzy, .regexp, .expression])
func independentConditionParticipatesInBrowseAndObservationIdentity(mode: SearchMode) throws {
    let composed = try HistorySearchExpression.parse("source-id:com.example.\u{e9}")
    let decomposed = try HistorySearchExpression.parse("source-id:com.example.e\u{301}")
    let kind = HistoryBrowseKind.search(text: "outer text", mode: mode)
    let first = HistoryBrowseRequest(kind: kind, limit: 10, conditionExpression: composed)
    let changed = HistoryBrowseRequest(kind: kind, limit: 10, conditionExpression: decomposed)
    #expect(first != changed)
    #expect(Set([first, changed]).count == 2)
    #expect(first != HistoryBrowseRequest(kind: kind, limit: 10))
    #expect(HistoryBrowseRequest(kind: kind, limit: 10)
            == HistoryBrowseRequest(kind: kind, limit: 10, conditionExpression: nil))

    let observation = HistoryObservationRequest(kind: kind, limit: 10, conditionExpression: composed)
    let changedObservation = HistoryObservationRequest(kind: kind, limit: 10, conditionExpression: decomposed)
    #expect(observation != changedObservation)
    #expect(Set([observation, changedObservation]).count == 2)
    #expect(observation != HistoryObservationRequest(kind: kind, limit: 10))
}
