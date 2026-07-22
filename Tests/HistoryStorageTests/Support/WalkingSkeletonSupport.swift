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
    /// directory in a `defer` (see `removeStore`).
    static func tempStoreURL(_ testName: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-ws-\(testName)-\(UUID().uuidString)")
            .appendingPathComponent("store.sqlite")
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
    static func makeContainer(storeURL: URL) throws -> ModelContainer {
        try ModelContainer(
            for: v1Schema,
            configurations: ModelConfiguration(schema: v1Schema, url: storeURL)
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
        return rows.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Fetches the position singleton (fails the test via `try` if absent
    /// or duplicated — the store always violates loudly here).
    static func fetchPosition(_ container: ModelContainer) throws -> LastChangePositionRow {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LastChangePositionRow>())
        precondition(rows.count == 1, "position singleton must exist exactly once, got \(rows.count)")
        return rows[0]
    }
}
