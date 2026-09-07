import Foundation
import HistoryCore
import HistoryDomain

/// Operation-local values after file publication and before SQL BEGIN
/// (V2-09 §6). Large payloads are represented only by their immutable BlobID.
internal struct PublishedHistoryContent {
    internal let id: UUID
    internal let representations: [PublishedHistoryRepresentation]

    internal var byteCount: Int { representations.reduce(0) { $0 + $1.byteCount } }
}

internal struct PublishedHistoryRepresentation {
    internal let exactType: String
    internal let typeKey: String
    internal let byteCount: Int
    internal let fingerprint: UInt64?
    internal let inline: SQLiteValue
    internal let blobID: SQLiteValue
}

extension HistoryAuthority {
    /// Only content-creating mutations occupy this operation-local map.
    /// Authority does not suspend between reuse lookup, file publication and
    /// the reference transaction, so current/Canonical sources cannot change.
    internal func publishHistoryContent(
        for plan: StampedCommitPlan
    ) throws -> [Int: PublishedHistoryContent] {
        var published: [Int: PublishedHistoryContent] = [:]
        var newPayloadBytes: Int64 = 0
        let available = volumeAvailableCapacityOverride ?? volumeAvailableCapacityReader()
        for (index, mutation) in plan.mutations.enumerated() {
            switch mutation {
            case .create(let item):
                published[index] = try publishContent(
                    id: UUID(), itemID: item.id,
                    representations: item.canonical.representations.lazy.map {
                        ($0.content, Optional($0.fingerprint.rawValue))
                    }, newPayloadBytes: &newPayloadBytes, available: available
                )
            case .appendRevision(let update):
                published[index] = try publishContent(
                    id: update.revision.id.rawValue, itemID: update.itemID,
                    representations: update.revision.content.representations.lazy.map {
                        ($0, nil as UInt64?)
                    }, newPayloadBytes: &newPayloadBytes, available: available
                )
            case .updateOccurrence, .setPinOrdinal, .delete, .setRetentionPolicy,
                    .pruneRevisions, .setRetentionPolicies:
                break
            }
        }
        return published
    }

    private func publishContent(
        id: UUID, itemID: HistoryItemID,
        representations: some Sequence<(ContentRepresentation, UInt64?)>,
        newPayloadBytes: inout Int64, available: Int64?
    ) throws -> PublishedHistoryContent {
        var published: [PublishedHistoryRepresentation] = []
        for (representation, fingerprint) in representations {
            let reused = try reusableRepresentation(representation, itemID: itemID)
            let inline: SQLiteValue
            let blobID: SQLiteValue
            if let reused, case .text = reused.blobID {
                // Reused files consume no new payload space. Inline bytes,
                // even reused values, are inserted into a new SQLite row.
                inline = reused.inline
                blobID = reused.blobID
            } else {
                newPayloadBytes += Int64(representation.bytes.count)
                if let failure = CaptureCapacityAdmission.failure(
                    demandBytes: newPayloadBytes, availableCapacity: available
                ) { throw failure }
                if let reused {
                    inline = reused.inline
                    blobID = reused.blobID
                } else if representation.bytes.count <= 64 * 1_024 {
                    inline = .blob(representation.bytes)
                    blobID = .null
                } else {
                    let blob = try blobStore.write(representation.bytes)
                    inline = .null
                    blobID = .text(blob.id.uuidString)
                }
            }
            published.append(PublishedHistoryRepresentation(
                exactType: representation.typeIdentifier,
                typeKey: representation.typeIdentifier.precomposedStringWithCanonicalMapping,
                byteCount: representation.bytes.count, fingerprint: fingerprint,
                inline: inline, blobID: blobID
            ))
        }
        return PublishedHistoryContent(id: id, representations: published)
    }
}
