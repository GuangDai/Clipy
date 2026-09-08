import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Filters narrow the retained corpus before pagination, regardless of matcher.
struct HistoryGlobalFilterTests {
    @Test(arguments: [HistoryBrowseKind.recent, .search(text: "", mode: .exact),
                      .search(text: "needle", mode: .exact),
                      .search(text: "needle", mode: .fuzzy),
                      .search(text: "needle", mode: .regexp)])
    func matchingRowsOutsideTheFirstWindowRemainReachable(kind: HistoryBrowseKind) async throws {
        let history = try await WSSupport.makeHistory()
        var links: [HistoryItemID] = []
        for index in 0..<8 {
            let item = try await capture(history, text: "needle link \(index)", index: index,
                                         extra: [("public.url", Array("https://example.com/\(index)".utf8))])
            links.append(item.id)
        }
        // More than three initial pages contain newer nonmatching items.
        for index in 8..<28 {
            _ = try await capture(history, text: "needle text \(index)", index: index)
        }
        _ = try await history.perform(.placePinned(links[2], at: .last))
        _ = try await history.perform(.placePinned(links[5], at: .last))
        let unfiltered = try await history.browse(.init(kind: kind, limit: 100))
        let expected = unfiltered.rows.filter { links.contains($0.item.id) }
        var pages: [HistoryPage] = []
        var cursor: HistoryPageCursor?
        repeat {
            let page = try await history.browse(.init(kind: kind, limit: 3, cursor: cursor,
                                                     filter: .init(type: .links)))
            pages.append(page)
            cursor = page.next
        } while cursor != nil && pages.count < 10
        #expect(pages.flatMap(\.rows) == expected)
        #expect(pages.count == 3)
        #expect(cursor == nil)
        var backward = try #require(pages.last)
        for index in stride(from: pages.count - 2, through: 0, by: -1) {
            backward = try await history.browse(.init(
                kind: kind, limit: 3, cursor: #require(backward.previous), filter: .init(type: .links)
            ))
            #expect(backward == pages[index])
        }
        #expect(backward.previous == nil)
        let pinned = try await history.browse(.init(kind: kind, limit: 3,
                                                   filter: .init(type: .links, pinnedOnly: true)))
        #expect(pinned.rows.map(\.item.id) == [links[2], links[5]])
        #expect(pinned.next == nil)
        let first = try #require(pages.first)
        let continuation = try #require(first.next)
        await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
            try await history.browse(.init(kind: kind, limit: 3, cursor: continuation,
                                           filter: .init(type: .text)))
        }
        await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
            try await history.browse(.init(kind: kind, limit: 3, cursor: continuation,
                                           filter: .init(type: .links, pinnedOnly: true)))
        }
    }

    @Test func familyUsesEffectiveContentAndImageLinkTextPriority() async throws {
        let history = try await WSSupport.makeHistory()
        let mixed = try await capture(history, text: "needle mixed", index: 0,
                                      extra: [("public.url", [1]), ("public.png", [2])])
        let opaque = try await capture(history, text: "needle unknown", index: 1,
                                       extra: [("public.png.custom", [3])])
        let image = try await history.browse(.init(kind: .recent, limit: 10, filter: .init(type: .images)))
        #expect(image.rows.map(\.item.id) == [mixed.id])
        let links = try await history.browse(.init(kind: .recent, limit: 10, filter: .init(type: .links)))
        #expect(links.rows.isEmpty)
        let text = try await history.browse(.init(kind: .recent, limit: 10, filter: .init(type: .text)))
        #expect(text.rows.map(\.item.id) == [opaque.id])

        _ = try await history.perform(.revise(RevisionRequest(
            itemID: mixed.id, expected: mixed.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                .init(typeIdentifier: "public.utf8-plain-text", action: .inheritCurrent),
                .init(typeIdentifier: "public.url", action: .inheritCurrent),
                .init(typeIdentifier: "public.png", action: .hide),
            ]))
        )))
        let revisedImages = try await history.browse(.init(kind: .recent, limit: 10, filter: .init(type: .images)))
        let revisedLinks = try await history.browse(.init(kind: .recent, limit: 10, filter: .init(type: .links)))
        #expect(revisedImages.rows.isEmpty)
        #expect(revisedLinks.rows.map(\.item.id) == [mixed.id])
        #expect(try await history.details(for: mixed.id).revisions.count == 1)
    }

    @Test func observationReplacesPinnedMembershipAfterUnpin() async throws {
        let history = try await WSSupport.makeHistory()
        let link = try await capture(history, text: "needle", index: 0, extra: [("public.url", [1])])
        _ = try await history.perform(.placePinned(link.id, at: .last))
        let stream = await history.observe(.init(kind: .recent, limit: 10,
                                                filter: .init(type: .links, pinnedOnly: true)))
        var iterator = stream.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.rows.map(\.item.id) == [link.id])
        _ = try await history.perform(.unpin(link.id))
        let changed = try #require(await iterator.next())
        #expect(changed.rows.isEmpty)
        #expect(changed.position > first.position)
    }

    private func capture(
        _ history: SQLiteHistory, text: String, index: Int,
        extra: [(typeIdentifier: String, bytes: [UInt8])] = []
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: 840_000_000 + Double(index)), extra: extra
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}
