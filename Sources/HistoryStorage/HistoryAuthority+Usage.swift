/// Settings usage read: committed content-byte totals and retained item
/// counts from existing projections (05 §14 read interval; V2-02 §3.3b).
/// Encoded content bytes are independent of SQLite/APFS allocation size.
import Foundation
import HistoryCore
import SwiftData

extension HistoryAuthority {
    /// One authoritative snapshot of count, pin state, and immutable content
    /// storage. No content/revision blob is decoded, and no derived total is
    /// persisted. The existing retention scalar loader owns byte validation;
    /// this read joins its item IDs to the retained scalar rows before summing.
    internal func usage() async throws -> HistoryUsage {
        await suspendIfRequested(.readEntry)

        return try autoreleasepool {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            // No await while the operation-local context or its models live.
            let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
            let (position, _) = try Self.decodePositionRow(positionRow, limits: limits)
            var scalarsByItem = try RetentionConfigLoading.fetchProjectedScalars(
                in: context, limits: limits
            )

            var descriptor = FetchDescriptor<HistoryItemRow>()
            descriptor.propertiesToFetch = [\.id, \.pinOrdinal]
            descriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
            let rows: [HistoryItemRow]
            do {
                rows = try context.fetch(descriptor)
            } catch {
                throw HistoryFailure.temporarilyUnavailable(.factProof)
            }
            guard rows.count == scalarsByItem.count else {
                throw HistoryFailure.persistence(.invariantViolation)
            }

            var pinnedItemCount = 0
            var canonicalBytes = 0
            var revisionBytes = 0
            for row in rows {
                // Consuming each projection proves one-to-one correspondence,
                // including duplicate retained IDs and equal-count orphan rows.
                guard let scalars = scalarsByItem.removeValue(
                    forKey: HistoryItemID(rawValue: row.id)
                ) else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                let pinOrdinal = try mapCodecFailure {
                    try RevisionStateBlobCodec.decodePinOrdinal(row.pinOrdinal)
                }
                if pinOrdinal != nil { pinnedItemCount += 1 }

                // The shared loader enforces both the 5,000-item bound and
                // each item's fixed byte limits; these sums fit arm64 Int.
                canonicalBytes += scalars.canonicalBytes
                revisionBytes += scalars.revisionBytes
            }
            return HistoryUsage(
                position: position,
                itemCount: rows.count,
                pinnedItemCount: pinnedItemCount,
                canonicalBytes: canonicalBytes,
                revisionBytes: revisionBytes
            )
        }
    }
}
