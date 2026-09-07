/// V2-09 §6: item scalars, normalized immutable contents and the aggregate
/// change in the same SQLite transaction. There is no separate byte projection.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct RetainedBytesProjectionLifecycleTests {
    @Test func captureAndCoalescingCountRepresentationBytesWithoutDuplicatingStorage() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let text = Data("r3 canonical base".utf8)
        let opaque = Data(repeating: 0xA7, count: 70_000)
        let capture = ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: text),
                CapturedRepresentation(typeIdentifier: "com.example.opaque", bytes: opaque),
            ], origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_100_000)
        )
        let receipt = try await history.perform(.capture(capture))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            Issue.record("Expected capture insertion"); return
        }
        let original = try await RetainedBytesTestSupport.counts(item.id, in: history)
        #expect(original == RetainedBytesTestSupport.Counts(canonical: 70_017, revisions: 0, revisionBytes: 0))
        let usage = try await history.usage()
        #expect(usage.canonicalBytes == text.count + opaque.count)
        #expect(usage.revisionBytes == 0)
        #expect(usage.itemCount == 1)
        let repeated = try await history.perform(.capture(capture))
        guard case .committed(let repeatedCommit) = repeated, case .coalesced(let winner) = repeatedCommit.outcome else {
            Issue.record("Expected coalescing"); return
        }
        #expect(winner.id == item.id)
        #expect(try await RetainedBytesTestSupport.counts(item.id, in: history) == original)
        #expect(try await history.usage().totalContentBytes == usage.totalContentBytes)
        let details = try await history.details(for: item.id)
        #expect(details.canonical.reduce(0) { $0 + $1.byteCount } == 70_017)
        for (type, expected) in [("public.utf8-plain-text", text), ("com.example.opaque", opaque)] {
            let representation = try await history.representation(.init(
                item: item, basis: .canonical, typeIdentifier: type
            ))
            #expect(representation.bytes == expected)
        }
        #expect(details.occurrence.count == 2)
        try await RetainedBytesTestSupport.assertAccounting(in: history)
    }

    @Test func appendAndPrunePreserveCanonicalAndCurrentImmutableContent() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let original = try await RetainedBytesTestSupport.capture("r3 canonical base", in: history)
        let first = try await RetainedBytesTestSupport.revise(original, text: "r3 revised effective bytes", in: history)
        let current = try await RetainedBytesTestSupport.revise(first, text: "r3 second revision", in: history)
        #expect(try await RetainedBytesTestSupport.counts(original.id, in: history)
            == RetainedBytesTestSupport.Counts(canonical: 17, revisions: 2, revisionBytes: 44))
        let before = try await history.details(for: original.id)
        let canonicalBefore = try await history.representation(.init(
            item: current, basis: .canonical, typeIdentifier: "public.utf8-plain-text"
        ))
        let effectiveBefore = try await history.representation(.init(
            item: current, basis: .effective, typeIdentifier: "public.utf8-plain-text"
        ))
        let usage = try await history.usage()
        let receipt = try await history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: nil, storage: nil,
            revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )))
        guard case .committed(let commit) = receipt,
              case .retentionPoliciesSet(let retired, let pruned) = commit.outcome else {
            Issue.record("Expected a revision-pruning policy commit"); return
        }
        #expect(retired == 0)
        #expect(pruned == 1)
        let after = try await history.details(for: original.id)
        #expect(after.item == current)
        #expect(after.canonical == before.canonical)
        #expect(after.effective == before.effective)
        #expect(try await history.representation(.init(
            item: current, basis: .canonical, typeIdentifier: "public.utf8-plain-text"
        )) == canonicalBefore)
        #expect(try await history.representation(.init(
            item: current, basis: .effective, typeIdentifier: "public.utf8-plain-text"
        )) == effectiveBefore)
        #expect(after.revisions.count == 1)
        #expect(after.revisions.map(\.id) == Array(before.revisions.suffix(1)).map(\.id))
        #expect(try await RetainedBytesTestSupport.counts(original.id, in: history)
            == RetainedBytesTestSupport.Counts(canonical: 17, revisions: 1, revisionBytes: 18))
        #expect(try await history.usage().totalContentBytes == usage.totalContentBytes - 26)
        #expect(commit.position.rawValue == usage.position.rawValue + 1)
        try await RetainedBytesTestSupport.assertAccounting(in: history)
    }

    @Test func failedRevisionAndRemovalLeaveAllAccountingAndContentUnchanged() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await RetainedBytesTestSupport.capture("canonical", in: history)
        let before = try await history.details(for: item.id)
        let beforeBytes = try await history.representation(.init(
            item: item, basis: .canonical, typeIdentifier: "public.utf8-plain-text"
        ))
        let usage = try await history.usage()
        for action in [RetainedBytesTestSupport.revisionAction(item, text: "new content"), .remove(item.id)] {
            await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
            await #expect(throws: HistoryFailure.persistence(.transaction)) {
                try await history.perform(action)
            }
            #expect(try await history.usage() == usage)
            #expect(try await history.details(for: item.id) == before)
            for basis in [HistoryContentBasis.canonical, .effective] {
                #expect(try await history.representation(.init(
                    item: item, basis: basis, typeIdentifier: "public.utf8-plain-text"
                )) == beforeBytes)
            }
            try await RetainedBytesTestSupport.assertAccounting(in: history)
        }
    }

    enum Removal: CaseIterable, Sendable { case remove, clearAll, countRetention }

    @Test(arguments: Removal.allCases)
    func deletionRemovesContentAndAccountingTogether(_ removal: Removal) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let older = try await RetainedBytesTestSupport.capture("older", at: 700_100_000, in: history)
        _ = try await RetainedBytesTestSupport.revise(older, text: "old revision", in: history)
        let newer = try await RetainedBytesTestSupport.capture("newer", at: 700_100_100, in: history)
        let action: HistoryAction
        switch removal {
        case .remove: action = .remove(older.id)
        case .clearAll: action = .clear(.all)
        case .countRetention: action = .setRetentionPolicy(maximumUnpinnedItems: 1)
        }
        _ = try await history.perform(action)
        #expect(try await RetainedBytesTestSupport.counts(older.id, in: history) == nil)
        let usage = try await history.usage()
        #expect(usage.itemCount == (removal == .clearAll ? 0 : 1))
        #expect(usage.canonicalBytes == (removal == .clearAll ? 0 : 5))
        #expect(usage.revisionBytes == 0)
        if removal != .clearAll {
            #expect(try await history.pastePayload(for: newer.id).representations.first?.bytes == Data("newer".utf8))
        }
        try await RetainedBytesTestSupport.assertAccounting(in: history)
    }

    @Test func storageClockInjectionUsesTheCurrentSQLiteAuthority() async throws {
        struct FixedClock: StorageClock {
            let fixed: Date
            func now() -> Date { fixed }
        }
        let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let authority = try HistoryAuthority(storeLocation: HistoryStoreLocation(persistence: .temporary),
                                             storageClock: FixedClock(fixed: epoch))
        _ = try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        let clock = await authority.storageClock
        #expect(clock.now() == epoch)
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let systemClock = await history.authority.storageClock
        #expect(systemClock is SystemStorageClock)
    }
}

/// Shared direct fixtures for this accounting test group. All mutations use
/// the actual public writer; SQL only observes or deliberately damages facts.
enum RetainedBytesTestSupport {
    struct Counts: Equatable, Sendable {
        let canonical: Int
        let revisions: Int
        let revisionBytes: Int
    }

    static func capture(_ text: String, at seconds: Double = 700_100_000,
                        in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: seconds))))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    static func revisionAction(_ item: HistoryItemReference, text: String) -> HistoryAction {
        .revise(RevisionRequest(itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data(text.utf8))
            )]))))
    }

    static func revise(_ item: HistoryItemReference, text: String,
                       in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(revisionAction(item, text: text))
        guard case .committed(let commit) = receipt, case .revised(let revised) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return revised
    }

    static func counts(_ id: HistoryItemID, in history: SQLiteHistory) async throws -> Counts? {
        try await history.authority.withTestDatabase { authority in
            let row = try authority.database.prepare(
                "SELECT canonicalBytes,revisionCount,revisionBytes FROM history_items WHERE id=?",
                bindings: [.text(id.rawValue.uuidString)])
            defer { row.finalize() }
            guard try row.step() else { return nil }
            return try Counts(canonical: Int(row.integer(at: 0)), revisions: Int(row.integer(at: 1)),
                              revisionBytes: Int(row.integer(at: 2)))
        }
    }

    static func replaceCounts(_ id: HistoryItemID, with value: Counts, in history: SQLiteHistory) async throws {
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("""
                UPDATE history_items SET canonicalBytes=?,revisionCount=?,revisionBytes=? WHERE id=?
                """, bindings: [.integer(Int64(value.canonical)), .integer(Int64(value.revisions)),
                                 .integer(Int64(value.revisionBytes)), .text(id.rawValue.uuidString)])
        }
    }

    static func assertAccounting(in history: SQLiteHistory) async throws {
        let usage = try await history.usage()
        let totals = try await history.authority.withTestDatabase { authority -> [Int64] in
            let row = try authority.database.prepare("""
                SELECT (SELECT count(*) FROM history_items),
                    (SELECT coalesce(sum(canonicalBytes),0) FROM history_items),
                    (SELECT coalesce(sum(revisionBytes),0) FROM history_items),
                    (SELECT coalesce(sum(contentByteCount),0) FROM contents WHERE revisionOrdinal=0),
                    (SELECT coalesce(sum(contentByteCount),0) FROM contents WHERE revisionOrdinal>0),
                    (SELECT coalesce(sum(byteCount),0) FROM representations)
                """)
            defer { row.finalize() }
            guard try row.step() else { throw HistoryFailure.persistence(.invariantViolation) }
            return try (0..<6).map { try row.integer(at: Int32($0)) }
        }
        #expect(totals[0] == Int64(usage.itemCount))
        #expect(totals[1] == Int64(usage.canonicalBytes))
        #expect(totals[2] == Int64(usage.revisionBytes))
        #expect(totals[3] == totals[1])
        #expect(totals[4] == totals[2])
        #expect(totals[5] == Int64(usage.totalContentBytes))
    }
}
