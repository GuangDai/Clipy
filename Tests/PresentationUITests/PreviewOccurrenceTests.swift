import ContentPreview
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

@MainActor
struct PreviewOccurrenceTests {
    @Test func coalescedObservationUpdatesMetadataWithoutReloadingContent() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let item = try await capture("preview content", at: 1, source: "first.app", in: history)
        let viewState = HistoryViewState(history: history)
        viewState.activate()
        defer { viewState.deactivate() }
        try #require(await pollUntil { viewState.rows.first?.copyCount == 1 })
        let oldRow = try #require(viewState.rows.first)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        let loaded = try #require(loader.occurrence)
        #expect(loaded.count == 1)
        #expect(loader.phase == .content(.text("preview content")))

        let coalesced = try await capture("preview content", at: 2, source: "second.app", in: history)
        #expect(coalesced == item, "coalescing keeps the exact content-load key")
        try #require(await pollUntil { viewState.rows.first?.copyCount == 2 })
        let observed = try #require(viewState.rows.first)
        loader.updateOccurrence(from: observed)
        let displayed = try #require(loader.displayedOccurrence(for: item))
        #expect(displayed.count == 2)
        #expect(displayed.lastCopiedAt == Date(timeIntervalSinceReferenceDate: 700_200_002))
        #expect(displayed.lastSource == "second.app")
        #expect(displayed.firstCopiedAt == loaded.firstCopiedAt)
        #expect(displayed.firstSource == "first.app")
        // Query restart clears rows while Quick Look retains its exact target.
        // Neither that gap nor an older observation can undo accepted metadata.
        viewState.refresh()
        #expect(viewState.rows.isEmpty)
        loader.updateOccurrence(from: viewState.rows.first)
        #expect(loader.displayedOccurrence(for: item) == displayed)
        loader.updateOccurrence(from: oldRow)
        #expect(loader.displayedOccurrence(for: item) == displayed)
        // Only one content load was issued; accepted occurrence state changes
        // independently of the content reference and renderer publication.
        #expect(loader.occurrence == displayed)
        #expect(loader.requestedItem == item)
        #expect(loader.phase == .content(.text("preview content")))
    }

    @Test func staleOrUnrelatedRowsCannotReplaceTheLoadedOccurrence() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let item = try await capture("original", at: 1, source: "first.app", in: history)
        let oldPage = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        let oldRow = try #require(oldPage.rows.first)
        #expect(try await capture("original", at: 2, source: "second.app", in: history) == item)
        let equalPage = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        let equalRow = try #require(equalPage.rows.first)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        let loaded = try #require(loader.occurrence)
        #expect(loaded.count == 2)
        for row in [oldRow, equalRow, nil] {
            loader.updateOccurrence(from: row)
            #expect(loader.displayedOccurrence(for: item) == loaded)
        }

        #expect(try await capture("original", at: 3, source: "third.app", in: history) == item)
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data("revised".utf8))
            )]))
        )))
        guard case .committed(let commit) = receipt,
              case .revised(let revised) = commit.outcome else {
            Issue.record("expected a content revision")
            return
        }
        let other = try await capture("other item", at: 4, source: "other.app", in: history)
        for offset in 5...6 {
            #expect(try await capture("other item", at: offset, source: "other.app", in: history) == other)
        }
        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        let revisedRow = try #require(page.rows.first { $0.item == revised })
        let otherRow = try #require(page.rows.first { $0.item == other })
        #expect(revisedRow.copyCount == 3 && otherRow.copyCount == 3)
        loader.updateOccurrence(from: revisedRow)
        #expect(loader.displayedOccurrence(for: item) == loaded)
        loader.updateOccurrence(from: otherRow)
        #expect(loader.displayedOccurrence(for: item) == loaded)
        #expect(loader.displayedOccurrence(for: revised) == nil)
        #expect(loader.displayedOccurrence(for: other) == nil)
        #expect(loader.displayedOccurrence(for: nil) == nil)
        loader.clear()
        loader.updateOccurrence(from: equalRow)
        #expect(loader.displayedOccurrence(for: item) == nil)
    }

    #if DEBUG
    @Test func observationBeforeLoadCompletionIsAcceptedAfterPublication() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let representations = [CapturedRepresentation(
            typeIdentifier: "public.png", bytes: fixturePNGData
        )]
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: representations,
            origin: CopyOriginObservation(sourceApplication: "first.app", lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_200_001)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let item) = commit.outcome else {
            Issue.record("expected an image capture")
            return
        }
        let viewState = HistoryViewState(history: history)
        viewState.activate()
        defer { viewState.deactivate() }
        try #require(await pollUntil { viewState.rows.first?.copyCount == 1 })
        let loader = PreviewContentLoader(history: history)
        // The existing native-render hook runs after details were read but
        // before the loader publishes their occurrence. Real coalescing and
        // observation complete here, without another History implementation.
        let hook: @Sendable () async -> Void = {
            do {
                let coalesced = try await history.perform(.capture(ClipboardCapture(
                    representations: representations,
                    origin: CopyOriginObservation(sourceApplication: "second.app", lineageHint: nil),
                    observedAt: Date(timeIntervalSinceReferenceDate: 700_200_002)
                )))
                guard case .committed(let update) = coalesced,
                      case .coalesced(let sameItem) = update.outcome else {
                    Issue.record("expected the image to coalesce during rendering")
                    return
                }
                #expect(sameItem == item)
                try #require(await pollUntil { viewState.rows.first?.copyCount == 2 })
                await MainActor.run {
                    #expect(loader.phase == .loading)
                    loader.updateOccurrence(from: viewState.rows.first)
                    #expect(loader.occurrence == nil, "loading cannot publish partial metadata")
                }
            } catch {
                Issue.record("coalescing during the real preview load failed: \(error)")
            }
        }
        await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            await loader.load(item: item)
            #expect(loader.occurrence?.count == 1)
            // The view-owned task performs this second acceptance after its
            // await, even though the observed row no longer changes again.
            loader.updateOccurrence(from: viewState.rows.first)
        }
        let displayed = try #require(loader.displayedOccurrence(for: item))
        #expect(displayed.count == 2)
        #expect(displayed.lastSource == "second.app")
        #expect(displayed.firstSource == "first.app")
        #expect(loader.phase == .content(.image))
        #expect(loader.requestedItem == item)
    }
    #endif

    private func capture(
        _ text: String, at offset: Int, source: String, in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8)
            )],
            origin: CopyOriginObservation(sourceApplication: source, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_200_000 + Double(offset))
        )))
        guard case .committed(let commit) = receipt else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        switch commit.outcome {
        case .inserted(let item), .coalesced(let item): return item
        default: throw HistoryFailure.persistence(.invariantViolation)
        }
    }
}
