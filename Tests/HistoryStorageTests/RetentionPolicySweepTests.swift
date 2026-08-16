/// R.6 — policy-sweep proofs (`V2-roadmap` §6 R.6 "Policy sweep"):
/// `HistoryAction.setRetentionPolicies` end to end through the PUBLIC
/// `SwiftDataHistory.perform(_:)` — boundary validation, the R3-then-R2
/// projected sweep, the DC-27 survivor-scoped unsatisfiable-R3 veto, the
/// retire-subsumes-prune drop, the same-value/satisfied `.unchanged` no-op,
/// the §6.4 clock seam, and config persistence across reopen.
///
/// Owning spec: `V2-02` §4.4 (the authoritative sweep pseudocode and its
/// DC-27 resolution), §3.2 (the post-R3-prune projection — R2 never credits
/// soon-to-be-pruned revision bytes, `RET-PRUNE-2`), §5.5/§5.6 (R3 with no
/// append; the explicit policy-persisting mutation, D18), §6.3
/// (retire-subsumes-prune — the composer drops prunes for items the same
/// commit retires BEFORE stamping, `RET-STAMP-2`), §6.4 (the Storage clock
/// is the sweep lane's seam), §8.1 (`retiredItems` = R1∪R2 count;
/// `prunedRevisions` = SURVIVORS' prunes only), §8.3 (boundary validation →
/// `.invalidInput(.invalidRetentionPolicy)` before any store work; the
/// PHASE-C veto; the same-value satisfied `.unchanged` — the v1 WS21
/// posture), §11 D24; Record 3 gates `RET-PERF-2` (lineages decoded only
/// for exceeding items — proven behaviorally here through a corrupted
/// non-exceeding blob the sweep must never decode), `RET-SECURITY-1`
/// (deletion atomicity — a vetoed sweep commits nothing).
///
/// Every fixture crosses the public `perform(.setRetentionPolicies(...))`
/// seam; the two clock-dependent R1 fixtures instead drive a directly
/// constructed Authority with a fixed `RetentionClock` (§6.4's only
/// injection point — the public `open` wires the system witness), and
/// assert rows/position/config through an INDEPENDENT container.
///
/// Hand-worked fixture values (single-representation ASCII text: one
/// `public.utf8-plain-text` representation, so a revision's representation
/// bytes equal its UTF-8 length and an item's `canonicalBytes` equal the
/// capture text's UTF-8 length; an item's R2 footprint is `canonicalBytes +
/// revisionBytes`; times are `timeIntervalSinceReferenceDate` seconds):
/// - boundary fixtures — 0 / NaN / ±∞ / 3,650 d + 1 s ages; 0 and
///   5,000 × 384 MiB + 1 budgets; 0 / 101 counts; 0 / 256 MiB + 1 bytes;
/// - R1 (fixed now 800,000,000, maxAge 100 → cutoff 799,999,900): P
///   (pinned, …800), A (…850), B (…880) aged; D (…900) exactly AT the
///   cutoff — the strict `<` boundary (RET-SELECT-1(a)); C (…950) fresh;
/// - retire-subsumes-prune: H = 30 canonical + [10, 10] revisions
///   (footprint 50) under budget 40 retires (T = 10 survives alone at
///   10 ≤ 40) while R3 count 1 plans H's [rev1] prune — dropped, so the
///   receipt's `prunedRevisions` is 0;
/// - R3 sweep: A = 30 + [10, 10, 10] (count 3 > 2 prunes [rev1] → 2/20),
///   B = 20 + [30, 10] (bytes 40 > 35 prunes [rev1] → 1/10), T = 10 +
///   [5] non-exceeding (corrupted blob, never decoded);
/// - RET-PRUNE-2: A = 30 + [30, 10] prunes [rev1] (bytes 40 → 10 ≤ 35);
///   projected total 40 + 10 = 50 ≤ budget 50 → ZERO retirements (unpruned
///   70 + 10 = 80 > 50 would retire A);
/// - DC-27: H = 30 + [25] (footprint 55, active alone 25 > 20), T = 10;
///   budget 60 of total 65 retires the unpinned H in variant A (sweep
///   succeeds) but only T once H is pinned in variant B (survivors 55 ≤ 60
///   pass the budget check; PHASE C alone fires `.invalidRetentionPolicy`).
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Retention policy sweep (R.6)")
struct RetentionPolicySweepTests {

    // MARK: - Fixtures

    /// The §6.4 fixed-date clock witness (the R.3 seam-test stance): the
    /// sweep lane's R1 reference time, injected through the `@testable`
    /// `HistoryAuthority` initializer only.
    private struct FixedSweepClock: RetentionClock {
        let fixed: Date
        func now() -> Date { fixed }
    }

    /// A directly constructed, started Authority over the store with the
    /// fixed clock wired — the one deterministic way to drive an R1 sweep
    /// (the public facade's `SystemRetentionClock` reads real `Date.now`).
    private static func makeSweepAuthority(
        storeURL: URL,
        now: Date
    ) async throws -> HistoryAuthority {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let authority = HistoryAuthority(
            container: container,
            retentionClock: FixedSweepClock(fixed: now)
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        return authority
    }

    /// Performs one raw text capture through a directly constructed
    /// Authority (clock-fixture lane), asserting the `.inserted` shape.
    @discardableResult
    private static func authorityCapture(
        _ text: String,
        at seconds: Double,
        source: String,
        in authority: HistoryAuthority
    ) async throws -> HistoryItemReference {
        let prepared = try await IngestPreparationActor().prepare(
            WSSupport.textCapture(
                text,
                observedAt: Date(timeIntervalSinceReferenceDate: seconds),
                source: source
            )
        )
        let receipt = try await authority.commitCapture(prepared)
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record("R.6 setup: expected .committed with .inserted, got \(receipt)")
            throw HistoryFailure.notFound(HistoryItemID(rawValue: UUID()))
        }
        return reference
    }

    /// Performs one raw text capture through the public facade.
    @discardableResult
    private static func capture(
        _ text: String,
        at seconds: Double,
        source: String,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                text,
                observedAt: Date(timeIntervalSinceReferenceDate: seconds),
                source: source
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record("R.6 setup: expected .committed with .inserted, got \(receipt)")
            throw HistoryFailure.notFound(HistoryItemID(rawValue: UUID()))
        }
        return reference
    }

    /// A byte-changing `.replace` revision request for the single
    /// `public.utf8-plain-text` representation, OCC-tokened at `expected`.
    private static func replaceRequest(
        itemID: HistoryItemID,
        expected: Int,
        bytes: Int
    ) -> RevisionRequest {
        // Unique payload per append: `expected` is the OCC version, which
        // increments with every append in a lineage — so the last byte
        // differs per revision. A byte-identical repeat would be `.unchanged`
        // under D4 (only effective-content-changing revisions append), which
        // the seeding of equal-length lineages ([10, 10, 10]) must avoid.
        // Length stays exactly `bytes`.
        let distinguishingScalar = UnicodeScalar(97 + min(expected, 25))!
        let payload = String(repeating: "r", count: max(bytes - 1, 0))
            + String(Character(distinguishingScalar))
        return RevisionRequest(
            itemID: itemID,
            expected: ContentVersion(rawValue: UInt64(expected)),
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: "public.utf8-plain-text",
                    action: .replace(
                        bytes: Data(payload.utf8)
                    )
                ),
            ]))
        )
    }

    /// Performs one public revise appending `bytes` representation bytes at
    /// `expected`, asserting the `.revised` outcome shape.
    @discardableResult
    private static func revise(
        _ itemID: HistoryItemID,
        expected: Int,
        bytes: Int,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.revise(
            Self.replaceRequest(itemID: itemID, expected: expected, bytes: bytes)
        ))
        guard case let .committed(commit) = receipt,
              case let .revised(reference) = commit.outcome else {
            Issue.record("R.6 setup: expected .committed with .revised, got \(receipt)")
            throw HistoryFailure.notFound(itemID)
        }
        return reference
    }

    /// Appends revisions of the given byte counts to `itemID` through the
    /// public path (configs are all-disabled during seeding, so the store
    /// reaches the pre-sweep lineage untouched).
    private static func seedRevisions(
        _ itemID: HistoryItemID,
        byteCounts: [Int],
        in history: SwiftDataHistory
    ) async throws {
        for (index, count) in byteCounts.enumerated() {
            _ = try await Self.revise(
                itemID,
                expected: index + 1,
                bytes: count,
                in: history
            )
        }
    }

    /// The reloaded revision lineage of `itemID` through the production
    /// fact loader (05 §7.3), over the independent assertion container.
    private static func lineage(
        of itemID: HistoryItemID,
        in container: ModelContainer
    ) throws -> RevisionFacts {
        try MutationFactLoaders.loadRevisionFacts(
            itemID: itemID,
            in: ModelContext(container)
        )
    }

    /// The unique projection row for `itemID`, or `nil` (0 or 1 rows; 2+
    /// fails the fixture loudly — the 1:1 law is a precondition here).
    private static func fetchBytesRow(
        for itemID: HistoryItemID,
        in container: ModelContainer
    ) throws -> RetainedBytesRow? {
        let context = ModelContext(container)
        let uuid = itemID.rawValue
        var descriptor = FetchDescriptor<RetainedBytesRow>(
            predicate: #Predicate { row in row.itemID == uuid }
        )
        descriptor.fetchLimit = 2
        let rows = try context.fetch(descriptor)
        precondition(
            rows.count <= 1,
            "RetainedBytesRow 1:1 law violated in fixture: \(rows.count) rows"
        )
        return rows.first
    }

    /// Every `RetainedBytesRow`, deterministically ordered by item ID.
    private static func fetchBytesRows(
        _ container: ModelContainer
    ) throws -> [RetainedBytesRow] {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        return rows.sorted { $0.itemID.uuidString < $1.itemID.uuidString }
    }

    /// The unique config singleton (fails the fixture loudly otherwise).
    private static func fetchConfigRow(
        _ container: ModelContainer
    ) throws -> RetentionExpansionConfigRow {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
        precondition(
            rows.count == 1,
            "config singleton must exist exactly once, got \(rows.count)"
        )
        return rows[0]
    }

    /// Asserts the config singleton is exactly the all-disabled bootstrap
    /// shape (the `open` default; also the atomicity reference for vetoed
    /// sweeps).
    private static func expectAllDisabledConfig(
        _ container: ModelContainer
    ) throws {
        let config = try Self.fetchConfigRow(container)
        #expect(config.agePolicyEnabled == false)
        #expect(config.ageMaxSeconds == 0)
        #expect(config.storagePolicyEnabled == false)
        #expect(config.storageMaxBytes == 0)
        #expect(config.revisionPolicyEnabled == false)
        #expect(config.revisionMaxCount == nil)
        #expect(config.revisionMaxBytes == nil)
        #expect(config.configSchemaVersion == 1)
    }

    // MARK: - Boundary validation (V2-02 §8.3)

    /// Every dimension's out-of-range / NaN / ±∞ value is rejected at the
    /// boundary with `.invalidInput(.invalidRetentionPolicy)` BEFORE any
    /// store work (§8.3): the position, the retained row, and the
    /// all-disabled config singleton are exactly as the setup capture left
    /// them.
    @Test("boundary rejections throw invalidRetentionPolicy and commit nothing")
    func boundaryRejectionsThrowInvalidRetentionPolicyAndCommitNothing() async throws {
        let storeURL = WSSupport.tempStoreURL("r6-boundary")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                "r6 boundary",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_600_000),
                source: "com.example.r6"
            )
        ))
        guard case let .committed(commit) = receipt else {
            Issue.record("R.6 setup: expected .committed for the capture, got \(receipt)")
            return
        }
        #expect(commit.position.rawValue == 1)

        // §8.3 rows: R1 maxAge (1 s ... 3,650 d; DC-21 finiteness), R2
        // maxTotalBytes (1 ... 5,000 × 384 MiB), R3 maxRevisionsPerItem
        // (1 ... 100) and maxRevisionBytesPerItem (1 ... 256 MiB).
        let badPolicies: [HistoryRetentionPolicies] = [
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 0), storage: nil, revisions: nil
            ),
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: .nan), storage: nil, revisions: nil
            ),
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: .infinity), storage: nil, revisions: nil
            ),
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 3_650 * 86_400 + 1),
                storage: nil,
                revisions: nil
            ),
            HistoryRetentionPolicies(
                age: nil,
                storage: StorageRetention(maxTotalBytes: 0),
                revisions: nil
            ),
            HistoryRetentionPolicies(
                age: nil,
                storage: StorageRetention(maxTotalBytes: 5_000 * 384 * 1_048_576 + 1),
                revisions: nil
            ),
            HistoryRetentionPolicies(
                age: nil,
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 0, maxRevisionBytesPerItem: nil
                )
            ),
            HistoryRetentionPolicies(
                age: nil,
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 101, maxRevisionBytesPerItem: nil
                )
            ),
            HistoryRetentionPolicies(
                age: nil,
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: nil, maxRevisionBytesPerItem: 0
                )
            ),
            HistoryRetentionPolicies(
                age: nil,
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: nil,
                    maxRevisionBytesPerItem: 256 * 1_048_576 + 1
                )
            ),
        ]
        for bad in badPolicies {
            await #expect(throws: HistoryFailure.invalidInput(.invalidRetentionPolicy)) {
                try await history.perform(.setRetentionPolicies(bad))
            }
        }

        // Nothing durable (§8.3 "at the boundary" — before any store work).
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try WSSupport.fetchPosition(container).rawValue == 1)
        #expect(try WSSupport.fetchRows(container).count == 1)
        try Self.expectAllDisabledConfig(container)
    }

    // MARK: - R1 sweep (V2-02 §4.4 PHASE B, §6.4 clock)

    /// Fixed now 800,000,000, maxAge 100 → strict cutoff 799,999,900
    /// (RET-SELECT-1(a): an item exactly `maxAge` old is NOT retired).
    /// Pinned P (…800, oldest of all) survives as protected (D13); aged A
    /// (…850) and B (…880) retire; D (…900, exactly at the cutoff) and C
    /// (…950) survive. ONE commit: the five captures plus the pin leave
    /// position 6, and the sweep advances it exactly once to 7; the receipt
    /// carries `retiredItems == 2` / `prunedRevisions == 0`; the age lane
    /// persists on the config singleton.
    @Test("R1 sweep retires the aged oldest-first in one commit; pinned survives")
    func r1SweepRetiresAgedOldestFirstInOneCommitAndSparesPinned() async throws {
        let storeURL = WSSupport.tempStoreURL("r6-r1-sweep")
        defer { WSSupport.removeStore(storeURL) }
        let fixedNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let authority = try await Self.makeSweepAuthority(
            storeURL: storeURL, now: fixedNow
        )
        let source = "com.example.r6.r1"

        let pinned = try await Self.authorityCapture(
            "p", at: 799_999_800, source: source, in: authority
        )
        let a = try await Self.authorityCapture(
            "a", at: 799_999_850, source: source, in: authority
        )
        let b = try await Self.authorityCapture(
            "b", at: 799_999_880, source: source, in: authority
        )
        let d = try await Self.authorityCapture(
            "d", at: 799_999_900, source: source, in: authority
        )
        let c = try await Self.authorityCapture(
            "c", at: 799_999_950, source: source, in: authority
        )
        // Pin mutations do not trigger V2 expansion (V2-02 §7).
        let pinReceipt = try await authority.commitPinnedPlacement(pinned.id, .last)
        guard case .committed = pinReceipt else {
            Issue.record("R.6 setup: expected the pin to commit, got \(pinReceipt)")
            return
        }

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try WSSupport.fetchPosition(container).rawValue == 6)

        let receipt = try await authority.commitRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 100), storage: nil, revisions: nil
            )
        )
        guard case let .committed(sweepCommit) = receipt else {
            Issue.record("R.6: expected .committed for the sweep, got \(receipt)")
            return
        }
        // ONE position advance for the whole plan (D6/D24(a)).
        #expect(sweepCommit.position.rawValue == 7)
        guard case let .retentionPoliciesSet(retiredItems, prunedRevisions) =
            sweepCommit.outcome else {
            Issue.record(
                "R.6: expected .retentionPoliciesSet, got \(sweepCommit.outcome)"
            )
            return
        }
        #expect(retiredItems == 2)
        #expect(prunedRevisions == 0)

        // Storage side: A and B retired; P (pinned), D (exactly at the
        // strict cutoff), and C survive; the pinned lane is untouched.
        let survivors = Set(
            try WSSupport.fetchRows(container).map { HistoryItemID(rawValue: $0.id) }
        )
        #expect(survivors == Set([pinned.id, d.id, c.id]))
        #expect(!survivors.contains(a.id))
        #expect(!survivors.contains(b.id))
        let pinnedRow = try #require(
            try WSSupport.fetchRows(container)
                .first { $0.id == pinned.id.rawValue }
        )
        #expect(pinnedRow.pinOrdinal == 0)

        // §5.6 persistence: the age lane landed on the config singleton.
        let config = try Self.fetchConfigRow(container)
        #expect(config.agePolicyEnabled == true)
        #expect(config.ageMaxSeconds == 100)
        #expect(config.storagePolicyEnabled == false)
        #expect(config.revisionPolicyEnabled == false)
    }

    // MARK: - Clock seam (V2-02 §6.4)

    /// The sweep's R1 reference time is `retentionClock.now()` (§6.4 — the
    /// seam's only production consumer), never `Date.now`: fixed now
    /// 800,000,000 with maxAge 100 retires the item at …850 (150 s old) and
    /// spares the item at …950 (50 s old). Under the real system clock
    /// (August 2026 ≈ timeIntervalSinceReferenceDate 808,000,000 ≫ the
    /// fixture times) BOTH items are years past any cutoff, so the fresh
    /// item's survival proves the comparison ran against the FIXED date.
    @Test("R1 reference time is the injected fixed clock, not Date.now")
    func r1ReferenceTimeIsTheInjectedFixedClockNotDateNow() async throws {
        let storeURL = WSSupport.tempStoreURL("r6-clock")
        defer { WSSupport.removeStore(storeURL) }
        let fixedNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let authority = try await Self.makeSweepAuthority(
            storeURL: storeURL, now: fixedNow
        )
        let source = "com.example.r6.clock"

        let old = try await Self.authorityCapture(
            "old", at: 799_999_850, source: source, in: authority
        )
        let fresh = try await Self.authorityCapture(
            "fresh", at: 799_999_950, source: source, in: authority
        )

        let receipt = try await authority.commitRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 100), storage: nil, revisions: nil
            )
        )
        guard case let .committed(sweepCommit) = receipt,
              case let .retentionPoliciesSet(retiredItems, _) = sweepCommit.outcome else {
            Issue.record("R.6 clock: expected a committed sweep receipt, got \(receipt)")
            return
        }
        #expect(retiredItems == 1)
        #expect(sweepCommit.position.rawValue == 3)

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let survivors = Set(
            try WSSupport.fetchRows(container).map { HistoryItemID(rawValue: $0.id) }
        )
        #expect(survivors == Set([fresh.id]))
        #expect(!survivors.contains(old.id))
    }

    // MARK: - R2 sweep: retire-subsumes-prune (V2-02 §4.4/§6.3, RET-STAMP-2)

    /// H (oldest, footprint 30 canonical + 20 revision bytes = 50) exceeds
    /// BOTH the NEW R3 count threshold (2 > 1 → PHASE A plans H's [rev1]
    /// prune, projected to 30 + 10 = 40) and the R2 budget (projected total
    /// 40 + 10 = 50 > 40 → PHASE B retires H, the oldest eligible,
    /// restoring 10 ≤ 40). Retirement SUBSUMES the prune (§6.3): the
    /// composer drops H's `.pruneRevisions` BEFORE stamping, so the receipt
    /// reports `prunedRevisions == 0` — H's revisions are deleted by the
    /// retirement, not pruned — and H's `revisionStateBlob` disappears WITH
    /// the row (no orphan `RetainedBytesRow`, `RET-SECURITY-1`).
    @Test("R2 retirement subsumes the planned prune; retired item contributes zero prunedRevisions")
    func r2RetirementSubsumesPruneAndDeletesBlobWithRow() async throws {
        let storeURL = WSSupport.tempStoreURL("r6-retire-subsumes")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let source = "com.example.r6.subsume"

        let heavy = try await Self.capture(
            String(repeating: "h", count: 30), at: 700_604_000,
            source: source, in: history
        )
        try await Self.seedRevisions(heavy.id, byteCounts: [10, 10], in: history)
        let tiny = try await Self.capture(
            String(repeating: "t", count: 10), at: 700_604_100,
            source: source, in: history
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try WSSupport.fetchPosition(container).rawValue == 4)
        let before = try Self.lineage(of: heavy.id, in: container)
        #expect(before.item.revisions.count == 2)

        let receipt = try await history.perform(.setRetentionPolicies(
            HistoryRetentionPolicies(
                age: nil,
                storage: StorageRetention(maxTotalBytes: 40),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil
                )
            )
        ))
        guard case let .committed(sweepCommit) = receipt else {
            Issue.record("R.6: expected .committed for the sweep, got \(receipt)")
            return
        }
        #expect(sweepCommit.position.rawValue == 5)
        guard case let .retentionPoliciesSet(retiredItems, prunedRevisions) =
            sweepCommit.outcome else {
            Issue.record(
                "R.6: expected .retentionPoliciesSet, got \(sweepCommit.outcome)"
            )
            return
        }
        // R1∪R2 retired H; H's planned prune was DROPPED — zero pruned
        // revisions reach the durable outcome (§8.1/§6.3, RET-STAMP-2).
        #expect(retiredItems == 1)
        #expect(prunedRevisions == 0)

        // Storage side: H's row AND its blob are gone with the retirement
        // (no prune rewrite of a deleted row); the 1:1 projection row went
        // with it; T survives alone within the restored budget.
        let survivors = Set(
            try WSSupport.fetchRows(container).map { HistoryItemID(rawValue: $0.id) }
        )
        #expect(survivors == Set([tiny.id]))
        #expect(!survivors.contains(heavy.id))
        #expect(try Self.fetchBytesRows(container).count == 1)
        let tinyRow = try #require(try Self.fetchBytesRow(for: tiny.id, in: container))
        #expect(tinyRow.canonicalBytes == 10)
        #expect(tinyRow.revisionCount == 0)
        #expect(tinyRow.revisionBytes == 0)

        // §5.6 persistence: both active lanes landed on the singleton.
        let config = try Self.fetchConfigRow(container)
        #expect(config.storagePolicyEnabled == true)
        #expect(config.storageMaxBytes == 40)
        #expect(config.revisionPolicyEnabled == true)
        #expect(config.revisionMaxCount == 1)
    }

    // MARK: - R3 sweep (V2-02 §4.4 PHASE A, §5.5; RET-PERF-2)

    /// A = 30 canonical + [10, 10, 10] (count 3 > 2 prunes the oldest
    /// inactive [rev1] → 2 revisions / 20 bytes); B = 20 + [30, 10] (bytes
    /// 40 > 35 prunes [rev1(30)] → 1 revision / 10 bytes); T = 10 + [5] is
    /// non-exceeding in both dimensions. No R1/R2 lane is active, so the
    /// receipt carries `retiredItems == 0` / `prunedRevisions == 2` and ONE
    /// position advance. The zero-decode law (`RET-PERF-2`) is proven
    /// behaviorally: T's `revisionStateBlob` is corrupted behind the
    /// Authority's back BEFORE the sweep — a lineage decode of T would fail
    /// the whole sweep `.corruptStoredValue` — and T's row and corrupt blob
    /// emerge byte-identical.
    @Test("R3 sweep prunes exceeding items only; non-exceeding lineages are never decoded")
    func r3SweepPrunesExceedingItemsOnlyWithoutDecodingNonExceeding() async throws {
        let storeURL = WSSupport.tempStoreURL("r6-r3-sweep")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let source = "com.example.r6.r3"

        let a = try await Self.capture(
            String(repeating: "a", count: 30), at: 700_605_000,
            source: source, in: history
        )
        try await Self.seedRevisions(a.id, byteCounts: [10, 10, 10], in: history)
        let b = try await Self.capture(
            String(repeating: "b", count: 20), at: 700_605_100,
            source: source, in: history
        )
        try await Self.seedRevisions(b.id, byteCounts: [30, 10], in: history)
        let t = try await Self.capture(
            String(repeating: "t", count: 10), at: 700_605_200,
            source: source, in: history
        )
        try await Self.seedRevisions(t.id, byteCounts: [5], in: history)

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try WSSupport.fetchPosition(container).rawValue == 9)
        let aBefore = try Self.lineage(of: a.id, in: container)
        let aRev1ID = aBefore.item.revisions[0].id
        let aRev2ID = aBefore.item.revisions[1].id
        let aRev3ID = aBefore.item.revisions[2].id
        let bBefore = try Self.lineage(of: b.id, in: container)
        let bRev1ID = bBefore.item.revisions[0].id
        let bRev2ID = bBefore.item.revisions[1].id

        // Corrupt T's revision blob through an INDEPENDENT container (the
        // R.3 fixture stance) — the sweep must never decode it.
        let corruptBlob = Data([0x00])
        let damageContainer = try WSSupport.makeContainer(storeURL: storeURL)
        let damageContext = ModelContext(damageContainer)
        let damageRow = try #require(
            try damageContext.fetch(FetchDescriptor<HistoryItemRow>())
                .first { $0.id == t.id.rawValue }
        )
        damageRow.revisionStateBlob = corruptBlob
        try damageContext.save()

        let receipt = try await history.perform(.setRetentionPolicies(
            HistoryRetentionPolicies(
                age: nil,
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 2, maxRevisionBytesPerItem: 35
                )
            )
        ))
        guard case let .committed(sweepCommit) = receipt else {
            Issue.record("R.6: expected .committed for the sweep, got \(receipt)")
            return
        }
        #expect(sweepCommit.position.rawValue == 10)
        guard case let .retentionPoliciesSet(retiredItems, prunedRevisions) =
            sweepCommit.outcome else {
            Issue.record(
                "R.6: expected .retentionPoliciesSet, got \(sweepCommit.outcome)"
            )
            return
        }
        #expect(retiredItems == 0)
        #expect(prunedRevisions == 2)

        // A: oldest-inactive prefix [rev1] pruned; survivors keep append
        // order; the active (rev3) survives (D3/D23); the projection row
        // restamped to 2 / 20 in the same transaction.
        let aAfter = try Self.lineage(of: a.id, in: container)
        #expect(aAfter.item.revisions.map(\.id) == [aRev2ID, aRev3ID])
        #expect(aAfter.item.activeRevisionID == aRev3ID)
        #expect(!aAfter.item.revisions.map(\.id).contains(aRev1ID))
        #expect(aAfter.item.contentVersion.rawValue == 4)
        let aRow = try #require(try Self.fetchBytesRow(for: a.id, in: container))
        #expect(aRow.canonicalBytes == 30)
        #expect(aRow.revisionCount == 2)
        #expect(aRow.revisionBytes == 20)

        // B: the byte dimension pruned [rev1(30)] (40 → 10 ≤ 35).
        let bAfter = try Self.lineage(of: b.id, in: container)
        #expect(bAfter.item.revisions.map(\.id) == [bRev2ID])
        #expect(bAfter.item.activeRevisionID == bRev2ID)
        #expect(!bAfter.item.revisions.map(\.id).contains(bRev1ID))
        let bRow = try #require(try Self.fetchBytesRow(for: b.id, in: container))
        #expect(bRow.canonicalBytes == 20)
        #expect(bRow.revisionCount == 1)
        #expect(bRow.revisionBytes == 10)

        // T: byte-identical corrupt blob and untouched projection row —
        // zero decodes and zero writes for the non-exceeding item.
        let untouchedRow = try #require(
            try WSSupport.fetchRows(container)
                .first { $0.id == t.id.rawValue }
        )
        #expect(untouchedRow.revisionStateBlob == corruptBlob)
        let tRow = try #require(try Self.fetchBytesRow(for: t.id, in: container))
        #expect(tRow.canonicalBytes == 10)
        #expect(tRow.revisionCount == 1)
        #expect(tRow.revisionBytes == 5)
    }

    // MARK: - R3-then-R2 projection (V2-02 §3.2/§4.4, RET-PRUNE-2)

    /// A (oldest, 30 canonical + [30, 10] revisions = 40 revision bytes)
    /// exceeds the NEW byte threshold 35: PHASE A prunes [rev1(30)],
    /// projecting A to 30 + 10 = 40 footprint. PHASE B then sees
    /// 40 + 10 (T) = 50 ≤ budget 50 — a SATISFIED projected state, so A is
    /// NOT retired. Without the projection R2 would credit A's unpruned
    /// 70 + 10 = 80 > 50 and retire A — silent data loss beyond what the
    /// policy requires (`RET-PRUNE-2`'s discriminator).
    @Test("R3-then-R2 projection: an item whose post-prune bytes fit the budget is not retired")
    func postPruneProjectionPreventsRetiringItemThatFitsAfterPrune() async throws {
        let storeURL = WSSupport.tempStoreURL("r6-prune-then-budget")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let source = "com.example.r6.prune2"

        let prunable = try await Self.capture(
            String(repeating: "a", count: 30), at: 700_606_000,
            source: source, in: history
        )
        try await Self.seedRevisions(prunable.id, byteCounts: [30, 10], in: history)
        let tiny = try await Self.capture(
            String(repeating: "t", count: 10), at: 700_606_100,
            source: source, in: history
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let before = try Self.lineage(of: prunable.id, in: container)
        let rev1ID = before.item.revisions[0].id
        let rev2ID = before.item.revisions[1].id

        let receipt = try await history.perform(.setRetentionPolicies(
            HistoryRetentionPolicies(
                age: nil,
                storage: StorageRetention(maxTotalBytes: 50),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: nil, maxRevisionBytesPerItem: 35
                )
            )
        ))
        guard case let .committed(sweepCommit) = receipt else {
            Issue.record("R.6: expected .committed for the sweep, got \(receipt)")
            return
        }
        #expect(sweepCommit.position.rawValue == 5)
        guard case let .retentionPoliciesSet(retiredItems, prunedRevisions) =
            sweepCommit.outcome else {
            Issue.record(
                "R.6: expected .retentionPoliciesSet, got \(sweepCommit.outcome)"
            )
            return
        }
        // The prune landed; the retirement did not (`RET-PRUNE-2`).
        #expect(retiredItems == 0)
        #expect(prunedRevisions == 1)

        // Both items survive; A carries the pruned lineage and the
        // restamped projection (30 canonical / 1 revision / 10 bytes).
        let survivors = Set(
            try WSSupport.fetchRows(container).map { HistoryItemID(rawValue: $0.id) }
        )
        #expect(survivors == Set([prunable.id, tiny.id]))
        let after = try Self.lineage(of: prunable.id, in: container)
        #expect(after.item.revisions.map(\.id) == [rev2ID])
        #expect(after.item.activeRevisionID == rev2ID)
        #expect(!after.item.revisions.map(\.id).contains(rev1ID))
        let row = try #require(
            try Self.fetchBytesRow(for: prunable.id, in: container)
        )
        #expect(row.canonicalBytes == 30)
        #expect(row.revisionCount == 1)
        #expect(row.revisionBytes == 10)
    }

    // MARK: - PHASE C: DC-27 survivor-scoped veto (V2-02 §4.4, §8.3)

    /// H (30 canonical + one 25-byte ACTIVE revision, footprint 55) has an
    /// active revision alone over the NEW `maxRevisionBytesPerItem` 20; T
    /// (10) completes total 65 under budget 60.
    ///
    /// Unpinned variant: PHASE B retires H (the oldest eligible; 65 − 55 =
    /// 10 ≤ 60) — retirement deletes H and its revisions, so PHASE C never
    /// sees it and the sweep SUCCEEDS (`retiredItems == 1`).
    ///
    /// Pinned variant: H is protected (D13), so PHASE B retires only T
    /// (65 − 10 = 55 ≤ 60 — the budget check passes, isolating PHASE C);
    /// H SURVIVES with a post-prune active alone over the threshold, so the
    /// ENTIRE action fails `.invalidInput(.invalidRetentionPolicy)`
    /// ATOMICALLY: both items present, position unchanged, config still
    /// all-disabled, H's lineage and scalars untouched.
    @Test("DC-27: unpinned heavy item retires without veto; pinned twin triggers the atomic veto")
    func phaseCVetoIsScopedToSurvivorsAndFailsAtomically() async throws {
        // ── Variant A: unpinned — R2 retires H, PHASE C never sees it. ──
        do {
            let storeURL = WSSupport.tempStoreURL("r6-dc27-unpinned")
            defer { WSSupport.removeStore(storeURL) }
            let history = try await WSSupport.openHistory(storeURL: storeURL)
            let source = "com.example.r6.dc27a"

            let heavy = try await Self.capture(
                String(repeating: "h", count: 30), at: 700_607_000,
                source: source, in: history
            )
            try await Self.seedRevisions(heavy.id, byteCounts: [25], in: history)
            let tiny = try await Self.capture(
                String(repeating: "t", count: 10), at: 700_607_100,
                source: source, in: history
            )

            let receipt = try await history.perform(.setRetentionPolicies(
                HistoryRetentionPolicies(
                    age: nil,
                    storage: StorageRetention(maxTotalBytes: 60),
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: nil, maxRevisionBytesPerItem: 20
                    )
                )
            ))
            guard case let .committed(sweepCommit) = receipt else {
                Issue.record("R.6 DC-27 A: expected .committed, got \(receipt)")
                return
            }
            #expect(sweepCommit.position.rawValue == 4)
            guard case let .retentionPoliciesSet(retiredItems, prunedRevisions) =
                sweepCommit.outcome else {
                Issue.record(
                    "R.6 DC-27 A: expected .retentionPoliciesSet, got \(sweepCommit.outcome)"
                )
                return
            }
            #expect(retiredItems == 1)
            #expect(prunedRevisions == 0)

            let container = try WSSupport.makeContainer(storeURL: storeURL)
            let survivors = Set(
                try WSSupport.fetchRows(container).map { HistoryItemID(rawValue: $0.id) }
            )
            #expect(survivors == Set([tiny.id]))
            #expect(try Self.fetchBytesRows(container).count == 1)
        }

        // ── Variant B: pinned — H survives PHASE B, PHASE C vetoes. ──
        do {
            let storeURL = WSSupport.tempStoreURL("r6-dc27-pinned")
            defer { WSSupport.removeStore(storeURL) }
            let history = try await WSSupport.openHistory(storeURL: storeURL)
            let source = "com.example.r6.dc27b"

            let heavy = try await Self.capture(
                String(repeating: "h", count: 30), at: 700_608_000,
                source: source, in: history
            )
            try await Self.seedRevisions(heavy.id, byteCounts: [25], in: history)
            let tiny = try await Self.capture(
                String(repeating: "t", count: 10), at: 700_608_100,
                source: source, in: history
            )
            // Pin mutations do not trigger V2 expansion (V2-02 §7); with one
            // pinned row the lane is exactly 0 ..< 1 (D12).
            let pinReceipt = try await history.perform(.placePinned(heavy.id, at: .last))
            guard case .committed = pinReceipt else {
                Issue.record("R.6 DC-27 B setup: expected the pin to commit, got \(pinReceipt)")
                return
            }

            let container = try WSSupport.makeContainer(storeURL: storeURL)
            #expect(try WSSupport.fetchPosition(container).rawValue == 4)
            let heavyRev1ID = try #require(
                try Self.lineage(of: heavy.id, in: container).item.activeRevisionID
            )

            await #expect(throws: HistoryFailure.invalidInput(.invalidRetentionPolicy)) {
                try await history.perform(.setRetentionPolicies(
                    HistoryRetentionPolicies(
                        age: nil,
                        storage: StorageRetention(maxTotalBytes: 60),
                        revisions: RevisionRetention(
                            maxRevisionsPerItem: nil, maxRevisionBytesPerItem: 20
                        )
                    )
                ))
            }

            // Atomicity (§4.4/§2.2/§8.3): the veto precedes the merge, so
            // NOTHING is durable — no policy, no retirement (T survives
            // even though PHASE B selected it), no prune, no position.
            #expect(try WSSupport.fetchPosition(container).rawValue == 4)
            let survivors = Set(
                try WSSupport.fetchRows(container).map { HistoryItemID(rawValue: $0.id) }
            )
            #expect(survivors == Set([heavy.id, tiny.id]))
            try Self.expectAllDisabledConfig(container)
            let heavyAfter = try Self.lineage(of: heavy.id, in: container)
            #expect(heavyAfter.item.revisions.map(\.id) == [heavyRev1ID])
            #expect(heavyAfter.item.activeRevisionID == heavyRev1ID)
            #expect(heavyAfter.item.contentVersion.rawValue == 2)
            let heavyRow = try #require(
                try Self.fetchBytesRow(for: heavy.id, in: container)
            )
            #expect(heavyRow.canonicalBytes == 30)
            #expect(heavyRow.revisionCount == 1)
            #expect(heavyRow.revisionBytes == 25)
        }
    }

    // MARK: - No-op (V2-02 §4.4/§5.6; v1 WS21 posture)

    /// Setting the value the store already holds, with the state already
    /// satisfying it (two revision-less items under `maxRevisionsPerItem`
    /// 5, no R1/R2 lanes), is a TRUE `.unchanged` — the WS21 receipt shape:
    /// no commit, no position advance (02 §13), no invalidation. The FIRST
    /// set (disabled → P) commits the policy write alone: one position
    /// advance, `retentionPoliciesSet(0, 0)`, the value persisted (§5.6).
    @Test("same-value satisfied state is a true no-op with no commit or advance")
    func sameValueSatisfiedStateIsATrueNoOp() async throws {
        let storeURL = WSSupport.tempStoreURL("r6-noop")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let source = "com.example.r6.noop"

        _ = try await Self.capture(
            "r6 no-op one", at: 700_609_000, source: source, in: history
        )
        _ = try await Self.capture(
            "r6 no-op two", at: 700_609_100, source: source, in: history
        )
        let policies = HistoryRetentionPolicies(
            age: nil,
            storage: nil,
            revisions: RevisionRetention(
                maxRevisionsPerItem: 5, maxRevisionBytesPerItem: nil
            )
        )

        // First set: the value changes (disabled → P) over a satisfied
        // state — the explicit policy write commits alone (§5.6).
        let firstReceipt = try await history.perform(.setRetentionPolicies(policies))
        guard case let .committed(firstCommit) = firstReceipt else {
            Issue.record("R.6: expected .committed for the first set, got \(firstReceipt)")
            return
        }
        #expect(firstCommit.position.rawValue == 3)
        guard case let .retentionPoliciesSet(firstRetired, firstPruned) =
            firstCommit.outcome else {
            Issue.record(
                "R.6: expected .retentionPoliciesSet, got \(firstCommit.outcome)"
            )
            return
        }
        #expect(firstRetired == 0)
        #expect(firstPruned == 0)

        // Same value, satisfied state: the WS21-shaped `.unchanged` — no
        // commit, no position advance, no invalidation (§4.4/§5.6).
        let noOpReceipt = try await history.perform(.setRetentionPolicies(policies))
        guard case .unchanged = noOpReceipt else {
            Issue.record(
                "R.6 no-op: expected .unchanged (the WS21 shape), got \(noOpReceipt)"
            )
            return
        }
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try WSSupport.fetchPosition(container).rawValue == 3)
        #expect(try WSSupport.fetchRows(container).count == 2)
        let config = try Self.fetchConfigRow(container)
        #expect(config.revisionPolicyEnabled == true)
        #expect(config.revisionMaxCount == 5)
    }

    // MARK: - Config persistence across reopen (V2-02 §3.3/§5.6)

    /// A successful sweep persists exactly the new policies on the config
    /// singleton (`configSchemaVersion` stays 1); a fresh `open` over the
    /// same store reads them back — proven both through the row (the
    /// independent-container fetch) and behaviorally (re-setting the same
    /// value through the REOPENED facade is `.unchanged`, which only a
    /// store enforcing exactly those policies produces). All-disabled
    /// policies persist identically.
    @Test("successful sweep persists exact policies; all-disabled persists too")
    func configPersistsExactlyAcrossReopenIncludingAllDisabled() async throws {
        // ── Mixed lanes. ──
        do {
            let storeURL = WSSupport.tempStoreURL("r6-persist-mixed")
            defer { WSSupport.removeStore(storeURL) }
            let history = try await WSSupport.openHistory(storeURL: storeURL)

            let policies = HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 3_600),
                storage: StorageRetention(maxTotalBytes: 4_096),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 2, maxRevisionBytesPerItem: 2_048
                )
            )
            let receipt = try await history.perform(.setRetentionPolicies(policies))
            guard case let .committed(commit) = receipt,
                  case let .retentionPoliciesSet(retired, pruned) = commit.outcome else {
                Issue.record("R.6: expected a committed sweep, got \(receipt)")
                return
            }
            // Empty store: the policy write alone advances the position once.
            #expect(commit.position.rawValue == 1)
            #expect(retired == 0)
            #expect(pruned == 0)

            let container = try WSSupport.makeContainer(storeURL: storeURL)
            let config = try Self.fetchConfigRow(container)
            #expect(config.agePolicyEnabled == true)
            #expect(config.ageMaxSeconds == 3_600)
            #expect(config.storagePolicyEnabled == true)
            #expect(config.storageMaxBytes == 4_096)
            #expect(config.revisionPolicyEnabled == true)
            #expect(config.revisionMaxCount == 2)
            #expect(config.revisionMaxBytes == 2_048)
            #expect(config.configSchemaVersion == 1)

            // Reopen: the durable row rules; re-setting the same value is a
            // true no-op through the REOPENED facade (position unchanged).
            let reopened = try await WSSupport.openHistory(storeURL: storeURL)
            let reopenedReceipt = try await reopened.perform(
                .setRetentionPolicies(policies)
            )
            guard case .unchanged = reopenedReceipt else {
                Issue.record(
                    "R.6: expected .unchanged after reopen, got \(reopenedReceipt)"
                )
                return
            }
            let reopenContainer = try WSSupport.makeContainer(storeURL: storeURL)
            #expect(try WSSupport.fetchPosition(reopenContainer).rawValue == 1)
        }

        // ── All-disabled lanes persist too. ──
        do {
            let storeURL = WSSupport.tempStoreURL("r6-persist-disabled")
            defer { WSSupport.removeStore(storeURL) }
            let history = try await WSSupport.openHistory(storeURL: storeURL)

            // Enable something first, then disable every lane: the second
            // sweep's write normalizes each disabled lane to the dormant
            // zeroed shape (§5.6).
            _ = try await history.perform(.setRetentionPolicies(
                HistoryRetentionPolicies(
                    age: AgeRetention(maxAge: 60),
                    storage: StorageRetention(maxTotalBytes: 1_024),
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: 3, maxRevisionBytesPerItem: 512
                    )
                )
            ))
            let disabled = HistoryRetentionPolicies(
                age: nil, storage: nil, revisions: nil
            )
            let receipt = try await history.perform(.setRetentionPolicies(disabled))
            guard case let .committed(commit) = receipt else {
                Issue.record("R.6: expected .committed for the disable sweep, got \(receipt)")
                return
            }
            #expect(commit.position.rawValue == 2)

            _ = try await WSSupport.openHistory(storeURL: storeURL)
            let container = try WSSupport.makeContainer(storeURL: storeURL)
            try Self.expectAllDisabledConfig(container)
        }
    }
}
