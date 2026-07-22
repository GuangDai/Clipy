// Prepared action inputs (docs/02-domain.md §4).
//
// Preparation and entropy live in `HistoryStorage`, then enter pure planning as
// values. These types are types only: the Domain never calls `UUID()`, `Date()`,
// `ContentVersion.initial/successor`, or `ChangePosition.successor` — identifier
// and version minting is Storage's job (docs/02-domain.md §4, §13).
import Foundation
import HistoryCore

/// A capture prepared by `HistoryStorage` for pure ingest planning: the candidate
/// item identity, its immutable canonical content, the copy origin observation,
/// and the observation timestamp — all minted/validated off the Authority and
/// passed in as values (docs/02-domain.md §4).
package struct PreparedCapture: Sendable {
    /// Candidate History Item identity minted by Storage; used only if the
    /// capture inserts a new item rather than coalescing (docs/02-domain.md §4).
    package let candidateID: HistoryItemID
    /// Immutable ingest-lineage root content, validated at construction of
    /// `CanonicalContent` itself (docs/02-domain.md §2.3).
    package let canonical: CanonicalContent
    /// Provenance observations for the copy; never authenticated
    /// (docs/02-domain.md §3.1).
    package let origin: CopyOrigin
    /// Observation timestamp supplied by Storage; the Domain never reads a clock
    /// (docs/02-domain.md §4).
    package let observedAt: Date

    package init(
        candidateID: HistoryItemID,
        canonical: CanonicalContent,
        origin: CopyOrigin,
        observedAt: Date
    ) {
        self.candidateID = candidateID
        self.canonical = canonical
        self.origin = origin
        self.observedAt = observedAt
    }
}

/// A revision prepared by `HistoryStorage` from the public `RevisionDraft` /
/// `RevisionTarget` intent: raw byte/count/coherence bounds are validated off
/// the Authority against an immutable revision-preparation snapshot, producing
/// this complete proposed content. Domain planning rechecks it against the
/// latest item and the request's OCC token before admitting it
/// (docs/02-domain.md §4).
package struct PreparedRevision: Sendable {
    /// Candidate revision identity minted by Storage; used only if the revision
    /// is admitted and appended (docs/02-domain.md §4).
    package let candidateRevisionID: RevisionID
    /// Creation timestamp supplied by Storage; the Domain never reads a clock
    /// (docs/02-domain.md §4).
    package let createdAt: Date
    /// OCC token: the Content Version the proposer based its edit on; checked
    /// against the latest item during planning (docs/02-domain.md §4, §11).
    package let basedOn: ContentVersion
    /// The complete proposed Effective Content after applying the intent
    /// (docs/02-domain.md §2.4, §4).
    package let proposedContent: EffectiveContent

    package init(
        candidateRevisionID: RevisionID,
        createdAt: Date,
        basedOn: ContentVersion,
        proposedContent: EffectiveContent
    ) {
        self.candidateRevisionID = candidateRevisionID
        self.createdAt = createdAt
        self.basedOn = basedOn
        self.proposedContent = proposedContent
    }
}
