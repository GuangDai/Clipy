#if DEBUG
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct FuzzyEarlyCompletionTests {
    @Test func fullZeroScoreWindowCannotBeImprovedByLaterTies() {
        var selection = makeSelection()
        selection.insert(hit(0, score: 0.5))
        selection.insert(hit(1, score: 0))
        #expect(!selection.cannotBeImprovedByLaterDefaultOrderedRows())
        selection.insert(hit(2, score: 0))
        // Full heap alone is insufficient: the worse initial result can
        // still be replaced by another zero-score match farther down.
        #expect(!selection.cannotBeImprovedByLaterDefaultOrderedRows())
        selection.insert(hit(3, score: 0))
        #expect(selection.cannotBeImprovedByLaterDefaultOrderedRows())
        let completed = selection.evaluatedRows().map(\.corpusRow.id)
        for index in 4..<100 { selection.insert(hit(index, score: 0)) }
        #expect(selection.evaluatedRows().map(\.corpusRow.id) == completed)
        #expect(completed == [hit(1, score: 0), hit(2, score: 0), hit(3, score: 0)].map(\.corpusRow.id))
    }

    @Test func aLaterLowerScoreStillReplacesAnApparentlyCompletePage() {
        var selection = makeSelection()
        for index in 0..<3 { selection.insert(hit(index, score: 0.2)) }
        #expect(!selection.cannotBeImprovedByLaterDefaultOrderedRows())
        selection.insert(hit(3, score: 0))
        selection.insert(hit(4, score: 0.1))
        #expect(!selection.cannotBeImprovedByLaterDefaultOrderedRows())
        #expect(selection.evaluatedRows().map(\.corpusRow.id)
                == [hit(3, score: 0), hit(4, score: 0.1), hit(0, score: 0.2)].map(\.corpusRow.id))
    }

    @Test func provenNonzeroMinimumAllowsOnlyTheCorrespondingScoreWindow() {
        var selection = makeSelection()
        for index in 0..<3 { selection.insert(hit(index, score: 0.2)) }
        #expect(!selection.cannotBeImprovedByLaterDefaultOrderedRows(lowestPossibleScore: 0.1))
        for index in 3..<6 { selection.insert(hit(index, score: 0.1)) }
        #expect(selection.cannotBeImprovedByLaterDefaultOrderedRows(lowestPossibleScore: 0.1))
        #expect(!selection.cannotBeImprovedByLaterDefaultOrderedRows())
        let completed = selection.evaluatedRows().map(\.corpusRow.id)
        for index in 6..<100 { selection.insert(hit(index, score: 0.1)) }
        #expect(selection.evaluatedRows().map(\.corpusRow.id) == completed)
    }

    @Test func pinnedWindowUsesPinOrderAndMustIncludeLookahead() {
        var selection = makeSelection()
        for index in 0..<2 { selection.insert(hit(index, score: 0.7, pin: index)) }
        #expect(!selection.cannotBeImprovedByLaterDefaultOrderedRows())
        selection.insert(hit(2, score: 0.7, pin: 2))
        #expect(selection.cannotBeImprovedByLaterDefaultOrderedRows())
        let completed = selection.evaluatedRows().map(\.corpusRow.id)
        selection.insert(hit(3, score: 0, pin: 3))
        selection.insert(hit(4, score: 0))
        #expect(selection.evaluatedRows().map(\.corpusRow.id) == completed)
    }

    @Test func missingCursorAnchorCannotBeHiddenByAFullOptimalWindow() {
        let anchoredHit = hit(10, score: 0)
        let anchor = StoredOrderingAnchor.fuzzyUnpinned(
            score: 0, lastCopiedAt: anchoredHit.corpusRow.lastCopiedAt, id: anchoredHit.corpusRow.id
        )
        var missing = makeSelection(anchor: anchor)
        var confirmed = makeSelection(anchor: anchor)
        for index in 0..<15 {
            if index != 10 { missing.insert(hit(index, score: 0)) }
            confirmed.insert(hit(index, score: 0))
        }
        #expect(!missing.cannotBeImprovedByLaterDefaultOrderedRows())
        #expect(missing.evaluatedRows().isEmpty)
        #expect(confirmed.cannotBeImprovedByLaterDefaultOrderedRows())
    }

    @Test func backwardSelectionStillNeedsLaterDefaultOrderedRows() {
        let anchoredHit = hit(10, score: 0)
        let anchor = StoredOrderingAnchor.fuzzyUnpinned(
            score: 0, lastCopiedAt: anchoredHit.corpusRow.lastCopiedAt, id: anchoredHit.corpusRow.id
        )
        var selection = makeSelection(anchor: anchor, direction: .backward)
        for index in 0...10 { selection.insert(hit(index, score: 0)) }
        #expect(!selection.cannotBeImprovedByLaterDefaultOrderedRows())
    }

    private func makeSelection(
        anchor: StoredOrderingAnchor? = nil, direction: HistoryPageDirection = .forward
    ) -> SearchWorker.FuzzyPageSelection {
        SearchWorker.FuzzyPageSelection(directive: .init(
            continuationAnchor: anchor, maximumSurvivors: 3, direction: direction
        ))
    }

    private func hit(_ index: Int, score: Double, pin: Int? = nil) -> SearchWorker.FuzzyHit {
        let title = "item \(index)"
        let row = SearchCorpusRow(
            id: HistoryItemID(rawValue: UUID(uuidString:
                "00000000-0000-0000-0000-" + String(format: "%012d", index))!),
            contentVersion: .initial, title: title, searchBody: "",
            debugTitleUTF8Bytes: title.utf8.count, debugSearchBodyUTF8Bytes: 0,
            typeIdentifiers: ["public.utf8-plain-text"],
            // Adjacent rows also exercise the UUID tie break at equal dates.
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: Double(1_000 - index / 2)),
            copyCount: 1, lastSource: nil, pinOrdinal: pin.map { PinOrdinal(rawValue: $0) }
        )
        return SearchWorker.FuzzyHit(corpusRow: row, score: score, search: .titleRanges([0..<1]))
    }
}
#endif
