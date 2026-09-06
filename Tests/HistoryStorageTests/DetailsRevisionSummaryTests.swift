/// Detail summaries retain each revision's title when the active content
/// changes, including a revert that appends Canonical bytes (05 §14.3/§15).
/// The active summary may reuse the durable row title; older summaries must
/// continue to describe their own immutable content.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct DetailsRevisionSummaryTests {
    @Test func revisionTitlesFollowTheirOwnContentAcrossReplaceAndRevert() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let canonical = " \r\n Original title \r\noriginal body"
        let capture = try await history.perform(.capture(
            WSSupport.textCapture(
                canonical,
                observedAt: Date(timeIntervalSinceReferenceDate: 700_030_300),
                source: "com.example.details-summaries"
            )
        ))
        guard case let .committed(commit) = capture,
              case let .inserted(reference) = commit.outcome else {
            Issue.record("Expected an inserted item")
            return
        }
        let typeIdentifier = "public.utf8-plain-text"
        let first = " \n First title \rfirst body"
        let second = "\t Second title \r\nsecond body"
        let steps: [(RevisionIntent, String, String)] = [
            (.replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: typeIdentifier, action: .replace(bytes: Data(first.utf8))),
            ])), first, "First title"),
            (.replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: typeIdentifier, action: .replace(bytes: Data(second.utf8))),
            ])), second, "Second title"),
            (.revert(to: .canonical), canonical, "Original title"),
        ]
        var version = reference.contentVersion
        var expectedTitles: [String] = []
        var expectedByteCounts: [Int] = []
        var previousRevisionIDs: [RevisionID] = []
        for (intent, body, title) in steps {
            _ = try await history.perform(.revise(RevisionRequest(
                itemID: reference.id,
                expected: version,
                intent: intent
            )))
            let details = try await history.details(for: reference.id)
            let active = try #require(details.revisions.last)
            expectedTitles.append(title)
            expectedByteCounts.append(body.utf8.count)

            #expect(details.item.contentVersion.rawValue == version.rawValue + 1)
            #expect(details.canonical.map(\.bytes) == [Data(canonical.utf8)])
            #expect(details.effective.map(\.bytes) == [Data(body.utf8)])
            #expect(details.revisions.map(\.title) == expectedTitles)
            #expect(details.revisions.map(\.byteCount) == expectedByteCounts)
            #expect(details.revisions.allSatisfy { $0.typeIdentifiers == [typeIdentifier] })
            #expect(details.revisions.filter(\.isActive).map(\.id) == [active.id])
            #expect(Array(details.revisions.dropLast().map(\.id)) == previousRevisionIDs)
            let page = try await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 1)
            )
            #expect(page.rows.first?.title == active.title)

            version = details.item.contentVersion
            previousRevisionIDs = details.revisions.map(\.id)
        }
    }
}
