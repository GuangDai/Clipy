/// V2-09 logical retirement is immediately visible even while physical
/// content reclamation is paused. Exercise the real public History boundary.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct DetachedContentVisibilityTests {
    private static let park = "detached-content-visibility"
    private static let textType = "public.utf8-plain-text"

    @Test(arguments: [false, true])
    func removedPayloadCannotBeReadOrRediscoveredBeforeCleanup(withLineageHint: Bool) async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await capture("detached needle", in: history)
        await history.authority.waitForBlobCleanup()
        let gate = await parkCleanup(history)
        do {
            _ = try await history.perform(.remove(item.id))
            // This is the distinguishing fixture: payload rows still exist,
            // so successful assertions cannot be explained by physical GC.
            #expect(try await contentCount(in: history, owner: item.id) == 1)
            for kind in [HistoryBrowseKind.recent, .search(text: "needle", mode: .exact),
                         .search(text: "needle", mode: .fuzzy)] {
                #expect(try await history.browse(.init(kind: kind, limit: 10)).rows.isEmpty)
            }
            await #expect(throws: HistoryFailure.notFound(item.id)) {
                try await history.details(for: item.id)
            }
            await #expect(throws: HistoryFailure.notFound(item.id)) {
                try await history.pastePayload(for: item.id)
            }
            await #expect(throws: HistoryFailure.notFound(item.id)) {
                try await history.thumbnail(for: item, pixels: PixelSize(width: 32, height: 32))
            }
            for basis in [HistoryContentBasis.canonical, .effective] {
                await #expect(throws: HistoryFailure.notFound(item.id)) {
                    try await history.representation(.init(
                        item: item, basis: basis, typeIdentifier: Self.textType
                    ))
                }
            }
            await #expect(throws: HistoryFailure.notFound(item.id)) {
                try await history.perform(.revise(revision(item, text: "replacement")))
            }
            // Canonical signature postings of the detached item remain in
            // representations. They must not produce a coalesced outcome.
            let fresh = try await capture("detached needle", in: history,
                                          lineageHint: withLineageHint ? item.id : nil)
            #expect(fresh.id != item.id)
            #expect(try await history.pastePayload(for: fresh.id).representations.map(\.bytes)
                    == [Data("detached needle".utf8)])
            #expect(try await history.browse(.init(kind: .recent, limit: 10)).rows.map(\.item.id)
                    == [fresh.id])
            await resumeCleanup(history, gate: gate)
        } catch {
            await resumeCleanup(history, gate: gate)
            throw error
        }
    }

    @Test func prunedRevisionIsAbsentBeforeCleanupAndLaterRevisionsRemainValid() async throws {
        let history = try await WSSupport.makeHistory()
        let original = try await capture("canonical needle", in: history)
        var current = original
        for text in ["old revision needle", "current revision needle"] {
            let receipt = try await history.perform(.revise(revision(current, text: text)))
            guard case .committed(let commit) = receipt, case .revised(let item) = commit.outcome else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            current = item
        }
        await history.authority.waitForBlobCleanup()
        let gate = await parkCleanup(history)
        do {
            _ = try await history.perform(.setRetentionPolicies(.init(
                age: nil, storage: nil,
                revisions: .init(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
            )))
            #expect(try await contentCount(in: history, owner: nil) == 1)
            let details = try await history.details(for: original.id)
            #expect(details.revisions.map(\.title) == ["current revision needle"])
            #expect(details.item == current)
            #expect(try await history.pastePayload(for: current.id).representations.map(\.bytes)
                    == [Data("current revision needle".utf8)])
            #expect(try await history.browse(.init(
                kind: .search(text: "old revision", mode: .exact), limit: 10
            )).rows.isEmpty)
            let receipt = try await history.perform(.revise(revision(current, text: "third revision")))
            guard case .committed(let commit) = receipt, case .revised(let revised) = commit.outcome else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            #expect(try await history.details(for: revised.id).revisions.map(\.title) == ["third revision"])
            // A canonical repeat still finds the live owner after pruning.
            let repeated = try await history.perform(.capture(WSSupport.textCapture(
                "canonical needle", observedAt: Date(timeIntervalSinceReferenceDate: 850_000_100)
            )))
            guard case .committed(let repeatedCommit) = repeated,
                  case .coalesced(let coalesced) = repeatedCommit.outcome else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            #expect(coalesced.id == original.id)
            await resumeCleanup(history, gate: gate)
        } catch {
            await resumeCleanup(history, gate: gate)
            throw error
        }
    }

    private func capture(
        _ text: String, in history: SQLiteHistory, lineageHint: HistoryItemID? = nil
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: 850_000_000), lineageHint: lineageHint
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    private func revision(_ item: HistoryItemReference, text: String) -> RevisionRequest {
        RevisionRequest(itemID: item.id, expected: item.contentVersion,
            intent: .replace(.init(decisions: [
                .init(typeIdentifier: Self.textType, action: .replace(bytes: Data(text.utf8)))
            ])))
    }

    private func contentCount(in history: SQLiteHistory, owner: HistoryItemID?) async throws -> Int64 {
        try await history.authority.withTestDatabase { authority in
            let row = try authority.database.prepare(
                owner == nil ? "SELECT count(*) FROM contents WHERE itemID IS NULL"
                    : "SELECT count(*) FROM contents WHERE itemID = ?",
                bindings: owner.map { [.text($0.rawValue.uuidString)] } ?? []
            )
            defer { row.finalize() }
            guard try row.step() else { throw HistoryFailure.persistence(.invariantViolation) }
            return try row.integer(at: 0)
        }
    }

    private func parkCleanup(_ history: SQLiteHistory) async -> SuspensionGate {
        let gate = SuspensionGate()
        await history.authority.setSuspensionHandler { point in
            if point == .blobCleanupBatchEntry { await gate.park(at: Self.park) }
        }
        await history.authority.requestBlobCleanup()
        await gate.waitForPark(Self.park)
        return gate
    }

    private func resumeCleanup(_ history: SQLiteHistory, gate: SuspensionGate) async {
        await history.authority.setSuspensionHandler(nil)
        await gate.resumeAll()
        await history.authority.waitForBlobCleanup()
    }
}
