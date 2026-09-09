/// Scalar read-row projection (§14.1) and rejection mappings.
import Foundation
import HistoryCore
import HistoryDomain

// MARK: - Scalar read row helper (docs/05-authority-kernel.md §14.1)

/// One bounded metadata projection from a SQLite row. Canonical content,
/// revisions, inline representation bytes and blob files are not selected.
internal struct ScalarReadRow {
    internal let id: HistoryItemID
    internal let contentVersion: ContentVersion
    internal let title: String
    internal let effectiveTypeIdentifiersBlob: Data
    internal let lastCopiedAt: Date
    internal let copyCount: UInt64
    internal let lastSource: String?
    internal let sourceCount: Int
    internal let pinOrdinal: PinOrdinal?

    /// Both lanes select precisely this layout. Keeping payload columns out
    /// of the SELECT prevents their materialization, including lookahead rows.
    internal static let columns = """
        id, contentVersion, titleUTF8, effectiveTypeIdentifiersBlob,
        lastCopiedAt, copyCount, lastSource, pinOrdinal,
        sourceCount
        """

    internal init(_ statement: SQLiteStatement, limits: HistoryLimits) throws {
        let rawID = try statement.text(at: 0)
        guard let uuid = UUID(uuidString: rawID), uuid.uuidString == rawID,
              try statement.blobByteCount(at: 2) <= limits.maximumStoredTitleUTF8Bytes,
              try statement.blobByteCount(at: 3) <= EffectiveTypeIdentifiersBlobCodec.maximumBlobBytes(limits: limits) else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        id = HistoryItemID(rawValue: uuid)
        let titleUTF8 = try statement.blob(at: 2)
        let date = try Date(timeIntervalSinceReferenceDate: statement.real(at: 4))
        let count = try sqliteUInt64(statement.blob(at: 5))
        let source = try statement.optionalText(at: 6)
        let ordinal: Int?
        if try statement.isNull(at: 7) {
            ordinal = nil
        } else {
            guard let value = try Int(exactly: statement.integer(at: 7)) else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            ordinal = value
        }
        contentVersion = try mapCodecFailure {
            try RevisionStateBlobCodec.decodeContentVersion(sqliteUInt64(statement.blob(at: 1)))
        }
        title = try mapCodecFailure {
            try RevisionStateBlobCodec.validateFiniteLastCopiedAt(date)
            try RevisionStateBlobCodec.validateCopyCount(count)
            try RevisionStateBlobCodec.validateSourceObservation(source, limits: limits)
            return try ContentProjector.decodeStoredTitle(titleUTF8, limits: limits)
        }
        effectiveTypeIdentifiersBlob = try statement.blob(at: 3)
        lastCopiedAt = date
        copyCount = count
        lastSource = source
        sourceCount = try HistoryItemRowHydration.integer(statement, 8)
        guard sourceCount >= 0, UInt64(sourceCount) <= count else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        pinOrdinal = try mapCodecFailure { try RevisionStateBlobCodec.decodePinOrdinal(ordinal) }
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
            search: nil, sourceCount: sourceCount
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
