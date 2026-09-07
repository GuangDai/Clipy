import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// V2-09 §§3–4: nullable policies and item byte accounting use the current schema.
@Suite("Retention schema round trip")
struct RetentionSchemaRoundTripTests {
    @Test func retentionRowsRoundTrip() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .temporary
        ))
        _ = try await history.perform(.capture(WSSupport.textCapture(
            String(repeating: "a", count: 128), observedAt: Date()
        )))
        _ = try await history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 86_400),
            storage: nil,
            revisions: RevisionRetention(maxRevisionsPerItem: 20, maxRevisionBytesPerItem: nil)
        )))
        try await history.authority.withTestDatabase { authority in
            let config = try authority.database.prepare("""
                SELECT key, ageMaxSeconds, storageMaxBytes, revisionMaxCount, revisionMaxBytes
                FROM retention_policies
                """)
            defer { config.finalize() }
            #expect(try config.step())
            #expect(try config.text(at: 0) == "retention-expansion")
            #expect(try config.real(at: 1) == 86_400)
            #expect(try config.isNull(at: 2))
            #expect(try config.integer(at: 3) == 20)
            #expect(try config.isNull(at: 4))
            #expect(try !config.step())
            let item = try authority.database.prepare(
                "SELECT canonicalBytes, revisionCount, revisionBytes FROM history_items"
            )
            defer { item.finalize() }
            #expect(try item.step())
            #expect(try item.integer(at: 0) == 128)
            #expect(try item.integer(at: 1) == 0)
            #expect(try item.integer(at: 2) == 0)
            #expect(try !item.step())
        }
    }
}
