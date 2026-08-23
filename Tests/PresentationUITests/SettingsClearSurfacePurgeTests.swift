/// SettingsClearSurfacePurgeTests.swift — Card 9B regression coverage for
/// the Settings Danger Zone Clear ingress. These are Presentation seam tests:
/// a scripted `ClipboardHistory` supplies receipts to `HistoryViewState`, and
/// the real panel-surface owner consumes its published purge. No storage
/// semantics or private SwiftUI tree are inspected.
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct SettingsClearSurfacePurgeTests {

    /// Settings needs the receipt for inline count feedback, but the mutation
    /// must still cross `HistoryViewState.clearAwaitingReceipt` so only a
    /// committed Clear can retire owner-local navigation, preview, thumbnail,
    /// and details state (review Card 9B).
    @Test func clearIntentPurgesTheSharedSurfaceOnlyAfterACommittedReceipt() async throws {
        let row = fixtureRow(
            id: "00000000-0000-0000-0000-000000009B90",
            title: "sensitive"
        )
        let page = fixturePage(rows: [row], next: "settings-clear-next")
        let history = SettingsClearReceiptHistory(
            observedFirstPage: page,
            completions: [
                .success(.unchanged),
                .failure(.temporarilyUnavailable(.dedupIndexRebuild)),
                .success(
                    .committed(
                        HistoryCommit(
                            position: ChangePosition(rawValue: 2),
                            outcome: .cleared(count: 1)
                        )
                    )
                ),
            ]
        )
        let state = HistoryViewState(history: history)
        let preview = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(
            history: history,
            previewState: preview
        )
        surface.selection = row.item.id
        surface.detailsPath = [row.item]
        preview.togglePreview(for: row.item)

        state.activate()
        try #require(await pollUntil { state.rows == page.rows })

        let unchanged = try await state.clearAwaitingReceipt(.all)
        if case .committed = unchanged {
            Issue.record("unchanged Settings Clear returned a commit")
        }
        #expect(state.surfacePurge == nil)
        #expect(surface.selection == row.item.id)
        #expect(surface.detailsPath == [row.item])
        #expect(preview.previewedItem == row.item)

        do {
            _ = try await state.clearAwaitingReceipt(.all)
            Issue.record("typed Settings Clear failure returned a receipt")
        } catch let failure as HistoryFailure {
            #expect(failure == .temporarilyUnavailable(.dedupIndexRebuild))
        }
        #expect(state.surfacePurge == nil)
        #expect(surface.selection == row.item.id)
        #expect(surface.detailsPath == [row.item])
        #expect(preview.previewedItem == row.item)

        let committed = try await state.clearAwaitingReceipt(.all)
        guard case .committed(let commit) = committed else {
            Issue.record("Settings Clear did not return its committed receipt")
            state.deactivate()
            return
        }
        if case .cleared(count: 1) = commit.outcome {
            // Expected receipt used by Settings for inline feedback.
        } else {
            Issue.record("Settings Clear returned the wrong commit outcome")
        }
        let purge = try #require(state.surfacePurge)
        #expect(purge.generation == 1)
        #expect(purge.scope == .all)
        #expect(state.rows.isEmpty)
        #expect(!state.hasNextPage)

        surface.apply(purge)
        #expect(surface.selection == nil)
        #expect(surface.detailsPath.isEmpty)
        #expect(preview.previewedItem == nil)
        #expect(surface.appliedPurgeGeneration == 1)
        #expect(surface.detailsPurgeGeneration == 1)
        #expect(preview.purgeGeneration == 1)
        #expect(surface.thumbnails.purgeGeneration == 1)

        let actions = await history.recordedActions
        #expect(actions.count == 3)
        #expect(actions.allSatisfy {
            if case .clear(.all) = $0 { return true }
            return false
        })

        state.deactivate()
        await history.finishObservation()
    }
}

/// Scripted only at the public `ClipboardHistory` seam, as permitted for
/// Presentation view-state tests (01-architecture §4). It does not stand in
/// for a writer or assert storage semantics.
private actor SettingsClearReceiptHistory: ClipboardHistory {
    enum Completion: Sendable {
        case success(HistoryReceipt)
        case failure(HistoryFailure)
    }

    private let observedFirstPage: HistoryPage
    private var completions: [Completion]
    private var actions: [HistoryAction] = []
    private var observationContinuation:
        AsyncThrowingStream<HistoryPage, Error>.Continuation?

    init(observedFirstPage: HistoryPage, completions: [Completion]) {
        self.observedFirstPage = observedFirstPage
        self.completions = completions
    }

    var recordedActions: [HistoryAction] { actions }

    func finishObservation() {
        observationContinuation?.finish()
        observationContinuation = nil
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        actions.append(action)
        guard !completions.isEmpty else { return .unchanged }
        switch completions.removeFirst() {
        case .success(let receipt):
            return receipt
        case .failure(let failure):
            throw failure
        }
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        HistoryPage(position: ChangePosition(rawValue: 0), rows: [], next: nil)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        let (stream, continuation) =
            AsyncThrowingStream<HistoryPage, Error>.makeStream()
        observationContinuation = continuation
        continuation.yield(observedFirstPage)
        return stream
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        throw HistoryFailure.notFound(id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        throw HistoryFailure.notFound(id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        nil
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        .newStoreDefaults
    }
}
