/// Byte-exact projections through preparation, typed stamping and the real
/// capture writer, followed by a fresh SQL statement (05 §15; V2-09 §4).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct ProjectionTitleStorageBoundaryTests {
    @Test(arguments: [
        ("public.utf16-plain-text", Data([0xFF, 0xFE, 0xFF, 0xFE, 0x42, 0x00, 0x3E, 0xD8, 0x8A, 0xDD])),
        ("public.utf16-external-plain-text", Data([0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x42, 0xD8, 0x3E, 0xDD, 0x8A])),
    ])
    func utf16ContentMarkerSurvivesEachBodyStorageBoundary(type: String, wire: Data) async throws {
        let expected = Data([0xEF, 0xBB, 0xBF, 0x42, 0xF0, 0x9F, 0xA6, 0x8A])
        try await assertProjectionRoundTrip(type: type, bytes: wire, expectedTitle: expected, expectedBody: expected)
    }

    @Test(arguments: [("%EF%BB%BF", "\u{FEFF}"), ("%CC%81", "\u{301}")])
    func titleScalarsSurviveEachStorageBoundary(encodedPrefix: String, prefix: String) async throws {
        let address = "file:///\(encodedPrefix)before.txt"
        try await assertProjectionRoundTrip(
            type: "public.file-url", bytes: Data(address.utf8),
            expectedTitle: Data((prefix + "before.txt").utf8),
            expectedBody: Data((address + "\n/" + prefix + "before.txt").utf8)
        )
    }

    private func assertProjectionRoundTrip(
        type: String, bytes: Data, expectedTitle: Data, expectedBody: Data
    ) async throws {
        let observedAt = Date(timeIntervalSinceReferenceDate: 700_093_000)
        let capture = ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: bytes)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: observedAt
        )
        let bundle = try await IngestPreparationActor().prepare(capture)
        #expect(Data(bundle.projection.title.utf8) == expectedTitle)
        #expect(Data(bundle.projection.searchBody.utf8) == expectedBody)
        let stored = CommitPlanStamper.prepareNewItem(
            id: bundle.domain.candidateID, canonical: bundle.domain.canonical,
            projection: bundle.projection,
            occurrence: CopyOccurrence(
                firstCopiedAt: observedAt, lastCopiedAt: observedAt,
                count: 1, firstSource: nil, lastSource: nil
            )
        )
        #expect(Data(stored.projection.title.utf8) == expectedTitle)
        #expect(Data(stored.projection.searchBody.utf8) == expectedBody)
        #expect(stored.canonical == bundle.domain.canonical)
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let receipt = try await history.perform(.capture(capture))
        guard case .committed(let commit) = receipt,
              case .inserted(let reference) = commit.outcome else {
            Issue.record("Expected the real capture writer to insert a History Item")
            return
        }
        let (title, body) = try await history.authority.projectionBytesForRoundTripTest(reference.id)
        #expect(title == expectedTitle)
        #expect(body == expectedBody)
        #expect(Data(try ContentProjector.decodeStoredTitle(title, limits: .standard).utf8) == expectedTitle)
        #expect(Data(try ContentProjector.decodeStoredSearchBody(body, limits: .standard).utf8) == expectedBody)
    }
}

private extension HistoryAuthority {
    func projectionBytesForRoundTripTest(_ id: HistoryItemID) throws -> (Data, Data) {
        let statement = try database.prepare(
            "SELECT titleUTF8, searchBodyUTF8 FROM history_items WHERE id = ?",
            bindings: [.text(id.rawValue.uuidString)]
        )
        defer { statement.finalize() }
        guard try statement.step() else { throw HistoryFailure.notFound(id) }
        return (try statement.blob(at: 0), try statement.blob(at: 1))
    }
}
