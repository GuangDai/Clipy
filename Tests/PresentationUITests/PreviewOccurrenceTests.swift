import ContentPreview
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

@MainActor
struct PreviewOccurrenceTests {
    @Test func coalescingUpdatesVisibleMetadataWithoutReloadingContent() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("preview content", at: 1, source: "first.app", in: history)
        let viewState = HistoryViewState(history: history)
        viewState.activate()
        defer { viewState.deactivate() }
        try #require(await pollUntil { viewState.rows.first?.copyCount == 1 })
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        let first = try #require(PreviewFooterMetadata(item: item, row: viewState.rows.first))
        #expect(first.count == 1)
        #expect(first.lastSource == "first.app")

        #expect(try await capture("preview content", at: 2, source: "second.app", in: history) == item)
        try #require(await pollUntil { viewState.rows.first?.copyCount == 2 })
        let updated = try #require(PreviewFooterMetadata(item: item, row: viewState.rows.first))
        #expect(updated.count == 2)
        #expect(updated.lastCopiedAt == Date(timeIntervalSinceReferenceDate: 700_200_002))
        #expect(updated.lastSource == "second.app")
        // Metadata is current row state, never a second content load or a
        // cached approximation with invented first-copy/source fields.
        #expect(loader.phase == .content(.text("preview content")))
        #expect(loader.requestedItem == item)
        viewState.refresh()
        #expect(viewState.rows.isEmpty)
        #expect(PreviewFooterMetadata(item: item, row: viewState.rows.first) == nil)
        try #require(await pollUntil { viewState.rows.first?.copyCount == 2 })
        #expect(PreviewFooterMetadata(item: item, row: viewState.rows.first) == updated)
    }

    @Test func missingUnrelatedAndDifferentVersionRowsHideMetadata() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("original", at: 1, source: "first.app", in: history)
        _ = try await history.perform(.revise(.init(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(.init(decisions: [.init(
                typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("revised".utf8))
            )]))
        )))
        let other = try await capture("other item", at: 2, source: "other.app", in: history)
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        let revisedRow = try #require(page.rows.first { $0.item.id == item.id })
        let otherRow = try #require(page.rows.first { $0.item == other })
        #expect(PreviewFooterMetadata(item: item, row: revisedRow) == nil)
        #expect(PreviewFooterMetadata(item: item, row: otherRow) == nil)
        #expect(PreviewFooterMetadata(item: item, row: nil) == nil)
        #expect(PreviewFooterMetadata(item: nil, row: revisedRow) == nil)
        #expect(PreviewFooterMetadata(item: revisedRow.item, row: revisedRow)?.lastSource == "first.app")
    }

#if DEBUG
    @Test func coalescingDuringRenderCannotBeOverwrittenByContentPublication() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let representations = [CapturedRepresentation(typeIdentifier: "public.png", bytes: fixturePNGData)]
        let receipt = try await history.perform(.capture(.init(
            representations: representations,
            origin: .init(sourceApplication: "first.app", lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_200_001)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            Issue.record("Expected image capture")
            return
        }
        let viewState = HistoryViewState(history: history)
        viewState.activate()
        defer { viewState.deactivate() }
        try #require(await pollUntil { viewState.rows.first?.copyCount == 1 })
        let loader = PreviewContentLoader(history: history)
        let hook: @Sendable () async -> Void = {
            do {
                _ = try await history.perform(.capture(.init(
                    representations: representations,
                    origin: .init(sourceApplication: "second.app", lineageHint: nil),
                    observedAt: Date(timeIntervalSinceReferenceDate: 700_200_002)
                )))
                try #require(await pollUntil { viewState.rows.first?.copyCount == 2 })
                await MainActor.run {
                    #expect(loader.phase == .loading)
                    #expect(PreviewFooterMetadata(item: item, row: viewState.rows.first)?.count == 2)
                }
            } catch { Issue.record(error) }
        }
        await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            await loader.load(item: item)
        }
        let metadata = try #require(PreviewFooterMetadata(item: item, row: viewState.rows.first))
        #expect(metadata.count == 2)
        #expect(metadata.lastSource == "second.app")
        #expect(loader.phase == .content(.image))
    }
#endif

    private func capture(
        _ text: String, at offset: Int, source: String, in history: SQLiteHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(.init(
            representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))],
            origin: .init(sourceApplication: source, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_200_000 + Double(offset))
        )))
        guard case .committed(let commit) = receipt else { throw HistoryFailure.persistence(.invariantViolation) }
        switch commit.outcome {
        case .inserted(let item), .coalesced(let item): return item
        default: throw HistoryFailure.persistence(.invariantViolation)
        }
    }
}
