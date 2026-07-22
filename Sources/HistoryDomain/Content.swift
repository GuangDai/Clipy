/// Content lineage values: content representations, fingerprint and signature
/// evidence, Canonical and Effective Content, content revisions, and the
/// Effective Content derivation.
/// Owning spec: docs/02-domain.md §2. Immutable pure values and functions —
/// no I/O, actors, clocks, UUID generation, or version minting
/// (docs/02-domain.md §1, §4).
import Foundation
import HistoryCore

// MARK: - Content representation (docs/02-domain.md §2.1)

/// One typed byte representation of clipboard content.
/// docs/02-domain.md §2.1
///
/// Equality is byte-exact on `(typeIdentifier, bytes)`. A normalized content
/// set is non-empty, contains at most one representation per
/// `typeIdentifier`, contains no empty-bytes representation, and is sorted by
/// `typeIdentifier` using a stable Unicode scalar ordering. Two
/// representations with the same type identifier and different bytes are
/// ambiguous input — preparation rejects them with a typed invalid-input
/// failure rather than choosing by iteration order.
package struct ContentRepresentation: Sendable, Hashable {
    package let typeIdentifier: String
    package let bytes: Data

    package init(typeIdentifier: String, bytes: Data) {
        self.typeIdentifier = typeIdentifier
        self.bytes = bytes
    }
}

// MARK: - Fingerprint and signature evidence (docs/02-domain.md §2.2)

/// An xxh3-64 fingerprint over one representation's bytes.
/// docs/02-domain.md §2.2
///
/// Evidence only: a fingerprint is not identity and is never sufficient for
/// Copy Coalescing (D7). A corrupted or colliding fingerprint may create an
/// extra dedup candidate; it must never create a false confirmed match.
package struct ContentFingerprint: Sendable, Hashable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// One Canonical representation's signature entry.
/// docs/02-domain.md §2.2
///
/// Derived from a Canonical representation and used by the Signature Index
/// for candidate generation. Signature evidence only accelerates candidacy;
/// byte-exact confirmation decides every match (D7).
package struct ContentSignatureEntry: Sendable, Hashable {
    package let typeIdentifier: String
    package let fingerprint: ContentFingerprint
    package let byteCount: Int

    package init(
        typeIdentifier: String,
        fingerprint: ContentFingerprint,
        byteCount: Int
    ) {
        self.typeIdentifier = typeIdentifier
        self.fingerprint = fingerprint
        self.byteCount = byteCount
    }
}

// MARK: - Canonical Content (docs/02-domain.md §2.3)

/// One Canonical representation together with its fingerprint evidence.
/// docs/02-domain.md §2.3
///
/// Custom equality and hashing use `content` only — fingerprints never
/// participate in either (§2.2, D7).
package struct CanonicalRepresentation: Sendable, Hashable {
    package let content: ContentRepresentation
    package let fingerprint: ContentFingerprint

    package init(content: ContentRepresentation, fingerprint: ContentFingerprint) {
        self.content = content
        self.fingerprint = fingerprint
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(content)
    }
}

/// Rejection of a proposed Canonical Content value.
/// docs/02-domain.md §2.3
///
/// Thrown only by the validating `CanonicalContent` initializer when input
/// violates the normalized-set requirements of §2.1. Preparation
/// (Part V §6.1) already sorts, deduplicates, and filters representations, so
/// a throw here is a defensive backstop against invalid construction.
package enum CanonicalContentRejection: Error, Sendable, Equatable {
    /// The representation list was empty. docs/02-domain.md §2.1, §2.3
    case emptyRepresentations
    /// A type identifier appeared more than once. docs/02-domain.md §2.1, §2.3
    case duplicateTypeIdentifier(String)
    /// A representation carried zero-length bytes. docs/02-domain.md §2.1, §2.3
    case emptyBytes(typeIdentifier: String)
    /// The list was not sorted by type identifier in the stable Unicode
    /// scalar order. docs/02-domain.md §2.1, §2.3
    case nonNormalizedOrder
}

/// The immutable ingest-lineage root of a history item.
/// docs/02-domain.md §2.3
///
/// Created only for a new History Item; preserved on Copy Coalescing; never
/// replaced by a revision; never changed by pinning, retention, or
/// observation (D2). Used by the general deduplication lane.
///
/// Equality and hashing use `content` only: the synthesized conformance
/// delegates element-wise to `CanonicalRepresentation`, whose custom
/// equality and hash ignore fingerprints (§2.2).
package struct CanonicalContent: Sendable, Hashable {
    package let representations: [CanonicalRepresentation]

    /// The one validating initializer. docs/02-domain.md §2.3
    ///
    /// Accepts already-prepared representations and verifies the
    /// normalized-set requirements of §2.1: the list is non-empty, type
    /// identifiers are unique, no representation has empty bytes, and the
    /// list is sorted by type identifier in stable Unicode scalar order.
    /// Fingerprint coverage is verified by construction — every
    /// `CanonicalRepresentation` structurally carries its fingerprint.
    ///
    /// - Throws: `CanonicalContentRejection` when any requirement fails.
    package init(representations: [CanonicalRepresentation]) throws {
        guard !representations.isEmpty else {
            throw CanonicalContentRejection.emptyRepresentations
        }
        var seen = Set<String>()
        seen.reserveCapacity(representations.count)
        for representation in representations {
            let typeIdentifier = representation.content.typeIdentifier
            guard seen.insert(typeIdentifier).inserted else {
                throw CanonicalContentRejection.duplicateTypeIdentifier(typeIdentifier)
            }
            guard !representation.content.bytes.isEmpty else {
                throw CanonicalContentRejection.emptyBytes(typeIdentifier: typeIdentifier)
            }
        }
        for (previous, next) in zip(representations, representations.dropFirst()) {
            let earlier = previous.content.typeIdentifier.unicodeScalars
            let later = next.content.typeIdentifier.unicodeScalars
            guard earlier.lexicographicallyPrecedes(later) else {
                throw CanonicalContentRejection.nonNormalizedOrder
            }
        }
        self.representations = representations
    }
}

// MARK: - Effective Content (docs/02-domain.md §2.4)

/// The single content state used for display, search, paste, editing, and
/// thumbnails.
/// docs/02-domain.md §2.4
///
/// Distinct from Canonical Content even when their bytes currently match.
/// Every consumer derives it from `effectiveContent(of:)` (§2.6).
package struct EffectiveContent: Sendable, Hashable {
    package let representations: [ContentRepresentation]

    package init(representations: [ContentRepresentation]) {
        self.representations = representations
    }
}

// MARK: - Content Revision (docs/02-domain.md §2.5)

/// One immutable, append-only revision of an item's Effective Content.
/// docs/02-domain.md §2.5
///
/// A v1 revision stores a complete Effective Content snapshot, not a sparse
/// action map: the active revision alone contains every byte required to
/// rebuild current Effective Content after restart, inactive revisions are
/// independently readable, and reverting never depends on later Canonical
/// interpretation rules.
package struct ContentRevision: Sendable, Hashable {
    package let id: RevisionID
    package let createdAt: Date
    package let content: EffectiveContent

    package init(id: RevisionID, createdAt: Date, content: EffectiveContent) {
        self.id = id
        self.createdAt = createdAt
        self.content = content
    }
}

// MARK: - Effective Content derivation (docs/02-domain.md §2.6)

/// Derives the single Effective Content state of one fully hydrated item.
/// docs/02-domain.md §2.6
///
/// With no active revision, strips fingerprints from the Canonical
/// representations and returns the normalized result. With an active
/// revision, finds it in `item.revisions` and returns its complete content
/// snapshot. Title, search body, paste bytes, edit draft, and thumbnail
/// input all derive from this one result; revision never changes the
/// Canonical signature used by general deduplication.
///
/// - Throws: `DomainRejection.corruptLineage` for corrupt persisted lineage
///   (§6, §11 step 3, D3): a non-nil `activeRevisionID` naming no stored
///   revision, a duplicated active revision, or a non-empty revision list
///   with a nil active ID. Corrupt state is never an implicit fallback to
///   Canonical Content.
package func effectiveContent(of item: HistoryItemState) throws -> EffectiveContent {
    guard let activeRevisionID = item.activeRevisionID else {
        // D3: a nil active ID is valid only when the revision list is empty.
        guard item.revisions.isEmpty else {
            throw DomainRejection.corruptLineage
        }
        return EffectiveContent(
            representations: item.canonical.representations.map(\.content)
        )
    }
    var activeRevision: ContentRevision?
    for revision in item.revisions where revision.id == activeRevisionID {
        guard activeRevision == nil else {
            // The active ID names more than one stored revision.
            throw DomainRejection.corruptLineage
        }
        activeRevision = revision
    }
    guard let activeRevision else {
        // The active ID names no stored revision.
        throw DomainRejection.corruptLineage
    }
    return activeRevision.content
}
