/// Content lineage values: content representations, fingerprint and signature
/// evidence, Canonical and Effective Content, content revisions, and the
/// Effective Content derivation.
/// Owning spec: docs/02-domain.md §2. Immutable pure values and functions —
/// no I/O, actors, clocks, UUID generation, or version minting
/// (docs/02-domain.md §1, §4).
import Foundation
import HistoryCore

/// A representation is identified within one ordered system pasteboard item.
/// Payload bytes are deliberately absent from this lookup key (02 §2.1).
package struct ContentRepresentationKey: Sendable, Hashable {
    package let pasteboardItemIndex: Int
    package let typeIdentifier: String

    package init(pasteboardItemIndex: Int, typeIdentifier: String) {
        self.pasteboardItemIndex = pasteboardItemIndex
        self.typeIdentifier = typeIdentifier
    }

    /// Normalization orders exact scalar spellings; equality still recognizes
    /// canonically equivalent type spellings. This is deliberately separate
    /// from Comparable's equality-consistent ordering contract.
    package func precedes(_ other: Self) -> Bool {
        if pasteboardItemIndex != other.pasteboardItemIndex {
            return pasteboardItemIndex < other.pasteboardItemIndex
        }
        return typeIdentifier.unicodeScalars.lexicographicallyPrecedes(other.typeIdentifier.unicodeScalars)
    }
}

// MARK: - Content representation (docs/02-domain.md §2.1)

/// One typed byte representation of clipboard content.
/// docs/02-domain.md §2.1
///
/// Equality uses Swift String equality (Unicode canonical equivalence) for
/// `typeIdentifier` and byte-exact Data equality for `bytes`. A normalized
/// content set contains non-empty ordered items, at most one representation
/// per canonically equivalent `typeIdentifier` within each item, and no
/// empty bytes. It is sorted by item index then stable Unicode scalar type
/// order. Two representations at the same item index with the same type and
/// different bytes are
/// ambiguous input — preparation rejects them with a typed invalid-input
/// failure rather than choosing by iteration order.
package struct ContentRepresentation: Sendable, Hashable {
    package let pasteboardItemIndex: Int
    package var key: ContentRepresentationKey {
        ContentRepresentationKey(pasteboardItemIndex: pasteboardItemIndex, typeIdentifier: typeIdentifier)
    }
    package let typeIdentifier: String
    package let bytes: Data

    package init(typeIdentifier: String, bytes: Data, pasteboardItemIndex: Int = 0) {
        self.pasteboardItemIndex = pasteboardItemIndex
        self.typeIdentifier = typeIdentifier
        self.bytes = bytes
    }
}

// MARK: - Fingerprint and signature evidence (docs/02-domain.md §2.2)

/// An xxh3-64 fingerprint over one representation's bytes.
/// docs/02-domain.md §2.2
///
/// Evidence only: a fingerprint is not identity and is never sufficient for
/// Copy Coalescing (D7). A collision may add a candidate; Storage must prove
/// authoritative coverage before absence can exclude one. No fingerprint may
/// create a false confirmed match because confirmation remains byte-exact.
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
    package let pasteboardItemIndex: Int
    package var key: ContentRepresentationKey {
        ContentRepresentationKey(pasteboardItemIndex: pasteboardItemIndex, typeIdentifier: typeIdentifier)
    }
    package let typeIdentifier: String
    package let fingerprint: ContentFingerprint
    package let byteCount: Int

    package init(
        typeIdentifier: String,
        fingerprint: ContentFingerprint,
        byteCount: Int,
        pasteboardItemIndex: Int = 0
    ) {
        self.pasteboardItemIndex = pasteboardItemIndex
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
    package var pasteboardItemCount: Int { (representations.last?.content.pasteboardItemIndex ?? -1) + 1 }

    /// The one validating initializer. docs/02-domain.md §2.3
    ///
    /// Accepts already-prepared representations and verifies the
    /// normalized-set requirements of §2.1: the list is non-empty, type
    /// identifiers are unique, no representation has empty bytes, and the
    /// list is sorted by type identifier in stable Unicode scalar order.
    /// Fingerprint coverage is verified by construction — every
    /// `CanonicalRepresentation` structurally carries its fingerprint.
    /// Maintainers adding a new normalized-set invariant must also add the
    /// corresponding pre-proof and canary at IngestPreparation §6.1; its
    /// catch deliberately classifies any missed invariant as a Storage bug.
    ///
    /// - Throws: `CanonicalContentRejection` when any requirement fails.
    package init(representations: [CanonicalRepresentation]) throws {
        _ = try normalizedRepresentationKeys(representations.lazy.map(\.content))
        self.representations = representations
    }
}

/// Canonical ingest and proposed revisions share the same normalized shape
/// (02 §2.1/§11). Return the already-checked keys for revision membership
/// validation; lazy Canonical projections never copy clipboard payloads.
func normalizedRepresentationKeys(
    _ representations: some Collection<ContentRepresentation>
) throws -> Set<ContentRepresentationKey> {
    guard !representations.isEmpty else {
        throw CanonicalContentRejection.emptyRepresentations
    }
    var seen = Set<ContentRepresentationKey>()
    seen.reserveCapacity(representations.count)
    for representation in representations {
        guard seen.insert(representation.key).inserted else {
            throw CanonicalContentRejection.duplicateTypeIdentifier(representation.typeIdentifier)
        }
        guard !representation.bytes.isEmpty else {
            throw CanonicalContentRejection.emptyBytes(typeIdentifier: representation.typeIdentifier)
        }
    }
    guard representations.first?.pasteboardItemIndex == 0 else {
        throw CanonicalContentRejection.nonNormalizedOrder
    }
    for (previous, next) in zip(representations, representations.dropFirst()) {
        guard previous.key.precedes(next.key),
              next.pasteboardItemIndex - previous.pasteboardItemIndex <= 1 else {
            throw CanonicalContentRejection.nonNormalizedOrder
        }
    }
    return seen
}

// MARK: - Effective Content (docs/02-domain.md §2.4)

/// The single content state used for display, search, paste, editing, and
/// thumbnails.
/// docs/02-domain.md §2.4
///
/// Distinct from Canonical Content even when their bytes currently match.
/// Storage resolves the active lineage before constructing operation facts
/// (§2.6; V2-09 §5), without hydrating older revision payloads.
package struct EffectiveContent: Sendable, Hashable {
    package let representations: [ContentRepresentation]

    package init(representations: [ContentRepresentation]) {
        self.representations = representations
    }

    /// Representation-set equality for normalized content (`02` §2.1,
    /// §9.3, §11): equivalent identifier spellings can occupy different
    /// positions in scalar-sorted arrays. Index only the identifiers, then
    /// compare payload bytes without hashing clipboard content.
    package func hasSameRepresentations(as other: EffectiveContent) -> Bool {
        guard representations.count == other.representations.count else { return false }
        if representations == other.representations { return true }
        var bytesByType: [ContentRepresentationKey: Data] = [:]
        bytesByType.reserveCapacity(representations.count)
        for representation in representations {
            bytesByType[representation.key] = representation.bytes
        }
        return other.representations.allSatisfy {
            bytesByType[$0.key] == $0.bytes
        }
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
