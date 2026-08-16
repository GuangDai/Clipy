/// R.5 — revise-composition proofs (`V2-roadmap` §6 R.5 "Revise
/// composition": v1 two-phase preparation/recheck unchanged; when R2 or R3
/// is active, recompute the prune over the reloaded lineage, check the hard
/// bounds on the POST-PRUNE POST-APPEND state, plan R2 over the projected
/// post-append store, and commit ONE merged plan/position with the prune
/// folded into the append's single blob write).
///
/// Owning spec: `V2-02` §4.3 (the authoritative revise pseudocode and its
/// phase-2 policy re-read, prune recomputation, projected R2 inventory,
/// `protected` = pinned ∪ {revised item}, and merge order), §5.1/§5.4 (the
/// prune relation; the ordering rule — prune computed BEFORE the per-item
/// hard-bound check, `maxRevisionsPerItem == hard bound` is a no-op for
/// every state below the bound), §6.3 (compose-with-append: ONE blob write,
/// ONE ContentVersion successor; retire-subsumes-prune never arises on
/// revise, §7), §6.5 (`.revise(appended:)`), §7 (revise fires R2+R3 ONLY —
/// an R1-only config takes the exact v1 route), §8.3 (revise-time
/// unsatisfiable → `.capacityExceeded(.revisionBytes)` atomic; R2
/// irreducible → `.capacityExceeded(.storageBytes)`), §11 D24; Record 3
/// gates `RET-STAMP-1` (one stamped write for the revised item),
/// `RET-PLATFORM-3b` (the composed blob round-trips through the unchanged
/// v1 codec), `RET-CONCUR-1` (the R3-flavored stale interleaving).
///
/// Every public-path fixture crosses `SwiftDataHistory.perform(.revise)`
/// (the real two-phase flow: `revisionPreparationInputs` → the V2-extended
/// `RevisionPreparationActor.prepare` → `commitRevision`'s composition),
/// seeds policies by writing the `RetentionExpansionConfigRow` through an
/// INDEPENDENT container (`WSSupport.seedRetentionConfig` — behind the
/// Authority's back, the R.3/R.4 fixture stance, because the production
/// `.setRetentionPolicies` writer is the R.6 slice), and asserts rows/
/// position/projection through that same independent container. The
/// hard-bound ordering fixture (§5.4) drives the directly constructed
/// `RevisionPreparationActor` with injected limits — the
/// `RevisionPreparationCapacityTests` seam — because the public path pins
/// `HistoryLimits.standard`; the stale-interleaving fixture drives a
/// directly constructed Authority with the WS20 `SuspensionGate` harness.
///
/// Hand-worked fixture values (single-representation ASCII text: one
/// `public.utf8-plain-text` representation, so a revision's representation
/// bytes equal its UTF-8 length, and an item's `canonicalBytes` equals the
/// capture text's UTF-8 length; times are `timeIntervalSinceReferenceDate`
/// seconds):
/// - "r5 target base" — 14 canonical bytes (2 + 1 + 6 + 1 + 4);
/// - fixed-length revision payloads (e.g. `String(repeating: "a", count:
///   17)`) — 17/18/19/20/26/15/30/8/10/5 representation bytes each;
/// - R2 footprints (canonicalBytes + revisionBytes): A = 30 + 0, B = 10 + 0,
///   T = 5 + 20 projected, P = 30 + 0 pinned.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Retention revise composition (R.5)")
struct RetentionReviseCompositionTests {

    // MARK: - Fixtures

    /// Performs one raw text capture and returns the inserted reference.
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
            Issue.record("R.5 setup: expected .committed with .inserted, got \(receipt)")
            throw HistoryFailure.notFound(HistoryItemID(rawValue: UUID()))
        }
        return reference
    }

    /// A byte-changing `.replace` revision request for the single
    /// `public.utf8-plain-text` representation, OCC-tokened at `expected`.
    private static func replaceRequest(
        itemID: HistoryItemID,
        expected: ContentVersion,
        bytes: Int
    ) -> RevisionRequest {
        RevisionRequest(
            itemID: itemID,
            expected: expected,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: "public.utf8-plain-text",
                    action: .replace(
                        bytes: Data(String(repeating: "r", count: bytes).utf8)
                    )
                ),
            ]))
        )
    }

    /// Performs one public revise appending `bytes` representation bytes at
    /// `expected`, asserting the `.revised` outcome shape.
    private static func revise(
        _ itemID: HistoryItemID,
        expected: Int,
        bytes: Int,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.revise(
            Self.replaceRequest(
                itemID: itemID,
                expected: ContentVersion(rawValue: expected),
                bytes: bytes
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .revised(reference) = commit.outcome else {
            Issue.record("R.5 setup: expected .committed with .revised, got \(receipt)")
            throw HistoryFailure.notFound(itemID)
        }
        return reference
    }

    /// The reloaded revision lineage of `itemID` through the production
    /// fact loader (05 §7.3: exactly the target item), over the independent
    /// assertion container.
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

    /// Appends revisions of the given byte counts to `itemID` through the
    /// public path (v1 configs are all-disabled during seeding, so the
    /// store reaches the pre-fixture lineage untouched).
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

    // MARK: - R3 count prune on revise (V2-02 §4.3, §5.1, §6.3; RET-STAMP-1)

    /// An item at 3 revisions under `maxRevisionsPerItem = 3` appending a
    /// 4th prunes the oldest inactive in the SAME commit: the effective
    /// list [rev1(17), rev2(18), rev3(19), rev4(20)] holds count 4 > 3, so
    /// the shortest oldest-inactive prefix is [rev1] — survivors
    /// [rev2, rev3, rev4]. ONE commit: one position advance (4 → 5), ONE
    /// ContentVersion successor (4 → 5, `RET-STAMP-1`'s single
    /// `contentVersionRaw` write), survivor order preserved, the appended
    /// revision active, and the stored blob decodes to EXACTLY
    /// survivors + [appended] (`RET-PLATFORM-3b`: the composed
    /// `(loaded \ removed) + [appended]` shape round-trips the unchanged
    /// v1 codec — one write, asserted on the decoded FINAL state). The
    /// projection row carries the post-prune post-append scalars (3 / 57 =
    /// 18 + 19 + 20).
    @Test("R3 count prune on revise: one commit, one position, one version successor, folded blob")
    func countPruneFoldsIntoOneCommitWithFoldedBlob() async throws {
        let storeURL = WSSupport.tempStoreURL("r5-count-prune")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let target = try await Self.capture(
            "r5 target base", at: 700_400_000, source: "com.example.r5.count",
            in: history
        )
        try await Self.seedRevisions(
            target.id, byteCounts: [17, 18, 19], in: history
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            revisions: RevisionRetention(
                maxRevisionsPerItem: 3,
                maxRevisionBytesPerItem: nil
            )
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let before = try Self.lineage(of: target.id, in: container)
        #expect(before.item.revisions.count == 3)
        #expect(before.item.contentVersion.rawValue == 4)
        let rev1ID = before.item.revisions[0].id
        let rev2ID = before.item.revisions[1].id
        let rev3ID = before.item.revisions[2].id
        let positionBefore = try WSSupport.fetchPosition(container).rawValue
        #expect(positionBefore == 4)

        let reference = try await Self.revise(
            target.id, expected: 4, bytes: 20, in: history
        )
        // ONE ContentVersion successor for the whole composed plan.
        #expect(reference.contentVersion.rawValue == 5)

        let after = try Self.lineage(of: target.id, in: container)
        // ONE position advance (D6/D24(a)); one `.revised` receipt.
        #expect(try WSSupport.fetchPosition(container).rawValue == 5)
        // Survivor order preserved (§5.2: pruning never reorders), the
        // appended revision (the lineage's new last) active, the oldest
        // inactive gone.
        let survivors = after.item.revisions
        let appendedID = try #require(survivors.last?.id)
        #expect(survivors.count == 3)
        #expect(survivors.dropLast().map(\.id) == [rev2ID, rev3ID])
        #expect(!survivors.map(\.id).contains(rev1ID))
        #expect(after.item.activeRevisionID == appendedID)
        // Canonical Content and the item's identity are untouched (D2/D5);
        // the decoded FINAL blob is exactly survivors + [appended].
        let itemRow = try #require(
            try WSSupport.fetchRows(container)
                .first { $0.id == target.id.rawValue }
        )
        let canonical = try CanonicalBlobCodec.decode(itemRow.canonicalBlob)
        let decoded = try RevisionStateBlobCodec.decode(
            itemRow.revisionStateBlob,
            canonical: canonical
        )
        #expect(decoded.revisions.count == 3)
        #expect(decoded.revisions.dropLast().map(\.id) == [rev2ID, rev3ID])
        #expect(decoded.revisions.last?.id == appendedID)
        #expect(decoded.activeRevisionID == appendedID)
        #expect(!decoded.revisions.map(\.id).contains(rev1ID))
        #expect(itemRow.contentVersionRaw == 5)

        // The projection row restamped in the same transaction (§3.3b/§6.3):
        // post-prune post-append scalars 3 revisions / 57 bytes, canonical
        // bytes untouched (14).
        let row = try #require(try Self.fetchBytesRow(for: target.id, in: container))
        #expect(row.revisionCount == 3)
        #expect(row.revisionBytes == 57)
        #expect(row.canonicalBytes == 14)
        #expect(row.bytesSchemaVersion == 1)
    }

    // MARK: - R3 bytes prune on revise (V2-02 §5.1)

    /// The byte dimension: [rev1(26), rev2(18)] under
    /// `maxRevisionBytesPerItem = 40` appending rev3(10) projects
    /// 26 + 18 + 10 = 54 > 40, so the oldest-inactive prefix stops after
    /// rev1: 18 + 10 = 28 ≤ 40. Survivors [rev2, rev3]; scalars 2 / 28.
    @Test("R3 bytes prune on revise trims oldest inactive until under the byte threshold")
    func bytesPruneTrimsOldestInactiveUntilUnderThreshold() async throws {
        let storeURL = WSSupport.tempStoreURL("r5-bytes-prune")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let target = try await Self.capture(
            "r5 target base", at: 700_401_000, source: "com.example.r5.bytes",
            in: history
        )
        try await Self.seedRevisions(
            target.id, byteCounts: [26, 18], in: history
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            revisions: RevisionRetention(
                maxRevisionsPerItem: nil,
                maxRevisionBytesPerItem: 40
            )
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let before = try Self.lineage(of: target.id, in: container)
        let rev1ID = before.item.revisions[0].id
        let rev2ID = before.item.revisions[1].id

        let reference = try await Self.revise(
            target.id, expected: 3, bytes: 10, in: history
        )
        #expect(reference.contentVersion.rawValue == 4)

        let after = try Self.lineage(of: target.id, in: container)
        #expect(after.item.revisions.count == 2)
        #expect(after.item.revisions.first?.id == rev2ID)
        #expect(!after.item.revisions.map(\.id).contains(rev1ID))
        #expect(after.item.activeRevisionID == after.item.revisions.last?.id)
        let row = try #require(try Self.fetchBytesRow(for: target.id, in: container))
        #expect(row.revisionCount == 2)
        #expect(row.revisionBytes == 28)
    }

    /// Both thresholds jointly bound the FULL retained set (§5.1: the
    /// shortest prefix satisfying BOTH): [rev1(30), rev2(15)] under
    /// `maxRevisionsPerItem = 2` AND `maxRevisionBytesPerItem = 20`
    /// appending rev3(8) — count alone stops after rev1 (count 2 ≤ 2), but
    /// bytes 15 + 8 = 23 > 20 keep the walk going through rev2, ending at
    /// [rev3] alone (count 1, bytes 8). Count-alone pruning would have left
    /// [rev2, rev3] at 23 bytes — still over the byte threshold.
    @Test("R3 both thresholds: the byte dimension forces pruning past the count dimension")
    func bothThresholdsPruneUntilBothSatisfied() async throws {
        let storeURL = WSSupport.tempStoreURL("r5-both-thresholds")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let target = try await Self.capture(
            "r5 target base", at: 700_402_000, source: "com.example.r5.both",
            in: history
        )
        try await Self.seedRevisions(
            target.id, byteCounts: [30, 15], in: history
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            revisions: RevisionRetention(
                maxRevisionsPerItem: 2,
                maxRevisionBytesPerItem: 20
            )
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let before = try Self.lineage(of: target.id, in: container)
        let rev1ID = before.item.revisions[0].id
        let rev2ID = before.item.revisions[1].id

        let reference = try await Self.revise(
            target.id, expected: 3, bytes: 8, in: history
        )
        #expect(reference.contentVersion.rawValue == 4)

        let after = try Self.lineage(of: target.id, in: container)
        // Count alone would have stopped after rev1 (count 2 ≤ 2); the byte
        // threshold forced the walk through rev2, leaving the appended
        // revision alone (count 1, bytes 8).
        #expect(after.item.revisions.count == 1)
        #expect(after.item.activeRevisionID == after.item.revisions.last?.id)
        #expect(!after.item.revisions.map(\.id).contains(rev1ID))
        #expect(!after.item.revisions.map(\.id).contains(rev2ID))
        let row = try #require(try Self.fetchBytesRow(for: target.id, in: container))
        #expect(row.revisionCount == 1)
        #expect(row.revisionBytes == 8)
    }

    // MARK: - Threshold equal to the hard bound (V2-02 §5.4/§2.1)

    /// `maxRevisionsPerItem = 100` equals the v1 hard bound
    /// (`HistoryLimits.standard.maximumRevisionsPerItem`), so R3 is a no-op
    /// for the count dimension on every state below the bound (§2.1): an
    /// item at 2 revisions appending a 3rd reaches effective count 3 ≤ 100,
    /// prunes NOTHING, and lands exactly as v1 would — the full lineage
    /// survives and the scalars grow by the append alone.
    @Test("maxRevisionsPerItem equal to the hard bound prunes nothing below the bound")
    func thresholdEqualToHardBoundIsNoOpBelowTheBound() async throws {
        let storeURL = WSSupport.tempStoreURL("r5-hardbound-noop")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let target = try await Self.capture(
            "r5 target base", at: 700_403_000, source: "com.example.r5.noop",
            in: history
        )
        try await Self.seedRevisions(
            target.id, byteCounts: [17, 18], in: history
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            revisions: RevisionRetention(
                maxRevisionsPerItem: HistoryLimits.standard.maximumRevisionsPerItem,
                maxRevisionBytesPerItem: nil
            )
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let before = try Self.lineage(of: target.id, in: container)
        let rev1ID = before.item.revisions[0].id
        let rev2ID = before.item.revisions[1].id

        let reference = try await Self.revise(
            target.id, expected: 3, bytes: 19, in: history
        )
        #expect(reference.contentVersion.rawValue == 4)

        let after = try Self.lineage(of: target.id, in: container)
        // No prune: the full lineage survives, order preserved, the appended
        // revision (the new last) active.
        #expect(after.item.revisions.count == 3)
        #expect(after.item.revisions.dropLast().map(\.id) == [rev1ID, rev2ID])
        #expect(after.item.activeRevisionID == after.item.revisions.last?.id)
        let row = try #require(try Self.fetchBytesRow(for: target.id, in: container))
        #expect(row.revisionCount == 3)
        #expect(row.revisionBytes == 54)
    }

    // MARK: - Hard-bound interaction: the ordering rule's discriminator
    //           (V2-02 §5.4, Record 2's conditionally-extended 05 §6.2)

    /// A smaller `HistoryLimits` profile at the `RevisionPreparationActor`
    /// seam (the `RevisionPreparationCapacityTests` stance — the public
    /// path pins `.standard`): with `maximumRevisionsPerItem = 3` and a
    /// 3-revision lineage, an append that v1 rejects
    /// `.capacityExceeded(.revisionCount)` LANDS when R3's threshold equals
    /// the hard bound, because the prune set is computed BEFORE the
    /// hard-bound check and the check sees the POST-PRUNE POST-APPEND
    /// state (2 survivors + the append = 3 ≤ 3). The hard bound is never
    /// relaxed — it still bounds the post-prune state (§5.4: "R3 never
    /// relaxes the hard bound; it only prunes below the user threshold
    /// first").
    @Test("append rejected at the hard bound without R3 lands with R3 pruning first")
    func hardBoundRejectsWithoutR3ButLandsWithR3PruningFirst() async throws {
        let typeIdentifier = "public.utf8-plain-text"
        let canonical = try CanonicalContent(representations: [
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: typeIdentifier,
                    bytes: Data("canonical".utf8)
                ),
                fingerprint: ContentFingerprint(rawValue: 1)
            ),
        ])
        let revisionBytes = 8
        let revisions = (0 ..< 3).map { index in
            ContentRevision(
                id: RevisionID(
                    rawValue: UUID(uuidString: String(
                        format: "00000000-0000-0000-0000-00000000002%d", index
                    ))!
                ),
                createdAt: Date(timeIntervalSinceReferenceDate: 700_404_000 + index),
                content: EffectiveContent(representations: [
                    ContentRepresentation(
                        typeIdentifier: typeIdentifier,
                        bytes: Data(repeating: 0x61, count: revisionBytes)
                    ),
                ])
            )
        }
        let itemID = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        )
        let request = RevisionRequest(
            itemID: itemID,
            expected: .initial,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: typeIdentifier,
                    action: .replace(
                        bytes: Data(repeating: 0x62, count: revisionBytes)
                    )
                ),
            ]))
        )
        let snapshot = RevisionPreparationSnapshot(
            canonical: canonical,
            revisions: revisions,
            activeRevisionID: revisions.last?.id,
            contentVersion: .initial
        )
        let preparation = RevisionPreparationActor(limits: HistoryLimits(
            maximumRepresentationsPerCaptureOrRevision: 32,
            maximumTypeIdentifierUTF8Bytes: 512,
            maximumRepresentationBytes: 64 * 1_048_576,
            maximumCaptureBytes: 128 * 1_048_576,
            maximumProposedRevisionBytes: 64 * 1_048_576,
            maximumRevisionsPerItem: 3,
            maximumTotalRevisionBytesPerItem: 256 * 1_048_576,
            hardMaximumRetainedItems: 5_000,
            userMaximumUnpinnedLowerBound: 1,
            userMaximumUnpinnedUpperBound: 5_000,
            defaultMaximumUnpinnedItems: 200,
            maximumSourceApplicationObservationUTF8Bytes: 1_024,
            maximumStoredTitleUTF8Bytes: 1_024,
            maximumStoredSearchBodyUTF8Bytes: 256 * 1_024,
            pageRowLimitLowerBound: 1,
            pageRowLimitUpperBound: 500,
            maximumSearchTermUTF8Bytes: 4_096,
            maximumRegexpPatternCharacters: 512,
            maximumFuzzyQueryCharacters: 64,
            maximumFuzzyTitleBodyPrefixCharacters: 5_000,
            maximumRegexpTitleBodyPrefixCharacters: 1_000,
            maximumBodySearchSnippetCharacters: 322,
            thumbnailDimensionLowerBound: 1,
            thumbnailDimensionUpperBound: 2_048,
            maximumEncodedThumbnailBytes: 16 * 1_048_576
        )!)

        // v1 (no policies): the loaded count already equals the hard bound,
        // so the append is rejected exactly as v1 (§5.4's concrete example).
        await #expect(throws: HistoryFailure.capacityExceeded(.revisionCount)) {
            _ = try await preparation.prepare(request, from: snapshot)
        }

        // V2 (R3 threshold == the hard bound): the effective count 4 > 3
        // prunes the oldest inactive first; the hard-bound check then sees
        // the post-prune post-append count 3 ≤ 3 and the append prepares.
        let bundle = try await preparation.prepare(
            request,
            from: snapshot,
            retentionPolicies: HistoryRetentionPolicies(
                age: nil,
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 3,
                    maxRevisionBytesPerItem: nil
                )
            )
        )
        #expect(bundle.domain.basedOn == snapshot.contentVersion)
    }

    /// The byte-dimension flavor of the same ordering rule: with
    /// `maximumTotalRevisionBytesPerItem = 20`, a lineage [rev1(15),
    /// rev2(5)] plus an 8-byte proposal totals 28 > 20 — v1 rejects
    /// `.capacityExceeded(.revisionBytes)`, while R3 at the same 20-byte
    /// threshold prunes rev1 first (28 − 15 = 13 ≤ 20) and the append
    /// prepares over the post-prune state.
    @Test("byte hard bound rejects without R3 and admits with R3 at the same threshold")
    func byteHardBoundRejectsWithoutR3ButAdmitsWithR3() async throws {
        let typeIdentifier = "public.utf8-plain-text"
        let canonical = try CanonicalContent(representations: [
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: typeIdentifier,
                    bytes: Data("canonical".utf8)
                ),
                fingerprint: ContentFingerprint(rawValue: 1)
            ),
        ])
        let older = ContentRevision(
            id: RevisionID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_405_000),
            content: EffectiveContent(representations: [
                ContentRepresentation(
                    typeIdentifier: typeIdentifier,
                    bytes: Data(repeating: 0x61, count: 15)
                ),
            ])
        )
        let active = ContentRevision(
            id: RevisionID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_405_100),
            content: EffectiveContent(representations: [
                ContentRepresentation(
                    typeIdentifier: typeIdentifier,
                    bytes: Data(repeating: 0x61, count: 5)
                ),
            ])
        )
        let itemID = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        )
        let request = RevisionRequest(
            itemID: itemID,
            expected: .initial,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: typeIdentifier,
                    action: .replace(bytes: Data(repeating: 0x62, count: 8))
                ),
            ]))
        )
        let snapshot = RevisionPreparationSnapshot(
            canonical: canonical,
            revisions: [older, active],
            activeRevisionID: active.id,
            contentVersion: .initial
        )
        let preparation = RevisionPreparationActor(limits: HistoryLimits(
            maximumRepresentationsPerCaptureOrRevision: 32,
            maximumTypeIdentifierUTF8Bytes: 512,
            maximumRepresentationBytes: 20,
            maximumCaptureBytes: 128 * 1_048_576,
            maximumProposedRevisionBytes: 20,
            maximumRevisionsPerItem: 100,
            maximumTotalRevisionBytesPerItem: 20,
            hardMaximumRetainedItems: 5_000,
            userMaximumUnpinnedLowerBound: 1,
            userMaximumUnpinnedUpperBound: 5_000,
            defaultMaximumUnpinnedItems: 200,
            maximumSourceApplicationObservationUTF8Bytes: 1_024,
            maximumStoredTitleUTF8Bytes: 1_024,
            maximumStoredSearchBodyUTF8Bytes: 256 * 1_024,
            pageRowLimitLowerBound: 1,
            pageRowLimitUpperBound: 500,
            maximumSearchTermUTF8Bytes: 4_096,
            maximumRegexpPatternCharacters: 512,
            maximumFuzzyQueryCharacters: 64,
            maximumFuzzyTitleBodyPrefixCharacters: 5_000,
            maximumRegexpTitleBodyPrefixCharacters: 1_000,
            maximumBodySearchSnippetCharacters: 322,
            thumbnailDimensionLowerBound: 1,
            thumbnailDimensionUpperBound: 2_048,
            maximumEncodedThumbnailBytes: 16 * 1_048_576
        )!)

        await #expect(throws: HistoryFailure.capacityExceeded(.revisionBytes)) {
            _ = try await preparation.prepare(request, from: snapshot)
        }

        let bundle = try await preparation.prepare(
            request,
            from: snapshot,
            retentionPolicies: HistoryRetentionPolicies(
                age: nil,
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: nil,
                    maxRevisionBytesPerItem: 20
                )
            )
        )
        #expect(bundle.domain.basedOn == snapshot.contentVersion)
    }

    // MARK: - Revise-time unsatisfiable (V2-02 §4.3/§8.3, atomic)

    /// The appended now-active revision alone exceeds
    /// `maxRevisionBytesPerItem`: [rev1(5)] + the 20-byte append projects 25
    /// over the 10-byte threshold, pruning rev1 (the only inactive) still
    /// leaves 20 > 10, and the active can never be pruned (D3) — the prune
    /// relation is unsatisfiable at revise time. The revise fails
    /// `.capacityExceeded(.revisionBytes)` ATOMICALLY (phase 1 rejects
    /// before any Authority entry; nothing durable changes): same position,
    /// same lineage [rev1] with rev1 active, same version, same scalars.
    @Test("revise-time unsatisfiable active-alone over threshold fails atomically")
    func reviseTimeUnsatisfiableFailsAtomically() async throws {
        let storeURL = WSSupport.tempStoreURL("r5-unsatisfiable")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let target = try await Self.capture(
            "r5 target base", at: 700_406_000, source: "com.example.r5.unsat",
            in: history
        )
        try await Self.seedRevisions(target.id, byteCounts: [5], in: history)
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            revisions: RevisionRetention(
                maxRevisionsPerItem: nil,
                maxRevisionBytesPerItem: 10
            )
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let before = try Self.lineage(of: target.id, in: container)
        let rev1ID = try #require(before.item.activeRevisionID)
        let positionBefore = try WSSupport.fetchPosition(container).rawValue
        #expect(positionBefore == 2)

        await #expect(throws: HistoryFailure.capacityExceeded(.revisionBytes)) {
            _ = try await history.perform(.revise(Self.replaceRequest(
                itemID: target.id,
                expected: ContentVersion(rawValue: 2),
                bytes: 20
            )))
        }

        // Atomicity (§2.2/§8.3): the revise commits nothing — same position,
        // same single-revision lineage with rev1 still active, same version,
        // same projection scalars.
        let after = try Self.lineage(of: target.id, in: container)
        #expect(after.item.revisions.map(\.id) == [rev1ID])
        #expect(after.item.activeRevisionID == rev1ID)
        #expect(after.item.contentVersion.rawValue == 2)
        #expect(try WSSupport.fetchPosition(container).rawValue == positionBefore)
        let row = try #require(try Self.fetchBytesRow(for: target.id, in: container))
        #expect(row.revisionCount == 1)
        #expect(row.revisionBytes == 5)
    }

    // MARK: - R2 at revise (V2-02 §4.3, §8.3, D24)

    /// The projected post-append bytes over budget retire the oldest
    /// unpinned OTHER items, never the revised item, and stop as soon as
    /// the budget is restored: A(30 B, t=…000), T(5 B canonical, t=…050),
    /// B(10 B, t=…100), `maxTotalBytes = 45`; revising T by +20 revision
    /// bytes projects A 30 + T 25 + B 10 = 65 > 45 → retire A (the oldest
    /// eligible) → 35 ≤ 45 → stop. B survives (retiring it too would
    /// over-retire), T survives as the protected primary (plan invariant 7),
    /// and T's revision lands with its projection row restamped to the
    /// post-append value (5 canonical + 20 revision bytes).
    @Test("R2 at revise retires oldest unpinned others, never the revised item")
    func r2AtReviseRetiresOldestOthersUntilBudgetRestored() async throws {
        let storeURL = WSSupport.tempStoreURL("r5-r2-retire")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let a = try await Self.capture(
            String(repeating: "a", count: 30), at: 700_407_000,
            source: "com.example.r5.r2", in: history
        )
        let target = try await Self.capture(
            String(repeating: "t", count: 5), at: 700_407_050,
            source: "com.example.r5.r2", in: history
        )
        let b = try await Self.capture(
            String(repeating: "b", count: 10), at: 700_407_100,
            source: "com.example.r5.r2", in: history
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 45)
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let positionBefore = try WSSupport.fetchPosition(container).rawValue
        #expect(positionBefore == 3)

        let reference = try await Self.revise(
            target.id, expected: 1, bytes: 20, in: history
        )
        #expect(reference.id == target.id)
        #expect(reference.contentVersion.rawValue == 2)

        // ONE merged commit (D6/D24(a)); A retired with its projection row,
        // B and the revised T surviving.
        #expect(try WSSupport.fetchPosition(container).rawValue == 4)
        let survivors = Set(
            try WSSupport.fetchRows(container).map { HistoryItemID(rawValue: $0.id) }
        )
        #expect(survivors == Set([b.id, target.id]))
        #expect(!survivors.contains(a.id))
        #expect(try Self.fetchBytesRows(container).count == 2)
        // T's row: post-append revision scalars over the §3.2 projection.
        let row = try #require(try Self.fetchBytesRow(for: target.id, in: container))
        #expect(row.canonicalBytes == 5)
        #expect(row.revisionCount == 1)
        #expect(row.revisionBytes == 20)
        // B's row is untouched by the revision (its own stored scalars).
        let bRow = try #require(try Self.fetchBytesRow(for: b.id, in: container))
        #expect(bRow.canonicalBytes == 10)
        #expect(bRow.revisionCount == 0)
        #expect(bRow.revisionBytes == 0)
    }

    /// Pinned bytes ∪ revised-item bytes are irreducible (D13 for pinned;
    /// plan invariant 7 for the primary): the pinned P(30) plus the revised
    /// T(5 canonical + 20 revision = 25 projected) total 55 > 50 under
    /// `maxTotalBytes = 50`, so the revise fails
    /// `.capacityExceeded(.storageBytes)` (§8.3, D24(c)) BEFORE anything is
    /// stamped or transacted — the store is unchanged.
    @Test("pinned plus revised irreducible over budget fails storageBytes atomically")
    func pinnedPlusRevisedIrreducibleFailsClosedAtomically() async throws {
        let storeURL = WSSupport.tempStoreURL("r5-r2-irreducible")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let pinned = try await Self.capture(
            String(repeating: "p", count: 30), at: 700_408_000,
            source: "com.example.r5.pin", in: history
        )
        let target = try await Self.capture(
            String(repeating: "t", count: 5), at: 700_408_050,
            source: "com.example.r5.pin", in: history
        )
        // Pin mutations do not trigger V2 expansion (V2-02 §7).
        let pinReceipt = try await history.perform(.placePinned(pinned.id, at: .last))
        guard case .committed = pinReceipt else {
            Issue.record("R.5 setup: expected the pin to commit, got \(pinReceipt)")
            return
        }
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 50)
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let positionBefore = try WSSupport.fetchPosition(container).rawValue
        #expect(positionBefore == 3)

        await #expect(throws: HistoryFailure.capacityExceeded(.storageBytes)) {
            _ = try await history.perform(.revise(Self.replaceRequest(
                itemID: target.id,
                expected: ContentVersion(rawValue: 1),
                bytes: 20
            )))
        }

        // Atomic (§8.3/§2.2): the revise did not land — same position, both
        // items present, T still at version 1 with no revisions.
        #expect(try WSSupport.fetchPosition(container).rawValue == positionBefore)
        let survivors = Set(
            try WSSupport.fetchRows(container).map { HistoryItemID(rawValue: $0.id) }
        )
        #expect(survivors == Set([pinned.id, target.id]))
        #expect(try Self.fetchBytesRows(container).count == 2)
        let after = try Self.lineage(of: target.id, in: container)
        #expect(after.item.revisions.isEmpty)
        #expect(after.item.contentVersion.rawValue == 1)
        let row = try #require(try Self.fetchBytesRow(for: target.id, in: container))
        #expect(row.revisionCount == 0)
        #expect(row.revisionBytes == 0)
    }

    // MARK: - R1-only config: revise is exactly v1 (V2-02 §4.3/§7)

    /// An R1-only config (age lane alone) takes the exact v1 revise route:
    /// the over-age item A is NOT retired (§7: R1 does not fire on revise —
    /// a revision does not change `lastCopiedAt`) and the target's lineage
    /// grows by exactly the append with NO prune (no R3 lane is active, so
    /// no expansion work runs at all).
    @Test("R1-only config: revise is exact v1 — no prune, no retirement")
    func r1OnlyConfigLeavesReviseExactlyV1() async throws {
        let storeURL = WSSupport.tempStoreURL("r5-r1-only")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let aged = try await Self.capture(
            String(repeating: "a", count: 30), at: 700_409_000,
            source: "com.example.r5.r1", in: history
        )
        let target = try await Self.capture(
            "r5 target base", at: 700_409_050,
            source: "com.example.r5.r1", in: history
        )
        try await Self.seedRevisions(target.id, byteCounts: [17], in: history)
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            age: AgeRetention(maxAge: 100)
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let positionBefore = try WSSupport.fetchPosition(container).rawValue
        #expect(positionBefore == 3)
        let before = try Self.lineage(of: target.id, in: container)
        let rev1ID = before.item.revisions[0].id

        let reference = try await Self.revise(
            target.id, expected: 2, bytes: 18, in: history
        )
        #expect(reference.contentVersion.rawValue == 3)

        // No retirement: the aged item survives the revise (the NEXT capture
        // would retire it — that is the capture lane's job, §7).
        let survivors = Set(
            try WSSupport.fetchRows(container).map { HistoryItemID(rawValue: $0.id) }
        )
        #expect(survivors == Set([aged.id, target.id]))
        // No prune: the lineage grew by exactly the append.
        let after = try Self.lineage(of: target.id, in: container)
        #expect(after.item.revisions.count == 2)
        #expect(after.item.revisions.first?.id == rev1ID)
        #expect(after.item.activeRevisionID == after.item.revisions.last?.id)
        #expect(try WSSupport.fetchPosition(container).rawValue == 4)
        let row = try #require(try Self.fetchBytesRow(for: target.id, in: container))
        #expect(row.revisionCount == 2)
        #expect(row.revisionBytes == 35)
    }

    // MARK: - Stale interleaving with R3 active (RET-CONCUR-1 case 2)

    /// One-shot arming flag for the suspension handler (the WS20 stance):
    /// only the FIRST commit to reach the guarded point parks; the
    /// harness-driven interference passes through.
    /// `SuspensionGate.park(at:)` forbids two tasks parked at one named
    /// point.
    private actor FirstParkLatch {
        private var armed = true

        /// Returns `true` exactly once — to the first caller — then stays
        /// disarmed for every later arrival.
        func consume() -> Bool {
            defer { armed = false }
            return armed
        }
    }

    /// The R3-flavored RET-CONCUR-1 case (2) over the WS20 harness: with R3
    /// active and the lineage over threshold, a content-changing revision
    /// interleaved between the two phases of a first revision makes the
    /// first reject `.staleContent` at the second OCC check — with NO prune
    /// mutation emitted and no `revisionStateBlob` write from the stale
    /// proposal. The INTERFERING revision itself composes its own R3 prune
    /// over the reloaded lineage (the phase-2 recomputation: lineage
    /// [rev1(8), rev2(9)] + its 11-byte append prunes rev1, landing
    /// [rev2, rev2'] at 2 revisions), and a subsequent legitimate revise
    /// (expected 4) prunes over THAT reloaded lineage — [rev2, rev2'] + its
    /// 12-byte append prunes rev2, landing [rev2', rev3'].
    ///
    /// RET-CONCUR-1 cases (1) (coalescing interleave, speculative ==
    /// committed) and (3) (interleaving same-item R3 prune) are covered by
    /// WS20's coalescing fixture and the phase-2 policy re-read's structure
    /// respectively — case (3)'s interleaving producer (`.setRetentionPolicies`)
    /// is the deferred R.6 slice, so its interleaving is not publicly
    /// constructible yet.
    @Test("stale interleaving with R3 active rejects at OCC with no prune applied")
    func staleInterleavingWithR3RejectsAtOCCWithoutApplyingPrune() async throws {
        let storeURL = WSSupport.tempStoreURL("r5-concur-stale")
        defer { WSSupport.removeStore(storeURL) }
        let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
        let revisionPreparation = RevisionPreparationActor()

        // Arrange: one item, version 1, position 1.
        let targetText = "r5 concur target"
        let insertRequest = WSSupport.textCapture(
            targetText,
            observedAt: Date(timeIntervalSinceReferenceDate: 700_410_000),
            source: "com.example.r5.concur"
        )
        let insert = try await IngestPreparationActor().prepare(insertRequest)
        let insertReceipt = try await authority.commitCapture(insert)
        guard case let .committed(insertCommit) = insertReceipt,
              case let .inserted(target) = insertCommit.outcome else {
            Issue.record("R.5 arrange: expected a committed insert, got \(insertReceipt)")
            return
        }
        #expect(insertCommit.position.rawValue == 1)

        // Two storage-side revises build the over-threshold lineage
        // [rev1(8), rev2(9)] — version 3, position 3 — through the same
        // two-phase flow the facade drives.
        for (version, bytes) in zip([1, 2], [8, 9]) {
            let request = Self.replaceRequest(
                itemID: target.id,
                expected: ContentVersion(rawValue: version),
                bytes: bytes
            )
            let inputs = try await authority.revisionPreparationInputs(request)
            let bundle = try await revisionPreparation.prepare(
                request,
                from: inputs.snapshot,
                retentionPolicies: inputs.retentionPolicies
            )
            let setupReceipt = try await authority.commitRevision(request, bundle)
            guard case .committed = setupReceipt else {
                Issue.record("R.5 arrange: expected a committed setup revise, got \(setupReceipt)")
                return
            }
        }
        // Policies land only now (behind the Authority's back; the revise
        // lane re-reads the singleton inside every commit).
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            revisions: RevisionRetention(
                maxRevisionsPerItem: 2,
                maxRevisionBytesPerItem: nil
            )
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let seeded = try Self.lineage(of: target.id, in: container)
        #expect(seeded.item.revisions.count == 2)
        let rev1ID = seeded.item.revisions[0].id
        let rev2ID = seeded.item.revisions[1].id

        // Two preparations at the SAME base version 3 proposing DIFFERENT
        // bytes: the parked first revision and the interfering second.
        let parkedRequest = Self.replaceRequest(
            itemID: target.id, expected: ContentVersion(rawValue: 3), bytes: 10
        )
        let interferingRequest = Self.replaceRequest(
            itemID: target.id, expected: ContentVersion(rawValue: 3), bytes: 11
        )
        let parkedInputs = try await authority.revisionPreparationInputs(parkedRequest)
        let parkedBundle = try await revisionPreparation.prepare(
            parkedRequest,
            from: parkedInputs.snapshot,
            retentionPolicies: parkedInputs.retentionPolicies
        )
        let interferingInputs = try await authority
            .revisionPreparationInputs(interferingRequest)
        let interferingBundle = try await revisionPreparation.prepare(
            interferingRequest,
            from: interferingInputs.snapshot,
            retentionPolicies: interferingInputs.retentionPolicies
        )

        // Park the first revision at its commit-entry seam; the interfering
        // revision commits in between (composing ITS OWN R3 prune over the
        // reloaded lineage); the parked one resumes into the OCC recheck and
        // loses — no prune from the stale proposal is applied (05 §10: the
        // pre-transaction OCC rejection commits nothing).
        let gate = SuspensionGate()
        let latch = FirstParkLatch()
        await authority.setSuspensionHandler { point in
            guard point == .revisionCommitEntry else { return }
            let first = await latch.consume()
            guard first else { return }
            await gate.park(at: point.rawValue)
        }
        do {
            _ = try await gate.runParked(
                at: AuthoritySuspensionPoint.revisionCommitEntry.rawValue,
                operation: {
                    try await authority.commitRevision(parkedRequest, parkedBundle)
                },
                whileCommitting: {
                    try await authority.commitRevision(
                        interferingRequest,
                        interferingBundle
                    )
                }
            )
            Issue.record("R.5: expected the parked revision to throw .staleContent, but it committed")
        } catch let failure as HistoryFailure {
            #expect(failure == HistoryFailure.staleContent(
                expected: ContentVersion(rawValue: 3),
                current: ContentVersion(rawValue: 4)
            ))
        } catch {
            Issue.record("R.5: expected HistoryFailure.staleContent, got \(error)")
        }

        // The interfering commit composed its prune over the RELOADED
        // lineage [rev1, rev2]: effective 3 > 2 pruned rev1, landing
        // [rev2, interfering] — the phase-2 recomputation (§4.3).
        let afterInterference = try Self.lineage(of: target.id, in: container)
        #expect(afterInterference.item.revisions.map(\.id) == [rev2ID, interferingBundle.domain.candidateRevisionID])
        #expect(!afterInterference.item.revisions.map(\.id).contains(rev1ID))
        #expect(afterInterference.item.contentVersion.rawValue == 4)
        #expect(try WSSupport.fetchPosition(container).rawValue == 4)

        // A subsequent legitimate revise (expected 4) prunes over THAT
        // reloaded lineage: [rev2, interfering] + the 12-byte append prunes
        // rev2, landing [interfering, new] — no stale prune survives.
        let finalRequest = Self.replaceRequest(
            itemID: target.id, expected: ContentVersion(rawValue: 4), bytes: 12
        )
        let finalInputs = try await authority.revisionPreparationInputs(finalRequest)
        let finalBundle = try await revisionPreparation.prepare(
            finalRequest,
            from: finalInputs.snapshot,
            retentionPolicies: finalInputs.retentionPolicies
        )
        let finalReceipt = try await authority.commitRevision(finalRequest, finalBundle)
        guard case let .committed(finalCommit) = finalReceipt,
              case let .revised(finalReference) = finalCommit.outcome else {
            Issue.record("R.5: expected a committed final revise, got \(finalReceipt)")
            return
        }
        #expect(finalCommit.position.rawValue == 5)
        #expect(finalReference.contentVersion.rawValue == 5)
        let finalLineage = try Self.lineage(of: target.id, in: container)
        #expect(finalLineage.item.revisions.map(\.id) == [
            interferingBundle.domain.candidateRevisionID,
            finalBundle.domain.candidateRevisionID
        ])
        #expect(finalLineage.item.activeRevisionID == finalBundle.domain.candidateRevisionID)
        let row = try #require(try Self.fetchBytesRow(for: target.id, in: container))
        #expect(row.revisionCount == 2)
        #expect(row.revisionBytes == 23)
    }
}
