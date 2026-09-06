#if DEBUG
/// Opt-in, Debug-only SwiftData lifecycle checkpoints for diagnosing
/// operation-local `ModelContext` and fetched `@Model` ownership at the
/// supported-platform hard bound. Events contain fixed phase names, elapsed
/// time, and aggregate row counts only; clipboard content, item identifiers,
/// source applications, and store paths cannot enter this vocabulary.
import Foundation

/// Closed phase vocabulary prevents user-controlled strings from reaching a
/// lifecycle event accidentally.
internal enum StorageLifecycleDebugPhase: String, Codable, Hashable, Sendable {
    case startupFetchBegin = "startup.fetch.begin"
    case startupFetchComplete = "startup.fetch.complete"
    case startupAutoreleasePoolDrained = "startup.autoreleasepool.drained"
    case captureFactLoadBegin = "capture.fact-load.begin"
    case captureFactLoadComplete = "capture.fact-load.complete"
    case captureTransactionBegin = "capture.transaction.begin"
    case captureTransactionComplete = "capture.transaction.complete"
    case captureAutoreleasePoolDrained = "capture.autoreleasepool.drained"
    case recentFetchBegin = "recent.fetch.begin"
    case recentPinnedFetchBegin = "recent.pinned-fetch.begin"
    case recentPinnedFetchComplete = "recent.pinned-fetch.complete"
    case recentUnpinnedFetchBegin = "recent.unpinned-fetch.begin"
    case recentUnpinnedFetchComplete = "recent.unpinned-fetch.complete"
    case recentUnpinnedOrderBegin = "recent.unpinned-order.begin"
    case recentUnpinnedFallbackFetchBegin = "recent.unpinned-fallback-fetch.begin"
    case recentUnpinnedFallbackFetchComplete = "recent.unpinned-fallback-fetch.complete"
    case recentUnpinnedOrderComplete = "recent.unpinned-order.complete"
    case recentFetchComplete = "recent.fetch.complete"
    case recentAutoreleasePoolDrained = "recent.autoreleasepool.drained"
}

/// One privacy-safe storage lifecycle checkpoint.
internal struct StorageLifecycleDebugEvent: Codable, Equatable, Sendable {
    internal static let eventName = "clipy.storage.lifecycle"

    let event: String
    let schemaVersion: UInt16
    let phase: StorageLifecycleDebugPhase
    let elapsedMilliseconds: Double
    let rows: Int

    /// Stable one-line JSON keeps CI artifacts machine-readable.
    private var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A grep-friendly prefix survives interleaving with framework logs.
    internal var logLine: String? {
        guard let json else { return nil }
        return "\(StorageLifecycleDebugProbe.logPrefix) \(json)"
    }
}

/// A value probe with a synchronous `@Sendable` sink. Synchronous emission
/// preserves the Authority rule that no suspension occurs while a context or
/// fetched row is live. Release builds compile out this type and every call.
internal struct StorageLifecycleDebugProbe: Sendable {
    internal static let logPrefix = "[CLIPY_STORAGE_TRACE]"

    private let isEnabled: Bool
    private let sink: @Sendable (StorageLifecycleDebugEvent) -> Void

    internal init(
        isEnabled: Bool,
        sink: @escaping @Sendable (StorageLifecycleDebugEvent) -> Void = { event in
            guard let line = event.logLine else { return }
            try? FileHandle.standardError.write(
                contentsOf: Data("\(line)\n".utf8)
            )
        }
    ) {
        self.isEnabled = isEnabled
        self.sink = sink
    }

    /// Debug builds remain quiet by default. The environment is read once
    /// when an Authority is created, before any operation-local context.
    internal static func environmentConfigured() -> StorageLifecycleDebugProbe {
        StorageLifecycleDebugProbe(
            isEnabled: ProcessInfo.processInfo.environment["CLIPY_STORAGE_TRACE"] == "1"
        )
    }

    internal func record(
        phase: StorageLifecycleDebugPhase,
        elapsed: Duration = .zero,
        rows: Int = 0
    ) {
        guard isEnabled else { return }
        sink(StorageLifecycleDebugEvent(
            event: StorageLifecycleDebugEvent.eventName,
            schemaVersion: 1,
            phase: phase,
            elapsedMilliseconds: Self.milliseconds(elapsed),
            rows: rows
        ))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}

// MARK: - Representation-blob fetch counting (PLAY-STOR-2)

/// Closed lane vocabulary for the representation-blob fetch counter. A phase
/// names the owning read/mutation lane that invoked the shared lineage
/// blob-fetch seam (`HistoryItemRowHydration.hydrate` /
/// `.hydrateWithTitle`), never clipboard content or an item identifier. The
/// scalar browse lanes (`recentPage`, `searchCorpusSnapshot`) deliberately
/// have no case: they perform no lineage blob fetch at all, and that absence
/// is exactly the fact PLAY-STOR-2 characterizes (04-tdd-remediation-playbook
/// §26 STOR 2: "recent-page只返回scalars，安排的blob accessor调用次数为0").
internal enum RepresentationBlobFetchDebugPhase: String, Codable, Hashable, Sendable {
    case detailsLane = "details.blob-fetch"
    case pasteLane = "paste.blob-fetch"
    case thumbnailLane = "thumbnail.blob-fetch"
    case revisionMutationLane = "revision.blob-fetch"
}

/// One privacy-safe representation-blob fetch observation: the lane that
/// invoked the lineage blob-fetch seam plus how many blob columns that
/// invocation materializes. Like the lifecycle events, the value carries
/// fixed vocabulary and counts only — no content, identifier, or path.
internal struct RepresentationBlobFetchDebugEvent: Codable, Equatable, Sendable {
    internal static let eventName = "clipy.storage.blob-fetch"

    let event: String
    let schemaVersion: UInt16
    let phase: RepresentationBlobFetchDebugPhase
    /// The blob columns one full-lineage fetch materializes: Canonical,
    /// revision state, and Canonical signature.
    let blobColumns: Int

    /// Stable one-line JSON keeps CI artifacts machine-readable.
    private var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A grep-friendly prefix survives interleaving with framework logs.
    internal var logLine: String? {
        guard let json else { return nil }
        return "\(RepresentationBlobFetchDebugProbe.logPrefix) \(json)"
    }
}

/// A value probe with a synchronous `@Sendable` sink, mirroring
/// `StorageLifecycleDebugProbe`. It counts invocations of the lineage
/// blob-fetch seam — the only read-side function that materializes a fetched
/// row's Canonical, revision-state, and signature blobs — attributed to the
/// lane that invoked it. Recording happens at the fetching lane's invocation
/// site, so a lane with no recording site (the scalar browse lanes) cannot
/// produce an event; the §13 startup Canonical/signature coverage pass and
/// the static capture/mutation fact loaders use their own decode paths and
/// are outside this counter's vocabulary. Release builds compile out this
/// type and every call.
internal struct RepresentationBlobFetchDebugProbe: Sendable {
    internal static let logPrefix = "[CLIPY_BLOB_FETCH_TRACE]"

    private let isEnabled: Bool
    private let sink: @Sendable (RepresentationBlobFetchDebugEvent) -> Void

    internal init(
        isEnabled: Bool,
        sink: @escaping @Sendable (RepresentationBlobFetchDebugEvent) -> Void = { event in
            guard let line = event.logLine else { return }
            try? FileHandle.standardError.write(
                contentsOf: Data("\(line)\n".utf8)
            )
        }
    ) {
        self.isEnabled = isEnabled
        self.sink = sink
    }

    /// Debug builds remain quiet by default. The environment is read once
    /// when an Authority is created, before any operation-local context.
    internal static func environmentConfigured() -> RepresentationBlobFetchDebugProbe {
        RepresentationBlobFetchDebugProbe(
            isEnabled: ProcessInfo.processInfo.environment["CLIPY_BLOB_FETCH_TRACE"] == "1"
        )
    }

    /// Records one lineage blob fetch. `blobColumns` is the fixed number of
    /// blob columns a full-lineage fetch materializes (Canonical, revision
    /// state, signature); it is a column count, not a byte measurement, and
    /// must never be read as physical I/O, copies, or RSS.
    internal func record(
        phase: RepresentationBlobFetchDebugPhase,
        blobColumns: Int
    ) {
        guard isEnabled else { return }
        sink(RepresentationBlobFetchDebugEvent(
            event: RepresentationBlobFetchDebugEvent.eventName,
            schemaVersion: 1,
            phase: phase,
            blobColumns: blobColumns
        ))
    }

    /// The blob columns one full-lineage hydration materializes: the
    /// Canonical content aggregate, the revision-state aggregate, and the
    /// Canonical signature metadata.
    internal static let lineageBlobColumnCount = 3
}
#endif
