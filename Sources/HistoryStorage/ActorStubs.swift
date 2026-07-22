/// Step-5 stub actors for the `SwiftDataHistory` facade fields whose full
/// implementations land at roadmap steps 6–8.
/// Owning spec: docs/roadmap/03-historystorage.md step-5 note; facade field
/// list: docs/05-authority-kernel.md §2 (Part V).
///
/// At step 5, `SwiftDataHistory.open` constructs all five facade fields; a
/// stub `actor` is still `Sendable`, so `SwiftDataHistory: Sendable` is
/// derivable without escape hatches. Each stub pins the exact method
/// signature the `SwiftDataHistory` facade already calls (the signature its
/// step-6–8 implementation keeps) and throws
/// `StepDeferredError.notYetImplemented` (defined in SwiftDataHistory.swift);
/// no stub carries state — in particular the `SearchWorker` stub has no Fuse
/// field yet (Fuse is added inside it at step 7), and `ThumbnailService`
/// gains its flight table and `ThumbnailWorker` at step 8.
///
/// This file also hosts the internal Sendable value types those signatures
/// require that no other step-5 file owns (`PreparedRevisionBundle`,
/// `RevisionPreparationSnapshot`, `SearchCorpusSnapshot`, `SearchCorpusRow`).
/// Steps 6–7 may relocate each value type beside its owning implementation.
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

/// Revision-preparation worker (docs/05-authority-kernel.md §6.2). Step-5
/// stub; the two-phase OCC-safe implementation lands at roadmap step 6.
///
/// Expensive normalization/projection stays outside the commit interval: the
/// Authority captures a `RevisionPreparationSnapshot`, this actor resolves the
/// replace/revert intent into a complete proposed Effective Content, and the
/// Authority then reloads facts and lets Domain recheck the OCC token.
internal actor RevisionPreparationActor {
    internal init() {}

    /// Resolves `request` against `source` into a `PreparedRevisionBundle`
    /// (docs/05-authority-kernel.md §6.2, §8).
    ///
    /// Step-5 stub: always throws `StepDeferredError`. Step 6 implements
    /// replace/revert resolution, hard-limit validation, and projection.
    internal func prepare(
        _ request: RevisionRequest,
        from source: RevisionPreparationSnapshot
    ) throws -> PreparedRevisionBundle {
        throw StepDeferredError.notYetImplemented(
            operation: "RevisionPreparationActor.prepare"
        )
    }
}

/// Search evaluation worker (docs/05-authority-kernel.md §14.2). Step-5 stub;
/// the exact/fuzzy/regexp implementation lands at roadmap step 7.
///
/// The facade wires the two-step value pipeline: the Authority captures a
/// bounded Sendable `SearchCorpusSnapshot`, then this worker evaluates the
/// request over it off the Authority and returns the bounded page — the
/// worker never reads SwiftData and never uses dedup Candidate Rank. The stub
/// has no Fuse field yet — Fuse is confined inside this actor at step 7
/// (roadmap step-5 note).
internal actor SearchWorker {
    internal init() {}

    /// Evaluates `request` over `corpus`, returning the bounded page stamped
    /// with the corpus position (docs/05-authority-kernel.md §14.2).
    ///
    /// Step-5 stub: always throws `StepDeferredError`. Step 7 implements the
    /// three frozen search modes (docs/06-cross-cutting.md §8, WS17).
    internal func page(
        _ request: HistoryBrowseRequest,
        in corpus: SearchCorpusSnapshot
    ) throws -> HistoryPage {
        throw StepDeferredError.notYetImplemented(
            operation: "SearchWorker.page"
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
