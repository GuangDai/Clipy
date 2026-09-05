/// Recipe 3 could project a valid UTF-16 prefix after dropping an odd trailing
/// byte. Public reopen must remove that derived text without changing the
/// captured bytes or immutable revision that contained it (05 §13/§15).
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

struct ProjectionRecipeV4OddUTF16RebuildTests {
    struct Fixture: Sendable {
        let typeIdentifier: String
        let canonical: [UInt8]
        let revision: [UInt8]
    }

    private struct Seeded: Sendable {
        let details: HistoryDetails
        let paste: PastePayload
        let position: ChangePosition
    }

    private struct ContentBytes: Sendable {
        let canonicalBlob: Data
        let revisionStateBlob: Data
    }

    @Test(arguments: [
        Fixture(typeIdentifier: "public.utf16-plain-text",
                canonical: [0x4F, 0x00, 0x4B, 0x00], revision: [0x51, 0x00, 0x5A, 0x00, 0xFF]),
        Fixture(typeIdentifier: "public.utf16-plain-text",
                canonical: [0xFF, 0xFE, 0x4F, 0x00, 0x4B, 0x00],
                revision: [0xFF, 0xFE, 0x51, 0x00, 0x5A, 0x00, 0xFF]),
        Fixture(typeIdentifier: "public.utf16-external-plain-text",
                canonical: [0x00, 0x4F, 0x00, 0x4B], revision: [0x00, 0x51, 0x00, 0x5A, 0xFF]),
        Fixture(typeIdentifier: "public.utf16-external-plain-text",
                canonical: [0xFE, 0xFF, 0x00, 0x4F, 0x00, 0x4B],
                revision: [0xFE, 0xFF, 0x00, 0x51, 0x00, 0x5A, 0xFF]),
    ])
    func publicReopenRemovesOddTailProjectionAndPreservesRawLineage(_ fixture: Fixture) async throws {
        let storeURL = WSSupport.tempStoreURL("projection-v4-odd-utf16")
        defer { WSSupport.removeStore(storeURL) }
        let seeded = try await seedCurrentOwner(at: storeURL, fixture: fixture)

        // The first facade is gone. A separate, synchronous fixture context
        // writes only the former recipe's derived columns; no model/context
        // escapes this helper into the subsequent public open.
        let originalBytes = try installLegacyProjection(at: storeURL)
        let reopened = try await WSSupport.openHistory(storeURL: storeURL)
        let page = try await reopened.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(page.position == seeded.position)
        #expect(page.rows.map(\.item) == [seeded.details.item])
        #expect(page.rows.map(\.title) == [fixture.typeIdentifier])
        #expect(page.rows.map(\.typeIdentifiers) == [[fixture.typeIdentifier]])

        // QZ is absent from the fallback identifier. A query such as "A"
        // would legitimately match "plain-text" and would not prove rebuild.
        let search = try await reopened.browse(HistoryBrowseRequest(
            kind: .search(text: "QZ", mode: .exact), limit: 10
        ))
        #expect(search.rows.isEmpty)
        #expect(search.position == seeded.position)

        let details = try await reopened.details(for: seeded.details.item.id)
        #expect(details.item == seeded.details.item)
        #expect(details.canonical == seeded.details.canonical)
        #expect(details.effective == seeded.details.effective)
        #expect(details.canonical.map(\.bytes) == [Data(fixture.canonical)])
        #expect(details.effective.map(\.bytes) == [Data(fixture.revision)])
        #expect(details.revisions.map(\.id) == seeded.details.revisions.map(\.id))
        #expect(details.revisions.map(\.createdAt) == seeded.details.revisions.map(\.createdAt))
        #expect(details.revisions.map(\.byteCount) == [fixture.revision.count])
        #expect(details.revisions.map(\.isActive) == [true])
        #expect(details.revisions.map(\.title) == [fixture.typeIdentifier])
        #expect(details.occurrence == seeded.details.occurrence)
        #expect(try await reopened.pastePayload(for: details.item.id) == seeded.paste)

        try assertRebuiltStoredRow(at: storeURL, fixture: fixture, bytes: originalBytes)
        #expect(try await reopened.usage().position == seeded.position)
    }

    private func seedCurrentOwner(at storeURL: URL, fixture: Fixture) async throws -> Seeded {
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let capture = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: fixture.typeIdentifier, bytes: Data(fixture.canonical)
            )],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_065_000)
        )))
        guard case let .committed(captureCommit) = capture,
              case let .inserted(item) = captureCommit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let revision = try await history.perform(.revise(RevisionRequest(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: fixture.typeIdentifier, action: .replace(bytes: Data(fixture.revision))
            )]))
        )))
        guard case let .committed(revisionCommit) = revision,
              case let .revised(revised) = revisionCommit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(revised.id == item.id)
        #expect(revised.contentVersion.rawValue == 2)
        #expect(revisionCommit.position.rawValue == 2)
        let details = try await history.details(for: item.id)
        let paste = try await history.pastePayload(for: item.id)
        return Seeded(
            details: details,
            paste: paste,
            position: revisionCommit.position
        )
    }

    private func installLegacyProjection(at storeURL: URL) throws -> ContentBytes {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<HistoryItemRow>())
        let row = try #require(rows.count == 1 ? rows.first : nil)
        let bytes = ContentBytes(canonicalBlob: row.canonicalBlob,
                                 revisionStateBlob: row.revisionStateBlob)
        try context.transaction {
            row.projectionSchemaVersion = 3
            row.title = "QZ"
            row.searchBody = "QZ"
        }
        return bytes
    }

    private func assertRebuiltStoredRow(at storeURL: URL, fixture: Fixture, bytes: ContentBytes) throws {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<HistoryItemRow>())
        let row = try #require(rows.count == 1 ? rows.first : nil)
        #expect(row.projectionSchemaVersion == 4)
        #expect(row.title == fixture.typeIdentifier)
        #expect(row.searchBody.isEmpty)
        #expect(row.canonicalBlob == bytes.canonicalBlob)
        #expect(row.revisionStateBlob == bytes.revisionStateBlob)
    }
}
