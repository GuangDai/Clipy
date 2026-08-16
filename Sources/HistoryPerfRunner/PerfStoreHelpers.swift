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
///
/// `baseTime` threads `deterministicTextCapture`'s stamp origin through so an
/// R1-active workload (V2-02 §4.2) can seed `observedAt` values a fixed
/// distance behind the wall clock — the capture lane's R1 reference `now` is
/// the capture's own `observedAt` (§4.2/DC-28: the Storage clock belongs to
/// the `.setRetentionPolicies` sweep lane alone), but the one-time policy-set
/// sweep DOES read the real clock, so fixed 2001-epoch stamps would turn R1
/// into an accidental mass retirement once wall-clock time drifts far enough
/// past them.
func captureItem(
    _ history: SwiftDataHistory,
    index: Int,
    bodyBytes: Int = 64,
    baseTime: Double = 600_000_000
) async throws -> HistoryItemReference {
    let receipt = try await history.perform(
        .capture(deterministicTextCapture(
            index: index,
            bodyBytes: bodyBytes,
            baseTime: baseTime
        ))
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

/// Performs one byte-changing `.replace` revise on the item named by
/// `reference`, OCC-tokened at the reference's ContentVersion (03a §5: the
/// caller bases its edit on the version it holds and never mints the
/// successor), and returns the post-append reference the receipt carries.
///
/// The payload is index/append-derived and exactly `bodyBytes` long: within
/// one item's lineage every append differs from the current Effective bytes
/// (a byte-identical repeat would be `.unchanged` under D4 — only
/// effective-content-changing revisions append), and the fixed length keeps
/// the item's `RetainedBytesRow` revision scalars (V2-02 §3.3b) deterministic
/// for R2/R3 budget arithmetic.
func reviseItem(
    _ history: SwiftDataHistory,
    reference: HistoryItemReference,
    itemIndex: Int,
    appendSequence: Int,
    bodyBytes: Int = 32
) async throws -> HistoryItemReference {
    let prefix = "perf-rev-\(itemIndex)-\(appendSequence)-"
    let padding = String(repeating: "r", count: max(0, bodyBytes - prefix.utf8.count))
    let request = RevisionRequest(
        itemID: reference.id,
        expected: reference.contentVersion,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data((prefix + padding).utf8))
            )
        ]))
    )
    let receipt = try await history.perform(.revise(request))
    guard case .committed(let commit) = receipt,
          case .revised(let revised) = commit.outcome else {
        throw PerfError.reviseUnexpectedOutcome
    }
    return revised
}

/// Populates a store with `count` distinct unpinned items (untimed).
func populateItems(
    _ history: SwiftDataHistory,
    count: Int,
    bodyBytes: Int = 64,
    baseTime: Double = 600_000_000
) async throws {
    for i in 0..<count {
        _ = try await captureItem(
            history,
            index: i,
            bodyBytes: bodyBytes,
            baseTime: baseTime
        )
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

