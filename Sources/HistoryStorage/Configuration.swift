/// HistoryPersistence / HistoryConfiguration — the public configuration
/// values for opening a `SQLiteHistory`.
/// Owning spec: docs/05-authority-kernel.md §2 (Part V — public concrete
/// adapter); bounds validated against docs/06-cross-cutting.md §2 (Part VI)
/// at `SQLiteHistory.open` time.
import Foundation

/// The durability medium of a History store (docs/05-authority-kernel.md §2).
///
/// Both modes use the same SQLite/blob implementation and transaction path.
/// Disposable stores use a private temporary directory, allowing independent
/// read connections to observe a consistent snapshot just like production.
public enum HistoryPersistence: Sendable, Hashable {
    /// A durable store at the given file URL, created when absent.
    case persistent(storeURL: URL)

    /// A disposable store removed after its last owner/read has finished.
    case temporary
}

/// Configuration for `SQLiteHistory.open(configuration:)`
/// (docs/05-authority-kernel.md §2).
///
/// `initialMaximumUnpinnedItems` is the initial retention value for a *new*
/// store: it is written to the durable singleton when `open` creates one. An
/// existing store ignores it and uses its durable singleton value; the public
/// retention action (`.setRetentionPolicy`) changes that value afterward
/// (§2). `open` validates the initial value against the fixed Part VI user
/// range and rejects an out-of-range value with
/// `.invalidInput(.invalidRetentionPolicy)`.
public struct HistoryConfiguration: Sendable, Hashable {
    /// The durability medium of the store.
    public let persistence: HistoryPersistence

    /// The retention value a newly created store starts with; ignored by an
    /// existing store (docs/05-authority-kernel.md §2). Must lie inside
    /// `HistoryLimits.standard.userMaximumUnpinnedRange`
    /// (docs/06-cross-cutting.md §2: user maximum-unpinned range 1–5,000);
    /// the default is the Part VI default of 200.
    public let initialMaximumUnpinnedItems: Int

    /// Creates a configuration (docs/05-authority-kernel.md §2).
    ///
    /// Validation is deferred to `SQLiteHistory.open(configuration:)`,
    /// which throws the typed failure — this initializer only stores values.
    public init(
        persistence: HistoryPersistence,
        initialMaximumUnpinnedItems: Int = 200
    ) {
        self.persistence = persistence
        self.initialMaximumUnpinnedItems = initialMaximumUnpinnedItems
    }
}
