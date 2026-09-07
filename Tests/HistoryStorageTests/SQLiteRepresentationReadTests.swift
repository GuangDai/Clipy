/// SQLite/immutable-file read tests. Making an unrequested payload
/// unavailable is stronger evidence than counting hydrated aggregate bytes.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteRepresentationReadTests {
    @Test func detailsReadInactiveRevisionSummariesWithoutTheirPayloads() async throws {
        let fixture = try await makeFixture()
        try await fixture.history.authority.makePayloadUnavailable(
            itemID: fixture.current.id, revisionOrdinal: 1, typeIdentifier: "public.utf8-plain-text"
        )
        let details = try await fixture.history.details(for: fixture.current.id)
        #expect(details.item == fixture.current)
        #expect(details.canonical.map(\.bytes) == [fixture.image, Data("canonical text".utf8)])
        #expect(details.effective.map(\.bytes) == [fixture.image, Data("current text".utf8)])
        #expect(details.revisions.map(\.title) == ["older revision", "current text"])
        #expect(details.revisions.map(\.isActive) == [false, true])
        #expect(details.revisions.map(\.byteCount) == [
            fixture.image.count + fixture.olderText.count,
            fixture.image.count + "current text".utf8.count,
        ])
    }

    @Test func pasteReadsOnlyCurrentEffectiveRepresentationBytes() async throws {
        let fixture = try await makeFixture()
        for ordinal in [0, 1] {
            try await fixture.history.authority.makePayloadUnavailable(
                itemID: fixture.current.id, revisionOrdinal: ordinal, typeIdentifier: "public.utf8-plain-text"
            )
        }
        let payload = try await fixture.history.pastePayload(for: fixture.current.id)
        #expect(payload.item == fixture.current)
        #expect(payload.lineageHint == fixture.current.id)
        #expect(payload.representations.map(\.bytes) == [fixture.image, Data("current text".utf8)])
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await fixture.history.details(for: fixture.current.id)
        }
    }

    @Test func thumbnailOpensOnlyItsSelectedImageIncludingWhenSiblingsAreInline() async throws {
        let fixture = try await makeFixture()
        let position = try await fixture.history.authority.readPositionInLocalContext()
        // Current/canonical text are inline; the old revision text is large.
        // Replace all three payload locations with missing immutable files
        // while retaining exact type/order/count metadata.
        for ordinal in [0, 1, 2] {
            try await fixture.history.authority.makePayloadUnavailable(
                itemID: fixture.current.id, revisionOrdinal: ordinal, typeIdentifier: "public.utf8-plain-text"
            )
        }
        let source = try #require(try await fixture.history.authority.thumbnailSource(
            for: fixture.current, pixels: PixelSize(width: 32, height: 32)
        ))
        #expect(source.bytes == fixture.image)
        #expect(try await fixture.history.authority.readPositionInLocalContext() == position)
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await fixture.history.pastePayload(for: fixture.current.id)
        }
    }

    @Test func exactRepresentationReadChecksVersionAndKeepsCanonicalSpelling() async throws {
        let fixture = try await makeFixture()
        let value = try await fixture.history.authority.rawRepresentation(
            for: fixture.current, basis: .canonical, typeIdentifier: "public.utf8-plain-text"
        )
        #expect(value == HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("canonical text".utf8)))
        await #expect(throws: HistoryFailure.staleContent(
            expected: fixture.original.contentVersion, current: fixture.current.contentVersion
        )) {
            try await fixture.history.authority.rawRepresentation(
                for: fixture.original, basis: .effective, typeIdentifier: "public.utf8-plain-text"
            )
        }
    }

    private struct Fixture: Sendable {
        let history: SQLiteHistory
        let original: HistoryItemReference
        let current: HistoryItemReference
        let image: Data
        let olderText: Data
    }

    private func makeFixture() async throws -> Fixture {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        // Source selection is a raw-byte operation, not a decode claim.
        let image = Data(repeating: 0xAB, count: 128 * 1_024)
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            "canonical text", observedAt: Date(timeIntervalSinceReferenceDate: 850_000_000),
            extra: [(typeIdentifier: "public.png", bytes: Array(image))]
        )))
        guard case .committed(let commit) = receipt, case .inserted(let original) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let olderText = Data(("older revision\n" + String(repeating: "x", count: 128 * 1_024)).utf8)
        var current = original
        for bytes in [olderText, Data("current text".utf8)] {
            let receipt = try await history.perform(.revise(RevisionRequest(
                itemID: current.id, expected: current.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(typeIdentifier: "public.png", action: .inheritCanonical),
                    RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: bytes)),
                ]))
            )))
            guard case .committed(let commit) = receipt, case .revised(let revised) = commit.outcome else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            current = revised
        }
        #expect(try await history.authority.representationIsFileBacked(
            itemID: current.id, revisionOrdinal: 0, typeIdentifier: "public.png"
        ))
        #expect(try await history.authority.representationIsFileBacked(
            itemID: current.id, revisionOrdinal: 1, typeIdentifier: "public.utf8-plain-text"
        ))
        return Fixture(history: history, original: original, current: current, image: image, olderText: olderText)
    }
}

extension HistoryAuthority {
    func representationIsFileBacked(
        itemID: HistoryItemID, revisionOrdinal: Int, typeIdentifier: String
    ) throws -> Bool {
        let statement = try database.prepare("""
            SELECT blobID IS NOT NULL FROM representations
            WHERE contentID = (SELECT id FROM contents WHERE itemID = ? AND revisionOrdinal = ?)
              AND exactType = ?
            """, bindings: [.text(itemID.rawValue.uuidString), .integer(Int64(revisionOrdinal)), .text(typeIdentifier)])
        defer { statement.finalize() }
        guard try statement.step() else { throw HistoryFailure.persistence(.invariantViolation) }
        return try statement.integer(at: 0) == 1
    }

    /// Corrupt only the chosen stored representation. No alternate writer or
    /// leaked SQL handle crosses the actor boundary; fixture inputs are values.
    func makePayloadUnavailable(
        itemID: HistoryItemID, revisionOrdinal: Int, typeIdentifier: String
    ) throws {
        try database.writeTransaction {
            let statement = try database.prepare("""
                UPDATE representations SET inlineBytes = NULL, blobID = ?
                WHERE contentID = (SELECT id FROM contents WHERE itemID = ? AND revisionOrdinal = ?)
                  AND exactType = ?
                """, bindings: [
                    .text(UUID().uuidString), .text(itemID.rawValue.uuidString),
                    .integer(Int64(revisionOrdinal)), .text(typeIdentifier),
                ])
            defer { statement.finalize() }
            _ = try statement.step()
            guard try database.changedRowCount == 1 else { throw HistoryFailure.persistence(.invariantViolation) }
        }
    }
}
