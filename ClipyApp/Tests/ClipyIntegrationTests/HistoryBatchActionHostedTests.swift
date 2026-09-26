import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing
@testable import ClipyApp

@MainActor
struct HistoryBatchActionHostedTests {
    @Test(arguments: [false, true])
    func stoppingAfterCommitAcceptsItsReceiptPurgesThePanelAndKeepsTheRestForRetry(
        closesWorkspace: Bool
    ) async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let first = try await capture("first batch item", in: history)
        let second = try await capture("second batch item", in: history)
        let third = try await capture("third batch item", in: history)
        let delayed = BatchReceiptDeliveryHistory(base: history, heldItem: first.id)
        let composition = AppComposition.makeForTesting(
            history: delayed,
            adapter: PasteboardAdapter(pasteboard: ComposedSupport.makePasteboard())
        )
        defer {
            composition.stop()
            Task { await delayed.releaseReceipt() }
        }
        let workspace = composition.historyWorkspaceViewState
        workspace.activate()
        composition.viewState.activate()
        let loaded = await ComposedSupport.waitFor {
            workspace.rows.count == 3 && composition.viewState.rows.count == 3
        }
        try #require(loaded)
        let preview = PreviewPaneState()
        let surface = HistoryPanelSurfaceState(viewState: composition.viewState, previewState: preview)
        composition.installPanelSurface(surface)
        surface.selection = first.id
        preview.togglePreview(for: first)
        #expect(preview.previewedItem == first)

        let model = HistoryBatchActionModel(viewState: workspace)
        let running = Task { await model.execute(.remove, references: [first, second, third]) }
        await delayed.waitUntilReceiptIsHeld()
        #expect(model.isRunning)
        #expect(model.completedCount == 0)
        #expect(workspace.surfacePurge == nil)
        #expect(preview.previewedItem == first)
        await #expect(throws: HistoryFailure.notFound(first.id)) {
            try await history.details(for: first.id)
        }

        // A second click while the real first receipt is pending cannot start
        // another operation, overwrite progress, or send a second mutation.
        await model.execute(.unpin, references: [second])
        #expect(model.operation == .remove)
        #expect(model.requested == [first, second, third])
        #expect(await delayed.removeRequests == [first.id])
        model.stop()
        #expect(model.isStopping)
        if closesWorkspace {
            workspace.deactivate()
            // SwiftUI may also cancel its waiting task. A completed History
            // receipt still has to reach the shared presentation purge owner.
            running.cancel()
        }
        await delayed.releaseReceipt()
        await running.value

        #expect(!model.isRunning)
        #expect(!model.isStopping)
        #expect(model.wasStopped)
        #expect(model.succeeded == [first])
        #expect(model.failures.isEmpty)
        #expect(model.remaining == [second, third])
        #expect(model.retryReferences == [second, third])
        #expect(workspace.surfacePurge?.scope == .item(first.id))
        #expect(composition.viewState.surfacePurge?.scope == .item(first.id))
        #expect(surface.selection == nil)
        #expect(preview.previewedItem == nil)
        #expect(!preview.isOpen)
        #expect(surface.appliedPurgeGeneration == 1)
        #expect(try await history.details(for: second.id).item == second)
        #expect(try await history.details(for: third.id).item == third)
        #expect(await delayed.removeRequests == [first.id])
        if closesWorkspace { #expect(workspace.rows.isEmpty) }

        // Explicit retry contains only unfinished items. The prior committed
        // removal is neither repeated nor counted as a failure on reopening.
        await model.execute(.remove, references: model.retryReferences)
        #expect(model.requested == [second, third])
        #expect(model.succeeded == [second, third])
        #expect(model.failures.isEmpty)
        #expect(model.retryReferences.isEmpty)
        #expect(!model.wasStopped)
        #expect(await delayed.removeRequests == [first.id, second.id, third.id])
        #expect(surface.appliedPurgeGeneration == 3)
        #expect(try await history.browse(.init(kind: .recent, limit: 10)).rows.isEmpty)
    }

    private func capture(_ text: String, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ComposedSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: 700_331_000)
        )))
        return try #require(ComposedSupport.insertedReference(from: receipt, "batch arrange"))
    }
}

/// All work uses the real SQLite History. Only delivery of the first completed
/// removal receipt pauses, so stopping/closing can be tested after a durable
/// commit without introducing a second writer or a scripted mutation result.
private actor BatchReceiptDeliveryHistory: ClipboardHistory {
    private let base: SQLiteHistory
    private let heldItem: HistoryItemID
    private var didHold = false
    private var heldReceipt: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var removeRequests: [HistoryItemID] = []

    init(base: SQLiteHistory, heldItem: HistoryItemID) {
        self.base = base
        self.heldItem = heldItem
    }

    func waitUntilReceiptIsHeld() async {
        guard !didHold else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseReceipt() {
        heldReceipt?.resume()
        heldReceipt = nil
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        if case .remove(let id) = action { removeRequests.append(id) }
        let receipt = try await base.perform(action)
        if case .remove(let id) = action, id == heldItem, !didHold {
            didHold = true
            await withCheckedContinuation { continuation in
                heldReceipt = continuation
                let waiting = waiters
                waiters.removeAll()
                for waiter in waiting { waiter.resume() }
            }
        }
        return receipt
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        try await base.browse(request)
    }

    func observe(_ request: HistoryObservationRequest) async -> AsyncThrowingStream<HistoryPage, Error> {
        await base.observe(request)
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await base.details(for: id)
    }

    func representationMetadata(for item: HistoryItemReference) async throws -> [HistoryRepresentationMetadata] {
        try await base.representationMetadata(for: item)
    }

    func copySources(for id: HistoryItemID, expectedCopyCount: UInt64, offset: Int) async throws -> HistoryCopySourcePage {
        try await base.copySources(for: id, expectedCopyCount: expectedCopyCount, offset: offset)
    }

    func representation(_ request: HistoryRepresentationRequest) async throws -> HistoryRepresentation {
        try await base.representation(request)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        try await base.pastePayload(for: id)
    }

    func thumbnail(for item: HistoryItemReference, pixels: PixelSize) async throws -> ThumbnailPayload? {
        try await base.thumbnail(for: item, pixels: pixels)
    }

    func usage() async throws -> HistoryUsage {
        try await base.usage()
    }

    func backup(to directory: URL) async throws -> HistoryBackupReceipt {
        try await base.backup(to: directory)
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await base.retentionConfiguration()
    }
}
