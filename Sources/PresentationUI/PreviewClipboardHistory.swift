/// PreviewClipboardHistory.swift — the scripted `ClipboardHistory` double for
/// SwiftUI previews ONLY (docs/01-architecture.md §4; docs/
/// 03a-instruction-set.md §3; roadmap 05).
///
/// It exists so previews and view-development need no store. It is NOT a
/// second storage implementation and must never substitute for storage
/// semantic tests (docs/01-architecture.md §4). DTOs are constructed through
/// their `package` initializers, which this SwiftPM package target can reach.
///
/// The dataset is fully deterministic — fixed UUIDs and timestamps, no clock
/// or ID-source reads — so preview screenshots and view tests are stable.
import Foundation
import HistoryCore

/// Scripted preview adapter: one canned first page, or none.
///
/// Behavior: `browse` returns the scripted page (`next: nil`); `observe`
/// yields that page once and finishes; `perform` is always `.unchanged`;
/// `details` and `pastePayload` throw `.notFound`; `thumbnail` returns
/// `nil`; `retentionConfiguration` returns the new-store defaults.
package struct PreviewClipboardHistory: ClipboardHistory, Sendable {

    /// 2 pinned + 8 recent rows — realistic titles, types, timestamps,
    /// sources, and copy counts; one row carries a `SearchPresentation`
    /// with a snippet and matched ranges (docs/03b-instruction-set.md §8).
    package static var populated: PreviewClipboardHistory {
        PreviewClipboardHistory(page: Self.populatedPage)
    }

    /// No retained items at all.
    package static var empty: PreviewClipboardHistory {
        PreviewClipboardHistory(page: nil)
    }

    /// The scripted first page; `nil` models an empty history.
    private let page: HistoryPage?

    private init(page: HistoryPage?) {
        self.page = page
    }

    // MARK: - ClipboardHistory

    package func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        .unchanged
    }

    package func browse(
        _ request: HistoryBrowseRequest
    ) async throws -> HistoryPage {
        page ?? HistoryPage(position: ChangePosition.zero, rows: [], next: nil)
    }

    package func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        AsyncThrowingStream { continuation in
            if let page {
                continuation.yield(page)
            }
            continuation.finish()
        }
    }

    package func details(
        for id: HistoryItemID
    ) async throws -> HistoryDetails {
        throw HistoryFailure.notFound(id)
    }

    package func pastePayload(
        for id: HistoryItemID
    ) async throws -> PastePayload {
        throw HistoryFailure.notFound(id)
    }

    package func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        nil
    }

    package func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        // Previews show the new-store defaults: the Part VI default count
        // (06 §2) and every V2-02 dimension disabled (`V2-02` §3.3).
        HistoryRetentionConfiguration(
            maximumUnpinnedItems: HistoryLimits.standard.defaultMaximumUnpinnedItems,
            policies: HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil)
        )
    }

    // MARK: - Canned dataset (fixed literals; no clock or ID source)

    /// Anchor timestamp 2026-08-18 09:41:00 UTC; every row's
    /// `lastCopiedAt` is a fixed offset from it.
    private static let anchor = Date(timeIntervalSince1970: 1_787_046_060)

    /// Parses a fixed UUID literal into a `HistoryItemID`. The force unwrap
    /// cannot fail for a well-formed literal; a malformed one is a fixture
    /// authoring bug that must fail loudly at first preview render, not
    /// silently produce a broken dataset.
    private static func id(_ rawValue: String) -> HistoryItemID {
        HistoryItemID(rawValue: UUID(uuidString: rawValue)!)
    }

    /// One canned row at a fixed reference and Content Version.
    private static func row(
        id rawValue: String,
        version: UInt64,
        title: String,
        typeIdentifiers: [String],
        copiedAt: Date,
        copyCount: UInt64,
        source: String?,
        pinned: Int? = nil,
        search: SearchPresentation? = nil
    ) -> HistoryRow {
        HistoryRow(
            item: HistoryItemReference(
                id: id(rawValue),
                contentVersion: ContentVersion(rawValue: version)
            ),
            title: title,
            typeIdentifiers: typeIdentifiers,
            lastCopiedAt: copiedAt,
            copyCount: copyCount,
            lastSource: source,
            pinnedPosition: pinned,
            search: search
        )
    }

    /// UTF-16 range of `needle` in `haystack`, matching the offset space of
    /// `SearchPresentation.matchedRanges` (docs/03b-instruction-set.md §8).
    /// Fixed ASCII snippets make this deterministic.
    private static func utf16Range(
        of needle: String,
        in haystack: String
    ) -> UTF16TextRange? {
        let nsRange = (haystack as NSString).range(of: needle)
        guard nsRange.location != NSNotFound else { return nil }
        return UTF16TextRange(location: nsRange.location, length: nsRange.length)
    }

    /// The canned page: pinned lane first (0-based `pinnedPosition`),
    /// then recent rows by descending `lastCopiedAt` — the same order the
    /// storage read path produces (docs/03b-instruction-set.md §8; docs/
    /// 04-coherence.md §7). `next` is nil: previews show one page.
    private static let populatedPage: HistoryPage = {
        // One row carries search presentation evidence: a bounded body
        // excerpt plus two UTF-16 matched ranges inside it.
        let snippet =
            "…repeated copies of equal content coalesce into one retained "
            + "item with a higher copy count…"
        let matchedRanges = [
            utf16Range(of: "coalesce", in: snippet),
            utf16Range(of: "retained item", in: snippet),
        ].compactMap { $0 }

        let pinnedLane: [HistoryRow] = [
            row(
                id: "6B1F4C8E-9D2A-4A55-9A0F-2E7C01D3B4A1",
                version: 1,
                title: "Clipy step-9 wiring contract",
                typeIdentifiers: ["public.utf8-plain-text"],
                copiedAt: anchor.addingTimeInterval(-60),
                copyCount: 12,
                source: "com.apple.Notes",
                pinned: 0
            ),
            row(
                id: "0F5D2B77-31C4-4E88-B0A9-8C2D6E1F3A55",
                version: 2,
                title: "https://github.com/clipy/clipy",
                typeIdentifiers: ["public.url", "public.utf8-plain-text"],
                copiedAt: anchor.addingTimeInterval(-3_600),
                copyCount: 4,
                source: "com.apple.Safari",
                pinned: 1
            ),
        ]

        let recentLane: [HistoryRow] = [
            row(
                id: "9A3C5E11-7B44-4D09-8E6B-1F0A2C4D6E80",
                version: 2,
                title: "Repeated copies coalesce",
                typeIdentifiers: ["public.utf8-plain-text"],
                copiedAt: anchor.addingTimeInterval(-75),
                copyCount: 7,
                source: "com.apple.Notes",
                search: SearchPresentation(
                    snippet: snippet,
                    matchedRanges: matchedRanges
                )
            ),
            row(
                id: "3E7A9C22-5D16-4F3A-A8B4-9C1E2D3F4A06",
                version: 1,
                title: "Screenshot 2026-08-18 at 09.41.12.png",
                typeIdentifiers: ["public.png"],
                copiedAt: anchor.addingTimeInterval(-120),
                copyCount: 1,
                source: "com.apple.finder"
            ),
            row(
                id: "7C2E4F60-8A13-4B7D-9E5C-3D6F1A2B4C89",
                version: 1,
                title: "brew install xcbeautify swiftlint",
                typeIdentifiers: ["public.utf8-plain-text"],
                copiedAt: anchor.addingTimeInterval(-1_800),
                copyCount: 2,
                source: "com.apple.Terminal"
            ),
            row(
                id: "1D8B3F94-2C67-4E51-B3D9-7A4C5E6F7082",
                version: 1,
                title: "Q3 roadmap review — action items",
                typeIdentifiers: ["public.utf8-plain-text"],
                copiedAt: anchor.addingTimeInterval(-5_400),
                copyCount: 1,
                source: "com.tinyspeck.slackmacgap"
            ),
            row(
                id: "5A0D7E83-9F21-4C68-8D7B-2E9F1A3C5E74",
                version: 3,
                title: "Meeting notes 2026-08-17.rtf",
                typeIdentifiers: ["public.rtf", "public.utf8-plain-text"],
                copiedAt: anchor.addingTimeInterval(-43_200),
                copyCount: 3,
                source: "com.microsoft.VSCode"
            ),
            row(
                id: "8F4A1D36-7B95-4E20-A1C8-6D3F7E9B2C58",
                version: 1,
                title: "john.appleseed@example.com",
                typeIdentifiers: ["public.utf8-plain-text"],
                copiedAt: anchor.addingTimeInterval(-90_000),
                copyCount: 5,
                source: "com.apple.mail"
            ),
            row(
                id: "2B6C9F41-8E37-4A5D-B7E0-1C8A3F5D79E6",
                version: 1,
                title: "invoice-2026-08.pdf",
                typeIdentifiers: ["com.adobe.pdf"],
                copiedAt: anchor.addingTimeInterval(-172_800),
                copyCount: 1,
                source: "com.google.Chrome"
            ),
            row(
                id: "E3F1A5D9-6C42-4B98-9D2E-8B7C5A3F1E40",
                version: 1,
                title: "let limits = HistoryLimits.standard",
                typeIdentifiers: ["public.utf8-plain-text"],
                copiedAt: anchor.addingTimeInterval(-518_400),
                copyCount: 9,
                source: "com.apple.finder"
            ),
        ]

        return HistoryPage(
            position: ChangePosition(rawValue: 42),
            rows: pinnedLane + recentLane,
            next: nil
        )
    }()
}
