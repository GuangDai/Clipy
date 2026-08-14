/// Step-7 read/observation/no-emission clause closure
/// (docs/roadmap/README.md §3, WS-clause phasing note): the DEFERRED
/// public-read / observation / no-emission clauses of WS9, WS10, WS13, WS14,
/// WS16, WS19, WS21. Each clause below exercises the now-implemented public
/// read/observation APIs (`browse`, `observe`, `details`, `pastePayload`)
/// against the real `SwiftDataHistory` facade and the real `HistoryAuthority`.
/// The commit/storage side of every gate was closed in steps 5–6; this file
/// closes the remaining step-7 side.
///
/// Per-clause citations (docs/06-cross-cutting.md §8):
///
/// - WS9: after the third capture retires the oldest inside the same History
///   Commit, `browse(.recent)` shows exactly the two survivors — the retired
///   ID is absent from the public read.
/// - WS10: "No partial page is observable" — register `observe(.recent)`
///   before `.clear(.unpinned)`; the replacement page after the clear commit
///   shows the complete post-clear state (all-or-nothing).
/// - WS13: after the injected transaction failure, a capture attempt that
///   fails produces no replacement page on an `observe` stream (no
///   invalidation for a failed commit, docs/04-coherence.md §4).
/// - WS14: after restart, `browse(.recent)` + `details` results equal the
///   pre-restart public results.
/// - WS16: after remove, the ID is absent from `browse` and
///   `details(for:)` / `pastePayload(for:)` throw `.notFound`.
/// - WS19: after the out-of-order coalesce, `browse` still shows one row, the
///   winner unchanged.
/// - WS21: after the retention policy commit, `browse` shows exactly the
///   policy-surviving rows.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WSReadClauseClosureBTests {

// MARK: - Helpers

/// Capture one text item through the facade; returns the inserted reference
/// or nil after recording an issue if the receipt is unexpected. Used across
/// multiple scenarios to keep arrange blocks concise (same stance as WS10's
/// `arrangeFourItemsTwoPinned`).
internal static func captureText(
    _ history: SwiftDataHistory,
    _ text: String,
    observedAt: Date,
    source: String,
    clause: String
) async -> HistoryItemReference? {
    let receipt: HistoryReceipt
    do {
        receipt = try await history.perform(.capture(
            WSSupport.textCapture(text, observedAt: observedAt, source: source)
        ))
    } catch {
        Issue.record("\(clause): capture threw \(error)")
        return nil
    }
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome else {
        Issue.record("\(clause): expected .committed(.inserted), got \(receipt)")
        return nil
    }
    return reference
}

// MARK: - WS9 (docs/06-cross-cutting.md §8, step-7 read clause)

/// WS9 (docs/06-cross-cutting.md §8): with maximum unpinned 2, after the third
/// capture retires the oldest inside the same History Commit, `browse(.recent)`
/// shows exactly the two survivors — items two and three — and the retired
/// item one's ID is absent from the public read
/// (docs/roadmap/README.md §3 WS-clause phasing note).
@Test func browseShowsTwoSurvivorsAfterThirdCaptureRetiresOldest() async throws {
    let storeURL = WSSupport.tempStoreURL("ws9-read-clause")
    defer { WSSupport.removeStore(storeURL) }
    // WS9: "Configure maximum unpinned count 2".
    let history = try await WSSupport.openHistory(storeURL: storeURL, maximumUnpinned: 2)

    // Three DISTINCT unpinned captures with strictly increasing observation
    // times: eviction order is `lastCopiedAt` ascending (docs/02-domain.md
    // §12), so item one is the oldest eligible victim once the policy is
    // exceeded.
    let source = "com.example.ws9r"
    guard let firstRef = await Self.captureText(
        history, "ws9 read one",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_500_000),
        source: source, clause: "WS9 arrange capture one"
    ) else { return }
    guard let secondRef = await Self.captureText(
        history, "ws9 read two",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_500_100),
        source: source, clause: "WS9 arrange capture two"
    ) else { return }
    guard let thirdRef = await Self.captureText(
        history, "ws9 read three",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_500_200),
        source: source, clause: "WS9 arrange capture three"
    ) else { return }

    // WS9: `browse(.recent)` shows exactly the two survivors — items two and
    // three — and item one is absent (docs/06-cross-cutting.md §8 WS9).
    let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
    let rowIDs = Set(page.rows.map { $0.item.id })
    // WS9: "leaving two unpinned items" — the retired ID is gone from the
    // public read.
    #expect(
        rowIDs == Set([secondRef.id, thirdRef.id]),
        "WS9: browse(.recent) shows exactly the two surviving items"
    )
    #expect(
        !rowIDs.contains(firstRef.id),
        "WS9: the retired oldest item is absent from browse"
    )
}

// MARK: - WS10 (docs/06-cross-cutting.md §8, step-7 observation clause)

/// WS10 (docs/06-cross-cutting.md §8): "No partial page is observable" —
/// register `observe(.recent)` before `.clear(.unpinned)`; the replacement
/// page after the clear commit shows the complete post-clear state
/// (all-or-nothing — never a page listing a proper subset of the cleared
/// items). The clear is an atomic History Commit (docs/02-domain.md §5.4),
/// so the invalidation it publishes fires only after the complete unpinned set
/// is retired, and the replacement page reflects that complete state
/// (docs/04-coherence.md §5).
@Test func observeReplacementPageAfterClearShowsCompletePostClearStateNeverPartial() async throws {
    let storeURL = WSSupport.tempStoreURL("ws10-read-clause")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: four DISTINCT text captures (commits 1–4), then pin items two
    // and four (commits 5–6) — interleaving pinned and unpinned items so the
    // clear must select by pin state.
    let source = "com.example.ws10r"
    let observedAts = (0..<4).map {
        Date(timeIntervalSinceReferenceDate: 700_510_000 + Double($0) * 100)
    }
    var refs: [HistoryItemReference] = []
    for index in 0..<4 {
        guard let ref = await Self.captureText(
            history, "ws10 read item \(index)",
            observedAt: observedAts[index],
            source: "\(source).\(index)",
            clause: "WS10 arrange capture \(index)"
        ) else { return }
        refs.append(ref)
    }
    // Pin the second and fourth items (indices 1 and 3).
    let pinnedIndices = [1, 3]
    for index in pinnedIndices {
        let pinReceipt = try await history.perform(.placePinned(refs[index].id, at: .last))
        guard case let .committed(commit) = pinReceipt,
              case let .placedPinned(placedID) = commit.outcome,
              placedID == refs[index].id else {
            Issue.record("WS10 arrange: expected .committed(.placedPinned) for item \(index), got \(pinReceipt)")
            return
        }
    }
    let pinnedIDs = Set(pinnedIndices.map { refs[$0].id })
    let unpinnedIDs = Set([0, 2].map { refs[$0].id })
    let allIDs = Set(refs.map(\.id))

    // Register the observer BEFORE the clear (docs/04-coherence.md §5 ordering:
    // subscribe-before-query). The clear is performed inside the loop AFTER the
    // first page arrives, so the first page is the pre-clear state and the
    // replacement page is the post-clear state — the ordering is deterministic.
    let stream = await history.observe(HistoryObservationRequest(kind: .recent, limit: 10))
    let observerTask = Task { () -> [HistoryPage] in
        var pages: [HistoryPage] = []
        var didClear = false
        for try await page in stream {
            pages.append(page)
            if !didClear {
                // WS10: after the first (pre-clear) page is received, perform
                // the clear — its invalidation produces the replacement page.
                didClear = true
                _ = try await history.perform(.clear(.unpinned))
            }
            // Stop when the post-clear state (only pinned survivors) is seen.
            let ids = Set(page.rows.map { $0.item.id })
            if ids == pinnedIDs { break }
        }
        return pages
    }
    defer { observerTask.cancel() }
    let pages = try await observerTask.value

    // WS10: "No partial page is observable" — every page is either the
    // complete pre-clear state (all four items) or the complete post-clear
    // state (exactly the pinned survivors), never a proper subset
    // (docs/06-cross-cutting.md §8 WS10; docs/02-domain.md §5.4).
    for page in pages {
        let ids = Set(page.rows.map { $0.item.id })
        #expect(
            ids == allIDs || ids == pinnedIDs,
            "WS10: no partial page — every page is complete pre-clear or complete post-clear (got \(ids))"
        )
    }

    // WS10: the replacement page after the clear contains exactly the pinned
    // survivors (docs/06-cross-cutting.md §8 WS10).
    let replacementPage = try #require(
        pages.last,
        "WS10: at least one page was collected"
    )
    let replacementIDs = Set(replacementPage.rows.map { $0.item.id })
    #expect(
        replacementIDs == pinnedIDs,
        "WS10: the replacement page contains exactly the pinned survivors"
    )
    #expect(
        replacementIDs.isDisjoint(with: unpinnedIDs),
        "WS10: no unpinned item survives in the post-clear page"
    )
}

// MARK: - WS13 (docs/06-cross-cutting.md §8, step-7 no-emission clause)

/// WS13 (docs/06-cross-cutting.md §8): after the injected transaction failure
/// on the facade's own Authority, a capture attempt that fails yields no
/// replacement page on an `observe` stream — the failed commit publishes no
/// invalidation (docs/04-coherence.md §4; docs/05-authority-kernel.md §10).
/// The proof is positional: the first page is at the setup position; the
/// replacement page (produced by a later SUCCESSFUL capture) jumps exactly one
/// position — the failed attempt advanced nothing and emitted no page between
/// them.
@Test func observeYieldsNoReplacementPageForFailedCaptureTransaction() async throws {
    let storeURL = WSSupport.tempStoreURL("ws13-read-clause")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: one capture committed at Change Position 1, establishing the
    // known state the observer's first page reflects.
    let source = "com.example.ws13r"
    guard (await Self.captureText(
        history, "ws13 read setup",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_520_000),
        source: source, clause: "WS13 arrange setup"
    )) != nil else { return }

    // Register the observer BEFORE the interference; the first page is the
    // setup state at position 1.
    let stream = await history.observe(HistoryObservationRequest(kind: .recent, limit: 10))
    let observerTask = Task { () -> [HistoryPage] in
        var pages: [HistoryPage] = []
        var didInterfere = false
        for try await page in stream {
            pages.append(page)
            if !didInterfere {
                // After the first page arrives: arm the WS13 injection on the
                // facade's own Authority (internal fields, accessible via
                // @testable), attempt the doomed capture, then commit a
                // successful capture whose invalidation produces the
                // replacement page the loop collects.
                didInterfere = true
                await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
                // WS13: the armed capture fails with .persistence(.transaction)
                // (docs/05-authority-kernel.md §16). The injection is one-shot
                // and auto-disarms, so the next capture succeeds.
                _ = try? await history.perform(.capture(
                    WSSupport.textCapture(
                        "ws13 read doomed",
                        observedAt: Date(timeIntervalSinceReferenceDate: 700_520_100),
                        source: source
                    )
                ))
                // Successful capture: the injection has auto-disarmed.
                _ = try await history.perform(.capture(
                    WSSupport.textCapture(
                        "ws13 read survivor",
                        observedAt: Date(timeIntervalSinceReferenceDate: 700_520_200),
                        source: source
                    )
                ))
            }
            // Stop after two pages: first (setup) + replacement (successful
            // capture's invalidation).
            if pages.count == 2 { break }
        }
        return pages
    }
    defer { observerTask.cancel() }
    let pages = try await observerTask.value

    // WS13: exactly two pages — the first (setup state at position 1) and the
    // replacement (successful capture at position 2). No page exists between
    // them for the failed attempt (docs/04-coherence.md §4: no invalidation
    // for a failed commit).
    #expect(
        pages.count == 2,
        "WS13: exactly two pages — no replacement page for the failed capture"
    )
    // WS13: the position gap from 1 to 2 proves exactly ONE commit happened
    // between the two pages (the successful capture); the failed attempt
    // advanced nothing (docs/05-authority-kernel.md §10).
    let positions = pages.map(\.position.rawValue)
    #expect(
        positions == [1, 2],
        "WS13: positions [1, 2] — the failed capture did not advance the position"
    )
}
}
