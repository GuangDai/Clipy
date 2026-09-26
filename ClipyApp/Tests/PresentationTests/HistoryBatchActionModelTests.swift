import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

/// Batch feedback and retry selection use real History receipts. Each fixture
/// has its own temporary SQLite store; no scripted writer supplies outcomes.
@MainActor
struct HistoryBatchActionModelTests {
    @Test func pinPreservesExistingPriorityAndAppendsNewItemsInSelectionOrder() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let firstPinned = try await capture("existing first", in: history)
        let secondPinned = try await capture("existing second", in: history)
        let firstNew = try await capture("new first", in: history)
        let secondNew = try await capture("new second", in: history)
        let untouched = try await capture("not selected", in: history)
        _ = try await history.perform(.placePinned(firstPinned.id, at: .last))
        _ = try await history.perform(.placePinned(secondPinned.id, at: .last))
        let before = try await history.browse(.init(kind: .recent, limit: 20))
        let state = HistoryViewState(history: history)
        let model = HistoryBatchActionModel(viewState: state)

        // Existing pins appear in reverse order in this selection. They must
        // keep their priority while the two new pins append in selection order.
        await model.execute(.pin, references: [secondNew, secondPinned, firstNew, firstPinned, secondNew])

        let pinned = try await history.browse(.init(kind: .recent, limit: 20))
        let pinnedRows = pinned.rows.filter { $0.pinnedPosition != nil }
        #expect(pinnedRows.map(\.item) == [firstPinned, secondPinned, secondNew, firstNew])
        #expect(pinnedRows.compactMap(\.pinnedPosition) == [0, 1, 2, 3])
        #expect(pinned.position.rawValue == before.position.rawValue + 2)
        let untouchedRow = try #require(pinned.rows.first { $0.item == untouched })
        #expect(untouchedRow.pinnedPosition == nil)
        #expect(model.requested == [secondNew, secondPinned, firstNew, firstPinned])
        #expect(model.succeeded == model.requested)
        #expect(model.completedCount == 4)
        #expect(model.failures.isEmpty)
        #expect(model.retryReferences.isEmpty)
        #expect(!model.isRunning)
        #expect(!model.wasStopped)

        await model.execute(.unpin, references: [secondNew, firstPinned, secondNew])

        let unpinned = try await history.browse(.init(kind: .recent, limit: 20))
        #expect(unpinned.rows.filter { $0.pinnedPosition != nil }.map(\.item) == [secondPinned, firstNew])
        #expect(unpinned.rows.filter { $0.pinnedPosition == nil }.map(\.item).contains(firstPinned))
        #expect(unpinned.rows.filter { $0.pinnedPosition == nil }.map(\.item).contains(secondNew))
        #expect(Set(unpinned.rows.map(\.item)) == Set([firstPinned, secondPinned, firstNew, secondNew, untouched]))
        #expect(unpinned.position.rawValue == pinned.position.rawValue + 2)
        #expect(model.requested == [secondNew, firstPinned])
        #expect(model.succeeded == [secondNew, firstPinned])
        #expect(model.completedCount == 2)
        #expect(model.failures.isEmpty)
        #expect(model.retryReferences.isEmpty)
    }

    @Test func removeContinuesPastMissingItemsDeduplicatesIDsAndRetriesOnlyFailures() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let first = try await capture("remove first", in: history)
        let missing = try await capture("already removed", in: history)
        let second = try await capture("remove second", in: history)
        let survivor = try await capture("leave retained", in: history)
        _ = try await history.perform(.remove(missing.id))
        let before = try await history.browse(.init(kind: .recent, limit: 20))
        let state = HistoryViewState(history: history)
        let model = HistoryBatchActionModel(viewState: state)

        // The missing item sits between successful removals. Repeated IDs
        // must neither turn a successful removal into a later failure nor
        // report the same missing item more than once.
        await model.execute(.remove, references: [first, missing, second, first, missing, second])

        #expect(model.requested == [first, missing, second])
        #expect(model.succeeded == [first, second])
        #expect(model.successfulIDs == Set([first.id, second.id]))
        #expect(model.completedCount == 3)
        let failure = try #require(model.failures.first)
        #expect(model.failures.count == 1)
        #expect(failure.item == missing)
        #expect(failure.reason == .notFound(missing.id))
        #expect(model.failedReferences == [missing])
        #expect(model.retryReferences == [missing])
        #expect(model.remaining.isEmpty)
        #expect(!model.isRunning)
        #expect(!model.wasStopped)
        let removed = try await history.browse(.init(kind: .recent, limit: 20))
        #expect(removed.rows.map(\.item) == [survivor])
        #expect(removed.position.rawValue == before.position.rawValue + 2)
        let failureEpisode = state.failureEpisode

        await model.execute(.remove, references: model.retryReferences)

        #expect(model.requested == [missing])
        #expect(model.succeeded.isEmpty)
        #expect(model.successfulIDs.isEmpty)
        #expect(model.completedCount == 1)
        #expect(model.failures.count == 1)
        #expect(model.failures.first?.reason == .notFound(missing.id))
        #expect(model.retryReferences == [missing])
        #expect(model.remaining.isEmpty)
        // Replaying either completed removal would add another real notFound
        // failure at the shared receipt owner, even though it cannot commit.
        #expect(state.failureEpisode == failureEpisode + 1)
        let retried = try await history.browse(.init(kind: .recent, limit: 20))
        #expect(retried == removed)
    }

    @Test func cancellationBeforeTheTaskStartsNeverEntersTheBatchOrChangesHistory() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("keep when the workspace closes", in: history)
        let before = try await history.browse(.init(kind: .recent, limit: 20))
        let state = HistoryViewState(history: history)
        let model = HistoryBatchActionModel(viewState: state)

        // The task inherits this MainActor turn. Closing the workspace can
        // cancel it before any suspension gives the batch an executor turn.
        let task = Task { await model.execute(.remove, references: [item]) }
        task.cancel()
        await task.value

        #expect(model.operation == nil)
        #expect(model.requested.isEmpty)
        #expect(model.succeeded.isEmpty)
        #expect(model.failures.isEmpty)
        #expect(model.remaining.isEmpty)
        #expect(model.completedCount == 0)
        #expect(!model.isRunning)
        #expect(!model.wasStopped)
        #expect(state.surfacePurge == nil)
        #expect(state.failure == nil)
        let after = try await history.browse(.init(kind: .recent, limit: 20))
        #expect(after == before)
    }

    private func capture(_ text: String, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8)
            )],
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw FixtureFailure.expectedInsertion
        }
        return item
    }

    private enum FixtureFailure: Error { case expectedInsertion }
}
