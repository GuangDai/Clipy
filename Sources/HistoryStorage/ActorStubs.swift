/// The step-8 stub actor for the `SwiftDataHistory` facade field whose full
/// implementation lands at roadmap step 8 (`ThumbnailService`), plus the
/// step-6 `RevisionPreparationActor` implementation and the internal
/// Sendable value types those signatures share.
/// Owning spec: docs/roadmap/03-historystorage.md step-5 note; facade field
/// list: docs/05-authority-kernel.md §2 (Part V).
///
/// `SwiftDataHistory.open` constructs all five facade fields; a stub `actor`
/// is still `Sendable`, so `SwiftDataHistory: Sendable` is derivable without
/// escape hatches. The remaining stub pins the exact method signature the
/// `SwiftDataHistory` facade already calls (the signature its step-8
/// implementation keeps) and throws `StepDeferredError.notYetImplemented`
/// (defined in SwiftDataHistory.swift); no stub carries state —
/// `ThumbnailService` gains its flight table and `ThumbnailWorker` at
/// step 8. (The `SearchWorker` stub left this file at roadmap step 7: its
/// exact/fuzzy/regexp implementation now lives in SearchWorker.swift, with
/// Fuse confined inside the actor per docs/01-architecture.md §6.)
///
/// This file also hosts the internal Sendable value types those signatures
/// require that no other file owns (`PreparedRevisionBundle`,
/// `RevisionPreparationSnapshot`, `SearchCorpusSnapshot`, `SearchCorpusRow`).
/// Step 6 keeps the revision values beside their preparation actor here;
/// `SearchCorpusSnapshot`/`SearchCorpusRow` stay here as the
/// docs/05-authority-kernel.md §14.2 contract between the Authority (which
/// captures the corpus) and the `SearchWorker` in SearchWorker.swift
/// (which evaluates it).
import Foundation
import HistoryCore
import HistoryDomain

/// The output of revision preparation: the Domain-ready proposed revision plus
/// the durable bounded projection computed from the proposed Effective Content
/// (docs/05-authority-kernel.md §6.2).
///
/// Defined here at roadmap step 5 so the `RevisionPreparationActor` stub can
/// pin its step-6 signature; step 6 may relocate it beside
/// `PreparedCaptureBundle` in IngestPreparation.swift.
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
/// Defined here at roadmap step 5 so the `RevisionPreparationActor` stub can
/// pin its step-6 signature; step 6 may relocate it beside the fact
/// loaders/hydration in FactLoaders.swift.
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
/// Defined here at roadmap step 5 so the `SearchWorker` stub can pin its
/// step-7 signature; step 7 may relocate it beside the read path.
internal struct SearchCorpusSnapshot: Sendable {
    /// The durable position the corpus was read at; stamps the returned page.
    let position: ChangePosition
    /// Scalar projection rows for every retained item (bounded by the hard
    /// retained-item maximum, docs/06-cross-cutting.md §2).
    let rows: [SearchCorpusRow]
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

    /// Creates the preparation actor. Production uses the default
    /// `HistoryLimits.standard` (docs/06-cross-cutting.md §2).
    internal init(limits: HistoryLimits = .standard) {
        self.limits = limits
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
        // `count == limit` already means the append would exceed the bound —
        // the comparison itself needs no arithmetic that could wrap.
        guard source.revisions.count < limits.maximumRevisionsPerItem else {
            throw HistoryFailure.capacityExceeded(.revisionCount)
        }
        var itemRevisionBytes = proposedTotalBytes
        for revision in source.revisions {
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

        // Step 3 — mint the candidate Revision ID and creation timestamp;
        // entropy lives in Storage, never in the Domain (docs/02-domain.md
        // §4). `basedOn` is the snapshot's Content Version: the Authority
        // already rejected a stale `request.expected` when capturing the
        // snapshot, and Domain planning rechecks both tokens against the
        // reloaded facts (§6.2; docs/02-domain.md §11 steps 1–2).
        let candidateRevisionID = RevisionID(rawValue: UUID())
        let createdAt = Date()

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

/// Thumbnail single-flight service (docs/05-authority-kernel.md §14.5).
/// Step-5 stub; the flight table and its owned `ThumbnailWorker` land at
/// roadmap step 8 (docs/06-cross-cutting.md §8, WS15).
///
/// The facade wires the pipeline: the Authority validates the dimensions,
/// fetches exactly one item, verifies the requested Content Version, and
/// returns immutable source image bytes (the facade answers `nil` itself when
/// the item has no thumbnailable representation); this service then
/// joins/creates the single-flight for the exact key and decodes off the
/// Authority, after all SwiftData objects and context have been released.
/// Completed bytes are not retained (docs/04-coherence.md §9).
internal actor ThumbnailService {
    internal init() {}

    /// Decodes `sourceBytes` into an encoded thumbnail for one item at one
    /// Effective Content state, sized to `pixels`
    /// (docs/05-authority-kernel.md §14.5).
    ///
    /// Step-5 stub: always throws `StepDeferredError`. Step 8 implements the
    /// version fence and single-flight decode.
    internal func thumbnail(
        _ sourceBytes: Data,
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload {
        throw StepDeferredError.notYetImplemented(
            operation: "ThumbnailService.thumbnail"
        )
    }
}
