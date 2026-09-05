/// PageCursorCodec / cursor wire types — the versioned, fail-closed codec for
/// the opaque `HistoryPageCursor` payload.
/// Owning spec: docs/04-coherence.md §6 (cursor semantics: complete normalized
/// query shape + page ChangePosition + complete last-row ordering anchor +
/// process-instance marker), §16 (failure translation: cursor shape,
/// generation, or position mismatch → `.snapshotExpired`); bounds:
/// docs/06-cross-cutting.md §2.
///
/// `HistoryPageCursor.payload` is the only public surface; callers never
/// inspect or mint it. Decode validates the wire format, the format version,
/// and the process-instance marker exactly, then returns a
/// `ResolvedPageCursor`. ANY decode or marker failure throws one typed
/// decode-side `PageCursorRejection`; the caller maps those cases to
/// `.snapshotExpired(current:)` — an undecodable or mismatched cursor is an
/// EXPIRED/INVALID cursor (§16), NEVER codec corruption of durable state.
/// The separate encode-side rejection is an internal invariant violation.
///
/// `HistoryItemID`, `SearchMode`, and `ChangePosition` are not `Codable` in
/// `HistoryCore`; the cursor's Codable conformance is manual, encoding each
/// through its primitive raw value.
import Foundation
import HistoryCore

// MARK: - Resolved cursor value (docs/04-coherence.md §6)

/// The fully validated cursor the read paths resume from: the complete
/// normalized query shape, the page's Change Position, and the complete
/// last-row ordering anchor. docs/04-coherence.md §6
///
/// The Authority captures the position inside one non-suspending read
/// interval (§2) and the `SearchWorker` mints the continuation cursor
/// off-actor (§7); `PageCursorCodec` is the sole encode/decode boundary.
internal struct ResolvedPageCursor: Sendable, Hashable {
    internal let queryShape: StoredQueryShape
    internal let position: ChangePosition
    internal let anchor: StoredOrderingAnchor

    internal init(
        queryShape: StoredQueryShape,
        position: ChangePosition,
        anchor: StoredOrderingAnchor
    ) {
        self.queryShape = queryShape
        self.position = position
        self.anchor = anchor
    }
}

/// The complete normalized query shape a cursor binds to (§6 step 1: "the
/// request shape matches the cursor"). Same kind, same term+mode for search,
/// same limit.
internal enum StoredQueryShape: Sendable, Hashable {
    /// Recent browse: the limit alone distinguishes the shape.
    case recent(limit: Int)
    /// Search browse: the normalized term, the evaluation mode, and the limit.
    case search(text: String, mode: SearchMode, limit: Int)

    // MARK: Request correspondence (§6 step 1)

    /// Builds the stored shape from a browse request. The caller has already
    /// validated the limit against the Part VI page-row range (§14.1).
    internal init(request: HistoryBrowseRequest) {
        switch request.kind {
        case .recent:
            self = .recent(limit: request.limit)
        case .search(let text, let mode):
            self = .search(text: text, mode: mode, limit: request.limit)
        }
    }

    /// Whether `request` matches this stored shape — same kind, same
    /// term+mode for search, same limit (§6 step 1).
    internal func matches(_ request: HistoryBrowseRequest) -> Bool {
        switch self {
        case .recent(let limit):
            guard case .recent = request.kind else { return false }
            return request.limit == limit
        case .search(let text, let mode, let limit):
            guard case .search(let requestText, let requestMode) = request.kind else {
                return false
            }
            // Search consumes the original scalar sequence (exact uses
            // literal matching). Swift String equality folds canonical
            // equivalents, which can resume a different query at this anchor.
            return text.utf8.elementsEqual(requestText.utf8)
                && mode == requestMode
                && request.limit == limit
        }
    }
}

/// The complete last-row ordering anchor a continuation cursor binds to
/// (§6: "the complete last-row ordering anchor"). Each case is one ordering
/// lane; decode reproduces the exact lane the encode chose.
internal enum StoredOrderingAnchor: Sendable, Hashable {
    /// Default-order anchor (recent browse; exact/regexp search; fuzzy pinned
    /// lane): the last row's pin group, ordinal-or-recency key, and final ID
    /// (04 §6).
    case defaultOrder(pinnedOrdinal: Int?, lastCopiedAt: Date, id: HistoryItemID)
    /// Fuzzy unpinned lane: the last row's full sort key (score is internal,
    /// the cursor is opaque — 03b §8: "Search scores and Fuse objects remain
    /// internal").
    case fuzzyUnpinned(score: Double, lastCopiedAt: Date, id: HistoryItemID)
}

// MARK: - Cursor rejection (docs/05-authority-kernel.md §16)

/// One typed cursor-codec rejection. Decode-side cases map to
/// `.snapshotExpired(current:)` (§16: "cursor shape, generation, or position
/// mismatch → `.snapshotExpired`"); the encode-side case maps to an internal
/// invariant violation at the minting boundary.
internal enum PageCursorRejection: Error, Sendable, Equatable {
    /// The payload is not a decodable v1 container at all — foreign bytes,
    /// truncation, or a well-formed container of the wrong shape.
    case malformedCursor
    /// `formatVersion` is not exactly 1.
    case unknownCursorVersion(found: UInt16)
    /// The process-instance marker does not match this Authority.
    case processMarkerMismatch
    /// Encoding a previously validated cursor failed. Unreachable for valid
    /// input; an encode-side failure is an internal invariant violation, not
    /// an expired cursor.
    case encodingFailed
}

// MARK: - Manual Codable (HistoryItemID/SearchMode/ChangePosition are not Codable)

/// The Codable wire form of a `StoredQueryShape`. `SearchMode` is not Codable,
/// so the mode is serialized as a raw `String` tag.
private struct StoredQueryShapeWire: Codable {
    let kind: String
    let limit: Int
    let text: String?
    let mode: String?
}

/// The Codable wire form of a `StoredOrderingAnchor`. `HistoryItemID` is not
/// Codable, so the ID is serialized as its raw `UUID`.
private struct StoredOrderingAnchorWire: Codable {
    let kind: String
    let pinnedOrdinal: Int?
    let score: Double?
    let lastCopiedAt: Date?
    let id: UUID?
}

private extension StoredQueryShape {
    var wire: StoredQueryShapeWire {
        switch self {
        case .recent(let limit):
            return StoredQueryShapeWire(
                kind: "recent", limit: limit, text: nil, mode: nil
            )
        case .search(let text, let mode, let limit):
            return StoredQueryShapeWire(
                kind: "search",
                limit: limit,
                text: text,
                mode: StoredQueryShape.modeTag(mode)
            )
        }
    }

    init(fromWire wire: StoredQueryShapeWire) throws {
        let limits = HistoryLimits.standard
        guard limits.pageRowLimitRange.contains(wire.limit) else {
            throw PageCursorRejection.malformedCursor
        }
        switch wire.kind {
        case "recent":
            guard wire.text == nil, wire.mode == nil else {
                throw PageCursorRejection.malformedCursor
            }
            self = .recent(limit: wire.limit)
        case "search":
            guard let text = wire.text, let modeTag = wire.mode else {
                throw PageCursorRejection.malformedCursor
            }
            guard text.utf8.count <= limits.maximumSearchTermUTF8Bytes else {
                throw PageCursorRejection.malformedCursor
            }
            let mode = try StoredQueryShape.mode(fromTag: modeTag)
            self = .search(text: text, mode: mode, limit: wire.limit)
        default:
            throw PageCursorRejection.malformedCursor
        }
    }

    private static func modeTag(_ mode: SearchMode) -> String {
        switch mode {
        case .exact: return "exact"
        case .fuzzy: return "fuzzy"
        case .regexp: return "regexp"
        }
    }

    private static func mode(fromTag tag: String) throws -> SearchMode {
        switch tag {
        case "exact": return .exact
        case "fuzzy": return .fuzzy
        case "regexp": return .regexp
        default:
            throw PageCursorRejection.malformedCursor
        }
    }
}

private extension StoredOrderingAnchor {
    var wire: StoredOrderingAnchorWire {
        switch self {
        case .defaultOrder(let pinnedOrdinal, let lastCopiedAt, let id):
            return StoredOrderingAnchorWire(
                kind: "defaultOrder",
                pinnedOrdinal: pinnedOrdinal,
                score: nil,
                lastCopiedAt: lastCopiedAt,
                id: id.rawValue
            )
        case .fuzzyUnpinned(let score, let lastCopiedAt, let id):
            return StoredOrderingAnchorWire(
                kind: "fuzzyUnpinned",
                pinnedOrdinal: nil,
                score: score,
                lastCopiedAt: lastCopiedAt,
                id: id.rawValue
            )
        }
    }

    init(fromWire wire: StoredOrderingAnchorWire) throws {
        switch wire.kind {
        case "defaultOrder":
            guard wire.score == nil,
                  wire.pinnedOrdinal.map({ $0 >= 0 }) ?? true,
                  let lastCopiedAt = wire.lastCopiedAt,
                  lastCopiedAt.timeIntervalSinceReferenceDate.isFinite,
                  let id = wire.id
            else {
                throw PageCursorRejection.malformedCursor
            }
            self = .defaultOrder(
                pinnedOrdinal: wire.pinnedOrdinal,
                lastCopiedAt: lastCopiedAt,
                id: HistoryItemID(rawValue: id)
            )
        case "fuzzyUnpinned":
            guard wire.pinnedOrdinal == nil,
                  let score = wire.score,
                  score.isFinite,
                  let lastCopiedAt = wire.lastCopiedAt,
                  lastCopiedAt.timeIntervalSinceReferenceDate.isFinite,
                  let id = wire.id else {
                throw PageCursorRejection.malformedCursor
            }
            self = .fuzzyUnpinned(
                score: score,
                lastCopiedAt: lastCopiedAt,
                id: HistoryItemID(rawValue: id)
            )
        default:
            throw PageCursorRejection.malformedCursor
        }
    }
}

// MARK: - Wire value (docs/05-authority-kernel.md §4 style)

/// Versioned wire value of the opaque cursor payload. `formatVersion` is
/// exactly 1 for every cursor `PageCursorCodec` writes; decode rejects any
/// other version. The `processMarker` is the Authority's process-instance
/// marker (04 §6). The query shape and anchor are carried as their Codable
/// wire forms.
private struct PageCursorBlobV1: Codable, Sendable {
    let formatVersion: UInt16
    let processMarker: UUID
    let rawValue: UInt64
    let queryShape: StoredQueryShapeWire
    let anchor: StoredOrderingAnchorWire
}

// MARK: - Codec (docs/04-coherence.md §6)

/// Encodes a `ResolvedPageCursor` to its opaque payload and decodes it back,
/// validating the wire format, format version, and process-instance marker
/// exactly. docs/04-coherence.md §6
internal enum PageCursorCodec {
    /// The only cursor version this codec reads or writes.
    private static let formatVersion: UInt16 = 1

    /// Pre-parse cursor envelope. A valid search term may consume 4,096 UTF-8
    /// bytes and JSON escaping can expand one input byte to six ASCII bytes;
    /// two KiB covers every fixed field and container delimiter (04 §6).
    internal static let maximumPayloadBytes =
        HistoryLimits.standard.maximumSearchTermUTF8Bytes * 6 + 2_048

    // MARK: Encode

    /// Encodes a resolved cursor deterministically with the Authority's
    /// process marker. Encoding is infallible for the finite primitive values
    /// built by the read paths; any encoder rejection is nevertheless surfaced
    /// as `PageCursorRejection.encodingFailed` so the minting boundary can map
    /// it to `.persistence(.invariantViolation)` immediately.
    internal static func encode(
        _ resolved: ResolvedPageCursor,
        processMarker: UUID
    ) throws -> HistoryPageCursor {
        let blob = PageCursorBlobV1(
            formatVersion: formatVersion,
            processMarker: processMarker,
            rawValue: resolved.position.rawValue,
            queryShape: resolved.queryShape.wire,
            anchor: resolved.anchor.wire
        )
        do {
            let payload = try CodecWireFormat.makeEncoder().encode(blob)
            guard payload.count <= maximumPayloadBytes else {
                throw PageCursorRejection.encodingFailed
            }
            return HistoryPageCursor(payload: payload)
        } catch {
            throw PageCursorRejection.encodingFailed
        }
    }

    // MARK: Decode

    /// Decodes an opaque cursor, validating the wire format, format version,
    /// and process marker exactly. ANY failure throws one decode-side
    /// `PageCursorRejection`, which the caller maps to
    /// `.snapshotExpired(current:)` (§16).
    internal static func decode(
        _ cursor: HistoryPageCursor,
        processMarker: UUID
    ) throws -> ResolvedPageCursor {
        guard cursor.payload.count <= maximumPayloadBytes else {
            throw PageCursorRejection.malformedCursor
        }
        let blob: PageCursorBlobV1
        do {
            blob = try CodecWireFormat.makeDecoder().decode(
                PageCursorBlobV1.self,
                from: cursor.payload
            )
        } catch {
            throw PageCursorRejection.malformedCursor
        }
        guard blob.formatVersion == formatVersion else {
            throw PageCursorRejection.unknownCursorVersion(found: blob.formatVersion)
        }
        guard blob.processMarker == processMarker else {
            throw PageCursorRejection.processMarkerMismatch
        }
        let queryShape = try StoredQueryShape(fromWire: blob.queryShape)
        let anchor = try StoredOrderingAnchor(fromWire: blob.anchor)
        return ResolvedPageCursor(
            queryShape: queryShape,
            position: ChangePosition(rawValue: blob.rawValue),
            anchor: anchor
        )
    }
}
