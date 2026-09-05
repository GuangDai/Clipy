/// Visible counts follow client filtering and disclose remaining pages.
import Foundation
import HistoryCore
import Testing
@testable import PresentationUI

@MainActor
struct HistoryCountPresentationTests {
    private func bundle(_ language: String) throws -> Bundle {
        let localization = try #require(HistoryCountCopy.bundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(HistoryCountCopy.bundle.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
    }

    @Test(arguments: [0, 1, 2, 5_000], [false, true])
    func realTranslationsAndPlurals(count: Int, hasNextPage: Bool) throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        let locale = Locale(identifier: "en_US")
        let digits = count == 5_000 ? "5,000" : String(count)
        let displayed = digits + (hasNextPage ? "+" : "")
        let item = count == 1 && !hasNextPage ? "item" : "items"
        let result = count == 1 && !hasNextPage ? "result" : "results"
        #expect(HistoryCountCopy.items(
            count: count, hasNextPage: hasNextPage, locale: locale, bundle: english
        ) == "\(displayed) \(item)")
        #expect(HistoryCountCopy.results(
            count: count, hasNextPage: hasNextPage, locale: locale, bundle: english
        ) == "\(displayed) \(result)")
        #expect(HistoryCountCopy.items(
            count: count, hasNextPage: hasNextPage, locale: locale, bundle: chinese
        ) == "\(displayed) 个项目")
        #expect(HistoryCountCopy.results(
            count: count, hasNextPage: hasNextPage, locale: locale, bundle: chinese
        ) == "\(displayed) 个结果")
    }

    @Test func numericRegionIsIndependentOfTheTranslatedNouns() throws {
        let chinese = try bundle("zh-Hans")
        #expect(HistoryCountCopy.items(
            count: 5_000, hasNextPage: false,
            locale: Locale(identifier: "de_DE"), bundle: chinese
        ) == "5.000 个项目")
        #expect(HistoryCountCopy.results(
            count: 5_000, hasNextPage: true,
            locale: Locale(identifier: "de_DE"), bundle: chinese
        ) == "5.000+ 个结果")
    }

    @Test(arguments: [false, true])
    func captionsCountDisplayedRowsAndPreserveCursorUncertainty(hasNextPage: Bool) async throws {
        let rows = [
            row(1, type: "public.utf8-plain-text", pinned: 0),
            row(2, type: "public.png", pinned: 1),
            row(3, type: "public.utf8-plain-text"),
            row(4, type: "public.png"),
        ]
        let history = ScriptedHistory(observedFirstPage: fixturePage(
            rows: rows, next: hasNextPage ? "remaining" : nil
        ))
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        let english = try bundle("en")
        let suffix = hasNextPage ? "+" : ""
        expectCaptions(state, items: "4\(suffix) items", results: "4\(suffix) results", bundle: english)

        state.typeFilter = .text
        #expect(state.rows.count == 4)
        expectCaptions(state, items: "2\(suffix) items", results: "2\(suffix) results", bundle: english)

        state.showsPinnedOnly = true
        expectCaptions(
            state, items: hasNextPage ? "1+ items" : "1 item",
            results: hasNextPage ? "1+ results" : "1 result", bundle: english
        )

        state.typeFilter = .links
        expectCaptions(state, items: "0\(suffix) items", results: "0\(suffix) results", bundle: english)
        #expect(state.hasNextPage == hasNextPage)

        state.typeFilter = .all
        state.showsPinnedOnly = false
        expectCaptions(state, items: "4\(suffix) items", results: "4\(suffix) results", bundle: english)
        await history.finishObservation()
    }

    private func expectCaptions(
        _ state: HistoryViewState, items: String, results: String, bundle: Bundle
    ) {
        let locale = Locale(identifier: "en_US")
        #expect(HistoryPanelView.itemCountText(for: state, locale: locale, bundle: bundle) == items)
        #expect(SearchHeaderView.resultCountText(for: state, locale: locale, bundle: bundle) == results)
    }

    private func row(_ index: Int, type: String, pinned: Int? = nil) -> HistoryRow {
        HistoryRow(
            item: HistoryItemReference(
                id: HistoryItemID(rawValue: UUID(uuidString:
                    "00000000-0000-0000-0000-" + String(format: "%012d", index)
                )!), contentVersion: .initial
            ),
            title: "row \(index)", typeIdentifiers: [type],
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            copyCount: 1, lastSource: nil, pinnedPosition: pinned, search: nil
        )
    }
}
