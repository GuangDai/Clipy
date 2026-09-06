/// Scalar read-row projection (§14.1) and rejection mappings.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

// MARK: - Scalar read row helper (docs/05-authority-kernel.md §14.1)

/// One scalar projection row extracted from a fetched `HistoryItemRow`, with
/// the decoded scalar fields `recentPage` needs to assemble a `HistoryRow` and
/// mint the continuation anchor. No `@Model` instance escapes the read
/// interval (§5).
internal struct ScalarReadRow {
    internal let id: HistoryItemID
    internal let contentVersion: ContentVersion
    internal let title: String
    internal let effectiveTypeIdentifiersBlob: Data
    internal let lastCopiedAt: Date
    internal let copyCount: UInt64
    internal let lastSource: String?
    internal let pinOrdinal: PinOrdinal?

    internal init(_ row: HistoryItemRow, limits: HistoryLimits) throws {
        self.id = HistoryItemID(rawValue: row.id)
        let titleUTF8 = row.titleUTF8
        let lastCopiedAt = row.lastCopiedAt
        let copyCount = row.copyCount
        let lastSource = row.lastSource
        let title = try mapCodecFailure {
            let title = try ContentProjector.decodeStoredTitle(titleUTF8, limits: limits)
            try RevisionStateBlobCodec.validateFiniteLastCopiedAt(lastCopiedAt)
            try RevisionStateBlobCodec.validateCopyCount(copyCount)
            try RevisionStateBlobCodec.validateSourceObservation(
                lastSource,
                limits: limits
            )
            return title
        }
        self.contentVersion = try mapCodecFailure {
            try RevisionStateBlobCodec.decodeContentVersion(row.contentVersionRaw)
        }
        self.title = title
        self.effectiveTypeIdentifiersBlob = row.effectiveTypeIdentifiersBlob
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.lastSource = lastSource
        self.pinOrdinal = try mapCodecFailure {
            try RevisionStateBlobCodec.decodePinOrdinal(row.pinOrdinal)
        }
    }

    /// The `.defaultOrder` anchor for this row (04 §6).
    internal var defaultOrderAnchor: StoredOrderingAnchor {
        .defaultOrder(
            pinnedOrdinal: pinOrdinal?.rawValue,
            lastCopiedAt: lastCopiedAt,
            id: id
        )
    }

    /// Whether this row matches the given continuation anchor (04 §6).
    internal func matches(_ anchor: StoredOrderingAnchor) -> Bool {
        switch anchor {
        case .defaultOrder(let pinnedOrdinal, let anchoredLastCopiedAt, let anchoredID):
            return id == anchoredID
                && lastCopiedAt == anchoredLastCopiedAt
                && pinOrdinal?.rawValue == pinnedOrdinal
        case .fuzzyUnpinned:
            // The recent-browse path only produces `.defaultOrder` anchors;
            // a fuzzy anchor never matches here.
            return false
        }
    }

    /// Maps this scalar row to a `HistoryRow`, decoding the small
    /// `effectiveTypeIdentifiersBlob` projection (§14.1: the effective type
    /// identifiers blob decode is a small scalar blob, not a content blob).
    internal func toHistoryRow(limits: HistoryLimits) throws -> HistoryRow {
        let typeIdentifiers = try mapCodecFailure {
            try EffectiveTypeIdentifiersBlobCodec.decode(
                effectiveTypeIdentifiersBlob,
                limits: limits
            )
        }
        return HistoryRow(
            item: HistoryItemReference(id: id, contentVersion: contentVersion),
            title: title,
            typeIdentifiers: typeIdentifiers,
            lastCopiedAt: lastCopiedAt,
            copyCount: copyCount,
            lastSource: lastSource,
            pinnedPosition: pinOrdinal?.rawValue,
            search: nil
        )
    }
}

internal extension DomainRejection {
    /// The exhaustive docs/02-domain.md §6 → Part III mapping the storage
    /// boundary applies to every planner throw.
    var historyFailure: HistoryFailure {
        switch self {
        case .notFound(let itemID):
            return .notFound(itemID)
        case .staleContent(let expected, let current):
            return .staleContent(expected: expected, current: current)
        case .invalidPinnedPlacement(let failure):
            return .invalidPinnedPlacement(failure)
        case .invalidRevisionDraft:
            return .invalidInput(.incoherentRevisionDraft)
        case .candidateItemIDCollision:
            // Capture Authority intercepts this package-only retry signal.
            // Any other mapping site seeing it has violated that ownership.
            return .persistence(.invariantViolation)
        case .corruptLineage:
            return .persistence(.invariantViolation)
        case .capacityExceeded(let kind):
            return .capacityExceeded(kind)
        }
    }
}

internal extension SignatureIndexRejection {
    /// The §13 startup mapping (§2, §16): corrupt durable signature metadata
    /// fails open as `.persistence(.corruptStoredValue)` rather than
    /// enabling writes from an unproved state; an over-bound retained count
    /// is an invariant violation. Delta-prevalidation cases are unreachable
    /// from `build(from:limits:)` and map defensively.
    var startupFailure: HistoryFailure {
        switch self {
        case .retainedCountExceedsBound:
            return .persistence(.invariantViolation)
        case .emptySignatureEntries, .duplicateEntry, .duplicateTypeIdentifier:
            return .persistence(.corruptStoredValue)
        case .additionAlreadyIndexed, .removalNotIndexed, .overlappingAdditionAndRemoval:
            return .persistence(.invariantViolation)
        }
    }
}
