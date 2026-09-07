/// Usage reads the committed aggregate only. Missing content files must not
/// trigger lineage reads, while impossible aggregate facts remain failures.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct HistoryUsageReadValidationTests {
    @Test(arguments: [false, true])
    func usageDoesNotReadCanonicalOrRevisionPayloads(damageRevision: Bool) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let original = try await RetainedBytesTestSupport.capture("alpha", in: history)
        let item = try await RetainedBytesTestSupport.revise(original, text: "beta", in: history)
        let before = try await history.usage()
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("""
                UPDATE representations SET inlineBytes=NULL,blobID=?
                WHERE contentID IN (SELECT id FROM contents WHERE itemID=? AND revisionOrdinal=?)
                """, bindings: [.text(UUID().uuidString), .text(item.id.rawValue.uuidString),
                                 .integer(damageRevision ? 1 : 0)])
        }
        #expect(try await history.usage() == before)
        #expect(before.itemCount == 1)
        #expect(before.pinnedItemCount == 0)
        #expect(before.canonicalBytes == 5)
        #expect(before.revisionBytes == 4)
        #expect(before.totalContentBytes == 9)
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.details(for: item.id)
        }
        #expect(try await history.usage() == before)
    }

    enum Damage: CaseIterable, Sendable {
        case missingState, tooManyPinned, overflowingBytes, wrongScalarType
        case itemWithoutCanonicalBytes, revisionsWithoutItems

        var sql: String {
            switch self {
            case .missingState: "DELETE FROM history_state"
            case .tooManyPinned: "UPDATE history_state SET pinnedItemCount=2"
            case .overflowingBytes: "UPDATE history_state SET canonicalBytes=9223372036854775807,revisionBytes=1"
            case .wrongScalarType: "UPDATE history_state SET canonicalBytes='not an integer'"
            case .itemWithoutCanonicalBytes: "UPDATE history_state SET canonicalBytes=0"
            case .revisionsWithoutItems:
                "UPDATE history_state SET retainedItemCount=0,canonicalBytes=0,revisionBytes=1"
            }
        }
    }

    @Test(arguments: Damage.allCases)
    func impossibleAggregateIsNotPublishedAsNormalUsage(_ damage: Damage) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        _ = try await RetainedBytesTestSupport.capture("alpha", in: history)
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute(damage.sql)
        }
        let failure: HistoryFailure = damage == .wrongScalarType
            ? .persistence(.corruptStoredValue) : .persistence(.invariantViolation)
        await #expect(throws: failure) { try await history.usage() }
        // Repeating the read must not repair the bad aggregate into defaults.
        await #expect(throws: failure) { try await history.usage() }
    }

    @Test(arguments: ["retainedItemCount", "pinnedItemCount", "canonicalBytes", "revisionBytes"])
    func negativeAggregateIsRejectedByTheActualSQLiteConstraint(_ column: String) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        _ = try await RetainedBytesTestSupport.capture("alpha", in: history)
        let before = try await history.usage()
        do {
            try await history.authority.withTestDatabase { authority in
                try authority.database.execute("UPDATE history_state SET \(column)=-1")
            }
            Issue.record("Negative aggregate must fail its CHECK constraint")
        } catch let failure as SQLiteFailure {
            #expect(failure.isConstraint)
        }
        #expect(try await history.usage() == before)
    }
}
