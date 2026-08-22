/// PreviewClipboardHistoryTests — the scripted preview adapter's frozen
/// behavior (docs/01-architecture.md §4; docs/03a-instruction-set.md §3;
/// docs/roadmap/05-presentationui.md): `browse` returns the canned page
/// (`next: nil`), `observe` yields that page exactly once and finishes,
/// `perform` answers `.unchanged`, `details`/`pastePayload` throw
/// `.notFound`, and `thumbnail` returns `nil`. The dataset itself is pinned:
/// 2 pinned + 8 recent rows with deterministic IDs and timestamps, one row
/// carrying search presentation evidence (docs/03b-instruction-set.md §8).
import Foundation
import HistoryCore
import PresentationUI
import Testing

struct PreviewClipboardHistoryTests {

    // MARK: - Fixtures

    private var browseRequest: HistoryBrowseRequest {
        HistoryBrowseRequest(kind: .recent, limit: 50)
    }

    private var observationRequest: HistoryObservationRequest {
        HistoryObservationRequest(kind: .recent, limit: 50)
    }

    // MARK: - Canned dataset

    /// The populated variant browses ten rows — the pinned lane first with
    /// 0-based ordinals 0 and 1, then eight recent rows — and exactly one
    /// row carries a `SearchPresentation` with a snippet and two matched
    /// ranges (docs/03b-instruction-set.md §8).
    @Test func browseReturnsTheCannedPopulatedPage() async throws {
        let page = try await PreviewClipboardHistory.populated.browse(browseRequest)

        #expect(page.next == nil)
        #expect(page.rows.count == 10)

        let pinned = page.rows.filter { $0.pinnedPosition != nil }
        #expect(pinned.count == 2)
        #expect(pinned.map(\.pinnedPosition) == [0, 1])

        let searchRows = page.rows.filter { $0.search != nil }
        #expect(searchRows.count == 1)
        #expect(searchRows.first?.search?.snippet != nil)
        #expect(searchRows.first?.search?.matchedRanges.count == 2)
    }

    /// The empty variant models no retained items at all.
    @Test func browseOnEmptyVariantReturnsNoRows() async throws {
        let page = try await PreviewClipboardHistory.empty.browse(browseRequest)

        #expect(page.rows.isEmpty)
        #expect(page.next == nil)
    }

    /// The dataset is deterministic across instances (fixed UUIDs and
    /// timestamps — no clock or ID-source reads), so preview rendering and
    /// view tests are stable.
    @Test func populatedDatasetIsDeterministicAcrossInstances() async throws {
        let first = try await PreviewClipboardHistory.populated.browse(browseRequest)
        let second = try await PreviewClipboardHistory.populated.browse(browseRequest)
        #expect(first.rows == second.rows)
    }

    // MARK: - Observe yields once

    /// `observe` streams the canned page exactly once, then finishes — the
    /// same page `browse` returns (snapshot replacement discipline,
    /// docs/04-coherence.md §5, holds trivially for one page).
    @Test func observeYieldsTheCannedPageOnceThenFinishes() async throws {
        let history = PreviewClipboardHistory.populated
        let browsed = try await history.browse(browseRequest)

        let stream = await history.observe(observationRequest)
        var observed: [HistoryPage] = []
        for try await page in stream {
            observed.append(page)
        }

        #expect(observed.count == 1)
        #expect(observed.first == browsed)
    }

    /// The empty variant's stream finishes without yielding.
    @Test func observeOnEmptyVariantYieldsNothing() async throws {
        let stream = await PreviewClipboardHistory.empty.observe(observationRequest)
        var observed: [HistoryPage] = []
        for try await page in stream {
            observed.append(page)
        }
        #expect(observed.isEmpty)
    }

    // MARK: - Frozen method behavior

    /// `perform` always answers `.unchanged` — previews never mutate.
    @Test func performAlwaysAnswersUnchanged() async throws {
        let target = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
        )
        let receipt = try await PreviewClipboardHistory.populated.perform(.unpin(target))
        guard case .unchanged = receipt else {
            Issue.record("expected .unchanged, got \(receipt)")
            return
        }
    }

    /// `details` and `pastePayload` throw `.notFound` for any ID — the
    /// preview adapter scripts no content lineage.
    @Test func detailsAndPastePayloadThrowNotFound() async throws {
        let id = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
        )
        await #expect(throws: HistoryFailure.notFound(id)) {
            try await PreviewClipboardHistory.populated.details(for: id)
        }
        await #expect(throws: HistoryFailure.notFound(id)) {
            try await PreviewClipboardHistory.populated.pastePayload(for: id)
        }
    }

    /// `thumbnail` answers `nil` — the preview adapter scripts no pixels.
    @Test func thumbnailAnswersNil() async throws {
        let item = HistoryItemReference(
            id: HistoryItemID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!
            ),
            contentVersion: ContentVersion(rawValue: 1)
        )
        let payload = try await PreviewClipboardHistory.populated.thumbnail(
            for: item,
            pixels: PixelSize(width: 72, height: 72)
        )
        #expect(payload == nil)
    }
}
