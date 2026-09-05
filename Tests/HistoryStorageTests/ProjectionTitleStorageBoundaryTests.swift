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
        let row = HistoryAuthority.makeRow(for: encoded.stored)
        #expect(row.titleUTF8 == expectedTitle, "after production model initialization, before insertion")

        // This isolated schema round trip distinguishes an accessor/insert
        // change from a transaction-save or fresh-context materialization
        // change. Public capture/revise/search remain covered by the journey.
        let schema = Schema(versionedSchema: HistorySchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try context.transaction {
            context.insert(row)
            #expect(row.titleUTF8 == expectedTitle, "after insertion, before transaction save")
        }
        #expect(row.titleUTF8 == expectedTitle, "same model after transaction save")
        #expect(Data(row.searchBody.utf8) == expectedBody)

        let freshContext = ModelContext(container)
        freshContext.autosaveEnabled = false
        let rows = try freshContext.fetch(FetchDescriptor<HistoryItemRow>())
        let reloaded = try #require(rows.count == 1 ? rows.first : nil)
        #expect(reloaded.titleUTF8 == expectedTitle, "fresh context materialization")
        let decodedTitle = try ContentProjector.decodeStoredTitle(
            reloaded.titleUTF8, limits: .standard
        )
        #expect(Data(decodedTitle.utf8) == expectedTitle, "strict title decode preserves every scalar")
        #expect(Data(reloaded.searchBody.utf8) == expectedBody)
        #expect(reloaded.canonicalBlob == encoded.stored.canonicalBlob)
        #expect(reloaded.revisionStateBlob == encoded.stored.revisionStateBlob)
    }
}
