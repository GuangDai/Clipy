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
#endif
