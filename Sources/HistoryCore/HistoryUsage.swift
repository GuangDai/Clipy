/// A coherent snapshot of retained item counts and logical content bytes.
/// Byte totals count stored content, not physical disk usage: database,
/// filesystem, and thumbnail overhead are excluded.
public struct HistoryUsage: Sendable, Equatable {
    public let position: ChangePosition

    /// All retained items, including pinned items.
    public let itemCount: Int
    public let pinnedItemCount: Int

    /// Canonical representation bytes across all retained items.
    public let canonicalBytes: Int

    /// Content bytes across all retained revisions, including inactive ones.
    public let revisionBytes: Int

    public init(
        position: ChangePosition,
        itemCount: Int,
        pinnedItemCount: Int,
        canonicalBytes: Int,
        revisionBytes: Int
    ) {
        self.position = position
        self.itemCount = itemCount
        self.pinnedItemCount = pinnedItemCount
        self.canonicalBytes = canonicalBytes
        self.revisionBytes = revisionBytes
    }

    public var totalContentBytes: Int { canonicalBytes + revisionBytes }
}
