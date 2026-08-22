/// WS21 — Retention policy in the primary commit (docs/06-cross-cutting.md
/// §8 WS21): the commit/receipt/storage side of
/// `HistoryAction.setRetentionPolicy` through the public
/// `SwiftDataHistory.perform(_:)` and the real `HistoryAuthority` commit
/// path — the last previously path-less included behavior.
///
/// This file closes, all on the commit/storage side:
///
/// - the satisfied-value no-op: setting the value the current state already
///   satisfies (the requested value equals the durable value AND the state
///   satisfies it, docs/02-domain.md §12) returns `.unchanged` — no commit,
///   no position advance (02 §13);
/// - lowering below the current unpinned count: the excess oldest unpinned
///   items retire in the SAME History Commit (02 §12 eviction order:
///   `lastCopiedAt` ascending, HistoryItemID bytes ascending tie-break), the
///   receipt carries `.retentionPolicySet(removedCount:)`, `ChangePosition`
///   advances exactly once for the whole plan (02 §13), and the new policy
///   value is persisted on the position singleton (05 §3.2);
/// - restart survival: reopening the store keeps the durable singleton
///   policy value — the configuration's initial value is ignored for an
///   existing store (05 §13 steps 3–4, §2);
/// - the boundary: values outside the Part VI user range 1–5,000 (06 §2)
///   throw `.invalidInput(.invalidRetentionPolicy)` with no commit and no
///   position advance (02 §5.5, D19);
/// - the pinned exemption: retention never retires a pinned item (02 §12,
///   D13) — the oldest item in the store survives once pinned while a newer
///   unpinned item is retired.
///
/// Phasing (docs/roadmap/README.md §3, WS-clause phasing note): WS21 carries
/// no public-read or observation clause — every assertion here is
/// commit/storage side: receipts plus the INDEPENDENT second
/// `ModelContainer` over the same on-disk store (see `WSSupport`). The
/// public reads (`browse`, `details`, `pastePayload`, `observe`) are covered by
/// the separate step-7 suites and are intentionally not called here.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS21RetentionPolicyTests {

/// WS21 (docs/06-cross-cutting.md §8): a satisfied set is `.unchanged` with
/// no advance; lowering to 1 with three unpinned items retires the two
/// oldest in the same commit at exactly one position advance, persists the
/// policy on the singleton, and the durable value survives a restart.
@Test func satisfiedSetIsUnchangedLoweredSetRetiresOldestUnpinnedAndSurvivesRestart() async throws {
    let storeURL = WSSupport.tempStoreURL("ws21-retention-policy")
    defer { WSSupport.removeStore(storeURL) }
    // The default initial policy value, 200 (06 §2).
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Three unpinned text captures with strictly increasing observation
    // times: the §12 eviction order (`lastCopiedAt` ascending, HistoryItemID
    // bytes ascending tie-break) ranks alpha oldest and charlie newest — the
    // tie-break is never reached.
    let source = "com.example.ws21"
    let alphaObservedAt = Date(timeIntervalSinceReferenceDate: 700_100_000)
    let bravoObservedAt = Date(timeIntervalSinceReferenceDate: 700_100_100)
    let charlieObservedAt = Date(timeIntervalSinceReferenceDate: 700_100_200)
    let charlieText = "ws21 charlie"

    let alphaReceipt = try await history.perform(.capture(
        WSSupport.textCapture("ws21 alpha", observedAt: alphaObservedAt, source: source)
    ))
    guard case let .committed(alphaCommit) = alphaReceipt else {
        Issue.record("WS21: expected .committed for the alpha capture, got \(alphaReceipt)")
        return
    }
    #expect(alphaCommit.position.rawValue == 1)

    let bravoReceipt = try await history.perform(.capture(
        WSSupport.textCapture("ws21 bravo", observedAt: bravoObservedAt, source: source)
    ))
    guard case let .committed(bravoCommit) = bravoReceipt else {
        Issue.record("WS21: expected .committed for the bravo capture, got \(bravoReceipt)")
        return
    }
    #expect(bravoCommit.position.rawValue == 2)

    let charlieReceipt = try await history.perform(.capture(
        WSSupport.textCapture(charlieText, observedAt: charlieObservedAt, source: source)
    ))
    guard case let .committed(charlieCommit) = charlieReceipt else {
        Issue.record("WS21: expected .committed for the charlie capture, got \(charlieReceipt)")
        return
    }
    #expect(charlieCommit.position.rawValue == 3)
    guard case let .inserted(charlieReference) = charlieCommit.outcome else {
        Issue.record("WS21: expected .inserted(reference) for the charlie capture, got \(charlieCommit.outcome)")
        return
    }

    // WS21 satisfied-value clause (06 §8): "Set maximumUnpinnedItems to a
    // value the current state already satisfies and assert .unchanged" — 200
    // equals the durable value and 3 unpinned ≤ 200 (docs/02-domain.md §12).
    let satisfiedReceipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 200))
    guard case .unchanged = satisfiedReceipt else {
        Issue.record("WS21 satisfied-value clause: expected .unchanged, got \(satisfiedReceipt)")
        return
    }
    // No commit, no advance (02 §13): the singleton still shows position 3
    // and the untouched policy value.
    let afterNoOp = try WSSupport.makeContainer(storeURL: storeURL)
    let noOpSingleton = try WSSupport.fetchPosition(afterNoOp)
    #expect(noOpSingleton.rawValue == 3)
    #expect(noOpSingleton.maximumUnpinnedItems == 200)

    // WS21 lowering clause (06 §8): "lower it below the current unpinned
    // count and assert the excess oldest unpinned items are retired in the
    // same History Commit … and .retentionPolicySet(removedCount:) is
    // returned with ChangePosition advanced once".
    let loweredReceipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
    guard case let .committed(loweredCommit) = loweredReceipt else {
        Issue.record("WS21 lowering clause: expected .committed, got \(loweredReceipt)")
        return
    }
    // 02 §13: exactly one position advance for the whole plan — the policy
    // write plus both retirements — never one per mutation.
    #expect(loweredCommit.position.rawValue == 4)
    guard case let .retentionPolicySet(removedCount) = loweredCommit.outcome else {
        Issue.record("WS21 lowering clause: expected .retentionPolicySet(removedCount:), got \(loweredCommit.outcome)")
        return
    }
    // 02 §12 eviction order (`lastCopiedAt` ascending): alpha and bravo, the
    // two oldest unpinned items, are the victims of the same commit.
    #expect(removedCount == 2)

    // Storage side, through the INDEPENDENT container: only the newest
    // item's row survives.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 1)
    let survivor = try #require(rows.first)
    #expect(survivor.id == charlieReference.id.rawValue)
    #expect(survivor.lastCopiedAt == charlieObservedAt)
    #expect(survivor.copyCount == 1)
    #expect(survivor.pinOrdinal == nil)
    let survivorCanonical = try CanonicalBlobCodec.decode(survivor.canonicalBlob)
    #expect(survivorCanonical.representations.map(\.content.bytes) == [Data(charlieText.utf8)])

    // 06 §8 WS21: "the policy value is persisted on the singleton" (05 §3.2)
    // with the position advanced exactly once.
    let singleton = try WSSupport.fetchPosition(container)
    #expect(singleton.rawValue == 4)
    #expect(singleton.maximumUnpinnedItems == 1)

    // WS21 restart clause (06 §8): "Restart and confirm the singleton
    // maximumUnpinnedItems survived." A fresh facade over the same store:
    // the durable singleton value rules and the configuration's initial
    // value (the `openHistory` default 200) is ignored for an existing store
    // (05 §13 steps 3–4, §2).
    let restartedHistory = try await WSSupport.openHistory(storeURL: storeURL)
    let restartContainer = try WSSupport.makeContainer(storeURL: storeURL)
    let restartSingleton = try WSSupport.fetchPosition(restartContainer)
    #expect(restartSingleton.rawValue == 4)
    #expect(restartSingleton.maximumUnpinnedItems == 1)

    // Behavioral proof through the restarted facade: re-setting the durable
    // value is `.unchanged` — had the restart reset the policy to the
    // configuration's 200, this call would have committed — and the position
    // still does not advance (02 §12, §13).
    let restartedReceipt = try await restartedHistory.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
    guard case .unchanged = restartedReceipt else {
        Issue.record("WS21 restart clause: expected .unchanged after restart, got \(restartedReceipt)")
        return
    }
    let finalSingleton = try WSSupport.fetchPosition(restartContainer)
    #expect(finalSingleton.rawValue == 4)
    #expect(finalSingleton.maximumUnpinnedItems == 1)
}

/// WS21 (docs/06-cross-cutting.md §8, boundary): values outside the Part VI
/// user range 1–5,000 (06 §2) are rejected at the storage boundary with
/// `.invalidInput(.invalidRetentionPolicy)` (02 §5.5, D19) — no commit, no
/// position advance, no policy change.
@Test func outOfRangePolicyValuesThrowInvalidRetentionPolicyWithoutCommitOrAdvance() async throws {
    let storeURL = WSSupport.tempStoreURL("ws21-retention-boundary")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // One committed capture, so the singleton holds a real position and the
    // default policy value the rejections must leave untouched.
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws21 boundary",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_200_000),
            source: "com.example.ws21"
        )
    ))
    guard case let .committed(commit) = receipt else {
        Issue.record("WS21 boundary clause: expected .committed for the setup capture, got \(receipt)")
        return
    }
    #expect(commit.position.rawValue == 1)

    // WS21 boundary clause: 0 is below the user range (02 §5.5, D19 — the
    // policy always permits at least one unpinned item).
    await #expect(throws: HistoryFailure.invalidInput(.invalidRetentionPolicy)) {
        try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 0))
    }
    // WS21 boundary clause: 5,001 is above the Part VI user range (06 §2).
    await #expect(throws: HistoryFailure.invalidInput(.invalidRetentionPolicy)) {
        try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 5_001))
    }

    // No commit and no advance for either rejection: the singleton and the
    // retained row are exactly as the setup capture left them.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let singleton = try WSSupport.fetchPosition(container)
    #expect(singleton.rawValue == 1)
    #expect(singleton.maximumUnpinnedItems == 200)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 1)
}

/// WS21 (docs/06-cross-cutting.md §8, pinned exemption): retention never
/// retires a pinned item (docs/02-domain.md §12: "Pinned items are excluded
/// before victim selection"; D13). The pinned item here has the OLDEST
/// `lastCopiedAt` in the store, so its survival is the exemption, not the
/// eviction order.
@Test func pinnedItemIsNeverARetentionVictim() async throws {
    let storeURL = WSSupport.tempStoreURL("ws21-retention-pinned-exempt")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // The pinned-to-be item is captured FIRST, so it carries the oldest
    // `lastCopiedAt` of the scenario; the two unpinned items follow.
    let source = "com.example.ws21"
    let pinnedText = "ws21 pinned"
    let pinnedObservedAt = Date(timeIntervalSinceReferenceDate: 700_300_000)
    let olderObservedAt = Date(timeIntervalSinceReferenceDate: 700_300_100)
    let newerObservedAt = Date(timeIntervalSinceReferenceDate: 700_300_200)

    let pinnedReceipt = try await history.perform(.capture(
        WSSupport.textCapture(pinnedText, observedAt: pinnedObservedAt, source: source)
    ))
    guard case let .committed(pinnedCaptureCommit) = pinnedReceipt else {
        Issue.record("WS21 pinned-exemption clause: expected .committed for the pinned capture, got \(pinnedReceipt)")
        return
    }
    #expect(pinnedCaptureCommit.position.rawValue == 1)
    guard case let .inserted(pinnedReference) = pinnedCaptureCommit.outcome else {
        Issue.record("WS21 pinned-exemption clause: expected .inserted(reference) for the pinned capture, got \(pinnedCaptureCommit.outcome)")
        return
    }

    let olderReceipt = try await history.perform(.capture(
        WSSupport.textCapture("ws21 unpinned older", observedAt: olderObservedAt, source: source)
    ))
    guard case let .committed(olderCommit) = olderReceipt else {
        Issue.record("WS21 pinned-exemption clause: expected .committed for the older capture, got \(olderReceipt)")
        return
    }
    #expect(olderCommit.position.rawValue == 2)

    let newerReceipt = try await history.perform(.capture(
        WSSupport.textCapture("ws21 unpinned newer", observedAt: newerObservedAt, source: source)
    ))
    guard case let .committed(newerCommit) = newerReceipt else {
        Issue.record("WS21 pinned-exemption clause: expected .committed for the newer capture, got \(newerReceipt)")
        return
    }
    #expect(newerCommit.position.rawValue == 3)
    guard case let .inserted(newerReference) = newerCommit.outcome else {
        Issue.record("WS21 pinned-exemption clause: expected .inserted(reference) for the newer capture, got \(newerCommit.outcome)")
        return
    }

    // Pin the oldest item at the front of the pinned lane (03a §5 `.first`):
    // with a single pinned row the lane is exactly 0 ..< 1 (05 §13 step 10,
    // D12), so its ordinal is 0.
    let pinReceipt = try await history.perform(.placePinned(pinnedReference.id, at: .first))
    guard case let .committed(pinCommit) = pinReceipt else {
        Issue.record("WS21 pinned-exemption clause: expected .committed for the pin, got \(pinReceipt)")
        return
    }
    #expect(pinCommit.position.rawValue == 4)
    guard case let .placedPinned(pinnedID) = pinCommit.outcome else {
        Issue.record("WS21 pinned-exemption clause: expected .placedPinned, got \(pinCommit.outcome)")
        return
    }
    #expect(pinnedID == pinnedReference.id)

    // Lower the cap to one unpinned item: the only eligible victim is the
    // oldest UNPINNED item — never the pinned one, even though the pinned
    // item is the oldest in the store (02 §12, D13).
    let retentionReceipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
    guard case let .committed(retentionCommit) = retentionReceipt else {
        Issue.record("WS21 pinned-exemption clause: expected .committed for the retention set, got \(retentionReceipt)")
        return
    }
    #expect(retentionCommit.position.rawValue == 5)
    guard case let .retentionPolicySet(removedCount) = retentionCommit.outcome else {
        Issue.record("WS21 pinned-exemption clause: expected .retentionPolicySet(removedCount:), got \(retentionCommit.outcome)")
        return
    }
    #expect(removedCount == 1)

    // Storage side: the pinned row is intact (ordinal 0, version 1, full
    // Canonical bytes, original occurrence) and the only unpinned survivor
    // is the newest item.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 2)

    let pinnedRow = try #require(rows.first { $0.id == pinnedReference.id.rawValue })
    #expect(pinnedRow.pinOrdinal == 0)
    #expect(pinnedRow.contentVersionRaw == 1)
    #expect(pinnedRow.copyCount == 1)
    #expect(pinnedRow.lastCopiedAt == pinnedObservedAt)
    let pinnedCanonical = try CanonicalBlobCodec.decode(pinnedRow.canonicalBlob)
    #expect(pinnedCanonical.representations.map(\.content.bytes) == [Data(pinnedText.utf8)])

    let unpinnedSurvivor = try #require(rows.first { $0.id == newerReference.id.rawValue })
    #expect(unpinnedSurvivor.pinOrdinal == nil)
    #expect(unpinnedSurvivor.lastCopiedAt == newerObservedAt)

    let singleton = try WSSupport.fetchPosition(container)
    #expect(singleton.rawValue == 5)
    #expect(singleton.maximumUnpinnedItems == 1)
}
}
