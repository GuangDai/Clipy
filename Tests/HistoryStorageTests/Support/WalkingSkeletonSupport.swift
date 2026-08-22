import Foundation
import SwiftData
@testable import HistoryStorage
import HistoryCore

/// Shared walking-skeleton test support (docs/06-cross-cutting.md §8: each
/// path crosses the public `ClipboardHistory` interface and the real
/// `SwiftDataHistory` implementation; row-level assertions use an
/// INDEPENDENT second `ModelContainer` over the same on-disk store, so no
/// production test seam is needed for reads).
enum WSSupport {
    /// A unique temporary store URL for one test; the caller removes the
    /// directory in a `defer` (see `removeStore`). The parent directory is
    /// created up front — CoreData otherwise logs file-status diagnostics
    /// when it has to create it implicitly.
    static func tempStoreURL(_ testName: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-ws-\(testName)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("store.sqlite")
    }

    /// Removes the store directory created for `url` (its parent directory).
    static func removeStore(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Opens the real public facade over a persistent temp store.
    static func openHistory(
        storeURL: URL,
        maximumUnpinned: Int = 200
    ) async throws -> SwiftDataHistory {
        try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL),
                initialMaximumUnpinnedItems: maximumUnpinned
            )
        )
    }

    /// An INDEPENDENT container over the same store file, used only for
    /// row-level assertions (never for mutations in these tests).
    ///
    /// Built at the current immutable schema (`HistorySchemaV4`, DC-25) since
    /// `SwiftDataHistory.open` constructs V4 stores through the migration
    /// plan (`V2-roadmap` §5 step 2) and `HistoryAuthority.performStartup`
    /// bootstraps the retention-expansion config singleton (step 5, M1.3) —
    /// a v1-schema container carries no `RetentionExpansionConfigRow`
    /// entity. No migration plan is passed: an assertion container never
    /// writes, and every store it opens here is created at V4 (freshly by
    /// itself, or by `SwiftDataHistory.open`), so no stage could run.
    static func makeContainer(storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
    }

    /// A directly-constructed Authority (storage-side proofs: WS5, §7.1,
    /// §7.6) over its own persistent container; startup has been performed.
    static func makeAuthority(
        storeURL: URL,
        limits: HistoryLimits = .standard,
        maximumUnpinned: Int = 200
    ) async throws -> HistoryAuthority {
        let container = try makeContainer(storeURL: storeURL)
        let authority = HistoryAuthority(container: container, limits: limits)
        try await authority.performStartup(initialMaximumUnpinnedItems: maximumUnpinned)
        return authority
    }

    /// A normalized raw text capture (docs/06 §8 WS1), with optional extra
    /// representations (e.g. rich text for WS3) and origin observation.
    static func textCapture(
        _ text: String,
        observedAt: Date,
        source: String? = nil,
        lineageHint: HistoryItemID? = nil,
        extra: [(typeIdentifier: String, bytes: [UInt8])] = []
    ) -> ClipboardCapture {
        var representations = [CapturedRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data(text.utf8)
        )]
        for item in extra {
            representations.append(CapturedRepresentation(
                typeIdentifier: item.typeIdentifier,
                bytes: Data(item.bytes)
            ))
        }
        return ClipboardCapture(
            representations: representations,
            origin: CopyOriginObservation(
                sourceApplication: source,
                lineageHint: lineageHint
            ),
            observedAt: observedAt
        )
    }

    /// Fetches every retained item row, sorted by id bytes for determinism.
    static func fetchRows(_ container: ModelContainer) throws -> [HistoryItemRow] {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<HistoryItemRow>())
        return rows.sorted {
            HistoryItemID(rawValue: $0.id) < HistoryItemID(rawValue: $1.id)
        }
    }

    /// Fetches the position singleton (fails the test via `try` if absent
    /// or duplicated — the store always violates loudly here).
    static func fetchPosition(_ container: ModelContainer) throws -> LastChangePositionRow {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LastChangePositionRow>())
        precondition(rows.count == 1, "position singleton must exist exactly once, got \(rows.count)")
        return rows[0]
    }

    /// Seeds the retention-expansion config singleton's policy lanes for the
    /// R.4 capture-composition fixtures: the row is written through an
    /// INDEPENDENT container over the same store — behind the Authority's
    /// back, the same stance the R.3 corruption fixtures take — so a fixture
    /// enables policies WITHOUT the `.setRetentionPolicies` sweep commit the
    /// production path would run (which would advance `ChangePosition` and
    /// potentially retire/prune fixture state). The capture lane re-reads
    /// and re-validates the singleton inside every capture interval
    /// (`RetentionConfigLoading.loadCaptureLanePolicies`), so the next
    /// capture enforces exactly these policies. The row must already exist
    /// (`SwiftDataHistory.open` bootstraps it all-disabled); a `nil` lane
    /// maps to the disabled shape with its dormant value zeroed, the exact
    /// normalization the `.setRetentionPolicies` stamping persists
    /// (`V2-02` §5.6).
    static func seedRetentionConfig(
        storeURL: URL,
        age: AgeRetention? = nil,
        storage: StorageRetention? = nil,
        revisions: RevisionRetention? = nil
    ) throws {
        let container = try makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
        precondition(
            rows.count == 1,
            "config singleton must exist exactly once, got \(rows.count)"
        )
        // A `@Model` is bound to the context that fetched it — mutate and
        // save through the SAME context (the R.3 fixture discipline).
        let row = rows[0]
        row.agePolicyEnabled = age != nil
        row.ageMaxSeconds = age?.maxAge ?? 0
        row.storagePolicyEnabled = storage != nil
        row.storageMaxBytes = storage?.maxTotalBytes ?? 0
        row.revisionPolicyEnabled = revisions != nil
        row.revisionMaxCount = revisions?.maxRevisionsPerItem
        row.revisionMaxBytes = revisions?.maxRevisionBytesPerItem
        try context.save()
    }
}
