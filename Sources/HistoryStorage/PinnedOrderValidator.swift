/// Linear-time validation and ordering for the durable pinned-lane
/// permutation. Owning spec: docs/02-domain.md §3.2, D12;
/// docs/05-authority-kernel.md §7.2, §10, §13 step 10.
///
/// This module owns only the pure collection proof. Callers retain ownership
/// of scalar decoding and of the path-specific public failure mapping.
internal enum PinnedOrderValidator {
    /// Returns input offsets in ordinal order when `ordinal` is exactly a
    /// permutation of `0 ..< entries.count`; otherwise returns `nil`.
    ///
    /// Slot placement is deterministic `O(P)` time and `O(P)` scratch. The
    /// previous sort-shaped proof was `O(P log P)` and could not also recover
    /// the ordered source values without another transformation.
    internal static func sourceOffsetsByOrdinal<Element>(
        in entries: [Element],
        ordinal ordinalOf: (Element) -> Int
    ) -> [Int]? {
        var sourceOffsetByOrdinal = Array(repeating: -1, count: entries.count)
        for (sourceOffset, entry) in entries.enumerated() {
            let ordinal = ordinalOf(entry)
            guard ordinal >= 0,
                  ordinal < sourceOffsetByOrdinal.count,
                  sourceOffsetByOrdinal[ordinal] == -1 else {
                return nil
            }
            sourceOffsetByOrdinal[ordinal] = sourceOffset
        }
        // P distinct entries placed into P in-range slots necessarily fill
        // every slot, so a second completeness scan is unnecessary.
        return sourceOffsetByOrdinal
    }
}
