/// Isolates the projection-to-model boundary behind the real reference-search
/// journey. Every encoded field and model assignment uses the production
/// preparation/stamping/mapping code; no alternate History writer is defined.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

@MainActor
struct ProjectionTitleStorageBoundaryTests {
    @Test(arguments: [
        ("public.utf16-plain-text", Data([0xFF, 0xFE, 0xFF, 0xFE, 0x42, 0x00, 0x3E, 0xD8, 0x8A, 0xDD])),
        ("public.utf16-external-plain-text", Data([0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x42, 0xD8, 0x3E, 0xDD, 0x8A])),
    ])
    func utf16ContentMarkerSurvivesEachBodyStorageBoundary(type: String, wire: Data) async throws {
        // One encoding BOM, then content U+FEFF + B + fox. The expected
        // UTF-8 bytes are literal, independent of the preparation decoder.
        let expected = Data([0xEF, 0xBB, 0xBF, 0x42, 0xF0, 0x9F, 0xA6, 0x8A])
        let observedAt = Date(timeIntervalSinceReferenceDate: 700_093_000)
        let bundle = try await IngestPreparationActor().prepare(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: wire)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: observedAt
        ))
        #expect(Data(bundle.projection.title.utf8) == expected, "title after ingest preparation")
        #expect(Data(bundle.projection.searchBody.utf8) == expected, "body after ingest preparation")
        let encoded = try CommitPlanStamper.encodeNewItem(
            id: bundle.domain.candidateID,
            canonical: bundle.domain.canonical,
            projection: bundle.projection,
            occurrence: CopyOccurrence(
                firstCopiedAt: observedAt, lastCopiedAt: observedAt,
                count: 1, firstSource: nil, lastSource: nil
            )
        )
        #expect(Data(encoded.stored.projection.title.utf8) == expected, "title after capture encoding")
        #expect(Data(encoded.stored.projection.searchBody.utf8) == expected, "body after capture encoding")

        // Register the current schema before constructing its model. From
        // here through fresh-context readback there is no actor suspension.
        let schema = historySchema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let row = HistoryAuthority.makeRow(for: encoded.stored)
        #expect(row.titleUTF8 == expected, "title after model initialization")
        #expect(row.searchBodyUTF8 == expected, "body after model initialization")
        try context.transaction {
            context.insert(row)
            #expect(row.titleUTF8 == expected, "title after insertion before save")
            #expect(row.searchBodyUTF8 == expected, "body after insertion before save")
        }
        #expect(row.titleUTF8 == expected, "title after transaction save")
        #expect(row.searchBodyUTF8 == expected, "body after transaction save")
        #expect(row.canonicalBlob == encoded.stored.canonicalBlob)
        #expect(row.revisionStateBlob == encoded.stored.revisionStateBlob)

        let freshContext = ModelContext(container)
        freshContext.autosaveEnabled = false
        let rows = try freshContext.fetch(FetchDescriptor<HistoryItemRow>())
        let reloaded = try #require(rows.count == 1 ? rows.first : nil)
        #expect(reloaded.titleUTF8 == expected, "title after fresh-context materialization")
        #expect(reloaded.searchBodyUTF8 == expected, "body after fresh-context materialization")
        let decodedBody = try ContentProjector.decodeStoredSearchBody(
            reloaded.searchBodyUTF8, limits: .standard
        )
        #expect(Data(decodedBody.utf8) == expected, "body after strict byte decoding")
        #expect(reloaded.canonicalBlob == encoded.stored.canonicalBlob)
        #expect(reloaded.revisionStateBlob == encoded.stored.revisionStateBlob)
    }

    @Test(arguments: [("%EF%BB%BF", "\u{FEFF}"), ("%CC%81", "\u{301}")])
    func titleScalarsSurviveEachModelBoundary(encodedPrefix: String, prefix: String) async throws {
        let address = "file:///\(encodedPrefix)before.txt"
        let expectedTitle = Data((prefix + "before.txt").utf8)
        let expectedBody = Data((address + "\n/" + prefix + "before.txt").utf8)
        let observedAt = Date(timeIntervalSinceReferenceDate: 700_091_000)
        let bundle = try await IngestPreparationActor().prepare(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.file-url", bytes: Data(address.utf8)
            )],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: observedAt
        ))
        #expect(Data(bundle.projection.title.utf8) == expectedTitle, "after real ingest preparation")
        #expect(Data(bundle.projection.searchBody.utf8) == expectedBody)

        let encoded = try CommitPlanStamper.encodeNewItem(
            id: bundle.domain.candidateID,
            canonical: bundle.domain.canonical,
            projection: bundle.projection,
            occurrence: CopyOccurrence(
                firstCopiedAt: observedAt, lastCopiedAt: observedAt,
                count: 1, firstSource: nil, lastSource: nil
            )
        )
        #expect(Data(encoded.stored.projection.title.utf8) == expectedTitle, "after real capture encoding")
        #expect(Data(encoded.stored.projection.searchBody.utf8) == expectedBody)

        // This isolated schema round trip distinguishes an accessor/insert
        // change from a transaction-save or fresh-context materialization
        // change. Public capture/revise/search remain covered by the journey.
        let schema = historySchema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let row = HistoryAuthority.makeRow(for: encoded.stored)
        #expect(row.titleUTF8 == expectedTitle, "after production model initialization, before insertion")
        #expect(row.searchBodyUTF8 == expectedBody, "body after model initialization")
        try context.transaction {
            context.insert(row)
            #expect(row.titleUTF8 == expectedTitle, "after insertion, before transaction save")
            #expect(row.searchBodyUTF8 == expectedBody, "body after insertion before save")
        }
        #expect(row.titleUTF8 == expectedTitle, "same model after transaction save")
        #expect(row.searchBodyUTF8 == expectedBody, "body after transaction save")

        let freshContext = ModelContext(container)
        freshContext.autosaveEnabled = false
        let rows = try freshContext.fetch(FetchDescriptor<HistoryItemRow>())
        let reloaded = try #require(rows.count == 1 ? rows.first : nil)
        #expect(reloaded.titleUTF8 == expectedTitle, "fresh context materialization")
        let decodedTitle = try ContentProjector.decodeStoredTitle(
            reloaded.titleUTF8, limits: .standard
        )
        #expect(Data(decodedTitle.utf8) == expectedTitle, "strict title decode preserves every scalar")
        #expect(reloaded.searchBodyUTF8 == expectedBody, "body after fresh-context materialization")
        let decodedBody = try ContentProjector.decodeStoredSearchBody(
            reloaded.searchBodyUTF8, limits: .standard
        )
        #expect(Data(decodedBody.utf8) == expectedBody, "strict body decode preserves every scalar")
        #expect(reloaded.canonicalBlob == encoded.stored.canonicalBlob)
        #expect(reloaded.revisionStateBlob == encoded.stored.revisionStateBlob)
    }
}
