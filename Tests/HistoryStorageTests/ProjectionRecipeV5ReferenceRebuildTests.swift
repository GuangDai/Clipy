/// Recipe 4 retained URL/file bytes with only a category title and no search
/// body. Public reopen rebuilds readable reference metadata from those bytes,
/// without changing content lineage or History coherence (05 §13/§15).
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

struct ProjectionRecipeV5ReferenceRebuildTests {
    struct Fixture: Sendable {
        let typeIdentifier: String
        let canonicalAddress: String
        let revisedAddress: String?
        let legacyTitle: String
        let title: String
        let body: String
        let searchNeedle: String
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
        Fixture(
            typeIdentifier: "public.file-url",
            canonicalAddress: "file:///clipy-reference-uncreated/QZ%20folder/Report%20caf%C3%A9.txt",
            revisedAddress: nil,
            legacyTitle: "File",
            title: "Report café.txt",
            body: "file:///clipy-reference-uncreated/QZ%20folder/Report%20caf%C3%A9.txt\n"
                + "/clipy-reference-uncreated/QZ folder/Report café.txt",
            searchNeedle: "QZ folder"
        ),
        Fixture(
            typeIdentifier: "public.url",
            canonicalAddress: "https://EXAMPLE.invalid/QZ%20topic?q=%2F#section",
            revisedAddress: nil,
            legacyTitle: "URL",
            title: "https://EXAMPLE.invalid/QZ%20topic?q=%2F#section",
            body: "https://EXAMPLE.invalid/QZ%20topic?q=%2F#section\n/QZ topic",
            searchNeedle: "QZ topic"
        ),
        Fixture(
            typeIdentifier: "public.url",
            canonicalAddress: "https://example.invalid/old-reference",
            revisedAddress: "https://EXAMPLE.invalid/New%20topic?x=%25#revised",
            legacyTitle: "URL",
            title: "https://EXAMPLE.invalid/New%20topic?x=%25#revised",
            body: "https://EXAMPLE.invalid/New%20topic?x=%25#revised\n/New topic",
            searchNeedle: "New topic"
        ),
    ])
    func publicReopenRebuildsReferenceMetadataWithoutChangingHistory(_ fixture: Fixture) async throws {
        let storeURL = WSSupport.tempStoreURL("projection-v5-reference")
        defer { WSSupport.removeStore(storeURL) }
        let seeded = try await seedCurrentOwner(at: storeURL, fixture: fixture)
        let contentBytes = try installRecipe4Projection(at: storeURL, title: fixture.legacyTitle)

        // The helper returned only immutable values. The old facade and the
        // separate fixture context are out of scope before this public reopen.
        let reopened = try await WSSupport.openHistory(storeURL: storeURL)
        let page = try await reopened.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(page.position == seeded.position)
        #expect(page.rows.map(\.item) == [seeded.details.item])
        let row = try #require(page.rows.first)
        #expect(Data(row.title.utf8) == Data(fixture.title.utf8))
        #expect(row.typeIdentifiers == [fixture.typeIdentifier])
        let search = try await reopened.browse(HistoryBrowseRequest(
            kind: .search(text: fixture.searchNeedle, mode: .exact), limit: 10
        ))
        #expect(search.rows.map(\.item) == [seeded.details.item])
        #expect(search.position == seeded.position)

        let details = try await reopened.details(for: seeded.details.item.id)
        #expect(details.item == seeded.details.item)
        #expect(details.canonical == seeded.details.canonical)
        #expect(details.effective == seeded.details.effective)
        #expect(details.canonical.map(\.bytes) == [Data(fixture.canonicalAddress.utf8)])
        #expect(details.effective.map(\.bytes) == [Data((fixture.revisedAddress ?? fixture.canonicalAddress).utf8)])
        #expect(details.occurrence == seeded.details.occurrence)
        #expect(details.pinnedPosition == seeded.details.pinnedPosition)
        #expect(details.revisions.map(\.id) == seeded.details.revisions.map(\.id))
        #expect(details.revisions.map(\.createdAt) == seeded.details.revisions.map(\.createdAt))
        #expect(details.revisions.map(\.byteCount) == seeded.details.revisions.map(\.byteCount))
        #expect(details.revisions.map(\.isActive) == seeded.details.revisions.map(\.isActive))
        #expect(try await reopened.pastePayload(for: details.item.id) == seeded.paste)

        if fixture.revisedAddress != nil {
            #expect(details.revisions.map(\.title) == [fixture.title])
            let canonicalSearch = try await reopened.browse(HistoryBrowseRequest(
                kind: .search(text: fixture.canonicalAddress, mode: .exact), limit: 10
            ))
            #expect(canonicalSearch.rows.isEmpty)
        }
        try assertRebuiltRow(at: storeURL, fixture: fixture, original: contentBytes)
        #expect(try await reopened.usage().position == seeded.position)
    }

    private func seedCurrentOwner(at storeURL: URL, fixture: Fixture) async throws -> Seeded {
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let capture = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: fixture.typeIdentifier, bytes: Data(fixture.canonicalAddress.utf8)
            )],
            origin: CopyOriginObservation(sourceApplication: "com.example.reference-rebuild", lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_090_000)
        )))
        guard case let .committed(captureCommit) = capture,
              case let .inserted(item) = captureCommit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var position = captureCommit.position
        if let address = fixture.revisedAddress {
            let receipt = try await history.perform(.revise(RevisionRequest(
                itemID: item.id, expected: item.contentVersion,
                intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                    typeIdentifier: fixture.typeIdentifier, action: .replace(bytes: Data(address.utf8))
                )]))
            )))
            guard case let .committed(commit) = receipt,
                  case .revised = commit.outcome else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            position = commit.position
        }
        let details = try await history.details(for: item.id)
        let paste = try await history.pastePayload(for: item.id)
        #expect(details.item.contentVersion.rawValue == (fixture.revisedAddress == nil ? 1 : 2))
        #expect(position.rawValue == (fixture.revisedAddress == nil ? 1 : 2))
        return Seeded(details: details, paste: paste, position: position)
    }

    private func installRecipe4Projection(at storeURL: URL, title: String) throws -> ContentBytes {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<HistoryItemRow>())
        let row = try #require(rows.count == 1 ? rows.first : nil)
        let original = ContentBytes(canonicalBlob: row.canonicalBlob, revisionStateBlob: row.revisionStateBlob)
        try context.transaction {
            row.projectionSchemaVersion = 4
            row.titleUTF8 = Data(title.utf8)
            row.searchBody = ""
        }
        return original
    }

    private func assertRebuiltRow(at storeURL: URL, fixture: Fixture, original: ContentBytes) throws {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<HistoryItemRow>())
        let row = try #require(rows.count == 1 ? rows.first : nil)
        #expect(row.projectionSchemaVersion == 6)
        #expect(row.titleUTF8 == Data(fixture.title.utf8))
        #expect(Data(row.searchBody.utf8) == Data(fixture.body.utf8))
        #expect(row.canonicalBlob == original.canonicalBlob)
        #expect(row.revisionStateBlob == original.revisionStateBlob)
    }
}
