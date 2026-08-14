/// Store construction and deterministic capture helpers.
/// Split out of PerformanceSuite.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

// MARK: - Store helpers

/// A unique temp store URL (parent directory created upfront to suppress
/// CoreData file-status diagnostics — same pattern as WS tests,
/// Tests/HistoryStorageTests/Support/WalkingSkeletonSupport.swift).
func makeStoreURL(_ label: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipy-perf-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: dir,
        withIntermediateDirectories: true
    )
    return dir.appendingPathComponent("store.sqlite")
}

/// Removes the store directory created by `makeStoreURL`.
func removeStoreDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// Opens the public facade over a persistent temp store with a generous
/// initial retention cap (avoids eviction during population). 05 §2: the
/// initial value is written to the durable singleton for a new store.
func openStore(url: URL, maxUnpinned: Int = 5_000) async throws -> SwiftDataHistory {
    try await SwiftDataHistory.open(
        configuration: HistoryConfiguration(
            persistence: .persistent(storeURL: url),
            initialMaximumUnpinnedItems: maxUnpinned
        )
    )
}

/// Opens the public facade over an in-memory store.
///
/// §9 measures algorithmic complexity (rows/bytes scaling), not durability:
/// Part V §2 states `.memory` changes the durability medium only and uses
/// the same Authority, planners, codecs, and transaction path, so a workload
/// that does not need to REOPEN durable state runs against the identical
/// algorithm without paying per-commit fsync — population is the runner's
/// dominant cost and is never part of a measurement. Only bullet 3 (index
/// rebuild across a durable reopen) keeps `.persistent`; every fixture note
/// records the medium.
func openMemoryStore(maxUnpinned: Int = 5_000) async throws -> SwiftDataHistory {
    try await SwiftDataHistory.open(
        configuration: HistoryConfiguration(
            persistence: .memory,
            initialMaximumUnpinnedItems: maxUnpinned
        )
    )
}

// MARK: - Deterministic capture helpers (no UUID/random in the measurement path)

/// A deterministic raw text capture (index-derived text; capture IDs come from
/// receipts, not from UUID/random in the content path).
func deterministicTextCapture(
    index: Int,
    bodyBytes: Int = 64,
    baseTime: Double = 600_000_000
) -> ClipboardCapture {
    let prefix = "perf-item-\(index)-"
    let padding = String(repeating: "a", count: max(0, bodyBytes - prefix.utf8.count))
    return ClipboardCapture(
        representations: [CapturedRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data((prefix + padding).utf8)
        )],
        origin: CopyOriginObservation(
            sourceApplication: "perf-runner",
            lineageHint: nil
        ),
        observedAt: Date(timeIntervalSinceReferenceDate: baseTime + Double(index))
    )
}

/// Captures one distinct item and returns its reference.
func captureItem(
    _ history: SwiftDataHistory,
    index: Int,
    bodyBytes: Int = 64
) async throws -> HistoryItemReference {
    let receipt = try await history.perform(
        .capture(deterministicTextCapture(index: index, bodyBytes: bodyBytes))
    )
    guard case .committed(let commit) = receipt,
          case .inserted(let ref) = commit.outcome else {
        throw PerfError.captureUnexpectedOutcome
    }
    return ref
}

/// Performs one already-built capture so a workload can keep String/Data
/// fixture construction outside its timed interval.
func capturePreparedItem(
    _ history: SwiftDataHistory,
    capture: ClipboardCapture
) async throws -> HistoryItemReference {
    let receipt = try await history.perform(.capture(capture))
    guard case .committed(let commit) = receipt,
          case .inserted(let reference) = commit.outcome else {
        throw PerfError.captureUnexpectedOutcome
    }
    return reference
}

/// Populates a store with `count` distinct unpinned items (untimed).
func populateItems(
    _ history: SwiftDataHistory,
    count: Int,
    bodyBytes: Int = 64
) async throws {
    for i in 0..<count {
        _ = try await captureItem(history, index: i, bodyBytes: bodyBytes)
    }
}

/// Populates a store and returns the first item's reference for later queries.
func populateAndReturnFirstRef(
    _ history: SwiftDataHistory,
    count: Int,
    bodyBytes: Int = 64
) async throws -> HistoryItemReference {
    let firstRef = try await captureItem(history, index: 0, bodyBytes: bodyBytes)
    for i in 1..<count {
        _ = try await captureItem(history, index: i, bodyBytes: bodyBytes)
    }
    return firstRef
}

// MARK: - Output helpers

/// Prints one summary line for a workload result.
func printResult(_ key: String, _ bullet: String, _ ratio: Double, _ bound: Double?, _ passed: Bool) {
    let status = passed ? "PASS" : "FAIL"
    if let bound {
        print(String(format: "  [%@] %@ (§9 bullet %@): ratio %.2f, bound %.1f", status, key, bullet, ratio, bound))
    } else {
        print(String(format: "  [%@] %@ (§9 bullet %@): ratio %.2f, bound n/a (record-only)", status, key, bullet, ratio))
    }
}

/// Builds a failure fixture for a workload that could not complete.
func failureFixture(key: String, bullet: String, error: Error) -> WorkloadFixture {
    print("  [FAIL] \(key) (§9 bullet \(bullet)): workload threw \(error)")
    return WorkloadFixture(
        key: key,
        bullet: bullet,
        sizes: [],
        mediansMs: [],
        ratio: nil,
        bound: nil,
        pass: false,
        note: "workload threw \(error)"
    )
}

