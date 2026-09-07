/// V2-09 §10: the scale runner exercises the production writer above the
/// product cap without changing the public store-opening contract.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteScaleFixtureTests {
    @Test func measurementCapacitySupportsSeedCaptureAndCandidateLookupAboveProductCap() async throws {
        let storeURL = WSSupport.tempStoreURL("sqlite-scale-fixture")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await SQLiteHistory.openPerformanceFixture(storeURL: storeURL, retainedRows: 5_001)
        let seeded = try await history.seedPerformanceFixture(rowCount: 5_000) { index in
            Self.capture(index: index)
        }
        #expect(seeded.retainedRows == 5_000)
        #expect(seeded.transactionCount == 79)

        let inserted = try await history.perform(.capture(Self.capture(index: 5_000)))
        guard case .committed(let insertCommit) = inserted,
              case .inserted = insertCommit.outcome else {
            Issue.record("expected public insertion above the product cap in a measurement store")
            return
        }
        #expect(insertCommit.position.rawValue == 80)
        let usage = try await history.usage()
        #expect(usage.itemCount == 5_001)
        #expect(usage.canonicalBytes == 5_001 * 64)

        let copied = try await history.perform(.capture(Self.capture(index: 0)))
        guard case .committed(let copyCommit) = copied,
              case .coalesced(let item) = copyCommit.outcome else {
            Issue.record("expected durable candidate lookup at measurement capacity")
            return
        }
        #expect(copyCommit.position.rawValue == 81)
        #expect(try await history.usage().itemCount == 5_001)
        let payload = try await history.pastePayload(for: item.id)
        #expect(payload.representations.first?.bytes == Self.capture(index: 0).representations[0].bytes)
    }

    @Test func publicOpenStillRejectsMeasurementOnlyRetentionCapacity() async throws {
        let storeURL = WSSupport.tempStoreURL("sqlite-scale-public-cap")
        defer { WSSupport.removeStore(storeURL) }
        await #expect(throws: HistoryFailure.invalidInput(.invalidRetentionPolicy)) {
            try await SQLiteHistory.open(configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL), initialMaximumUnpinnedItems: 5_001
            ))
        }
    }

    private static func capture(index: Int) -> ClipboardCapture {
        let prefix = "scale-fixture-\(index)-"
        return ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data((prefix + String(repeating: "a", count: 64 - prefix.utf8.count)).utf8)
            )],
            origin: CopyOriginObservation(sourceApplication: "scale-fixture", lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: Double(index))
        )
    }
}
