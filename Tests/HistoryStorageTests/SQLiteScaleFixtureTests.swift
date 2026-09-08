/// V2-09 §9/§10: ordinary public stores admit retained history above the
/// former 5,000-item cap. Fixture setup uses the same standard resource limits.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteScaleFixtureTests {
    @Test func publicCaptureAndCandidateLookupWorkAboveFormerCountCap() async throws {
        let storeURL = WSSupport.tempStoreURL("sqlite-scale-fixture")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .persistent(storeURL: storeURL), initialMaximumUnpinnedItems: nil
        ))
        let seeded = try await history.seedPerformanceFixture(rowCount: 5_000) { index in
            Self.capture(index: index)
        }
        #expect(seeded.retainedRows == 5_000)
        #expect(seeded.transactionCount == 79)

        let inserted = try await history.perform(.capture(Self.capture(index: 5_000)))
        guard case .committed(let insertCommit) = inserted,
              case .inserted = insertCommit.outcome else {
            Issue.record("expected public insertion above the former count cap")
            return
        }
        #expect(insertCommit.position.rawValue == 80)
        let usage = try await history.usage()
        #expect(usage.itemCount == 5_001)
        #expect(usage.canonicalBytes == 5_001 * 64)

        let copied = try await history.perform(.capture(Self.capture(index: 0)))
        guard case .committed(let copyCommit) = copied,
              case .coalesced(let item) = copyCommit.outcome else {
            Issue.record("expected durable candidate lookup above the former count cap")
            return
        }
        #expect(copyCommit.position.rawValue == 81)
        #expect(try await history.usage().itemCount == 5_001)
        let payload = try await history.pastePayload(for: item.id)
        #expect(payload.representations.first?.bytes == Self.capture(index: 0).representations[0].bytes)
        // Pins are valid above the former total cap and do not consume the
        // explicitly configured unpinned allowance.
        _ = try await history.perform(.placePinned(item.id, at: .last))
        _ = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 5_001))
        let next = try await history.perform(.capture(Self.capture(index: 5_001)))
        guard case .committed(let nextCommit) = next, case .inserted = nextCommit.outcome else {
            Issue.record("Pinned history must not consume the unpinned allowance")
            return
        }
        #expect(!nextCommit.hasDestructiveRetentionEffects)
        #expect(try await history.usage().itemCount == 5_002)
        let page = try await history.browse(.init(kind: .recent, limit: 2))
        #expect(page.rows.first?.item.id == item.id)
        #expect(page.rows.first?.pinnedPosition == 0)
        #expect(page.rows.count == 2)

    }

    @Test(arguments: [5_001, 1_000_000, Int.max])
    func publicOpenAcceptsPositiveCountWithoutAnArtificialUpperBound(maximum: Int) async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .temporary, initialMaximumUnpinnedItems: maximum
        ))
        #expect(try await history.retentionConfiguration().maximumUnpinnedItems == maximum)
        let receipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: maximum))
        guard case .unchanged = receipt else {
            Issue.record("A satisfied unchanged count policy should not commit")
            return
        }
        #expect(try await history.usage().position.rawValue == 0)
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
