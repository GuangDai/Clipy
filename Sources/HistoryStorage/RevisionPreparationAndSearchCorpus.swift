/// Revision preparation plus the immutable search-corpus transfer values.
/// Owning spec: docs/roadmap/03-historystorage.md step-5 note; facade field
/// list: docs/05-authority-kernel.md §2 (Part V).
///
/// `SwiftDataHistory.open` constructs all five facade fields; every field is
/// an `actor`, so `SwiftDataHistory: Sendable` is derivable without escape
/// hatches. `ThumbnailService` moved to ThumbnailService.swift at roadmap
/// step 8 (its flight table and owned `ThumbnailWorker` live there); this
/// file now hosts only `RevisionPreparationActor` and the four value types
/// (`PreparedRevisionBundle`, `RevisionPreparationSnapshot`,
/// `SearchCorpusSnapshot`, `SearchCorpusRow`). `SearchWorker` moved out at
/// roadmap step 7: its exact/fuzzy/regexp implementation lives
/// in SearchWorker.swift, with Fuse confined inside the actor per
/// docs/01-architecture.md §6.
///
/// This file hosts the internal Sendable value types those signatures
/// require that no other file owns. Step 6 keeps the revision values beside
/// their preparation actor here; `SearchCorpusSnapshot`/`SearchCorpusRow`
/// stay here as the docs/05-authority-kernel.md §14.2 contract between the
/// Authority (which captures the corpus) and the `SearchWorker` in
/// SearchWorker.swift (which evaluates it).
import Foundation
import HistoryCore
import HistoryDomain

/// The output of revision preparation: the Domain-ready proposed revision plus
/// the durable bounded projection computed from the proposed Effective Content
/// (docs/05-authority-kernel.md §6.2).
///
/// Defined at roadmap step 5 to pin the `RevisionPreparationActor` step-6
/// signature; it remains beside its owner and immutable transfer values.
internal struct PreparedRevisionBundle: Sendable {
    /// The complete proposed revision for pure Domain planning; Storage minted
    /// the candidate Revision ID and timestamp (docs/02-domain.md §4).
    let domain: PreparedRevision
    /// Projection of the prepared proposed Effective Content (Part V §15).
    let projection: ContentProjection
}

/// The OCC-safe two-phase revision input: the target's validated Canonical
/// Content, complete revision list, active ID, and Content Version, captured
/// by `HistoryAuthority` as a Sendable value — no row or context escapes
/// (docs/05-authority-kernel.md §6.2).
///
/// Defined at roadmap step 5 to pin the `RevisionPreparationActor` step-6
/// signature; it remains beside its owner and immutable transfer values.
internal struct RevisionPreparationSnapshot: Sendable {
    /// The target's validated Canonical Content (docs/02-domain.md §2.3).
    let canonical: CanonicalContent
    /// The target's complete stored revision list (docs/02-domain.md §2.5).
    let revisions: [ContentRevision]
    /// The active Revision ID; `nil` only for a Canonical-state item (D3).
    let activeRevisionID: RevisionID?
    /// The Content Version the preparation is based on; rechecked by Domain
    /// planning against the reloaded facts (Part V §6.2).
    let contentVersion: ContentVersion
}

/// A bounded, Sendable snapshot of the search corpus: the Change Position the
/// rows were captured at plus every retained row's scalar projection fields.
/// Captured within one `HistoryAuthority` interval
/// (docs/05-authority-kernel.md §14.2).
///
/// Defined at roadmap step 5 to pin the `SearchWorker` step-7 signature and
/// retained as the immutable Authority-to-worker transfer value.
internal struct SearchCorpusSnapshot: Sendable {
    /// The durable position the corpus was read at; stamps the returned page.
    let position: ChangePosition
    /// Scalar projection rows for every retained item (bounded by the hard
    /// retained-item maximum, docs/06-cross-cutting.md §2).
    let rows: [SearchCorpusRow]
#if DEBUG
    /// Correlates privacy-safe Authority and SearchWorker checkpoints. The
    /// identifier and the field itself are absent from Release builds.
    let debugTrace: SearchDebugTrace
#endif
}

/// One retained item's scalar projection inside a `SearchCorpusSnapshot`
/// (docs/05-authority-kernel.md §14.2). No Canonical/revision blob is decoded
/// to build it.
internal struct SearchCorpusRow: Sendable {
    /// Stable business ID.
    let id: HistoryItemID
    /// Current Effective Content version, always at least 1.
    let contentVersion: ContentVersion
    /// Durable bounded title projection (Part V §15).
    let title: String
    /// Durable bounded search-body projection (Part V §15).
    let searchBody: String
#if DEBUG
    /// Byte sizes already computed by fail-closed projection validation. They
    /// keep SearchWorker instrumentation from walking either String again.
    let debugTitleUTF8Bytes: Int
    let debugSearchBodyUTF8Bytes: Int
#endif
    /// Sorted unique effective type identifiers (Part V §15).
    let typeIdentifiers: [String]
    /// Occurrence summary scalars.
    let lastCopiedAt: Date
    let copyCount: UInt64
    let lastSource: String?
    /// Pinned order; `nil` is unpinned.
    let pinOrdinal: PinOrdinal?
}

/// Revision-preparation worker (docs/05-authority-kernel.md §6.2): the
/// off-Authority phase of the OCC-safe two-phase revision flow.
///
/// The Authority captures the `RevisionPreparationSnapshot` and rejects an
/// already-stale `request.expected`; this actor then resolves the
/// replace/revert intent into a complete proposed Effective Content,
/// validates the Part VI hard limits, mints the candidate Revision ID and
/// creation timestamp, and projects the durable title/search/type summary —
/// all outside the serial commit interval. The Authority afterwards reloads
/// the facts and Domain planning rechecks both OCC tokens before the commit
/// (docs/02-domain.md §11). Missing revert targets and incoherent drafts
/// fail here, before the second Authority entry (§6.2).
///
/// The actor holds only the immutable `HistoryLimits`, so every preparation
/// is independent and only immutable `Sendable` values cross its boundary
/// (docs/05-authority-kernel.md Part I-facing confinement rules;
/// docs/02-domain.md D17).
internal actor RevisionPreparationActor {
    /// The fixed `HistoryLimits.standard` safety profile in production
    /// (docs/06-cross-cutting.md §2); focused tests inject smaller bounds.
    private let limits: HistoryLimits

    /// Package-injected revision identity and clock dependencies. Production
    /// uses UUID/Date entropy; deterministic tests can pin both without
    /// moving generation into the pure Domain (docs/01-architecture.md §4).
    private let makeRevisionID: @Sendable () -> RevisionID
    private let now: @Sendable () -> Date

    /// Creates the preparation actor. Production uses the default
    /// `HistoryLimits.standard` (docs/06-cross-cutting.md §2).
    internal init(
        limits: HistoryLimits = .standard,
        makeRevisionID: @escaping @Sendable () -> RevisionID = {
            RevisionID(rawValue: UUID())
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.limits = limits
        self.makeRevisionID = makeRevisionID
        self.now = now
    }

    /// Resolves `request` against `source` into a `PreparedRevisionBundle`,
    /// in §6.2's fixed order:
    ///
    /// 1. Resolve the intent into a complete proposed Effective Content
    ///    (decision resolution: docs/03a-instruction-set.md §5).
    /// 2. Validate the Part VI hard limits with checked arithmetic — no
    ///    byte-count calculation wraps (docs/06-cross-cutting.md §2).
    /// 3. Mint the candidate Revision ID and creation timestamp — entropy
    ///    lives in Storage, never in the Domain (docs/02-domain.md §4).
    /// 4. Project the durable title/search/type summary from the prepared
    ///    proposed Effective Content (docs/05-authority-kernel.md §15).
    ///
    /// The v1 entry point (`retentionPolicies` absent): R3 is disabled for
    /// this preparation, so the path is byte-for-byte v1 (`V2-02` Record 2:
    /// "when R3 is disabled, the preparation path is byte-for-byte v1").
    ///
    /// - Throws: `HistoryFailure.invalidInput(.incoherentRevisionDraft)` for
    ///   a draft that misses a Canonical decision, duplicates one, names a
    ///   foreign type, supplies empty replacement bytes, or hides every type
    ///   (03a §5); `.invalidInput(.representationLimit)` or `.byteLimit` for
    ///   representation/byte violations; `.revisionNotFound` for an absent
    ///   revert target; `.capacityExceeded(.revisionCount)` or
    ///   `.capacityExceeded(.revisionBytes)` for the per-item revision bounds
    ///   (§16: hard limits → `.capacityExceeded` with the matching
    ///   CapacityKind; size problems → `.invalidInput`).
    internal func prepare(
        _ request: RevisionRequest,
        from source: RevisionPreparationSnapshot
    ) throws -> PreparedRevisionBundle {
        try prepare(request, from: source, retentionPolicies: nil)
    }

    /// The V2-extended preparation entry (`V2-02` §4.3 PHASE 1; `V2-roadmap`
    /// §6 R.5). Identical to the v1 flow except for one conditionally-armed
    /// block: when `retentionPolicies` carries an active R3 lane, the
    /// speculative prune set is computed BEFORE the per-item hard-bound
    /// check, so the check sees the POST-PRUNE POST-APPEND state — §5.4's
    /// ordering rule ("R3 never relaxes the hard bound; it only prunes below
    /// the user threshold first"). The hard-bound values and their rejection
    /// semantics are unchanged (docs/06-cross-cutting.md §2: 100 revisions /
    /// 256 MiB); with the R3 lane disabled no prune occurs and both checks
    /// degenerate to exactly v1's.
    ///
    /// `retentionPolicies` is the sibling V2 input of Record 2's
    /// policy-sourcing mechanism: the Authority reads the current
    /// `RetentionExpansionConfigRow` in the same serialized interval that
    /// captures `source` and threads the R3 lane here — the off-Authority
    /// preparation actor performs no durable-state read of its own (the v1
    /// `RevisionPreparationSnapshot` value is unchanged and carries no
    /// policies).
    ///
    /// The speculative prune set produces no mutation and performs no
    /// pruning itself (`V2-02` §4.3: preparation "only *speculatively*
    /// recomputes the same prune set ... to validate the post-prune
    /// post-append hard bound and reject early"); the commit path recomputes
    /// the prune over the reloaded lineage (§4.3 PHASE 2).
    ///
    /// - Throws: the v1 entry's failures above, plus `.capacityExceeded(
    ///   .revisionBytes)` for the §8.3 revise-time unsatisfiable prune (the
    ///   post-prune state — the appended now-active revision alone — still
    ///   over `maxRevisionBytesPerItem`; the active revision cannot be
    ///   pruned, D3, so the threshold is unsatisfiable at revise time and
    ///   the revise fails atomically before any Authority entry).
    internal func prepare(
        _ request: RevisionRequest,
        from source: RevisionPreparationSnapshot,
        retentionPolicies: HistoryRetentionPolicies?
    ) throws -> PreparedRevisionBundle {
        // Step 1 — resolve the intent into the complete proposed Effective
        // Content (§6.2; decision resolution: 03a §5).
        let proposed: EffectiveContent
        switch request.intent {
        case .replace(let draft):
            // A replace draft must make exactly one explicit decision for
            // every Canonical type and no decision for a foreign type
            // (03a §5). Duplicate decisions are rejected first; equal
            // decision/canonical counts then leave a missing Canonical
            // decision no room but to be paired with a foreign one — both
            // are the same incoherent-draft failure.
            var actionsByType: [String: RevisionDecisionAction] = [:]
            actionsByType.reserveCapacity(draft.decisions.count)
            for decision in draft.decisions {
                guard actionsByType.updateValue(
                    decision.action,
                    forKey: decision.typeIdentifier
                ) == nil else {
                    throw HistoryFailure.invalidInput(.incoherentRevisionDraft)
                }
            }
            guard actionsByType.count == source.canonical.representations.count else {
                throw HistoryFailure.invalidInput(.incoherentRevisionDraft)
            }
            // Resolution preserves the Canonical representation order, so the
            // proposed content stays in the normalized stable Unicode scalar
            // order (docs/02-domain.md §2.1) without re-sorting.
            var representations: [ContentRepresentation] = []
            representations.reserveCapacity(source.canonical.representations.count)
            for canonicalRepresentation in source.canonical.representations {
                let typeIdentifier = canonicalRepresentation.content.typeIdentifier
                guard let action = actionsByType[typeIdentifier] else {
                    // Counts matched, so a missing decision means a foreign
                    // type took its slot — still an incoherent draft.
                    throw HistoryFailure.invalidInput(.incoherentRevisionDraft)
                }
                switch action {
                case .inheritCanonical:
                    representations.append(canonicalRepresentation.content)
                case .replace(let bytes):
                    // A normalized content set forbids empty-bytes
                    // representations (docs/02-domain.md §2.1); an oversized
                    // replacement is a size problem (§16).
                    guard !bytes.isEmpty else {
                        throw HistoryFailure.invalidInput(.incoherentRevisionDraft)
                    }
                    guard bytes.count <= limits.maximumRepresentationBytes else {
                        throw HistoryFailure.invalidInput(.byteLimit)
                    }
                    representations.append(
                        ContentRepresentation(
                            typeIdentifier: typeIdentifier,
                            bytes: bytes
                        )
                    )
                case .hide:
                    // The Canonical representation is retained for lineage
                    // and general-lane dedup; only the proposed Effective
                    // Content omits it (03a §5).
                    continue
                }
            }
            // The proposed Effective Content must remain non-empty — a draft
            // that hides every Canonical type is rejected (03a §5).
            guard !representations.isEmpty else {
                throw HistoryFailure.invalidInput(.incoherentRevisionDraft)
            }
            proposed = EffectiveContent(representations: representations)
        case .revert(let target):
            switch target {
            case .canonical:
                // Revert-to-Canonical strips the Canonical fingerprints
                // (§6.2) — the same shape as the no-active-revision
                // Effective Content derivation (docs/02-domain.md §2.6).
                proposed = EffectiveContent(
                    representations: source.canonical.representations.map(\.content)
                )
            case .revision(let revisionID):
                // Revert-to-revision copies the target's complete stored
                // content (§6.2); an absent target fails before the second
                // Authority entry (§16: revision target absence →
                // `.revisionNotFound`).
                guard let revision = source.revisions.first(where: { $0.id == revisionID }) else {
                    throw HistoryFailure.revisionNotFound(revisionID)
                }
                proposed = revision.content
            }
        }

        // Step 2 — validate the Part VI hard limits with checked arithmetic:
        // no byte-count calculation wraps (docs/06-cross-cutting.md §2).
        // Representation/byte problems are `.invalidInput`, mirroring the
        // capture path; the per-item revision-count/byte bounds are
        // `.capacityExceeded` with the matching CapacityKind (§16).
        guard proposed.representations.count <= limits.maximumRepresentationsPerCaptureOrRevision else {
            throw HistoryFailure.invalidInput(.representationLimit)
        }
        var proposedTotalBytes = 0
        for representation in proposed.representations {
            guard representation.bytes.count <= limits.maximumRepresentationBytes else {
                throw HistoryFailure.invalidInput(.byteLimit)
            }
            let (newTotal, overflow) = proposedTotalBytes.addingReportingOverflow(
                representation.bytes.count
            )
            guard !overflow, newTotal <= limits.maximumProposedRevisionBytes else {
                throw HistoryFailure.invalidInput(.byteLimit)
            }
            proposedTotalBytes = newTotal
        }
        // Step 3 — mint the candidate Revision ID and creation timestamp;
        // entropy lives in Storage, never in the Domain (docs/02-domain.md
        // §4). `basedOn` is the snapshot's Content Version: the Authority
        // already rejected a stale `request.expected` when capturing the
        // snapshot, and Domain planning rechecks both tokens against the
        // reloaded facts (§6.2; docs/02-domain.md §11 steps 1–2). The mint
        // is hoisted above the R3 block below so the speculative prune
        // target (`.revise(appended:)`) carries the exact revision this
        // preparation will propose; the mint is one opaque call with no
        // side effects, so hoisting it changes nothing observable on the
        // R3-disabled (byte-for-byte v1) path.
        let candidateRevisionID = makeRevisionID()
        let createdAt = now()

        // ── V2-02 §4.3 PHASE 1 R3 block (Record 2's conditionally-EXTENDED
        //    preparation path; §5.4's ordering rule) ──
        // When R3 is active for this item's thresholds, compute the prune
        // set BEFORE the per-item hard-bound check so the check below sees
        // the POST-PRUNE POST-APPEND state. The prune relation is pure
        // (D16): `planRevisionRetentionExpansion` over the pre-append loaded
        // lineage with the revise-path target (§6.5) — the effective list is
        // `revisions + [appended]` and the active is the appended ID. With
        // the R3 lane disabled this block is skipped and the hard-bound
        // checks below run over the full loaded lineage, exactly as v1.
        var prunedInactiveRevisionIDs = Set<RevisionID>()
        if let revisionPolicy = retentionPolicies?.revisions {
            let appendedRevision = ContentRevision(
                id: candidateRevisionID,
                createdAt: createdAt,
                content: proposed
            )
            let speculativePruneSet = planRevisionRetentionExpansion(
                revisions: source.revisions,
                target: .revise(appended: appendedRevision),
                policies: HistoryRetentionPolicies(
                    age: nil,
                    storage: nil,
                    revisions: revisionPolicy
                )
            )
            let prunedIDs = Set(speculativePruneSet)
            // §8.3 revise-time unsatisfiable: if the POST-PRUNE state — the
            // pruned survivors plus the appended (now-active) revision — is
            // still over `maxRevisionBytesPerItem`, the active revision
            // alone exceeds the threshold (the planner already returned the
            // full inactive prefix; the active is never prunable, D3/D23).
            // The threshold was satisfiable when set and is unsatisfiable
            // after this large append, so the revise fails atomically here
            // — before any Authority entry, committing nothing (§2.2). The
            // count dimension is always satisfiable on revise (pruning to
            // the new active alone yields count 1 ≤ `maxRevisionsPerItem`
            // for any admitted `maxRevisionsPerItem >= 1`, §4.3), so only
            // the byte dimension is checked.
            if let maxRevisionBytes = revisionPolicy.maxRevisionBytesPerItem {
                var postPruneRevisions: [ContentRevision] = []
                postPruneRevisions.reserveCapacity(source.revisions.count + 1)
                for revision in source.revisions
                where !prunedIDs.contains(revision.id) {
                    postPruneRevisions.append(revision)
                }
                postPruneRevisions.append(appendedRevision)
                if RetainedBytesStamping.revisionScalars(of: postPruneRevisions).bytes
                    > maxRevisionBytes {
                    throw HistoryFailure.capacityExceeded(.revisionBytes)
                }
            }
            prunedInactiveRevisionIDs = prunedIDs
        }

        // `count == limit` already means the append would exceed the bound —
        // the comparison itself needs no arithmetic that could wrap. The
        // counts are the POST-PRUNE POST-APPEND state (§5.4): pruned
        // inactives are removed first, so the hard bound still rejects an
        // append whose post-prune post-append state exceeds it, and with R3
        // disabled the pruned set is empty and the check is exactly v1's.
        // The pruned IDs are a subset of the loaded IDs (the planner only
        // returns IDs from the list), so the subtraction cannot underflow.
        let postPruneRevisionCount =
            source.revisions.count - prunedInactiveRevisionIDs.count
        guard postPruneRevisionCount < limits.maximumRevisionsPerItem else {
            throw HistoryFailure.capacityExceeded(.revisionCount)
        }
        var itemRevisionBytes = proposedTotalBytes
        for revision in source.revisions
        where !prunedInactiveRevisionIDs.contains(revision.id) {
            for representation in revision.content.representations {
                let (newTotal, overflow) = itemRevisionBytes.addingReportingOverflow(
                    representation.bytes.count
                )
                guard !overflow, newTotal <= limits.maximumTotalRevisionBytesPerItem else {
                    throw HistoryFailure.capacityExceeded(.revisionBytes)
                }
                itemRevisionBytes = newTotal
            }
        }

        // Step 4 — revision projection uses the prepared proposed Effective
        // Content (§15).
        let projection = ContentProjector.project(proposed, limits: limits)

        return PreparedRevisionBundle(
            domain: PreparedRevision(
                candidateRevisionID: candidateRevisionID,
                createdAt: createdAt,
                basedOn: source.contentVersion,
                proposedContent: proposed
            ),
            projection: projection
        )
    }
}
