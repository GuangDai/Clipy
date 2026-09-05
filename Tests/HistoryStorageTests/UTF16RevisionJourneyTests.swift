import Foundation
import HistoryCore
import HistoryStorage
import Testing

@Suite("UTF-16 immutable revision journey")
struct UTF16RevisionJourneyTests {
    struct Fixture: Sendable {
        let typeIdentifier: String
        let canonical: Data
        let firstEdit: Data
        let secondEdit: Data
        let revisionByteTotals: [Int]
        let totalBytes: [Int]
    }

    // Independent wire literals: A中, B🦊 and C🙂文. The supplementary-plane
    // characters occupy surrogate pairs; external UTF-16 also retains its BOM.
    static let fixtures = [
        Fixture(
            typeIdentifier: "public.utf16-plain-text",
            canonical: Data([0x41, 0x00, 0x2D, 0x4E]),
            firstEdit: Data([0x42, 0x00, 0x3E, 0xD8, 0x8A, 0xDD]),
            secondEdit: Data([0x43, 0x00, 0x3D, 0xD8, 0x42, 0xDE, 0x87, 0x65]),
            revisionByteTotals: [0, 6, 14, 20, 24],
            totalBytes: [4, 10, 18, 24, 28]
        ),
        Fixture(
            typeIdentifier: "public.utf16-external-plain-text",
            canonical: Data([0xFE, 0xFF, 0x00, 0x41, 0x4E, 0x2D]),
            firstEdit: Data([0xFE, 0xFF, 0x00, 0x42, 0xD8, 0x3E, 0xDD, 0x8A]),
            secondEdit: Data([0xFE, 0xFF, 0x00, 0x43, 0xD8, 0x3D, 0xDE, 0x42, 0x65, 0x87]),
            revisionByteTotals: [0, 8, 18, 26, 32],
            totalBytes: [6, 14, 24, 32, 38]
        ),
    ]

    private func revise(
        _ item: HistoryItemReference,
        intent: RevisionIntent,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: item.id, expected: item.contentVersion, intent: intent
        )))
        guard case .committed(let commit) = receipt,
              case .revised(let revised) = commit.outcome else {
            Issue.record("Expected a byte-changing revision to append")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return revised
    }

    private func replacement(_ bytes: Data, fixture: Fixture) -> RevisionIntent {
        .replace(RevisionDraft(decisions: [RevisionDecision(
            typeIdentifier: fixture.typeIdentifier,
            action: .replace(bytes: bytes)
        )]))
    }

    @discardableResult
    private func expectCurrent(
        _ item: HistoryItemReference,
        text: String,
        bytes: Data,
        stage: Int,
        previousText: String?,
        fixture: Fixture,
        history: SwiftDataHistory
    ) async throws -> HistoryDetails {
        let details = try await history.details(for: item.id)
        #expect(details.item == item)
        #expect(details.canonical.map(\.typeIdentifier) == [fixture.typeIdentifier])
        #expect(details.canonical.map(\.bytes) == [fixture.canonical])
        #expect(details.effective.map(\.typeIdentifier) == [fixture.typeIdentifier])
        #expect(details.effective.map(\.bytes) == [bytes])
        #expect(details.revisions.count == stage)

        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(recent.rows.map(\.item) == [item])
        #expect(recent.rows.map(\.title) == [text])
        let search = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: text, mode: .exact), limit: 10
        ))
        #expect(search.rows.map(\.item) == [item])
        #expect(search.rows.map(\.title) == [text])
        if let previousText {
            let staleSearch = try await history.browse(HistoryBrowseRequest(
                kind: .search(text: previousText, mode: .exact), limit: 10
            ))
            #expect(staleSearch.rows.isEmpty)
        }

        let paste = try await history.pastePayload(for: item.id)
        #expect(paste.item == item)
        #expect(paste.lineageHint == item.id)
        #expect(paste.representations.map(\.typeIdentifier) == [fixture.typeIdentifier])
        #expect(paste.representations.map(\.bytes) == [bytes])

        let usage = try await history.usage()
        #expect(usage.position.rawValue == UInt64(stage + 1))
        #expect(recent.position == usage.position)
        #expect(search.position == usage.position)
        #expect(usage.itemCount == 1)
        #expect(usage.pinnedItemCount == 0)
        #expect(usage.canonicalBytes == fixture.canonical.count)
        #expect(usage.revisionBytes == fixture.revisionByteTotals[stage])
        #expect(usage.totalContentBytes == fixture.totalBytes[stage])
        return details
    }

    @Test("encoded edits update every read surface and retain canonical and prior revision bytes",
          arguments: UTF16RevisionJourneyTests.fixtures)
    func replacementAndRevertPreserveUTF16Lineage(_ fixture: Fixture) async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let capture = ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: fixture.typeIdentifier, bytes: fixture.canonical
            )],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_060_000)
        )
        let receipt = try await history.perform(.capture(capture))
        guard case .committed(let commit) = receipt,
              case .inserted(let captured) = commit.outcome else {
            Issue.record("Expected a UTF-16 capture")
            return
        }
        try await expectCurrent(captured, text: "A中", bytes: fixture.canonical, stage: 0,
                                previousText: nil, fixture: fixture, history: history)

        let first = try await revise(captured, intent: replacement(fixture.firstEdit, fixture: fixture), in: history)
        let firstDetails = try await expectCurrent(first, text: "B🦊", bytes: fixture.firstEdit, stage: 1,
                                                   previousText: "A中", fixture: fixture, history: history)
        let firstRevision = try #require(firstDetails.revisions.first)
        #expect(firstRevision.isActive)
        #expect(firstRevision.title == "B🦊")
        let supplementarySearch = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "🦊", mode: .exact), limit: 10
        ))
        let match = try #require(supplementarySearch.rows.first?.search)
        #expect(match.matchedRanges == [UTF16TextRange(location: 1, length: 2)])

        let second = try await revise(first, intent: replacement(fixture.secondEdit, fixture: fixture), in: history)
        let secondDetails = try await expectCurrent(second, text: "C🙂文", bytes: fixture.secondEdit, stage: 2,
                                                    previousText: "B🦊", fixture: fixture, history: history)
        #expect(secondDetails.revisions.first?.id == firstRevision.id)
        #expect(secondDetails.revisions.map(\.title) == ["B🦊", "C🙂文"])
        #expect(secondDetails.revisions.map(\.isActive) == [false, true])
        let secondRevision = try #require(secondDetails.revisions.last)

        // Resolving the old revision through the public revert operation
        // proves its actual bytes survived, beyond its summary metadata.
        let reverted = try await revise(second, intent: .revert(to: .revision(firstRevision.id)), in: history)
        let revertedDetails = try await expectCurrent(reverted, text: "B🦊", bytes: fixture.firstEdit, stage: 3,
                                                      previousText: "C🙂文", fixture: fixture, history: history)
        #expect(revertedDetails.revisions.prefix(2).map(\.id) == [firstRevision.id, secondRevision.id])
        #expect(revertedDetails.revisions.map(\.isActive) == [false, false, true])

        let canonical = try await revise(reverted, intent: .revert(to: .canonical), in: history)
        let finalDetails = try await expectCurrent(canonical, text: "A中", bytes: fixture.canonical, stage: 4,
                                                   previousText: "B🦊", fixture: fixture, history: history)
        #expect(finalDetails.revisions.prefix(3).map(\.id) == revertedDetails.revisions.map(\.id))
        #expect(finalDetails.revisions.map(\.title) == ["B🦊", "C🙂文", "B🦊", "A中"])
        #expect(finalDetails.revisions.map(\.isActive) == [false, false, false, true])
    }
}
