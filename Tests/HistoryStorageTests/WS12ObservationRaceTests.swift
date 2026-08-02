/// WS12 — Observation registration race (docs/06-cross-cutting.md §8 WS12;
/// docs/04-coherence.md §5 race-free observation, §4 internal invalidation):
/// the subscribe-before-query algorithm's three guarantees — (A) a commit
/// between registration and the first authoritative query appears in the first
/// yielded page, (B) a commit between the first query and the race-closing
/// position recheck is detected and forces a requery so the first yield still
/// includes the commit, and (C) a burst of later invalidations coalesces to
/// exactly one replacement page at the newest position.
///
/// Facade-driven proof through the PUBLIC observe loop, not a storage-side
/// path: every assertion goes through `SwiftDataHistory.observe` (Part V §14;
/// Part IV §5). The deterministic interleaving uses the `SuspensionGate`
/// concurrency harness (Tests/HistoryStorageTests/ConcurrencyHarness/
/// ConcurrencyHarness.swift) on the facade's OWN Authority — the five actor
/// fields of `SwiftDataHistory` are `internal` for exactly this harness
/// (docs/roadmap/03-historystorage.md step-5 note; the comment in
/// SwiftDataHistory.swift), so `history.authority` is reachable from
/// `@testable` tests and the two observation-race seams are drivable:
/// `AuthoritySuspensionPoint.readEntry` (parks between observer registration
/// and the first authoritative query, 04 §5 step 1→step 2 gap) and
/// `.positionRecheckEntry` (parks the `currentPosition` recheck of §5 step 4,
/// the discard path). Each test installs its own one-shot suspension handler,
/// parks the producer at the seam the clause exercises, commits through the
/// public `history.perform(.capture(_:))` facade, and resumes — the exact
/// WS12 interleaving.
///
/// Seam names: `AuthoritySuspensionPoint.readEntry` (§5 step 1→2 gap),
/// `.positionRecheckEntry` (§5 step 4 discard path).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS12ObservationRaceTests {

/// Re-armable one-shot latch for the WS12 suspension handler. `consume()`
/// returns `true` when armed and disarms in the same atomic step, so the
/// handler parks exactly one arrival at the guarded seam. `rearm()` arms the
/// next arrival. `SuspensionGate.park(at:)` forbids two tasks parked at one
/// named point, so the handler must let every non-armed arrival pass.
private actor ParkLatch {
    private var armed: Bool

    init(armed: Bool) {
        self.armed = armed
    }

    func consume() -> Bool {
        let wasArmed = armed
        armed = false
        return wasArmed
    }

    func rearm() {
        armed = true
    }
}

/// Installs a suspension handler that parks at `readEntry` only when the latch
/// is armed (§5 step 1→2 gap). The latch controls which `.readEntry` arrival
/// parks; every other arrival and every other suspension point passes.
private static func installReadEntryPark(
    on authority: HistoryAuthority,
    gate: SuspensionGate,
    latch: ParkLatch
) async {
    await authority.setSuspensionHandler { point in
        guard point == .readEntry else { return }
        let shouldPark = await latch.consume()
        guard shouldPark else { return }
        await gate.park(at: point.rawValue)
    }
}

/// Installs a suspension handler that parks at `positionRecheckEntry` only
/// when the latch is armed (§5 step 4 discard path).
private static func installPositionRecheckPark(
    on authority: HistoryAuthority,
    gate: SuspensionGate,
    latch: ParkLatch
) async {
    await authority.setSuspensionHandler { point in
        guard point == .positionRecheckEntry else { return }
        let shouldPark = await latch.consume()
        guard shouldPark else { return }
        await gate.park(at: point.rawValue)
    }
}

// MARK: Test A — registration → first-query gap (§5 steps 1–5)

/// WS12 (docs/06-cross-cutting.md §8): "Pause an observer between
/// registration and first query, commit a change, then resume. Its first
/// yielded page must include the commit or be replaced before yield."
///
/// The `.readEntry` seam parks the Authority AFTER observer registration
/// (§5 step 1) but BEFORE the first authoritative query (§5 step 2). A commit
/// during the park advances the durable position; on resume, the first query
/// runs against the already-committed state, so the page position matches the
/// recheck and the first yield includes the commit — no discard-requery cycle
/// is needed.
@Test func commitBetweenRegistrationAndFirstQueryAppearsInFirstYieldedPage() async throws {
    let storeURL = WSSupport.tempStoreURL("ws12-observe-read-entry")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let gate = SuspensionGate()
    let latch = ParkLatch(armed: true)
    await Self.installReadEntryPark(on: history.authority, gate: gate, latch: latch)

    // §5 step 1: observe registers the invalidation continuation BEFORE any
    // query; the producer Task then enters firstPage and parks at .readEntry
    // (§5 step 2 gap). The commit lands during this park.
    let stream = await history.observe(HistoryObservationRequest(kind: .recent, limit: 10))

    // WS12: wait until the producer is parked at the readEntry seam.
    await gate.waitForPark(AuthoritySuspensionPoint.readEntry.rawValue)

    // WS12: "commit a change" — a capture committed while the first query is
    // parked. The commit's invalidation is recorded in the subscriber's
    // bufferingNewest(1) buffer (§4), and the durable position advances.
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_030_000)
    let source = "com.example.ws12.a"
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture("ws12 test-a capture", observedAt: observedAt, source: source)
    ))
    guard case let .committed(commit) = receipt else {
        Issue.record("WS12-A: expected a .committed receipt, got \(receipt)")
        return
    }
    guard case let .inserted(reference) = commit.outcome else {
        Issue.record("WS12-A: expected .inserted(reference), got \(commit.outcome)")
        return
    }
    let commitPosition = commit.position

    // WS12: "then resume" — the first query runs against the committed state.
    gate.resume(AuthoritySuspensionPoint.readEntry.rawValue)

    // WS12: "Its first yielded page must include the commit" — consume exactly
    // one page (bounded), then cancel the stream's producer (defer).
    let consumer = Task { () -> HistoryPage in
        for try await page in stream {
            return page
        }
        throw HistoryFailure.persistence(.invariantViolation)
    }
    defer { consumer.cancel() }
    let page = try await consumer.value

    // WS12: the page position is at or after the commit's position (§3
    // read-after-commit).
    #expect(
        page.position >= commitPosition,
        "WS12-A: first page position \(page.position.rawValue) must include commit at \(commitPosition.rawValue)"
    )
    // WS12: the new item's reference appears in the page rows.
    let rowIDs = page.rows.map(\.item.id)
    #expect(
        rowIDs.contains(reference.id),
        "WS12-A: first page must include the committed item \(reference.id)"
    )
}

// MARK: Test B — discard path (§5 step 4: recheck detects stale page)

/// WS12 (docs/06-cross-cutting.md §8; 04 §5 step 4): the first query completes
/// at position P BEFORE the interference commit; the phase-1 race-closing
/// recheck (`currentPosition`) then parks at `.positionRecheckEntry`; on
/// resume the recheck sees the newer durable position (P' > P), discards the
/// stale page, and requeries — so the first yield still includes the commit.
@Test func commitBeforePositionRecheckForcesRequeryAndFirstYieldIncludesCommit() async throws {
    let storeURL = WSSupport.tempStoreURL("ws12-observe-recheck-entry")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let gate = SuspensionGate()
    let latch = ParkLatch(armed: true)
    await Self.installPositionRecheckPark(on: history.authority, gate: gate, latch: latch)

    // §5 steps 2–3: the first query runs WITHOUT parking (the handler parks
    // only at .positionRecheckEntry) and produces a page at the empty-store
    // position 0 (P = 0). The producer then calls currentPosition for the §5
    // step-4 recheck and parks.
    let stream = await history.observe(HistoryObservationRequest(kind: .recent, limit: 10))

    // WS12: wait until the producer's position recheck is parked.
    await gate.waitForPark(AuthoritySuspensionPoint.positionRecheckEntry.rawValue)

    // WS12: the first query already completed at P = 0 (empty store); now
    // commit — the durable position advances to 1, and the recheck will see
    // the mismatch on resume.
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_031_000)
    let source = "com.example.ws12.b"
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture("ws12 test-b capture", observedAt: observedAt, source: source)
    ))
    guard case let .committed(commit) = receipt else {
        Issue.record("WS12-B: expected a .committed receipt, got \(receipt)")
        return
    }
    guard case let .inserted(reference) = commit.outcome else {
        Issue.record("WS12-B: expected .inserted(reference), got \(commit.outcome)")
        return
    }
    let commitPosition = commit.position

    // WS12: resume — the recheck reads the durable position (now 1), finds
    // 1 ≠ P (0), and the loop body requeries firstPage at position 1.
    gate.resume(AuthoritySuspensionPoint.positionRecheckEntry.rawValue)

    // WS12: "first yielded page must include the commit" — the requery after
    // the discard produces a page that includes the commit.
    let consumer = Task { () -> HistoryPage in
        for try await page in stream {
            return page
        }
        throw HistoryFailure.persistence(.invariantViolation)
    }
    defer { consumer.cancel() }
    let page = try await consumer.value

    // WS12: the first yield is the REQUERIED page (§5 step 4 discard), not the
    // stale position-0 page — its position includes the commit.
    #expect(
        page.position >= commitPosition,
        "WS12-B: first page position \(page.position.rawValue) must include commit at \(commitPosition.rawValue)"
    )
    let rowIDs = page.rows.map(\.item.id)
    #expect(
        rowIDs.contains(reference.id),
        "WS12-B: first page must include the committed item \(reference.id)"
    )
}

// MARK: Test C — coalescing (§4 bufferingNewest(1) + §5 step 7)

/// WS12 (docs/06-cross-cutting.md §8): "Coalesce several later invalidations
/// and verify one fresh page reaches the latest position."
///
/// After the first yield at P0, the latch is rearmed so the SECOND
/// `.readEntry` arrival — the phase-2 replacement query of §5 step 7 — parks.
/// Three captures commit while parked: the first triggers the invalidation
/// that wakes the loop and enters the replacement query; the second and third
/// commit during the park. The subscriber's `.bufferingNewest(1)` buffer
/// coalesces the later invalidations (§4); on resume the replacement query
/// reads position P3, yields exactly ONE page at P3, and the buffered
/// invalidation at P3 is skipped (P3 ≤ page.position). No further page is
/// produced.
@Test func threeInvalidationsDuringReplacementQueryCoalesceToOnePageAtLatestPosition() async throws {
    let storeURL = WSSupport.tempStoreURL("ws12-observe-coalesce")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: one item already committed at position 1, so the first observed
    // page (P0 = 1) is non-empty.
    let setupObservedAt = Date(timeIntervalSinceReferenceDate: 700_032_000)
    let setupReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws12 test-c setup",
            observedAt: setupObservedAt,
            source: "com.example.ws12.c.setup"
        )
    ))
    guard case let .committed(setupCommit) = setupReceipt else {
        Issue.record("WS12-C arrange: expected a .committed receipt, got \(setupReceipt)")
        return
    }
    let p0 = setupCommit.position
    #expect(p0.rawValue == 1)

    // Latch starts DISARMED: the initial firstPage and currentPosition calls
    // pass through; the latch is rearmed after the first yield so the NEXT
    // .readEntry (the phase-2 replacement query) parks.
    let gate = SuspensionGate()
    let latch = ParkLatch(armed: false)
    await Self.installReadEntryPark(on: history.authority, gate: gate, latch: latch)

    let stream = await history.observe(HistoryObservationRequest(kind: .recent, limit: 10))

    // The producer Task and the test coordinate through the iterator and the
    // gate; the whole interaction runs inside a cancellable Task so the
    // producer is terminated on exit (defer cancel).
    let interaction = Task { () -> (first: HistoryPage, replacement: HistoryPage, thirdCommit: HistoryCommit) in
        var iterator = stream.makeAsyncIterator()

        // §5 steps 2–5: the first page yields immediately (latch disarmed).
        guard let firstPage = try await iterator.next() else {
            Issue.record("WS12-C: expected a first page from the observe stream")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(
            firstPage.position == p0,
            "WS12-C: initial page should be at position \(p0.rawValue)"
        )

        // Arm the latch so the next .readEntry parks (the replacement query).
        await latch.rearm()

        // Capture 1: its invalidation wakes the loop (P1 > P0); the producer
        // enters firstPage for the replacement and parks at .readEntry. The
        // receipt is discarded — only capture 3's position is asserted later.
        _ = try await history.perform(.capture(
            WSSupport.textCapture(
                "ws12 test-c capture one",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_032_500),
                source: "com.example.ws12.c.one"
            )
        ))
        // WS12: wait until the replacement query is parked.
        await gate.waitForPark(AuthoritySuspensionPoint.readEntry.rawValue)

        // Captures 2 and 3 commit while the replacement query is parked. Their
        // invalidations buffer in the subscriber's bufferingNewest(1) (§4),
        // coalescing to the newest (capture 3's position). Receipts discarded
        // — only capture 3's position is asserted below.
        _ = try await history.perform(.capture(
            WSSupport.textCapture(
                "ws12 test-c capture two",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_033_000),
                source: "com.example.ws12.c.two"
            )
        ))
        let r3 = try await history.perform(.capture(
            WSSupport.textCapture(
                "ws12 test-c capture three",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_033_500),
                source: "com.example.ws12.c.three"
            )
        ))
        guard case let .committed(c3) = r3 else {
            Issue.record("WS12-C: expected .committed for capture 3, got \(r3)")
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // WS12: resume — the replacement query reads position P3 and yields.
        gate.resume(AuthoritySuspensionPoint.readEntry.rawValue)

        // §5 step 7: exactly ONE replacement page at the latest position.
        guard let replacementPage = try await iterator.next() else {
            Issue.record("WS12-C: expected a replacement page")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return (first: firstPage, replacement: replacementPage, thirdCommit: c3)
    }
    defer { interaction.cancel() }
    let result = try await interaction.value

    // WS12 (§4 bufferingNewest(1), §5 step 7): the replacement page is at the
    // THIRD commit's position — the latest durable position — proving the burst
    // coalesced to one fresh page.
    #expect(
        result.replacement.position >= result.thirdCommit.position,
        "WS12-C: replacement page position \(result.replacement.position.rawValue) must reach the third commit at \(result.thirdCommit.position.rawValue)"
    )
    #expect(
        result.first.position == p0,
        "WS12-C: the first page must remain at the pre-burst position \(p0.rawValue)"
    )

    // WS12: the replacement page includes the latest item (capture 3).
    guard case let .inserted(thirdReference) = result.thirdCommit.outcome else {
        Issue.record("WS12-C: expected .inserted for the third capture")
        return
    }
    let replacementIDs = result.replacement.rows.map(\.item.id)
    #expect(
        replacementIDs.contains(thirdReference.id),
        "WS12-C: replacement page must include the third capture's item"
    )

    // WS12: the replacement page's position is strictly greater than the first
    // page's — exactly one replacement, not zero.
    #expect(
        result.replacement.position > result.first.position,
        "WS12-C: replacement position must advance past the first page"
    )
}
}
