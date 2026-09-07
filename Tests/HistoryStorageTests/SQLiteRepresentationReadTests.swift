/// SQLite/immutable-file read tests. Making an unrequested payload
/// unavailable is stronger evidence than counting hydrated aggregate bytes.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteRepresentationReadTests {
    @Test func detailsReadAllMetadataWhenEveryPayloadIsUnavailable() async throws {
        let fixture = try await makeFixture()
        let position = try await fixture.history.authority.readPositionInLocalContext()
        for ordinal in [0, 1, 2] {
            for type in ["public.png", "public.utf8-plain-text"] {
                try await fixture.history.authority.makePayloadUnavailable(
                    itemID: fixture.current.id, revisionOrdinal: ordinal, typeIdentifier: type
                )
            }
        }
        let details = try await fixture.history.details(for: fixture.current.id)
        #expect(details.item == fixture.current)
        #expect(details.title == "current text")
        #expect(!details.effectiveMatchesCanonical)
        #expect(details.canonical == [
            HistoryRepresentationMetadata(typeIdentifier: "public.png", byteCount: fixture.image.count),
            HistoryRepresentationMetadata(typeIdentifier: "public.utf8-plain-text", byteCount: "canonical text".utf8.count),
        ])
        #expect(details.effective == [
            HistoryRepresentationMetadata(typeIdentifier: "public.png", byteCount: fixture.image.count),
            HistoryRepresentationMetadata(typeIdentifier: "public.utf8-plain-text", byteCount: "current text".utf8.count),
        ])
        #expect(details.revisions.map(\.title) == ["older revision", "current text"])
        #expect(details.revisions.map(\.isActive) == [false, true])
        #expect(details.revisions.map(\.byteCount) == [
            fixture.image.count + fixture.olderText.count,
            fixture.image.count + "current text".utf8.count,
        ])
        #expect(try await fixture.history.authority.readPositionInLocalContext() == position)
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await fixture.history.representation(HistoryRepresentationRequest(
                item: fixture.current, basis: .effective, typeIdentifier: "public.utf8-plain-text"
            ))
        }
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
        let details = try await fixture.history.details(for: fixture.current.id)
        #expect(details.item == fixture.current)
        #expect(details.title == "current text")
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

    @Test func explicitReadSelectsOnlyRequestedBasisAndRepresentation() async throws {
        let fixture = try await makeFixture()
        // Neither canonical nor current image is needed for a text request.
        for ordinal in [0, 1, 2] {
            try await fixture.history.authority.makePayloadUnavailable(
                itemID: fixture.current.id, revisionOrdinal: ordinal, typeIdentifier: "public.png"
            )
        }
        let value = try await fixture.history.representation(HistoryRepresentationRequest(
            item: fixture.current, basis: .canonical, typeIdentifier: "public.utf8-plain-text"
        ))
        #expect(value == HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("canonical text".utf8)))
        let effective = try await fixture.history.representation(HistoryRepresentationRequest(
            item: fixture.current, basis: .effective, typeIdentifier: "public.utf8-plain-text"
        ))
        #expect(effective.bytes == Data("current text".utf8))
        await #expect(throws: HistoryFailure.invalidInput(.unsupportedRepresentationType("public.pdf"))) {
            try await fixture.history.representation(HistoryRepresentationRequest(
                item: fixture.current, basis: .effective, typeIdentifier: "public.pdf"
            ))
        }
    }

    @Test(arguments: [HistoryContentBasis.canonical, .effective])
    func staleExplicitReadRejectsBeforeAccessingMissingPayload(basis: HistoryContentBasis) async throws {
        let fixture = try await makeFixture()
        for ordinal in [0, 2] {
            try await fixture.history.authority.makePayloadUnavailable(
                itemID: fixture.current.id, revisionOrdinal: ordinal, typeIdentifier: "public.utf8-plain-text"
            )
        }
        await #expect(throws: HistoryFailure.staleContent(
            expected: fixture.original.contentVersion, current: fixture.current.contentVersion
        )) {
            try await fixture.history.representation(HistoryRepresentationRequest(
                item: fixture.original, basis: basis, typeIdentifier: "public.utf8-plain-text"
            ))
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await fixture.history.representation(HistoryRepresentationRequest(
                item: fixture.current, basis: basis, typeIdentifier: "public.utf8-plain-text"
            ))
        }
    }

    @Test func explicitReadPreservesStoredUnicodeSpellingAndRejectsRemovedItem() async throws {
        let history = try await WSSupport.makeHistory()
        let exactType = "\u{FEFF}com.example.e\u{301}"
        let bytes = Data([0, 0xEF, 0xBB, 0xBF, 0x41])
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: exactType, bytes: bytes)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 850_000_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let details = try await history.details(for: item.id)
        #expect(details.effectiveMatchesCanonical)
        #expect(details.canonical.first?.typeIdentifier.utf8.elementsEqual(exactType.utf8) == true)
        let request = HistoryRepresentationRequest(
            item: item, basis: .canonical, typeIdentifier: exactType.precomposedStringWithCanonicalMapping
        )
        let value = try await history.representation(request)
        #expect(value.typeIdentifier.utf8.elementsEqual(exactType.utf8))
        #expect(value.bytes == bytes)
        _ = try await history.perform(.remove(item.id))
        await #expect(throws: HistoryFailure.notFound(item.id)) {
            try await history.representation(request)
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
