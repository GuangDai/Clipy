/// R.3 — `RetainedBytesRow` projection-lifecycle proofs (`V2-roadmap` §6
/// R.3: "maintain the 1:1 scalar projection on create, append, prune, and
/// delete even while policies are disabled; inject the Storage clock
/// internally"; exit fixtures: "migration, missing-row-corruption, and
/// projection-lifecycle fixtures" / `RET-PLATFORM-1b(a)`,
/// `RET-PLATFORM-2`).
///
/// Owning spec: `V2-02` §3.3b (projection coherence: the insert stamp is
/// `revisionCount == 0` / `revisionBytes == 0` with `canonicalBytes` from
/// the signature postings; coalesce leaves the row unchanged; revise
/// restamps), §3.3/§3.4 (the `.delete` extension removes the 1:1 row in the
/// same transaction, explicitly, no `@Relationship`), §6.3 (restamp
/// discipline), §3.2 ("row existence is the migration invariant ... never
/// ... a zero-byte read"), §4.1/§7 (mandatory maintenance while disabled,
/// DC-04), §5.3 (the shorter same-active `RevisionStateBlobV1`), §6.4 (the
/// Storage clock seam); open order: `V2-roadmap` §5 step 7.
///
/// Every lifecycle case crosses the public `SwiftDataHistory.perform` /
/// real `HistoryAuthority` commit paths and asserts rows through an
/// INDEPENDENT second `ModelContainer` (see `WSSupport`); the corruption
/// matrix writes its damage behind the Authority's back through that same
/// independent container, then re-opens through the real `open`
/// (`V2-02` §13 fail-open stance: no silent repair). The prune and
/// missing-row clauses additionally drive the storage-internal
/// `RetainedBytesStamping` seam directly — the same stance
/// `RetentionConfigBootstrapTests` takes for bootstrap internals — because
/// the plans that EMIT `.pruneRevisions` (revise+R3 fold, R.6 sweep) are
/// owned by later slices.
///
/// Hand-worked fixture values (single-representation ASCII text captures:
/// one `public.utf8-plain-text` representation whose `byteCount` is the
/// UTF-8 length of the text):
/// - "r3 canonical base" — 17 bytes (2 + 1 + 9 + 1 + 4);
/// - "r3 revised effective bytes" — 26 bytes (2 + 1 + 7 + 1 + 9 + 1 + 5);
/// - "r3 second revision" — 18 bytes (2 + 1 + 6 + 1 + 8);
/// - "r3 disabled maintenance" — 23 bytes (2 + 1 + 8 + 1 + 11);
/// - "r3 remove target alpha" / "r3 remove survivor beta" /
///   "r3 clear target gamma" / "r3 corruption matrix item" — only identity
///   matters (existence per ID).
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("RetainedBytesRow projection lifecycle (R.3)")
struct RetainedBytesProjectionLifecycleTests {

    // MARK: - Fixtures

    /// Every `RetainedBytesRow`, deterministically ordered by item ID.
    private static func fetchBytesRows(
        _ container: ModelContainer
    ) throws -> [RetainedBytesRow] {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        return rows.sorted { $0.itemID.uuidString < $1.itemID.uuidString }
    }

    /// The unique projection row for `itemID`, or `nil` (0 or 1 rows;
    /// 2+ fails the fixture loudly — the 1:1 law is exactly what these
    /// tests establish).
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

    /// The four projection scalars compared across a commit.
    private struct ProjectionScalars: Equatable {
        let canonicalBytes: Int
        let revisionCount: Int
        let revisionBytes: Int
        let bytesSchemaVersion: UInt16
    }

    private static func scalars(
        of row: RetainedBytesRow
    ) -> ProjectionScalars {
        ProjectionScalars(
            canonicalBytes: row.canonicalBytes,
            revisionCount: row.revisionCount,
            revisionBytes: row.revisionBytes,
            bytesSchemaVersion: row.bytesSchemaVersion
        )
    }

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
            Issue.record("R.3 setup: expected .committed with .inserted, got \(receipt)")
            throw HistoryFailure.notFound(HistoryItemID(rawValue: UUID()))
        }
        return reference
    }

    // MARK: - (a) Insert (V2-02 §3.3b)

    /// Capture-insert creates exactly one 1:1 row: `canonicalBytes` equals
    /// the recomputed signature-entry byte-count sum of the item's durable
    /// `canonicalSignatureBlob` (independently re-decoded here, the §3.2
    /// signature-envelope measure), `revisionCount == 0` and
    /// `revisionBytes == 0` (a v1 insert carries an empty revision list,
    /// `02` §2 — DC-04), and `bytesSchemaVersion == 1` (§3.3b fence).
    @Test("capture insert stamps the 1:1 row with signature byte sum and zero revision scalars")
    func captureInsertStampsOneToOneRow() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-insert-stamp")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        // 17 UTF-8 bytes (see the file header's hand-worked values).
        let text = "r3 canonical base"
        let reference = try Self.capture(
            text,
            at: 700_100_000,
            source: "com.example.r3.insert",
            in: history
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let allRows = try Self.fetchBytesRows(container)
        #expect(allRows.count == 1)
        let row = try #require(allRows.first)
        #expect(row.itemID == reference.id.rawValue)

        // §3.3b insert stamp: zero revision scalars, version-1 fence.
        #expect(row.revisionCount == 0)
        #expect(row.revisionBytes == 0)
        #expect(row.bytesSchemaVersion == 1)

        // canonicalBytes: the recomputed signature-entry byte-count sum over
        // the durable blob (never the JSON framing of the blob itself), and
        // the hand-worked literal for the single ASCII representation.
        let items = try WSSupport.fetchRows(container)
        let itemRow = try #require(items.first(where: { $0.id == reference.id.rawValue }))
        let entries = try SignatureBlobCodec.decode(itemRow.canonicalSignatureBlob)
        var recomputed = 0
        for entry in entries {
            recomputed += entry.byteCount
        }
        #expect(recomputed == 17)
        #expect(row.canonicalBytes == recomputed)
        #expect(row.canonicalBytes == 17)
    }

    // MARK: - (b) Coalesce (V2-02 §3.3b / §6.3)

    /// Coalesce does not restamp: a coalesce stamps only `.updateOccurrence`
    /// (occurrence fields; no byte-changing blob write), so the winner's
    /// existing row is present and unchanged — the byte-projection analog
    /// of v1's "occurrence mutations preserve projections" rule (§6.3).
    @Test("coalesce leaves the projection row unchanged")
    func coalesceLeavesProjectionRowUnchanged() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-coalesce-unchanged")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let text = "r3 coalesce winner"
        let reference = try Self.capture(
            text,
            at: 700_101_000,
            source: "com.example.r3.coalesce",
            in: history
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let before = try Self.fetchBytesRow(for: reference.id, in: container)
        let scalarsBefore = Self.scalars(of: try #require(before))

        // Same content, later observation: the planner coalesces onto the
        // winner (docs/02-domain.md §9; equal content never inserts).
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                text,
                observedAt: Date(timeIntervalSinceReferenceDate: 700_101_500),
                source: "com.example.r3.coalesce"
            )
        ))
        guard case let .committed(commit) = receipt,
              case .coalesced(let winner) = commit.outcome else {
            Issue.record("R.3: expected .committed with .coalesced, got \(receipt)")
            return
        }
        #expect(winner.id == reference.id)

        // Still exactly one unchanged row for the one retained item.
        let after = try Self.fetchBytesRow(for: reference.id, in: container)
        #expect(Self.scalars(of: try #require(after)) == scalarsBefore)
        #expect(try Self.fetchBytesRows(container).count == 1)
    }

    // MARK: - (c) Revise restamp (V2-02 §3.3b / §6.3)

    /// Each appended revision restamps the row in the same transaction:
    /// `revisionCount` grows by one and `revisionBytes` by the appended
    /// representation bytes, while `canonicalBytes` never moves (Canonical
    /// Content is immutable, D2 — the append touches only Effective state).
    /// Hand-worked values: 17-byte canonical; first revision 26 bytes;
    /// second revision 18 bytes; post-second-append summary 2 / 44.
    @Test("revise append restamps revision scalars and never touches canonicalBytes")
    func reviseAppendRestampsRevisionScalars() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-revise-restamp")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let reference = try Self.capture(
            "r3 canonical base",
            at: 700_102_000,
            source: "com.example.r3.revise",
            in: history
        )
        let container = try WSSupport.makeContainer(storeURL: storeURL)

        // First append: replace the single Canonical type's Effective bytes
        // with 26 new bytes (docs/02-domain.md §11; OCC token = version 1).
        let firstRevisionText = "r3 revised effective bytes"
        var receipt = try await history.perform(.revise(RevisionRequest(
            itemID: reference.id,
            expected: ContentVersion(rawValue: 1),
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: "public.utf8-plain-text",
                    action: .replace(bytes: Data(firstRevisionText.utf8))
                ),
            ]))
        )))
        guard case .committed = receipt else {
            Issue.record("R.3: expected a committed first revise, got \(receipt)")
            return
        }
        var fetchedRow = try Self.fetchBytesRow(for: reference.id, in: container)
        var row = try #require(fetchedRow)
        #expect(row.revisionCount == 1)
        #expect(row.revisionBytes == 26)

        // Second append (OCC token = version 2): 18 more bytes.
        let secondRevisionText = "r3 second revision"
        receipt = try await history.perform(.revise(RevisionRequest(
            itemID: reference.id,
            expected: ContentVersion(rawValue: 2),
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: "public.utf8-plain-text",
                    action: .replace(bytes: Data(secondRevisionText.utf8))
                ),
            ]))
        )))
        guard case .committed = receipt else {
            Issue.record("R.3: expected a committed second revise, got \(receipt)")
            return
        }
        fetchedRow = try Self.fetchBytesRow(for: reference.id, in: container)
        row = try #require(fetchedRow)
        // Canonical never moves (D2; §5.2): still the 17-byte signature sum.
        #expect(row.revisionCount == 2)
        #expect(row.revisionBytes == 44)
        #expect(row.canonicalBytes == 17)
        #expect(row.bytesSchemaVersion == 1)
    }

    // MARK: - (d) Delete with the item (V2-02 §3.3/§3.4)

    /// User removal deletes the removed item's projection row in the same
    /// transaction — no orphan survives the item (§3.4's explicit step).
    @Test("remove deletes the projection row with its item")
    func removeDeletesProjectionRowWithItem() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-remove-row")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let removed = try Self.capture(
            "r3 remove target alpha",
            at: 700_103_000,
            source: "com.example.r3.remove",
            in: history
        )
        let survivor = try Self.capture(
            "r3 remove survivor beta",
            at: 700_103_100,
            source: "com.example.r3.remove",
            in: history
        )

        let receipt = try await history.perform(.remove(removed.id))
        guard case let .committed(commit) = receipt,
              case .removed(let count) = commit.outcome else {
            Issue.record("R.3: expected .committed with .removed, got \(receipt)")
            return
        }
        #expect(count == 1)

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try Self.fetchBytesRow(for: removed.id, in: container) == nil)
        #expect(try Self.fetchBytesRow(for: survivor.id, in: container) != nil)
        #expect(try Self.fetchBytesRows(container).count == 1)
    }

    /// `.clear(.all)` removes every remaining projection row with its item
    /// — no orphan survives a clear-all.
    @Test("clear all deletes every projection row")
    func clearAllDeletesEveryProjectionRow() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-clear-rows")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        _ = try Self.capture(
            "r3 clear target gamma",
            at: 700_104_000,
            source: "com.example.r3.clear",
            in: history
        )
        _ = try Self.capture(
            "r3 clear target delta",
            at: 700_104_100,
            source: "com.example.r3.clear",
            in: history
        )

        let receipt = try await history.perform(.clear(.all))
        guard case let .committed(commit) = receipt,
              case .cleared(let count) = commit.outcome else {
            Issue.record("R.3: expected .committed with .cleared, got \(receipt)")
            return
        }
        #expect(count == 2)

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try WSSupport.fetchRows(container).isEmpty)
        #expect(try Self.fetchBytesRows(container).isEmpty)
    }

    /// The retention reason shares the same explicit row deletion: a count
    /// retirement (v1 `.retire(itemID:, .retention)`, WS21's same-commit
    /// eviction) leaves no orphan behind either — the V2 `.delete`
    /// extension is reason-agnostic (§3.4).
    @Test("retirement deletes the projection row with its victim")
    func retirementDeletesProjectionRowWithVictim() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-retire-row")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let victim = try Self.capture(
            "r3 retention victim",
            at: 700_105_000,
            source: "com.example.r3.retire",
            in: history
        )
        let survivor = try Self.capture(
            "r3 retention survivor",
            at: 700_105_100,
            source: "com.example.r3.retire",
            in: history
        )

        // Lowering the count policy retires the oldest unpinned item in the
        // same History Commit (WS21; docs/02-domain.md §12).
        let receipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
        guard case let .committed(commit) = receipt,
              case .retentionPolicySet(let removedCount) = commit.outcome else {
            Issue.record("R.3: expected .committed with .retentionPolicySet, got \(receipt)")
            return
        }
        #expect(removedCount == 1)

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try Self.fetchBytesRow(for: victim.id, in: container) == nil)
        #expect(try Self.fetchBytesRow(for: survivor.id, in: container) != nil)
        #expect(try Self.fetchBytesRows(container).count == 1)
    }

    // MARK: - (e) Restart 1:1 enforcement (V2-roadmap §5 step 7)

    private enum ProjectionCorruption: Equatable {
        /// Direction 1 violation: a retained item with no projection row.
        case missingRow
        /// Direction 2 violation: a projection row naming no retained item.
        case orphanRow
        /// Fence violation: an unknown `bytesSchemaVersion`.
        case unknownBytesSchemaVersion
    }

    /// Re-open enforces the step-7 runtime 1:1 check
    /// (`RET-PLATFORM-1b(a)`, live from R.3): every retained item has
    /// exactly one row, every row names a retained item, and every
    /// `bytesSchemaVersion == 1` — each violation fails `open` closed as
    /// `.persistence(.invariantViolation)`, never a zero read and never a
    /// silent repair (`V2-02` §3.2/§3.3b). Damage is written behind the
    /// Authority's back through an independent container.
    @Test(
        "re-open fails closed on every 1:1 / version-fence corruption",
        arguments: [
            ProjectionCorruption.missingRow,
            ProjectionCorruption.orphanRow,
            ProjectionCorruption.unknownBytesSchemaVersion,
        ]
    )
    func reOpenFailsClosedOnProjectionCorruption(
        corruption: ProjectionCorruption
    ) async throws {
        let storeURL = WSSupport.tempStoreURL("r3-reopen-\(corruption)")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        _ = try Self.capture(
            "r3 corruption matrix item",
            at: 700_106_000,
            source: "com.example.r3.corruption",
            in: history
        )

        // Damage the projection behind the Authority's back. The target row
        // is fetched through the SAME context that is saved — a `@Model` is
        // bound to the context that fetched it, so a mutation through
        // another context would never persist.
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        switch corruption {
        case .missingRow:
            let rows = try context.fetch(FetchDescriptor<RetainedBytesRow>())
            context.delete(try #require(rows.first))
        case .orphanRow:
            context.insert(RetainedBytesRow(
                itemID: UUID(),
                canonicalBytes: 1,
                revisionCount: 0,
                revisionBytes: 0,
                bytesSchemaVersion: 1
            ))
        case .unknownBytesSchemaVersion:
            let rows = try context.fetch(FetchDescriptor<RetainedBytesRow>())
            try #require(rows.first).bytesSchemaVersion = 2
        }
        try context.save()

        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            _ = try await WSSupport.openHistory(storeURL: storeURL)
        }
    }

    /// The step-7 check holds vacuously on a fresh store (zero items; rows
    /// arrive via the capture-insert stamping) — an empty store re-opens.
    @Test("fresh store re-opens: the 1:1 check holds vacuously")
    func freshStoreReOpensVacuously() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-fresh-vacuous")
        defer { WSSupport.removeStore(storeURL) }
        _ = try await WSSupport.openHistory(storeURL: storeURL)

        _ = try await WSSupport.openHistory(storeURL: storeURL)
    }

    // MARK: - (f) Disabled policies (V2-02 §4.1/§7, DC-04)

    /// The projection is maintained while EVERY V2 policy is disabled: the
    /// persisted config singleton is the all-disabled default (a migrated
    /// store starts v1-faithful, §3.3), yet capture still stamps the 1:1
    /// row — mandatory maintenance, not policy-driven (`V2-02` §4.1/§7:
    /// "public behavior and v1 rows are exactly v1's, not byte-identical
    /// durable state — the `RetainedBytesRow` projection is mandatorily
    /// maintained 1:1 even while every policy is disabled").
    @Test("projection is maintained while all V2 policies are disabled")
    func projectionMaintainedWhileAllPoliciesDisabled() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-disabled-maintenance")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let reference = try Self.capture(
            "r3 disabled maintenance",
            at: 700_107_000,
            source: "com.example.r3.disabled",
            in: history
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        // The persisted policies really are all-disabled (§3.3 defaults).
        let configContext = ModelContext(container)
        let configs = try configContext.fetch(
            FetchDescriptor<RetentionExpansionConfigRow>()
        )
        #expect(configs.count == 1)
        let config = try #require(configs.first)
        #expect(config.agePolicyEnabled == false)
        #expect(config.storagePolicyEnabled == false)
        #expect(config.revisionPolicyEnabled == false)

        // ... and the projection row exists anyway, with the insert stamp.
        let projectionRow = try Self.fetchBytesRow(for: reference.id, in: container)
        let row = try #require(projectionRow)
        #expect(row.revisionCount == 0)
        #expect(row.revisionBytes == 0)
        // 23 UTF-8 bytes: "r3 disabled maintenance" is
        // 2 + 1 + 8 + 1 + 11 ("disabled" = 8, "maintenance" = 11).
        #expect(row.canonicalBytes == 23)
    }

    // MARK: - Prune payload seam (V2-02 §5.3)

    /// The prune re-encode over a real loaded lineage: removing the oldest
    /// inactive revision produces the shorter `RevisionStateBlobV1`
    /// (survivor order preserved, same `activeRevisionID`, decodable by the
    /// unchanged v1 codec against the item's Canonical) plus the post-prune
    /// scalars — 1 surviving revision / 18 representation bytes (the second
    /// revision's bytes; see the file header).
    ///
    /// Storage-side seam proof (the R.5/R.6 compositions that EMIT
    /// `.pruneRevisions` are not landed): the lineage is loaded through the
    /// real `MutationFactLoaders.loadRevisionFacts` from a store built by
    /// the public capture/revise path, then pruned through the exact
    /// static the stamping arm calls.
    @Test("prune re-encodes the shorter same-active blob and post-prune scalars")
    func pruneReencodesShorterBlobAndPostPruneScalars() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-prune-payload")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let reference = try Self.capture(
            "r3 canonical base",
            at: 700_108_000,
            source: "com.example.r3.prune",
            in: history
        )
        for (version, text) in zip(
            [ContentVersion(rawValue: 1), ContentVersion(rawValue: 2)],
            ["r3 revised effective bytes", "r3 second revision"]
        ) {
            let receipt = try await history.perform(.revise(RevisionRequest(
                itemID: reference.id,
                expected: version,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: "public.utf8-plain-text",
                        action: .replace(bytes: Data(text.utf8))
                    ),
                ]))
            )))
            guard case .committed = receipt else {
                Issue.record("R.3 setup: expected a committed revise, got \(receipt)")
                return
            }
        }

        // Load the real lineage (05 §7.3: exactly the target item).
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let facts = try MutationFactLoaders.loadRevisionFacts(
            itemID: reference.id,
            in: context
        )
        #expect(facts.item.revisions.count == 2)
        let active = try #require(facts.item.activeRevisionID)
        #expect(active == facts.item.revisions[1].id)
        let oldestInactive = facts.item.revisions[0].id

        let pruned = try RetainedBytesStamping.prunedRevisionState(
            loadedRevisions: facts.item.revisions,
            activeRevisionID: facts.item.activeRevisionID,
            removedRevisionIDs: [oldestInactive]
        )

        // §5.3: the v1 codec decodes the shorter blob unchanged — survivors
        // in append order, same active, formatVersion 1.
        let decoded = try RevisionStateBlobCodec.decode(
            pruned.revisionStateBlob,
            canonical: facts.item.canonical
        )
        #expect(decoded.revisions.map(\.id) == [active])
        #expect(decoded.activeRevisionID == active)

        // §6.3 restamp inputs: the post-prune summary (1 revision, 18
        // representation bytes — the surviving second revision).
        #expect(pruned.retainedRevisionScalars == RetainedRevisionScalars(
            count: 1,
            bytes: 18
        ))
    }

    /// The §5.1/§5.2 safety laws the prune re-encode re-guards: an empty
    /// removal set, the active revision, an unknown revision ID, and a
    /// Canonical-state (nil-active) lineage are all incoherent prune
    /// payloads — `StampingRejection.incoherentPlan`, never a blob write.
    @Test("prune re-encode rejects incoherent removal sets")
    func pruneReencodeRejectsIncoherentRemovalSets() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-prune-rejections")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let reference = try Self.capture(
            "r3 canonical base",
            at: 700_109_000,
            source: "com.example.r3.prune-reject",
            in: history
        )
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: reference.id,
            expected: ContentVersion(rawValue: 1),
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: "public.utf8-plain-text",
                    action: .replace(bytes: Data("r3 revised effective bytes".utf8))
                ),
            ]))
        )))
        guard case .committed = receipt else {
            Issue.record("R.3 setup: expected a committed revise, got \(receipt)")
            return
        }

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let facts = try MutationFactLoaders.loadRevisionFacts(
            itemID: reference.id,
            in: context
        )
        let active = try #require(facts.item.activeRevisionID)

        // Empty removal set (§5.3: a no-op prune never reaches stamping).
        #expect(throws: StampingRejection.incoherentPlan) {
            _ = try RetainedBytesStamping.prunedRevisionState(
                loadedRevisions: facts.item.revisions,
                activeRevisionID: facts.item.activeRevisionID,
                removedRevisionIDs: []
            )
        }
        // The active revision is never prunable (D3/D23).
        #expect(throws: StampingRejection.incoherentPlan) {
            _ = try RetainedBytesStamping.prunedRevisionState(
                loadedRevisions: facts.item.revisions,
                activeRevisionID: facts.item.activeRevisionID,
                removedRevisionIDs: [active]
            )
        }
        // A removed ID naming no loaded revision is incoherent.
        #expect(throws: StampingRejection.incoherentPlan) {
            _ = try RetainedBytesStamping.prunedRevisionState(
                loadedRevisions: facts.item.revisions,
                activeRevisionID: facts.item.activeRevisionID,
                removedRevisionIDs: [RevisionID(rawValue: UUID())]
            )
        }
        // A Canonical-state lineage (nil active) has nothing to prune.
        #expect(throws: StampingRejection.incoherentPlan) {
            _ = try RetainedBytesStamping.prunedRevisionState(
                loadedRevisions: [],
                activeRevisionID: nil,
                removedRevisionIDs: [RevisionID(rawValue: UUID())]
            )
        }
    }

    /// The missing-row clauses of the lifecycle primitives: `restamp` and
    /// `deleteRow` fail closed as `.persistence(.invariantViolation)` when
    /// the 1:1 row is absent — never a zero read, never a silent skip or
    /// delete-as-repair (`V2-02` §3.2 / Record 5). Driven on a store whose
    /// projection row was removed behind the Authority's back.
    @Test("restamp and deleteRow fail closed on a missing projection row")
    func restampAndDeleteRowFailClosedOnMissingRow() async throws {
        let storeURL = WSSupport.tempStoreURL("r3-missing-row-closed")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let reference = try Self.capture(
            "r3 missing row target",
            at: 700_110_000,
            source: "com.example.r3.missing",
            in: history
        )

        // Remove the projection row behind the Authority's back (fetched and
        // saved through the SAME context — a `@Model` is bound to the
        // context that fetched it).
        let damageContainer = try WSSupport.makeContainer(storeURL: storeURL)
        let damageContext = ModelContext(damageContainer)
        let damageRows = try damageContext.fetch(FetchDescriptor<RetainedBytesRow>())
        damageContext.delete(try #require(damageRows.first))
        try damageContext.save()

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try RetainedBytesStamping.restamp(
                itemID: reference.id,
                revisionScalars: RetainedRevisionScalars(count: 0, bytes: 0),
                in: context
            )
        }
        #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try RetainedBytesStamping.deleteRow(
                itemID: reference.id,
                in: context
            )
        }
    }

    // MARK: - Storage clock seam (V2-02 §6.4)

    /// A fixed-`Date` clock witness injected through the `@testable`
    /// `HistoryAuthority` initializer is stored and read back unchanged,
    /// and the public `open` path wires the production `SystemRetentionClock`
    /// witness. Seam/compile proof only (the §6.4 posture: the public
    /// `open(configuration:)` signature and `HistoryConfiguration` carry no
    /// clock, `RET-COMPILE-1`); the clock's behavioral consumer is the R.6
    /// `.setRetentionPolicies` sweep lane, which no public action reaches
    /// yet.
    @Test("RetentionClock seam: @testable injection compiles; open wires the system witness")
    func retentionClockSeamAcceptsInjectionWhileOpenWiresSystemClock() async throws {
        struct FixedRetentionClock: RetentionClock {
            let fixed: Date
            func now() -> Date { fixed }
        }
        let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

        // Injection: the internal init accepts a fixed witness; the actor
        // stores it and reads it back.
        let storeURL = WSSupport.tempStoreURL("r3-clock-seam")
        defer { WSSupport.removeStore(storeURL) }
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let authority = HistoryAuthority(
            container: container,
            retentionClock: FixedRetentionClock(fixed: epoch)
        )
        let injected = await authority.retentionClock
        #expect(injected.now() == epoch)

        // Production default: `open` wires the system witness internally —
        // no clock parameter on the public seam (V2-02 §6.4).
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let productionClock = await history.authority.retentionClock
        #expect(productionClock is SystemRetentionClock)
    }
}
