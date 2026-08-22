#if DEBUG
/// Opt-in, Debug-only search-path instrumentation for diagnosing the
/// hard-bound workload in docs/06-cross-cutting.md §9. The probe records only
/// timings and aggregate sizes: clipboard text, search terms, source
/// applications, and store paths never enter an event.
import Foundation

/// One privacy-safe checkpoint from the Authority-to-SearchWorker pipeline.
/// The type is absent from Release builds, so production search has no probe,
/// event allocation, environment lookup, or logging branch.
internal struct SearchDebugEvent: Codable, Equatable, Sendable {
    let event: String
    let schemaVersion: UInt16
    let traceID: UUID
    let component: String
    let phase: String
    let phaseElapsedMilliseconds: Double
    let totalElapsedMilliseconds: Double
    let rowsProcessed: Int
    let rowsTotal: Int
    let matchedRows: Int
    let titleUTF8Bytes: Int
    let bodyUTF8Bytes: Int
    let titleMatches: Int
    let bodyMatches: Int
    let exactASCIIEvaluations: Int
    let exactFoundationEvaluations: Int

    /// Stable one-line JSON keeps CI logs streamable and machine-readable.
    /// Sorted keys make fixture and unit-test diagnostics deterministic.
    internal var jsonLine: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Correlation metadata minted before Authority work begins and carried in
/// the immutable corpus snapshot to the SearchWorker. Every component reports
/// elapsed time against this same origin.
internal struct SearchDebugTrace: Sendable {
    let id: UUID
    let startedAt: ContinuousClock.Instant
}

/// A value probe with a `@Sendable` synchronous sink. Synchronous emission is
/// deliberate: `HistoryAuthority` must not suspend while an operation-local
/// `ModelContext` or fetched `@Model` row is live (docs/05 §5). Tests replace
/// the stderr sink without adding an alternate read or write implementation.
internal struct SearchDebugProbe: Sendable {
    /// Large enough to keep a 5,000-row trace compact, small enough to leave
    /// 20 progress points inside each expensive corpus phase.
    internal static let progressRowInterval = 250

    private let isEnabled: Bool
    private let sink: @Sendable (SearchDebugEvent) -> Void

    internal init(
        isEnabled: Bool,
        sink: @escaping @Sendable (SearchDebugEvent) -> Void = { event in
            guard let line = event.jsonLine else { return }
            // A diagnostic process can be killed by a timeout at any point;
            // direct stderr writes leave the last completed checkpoint in
            // the artifact even when stdout is block-buffered behind `tee`.
            try? FileHandle.standardError.write(
                contentsOf: Data("\(line)\n".utf8)
            )
        }
    ) {
        self.isEnabled = isEnabled
        self.sink = sink
    }

    /// Debug builds remain quiet by default. Set `CLIPY_SEARCH_TRACE=1` on a
    /// diagnostic process to activate source checkpoints; Release builds do
    /// not compile this code at all.
    internal static func environmentConfigured() -> SearchDebugProbe {
        SearchDebugProbe(
            isEnabled: ProcessInfo.processInfo.environment["CLIPY_SEARCH_TRACE"] == "1"
        )
    }

    internal func record(
        traceID: UUID,
        component: String,
        phase: String,
        phaseElapsed: Duration,
        totalElapsed: Duration,
        rowsProcessed: Int = 0,
        rowsTotal: Int = 0,
        matchedRows: Int = 0,
        titleUTF8Bytes: Int = 0,
        bodyUTF8Bytes: Int = 0,
        titleMatches: Int = 0,
        bodyMatches: Int = 0,
        exactASCIIEvaluations: Int = 0,
        exactFoundationEvaluations: Int = 0
    ) {
        guard isEnabled else { return }
        sink(SearchDebugEvent(
            event: "clipy.search.trace",
            schemaVersion: 2,
            traceID: traceID,
            component: component,
            phase: phase,
            phaseElapsedMilliseconds: Self.milliseconds(phaseElapsed),
            totalElapsedMilliseconds: Self.milliseconds(totalElapsed),
            rowsProcessed: rowsProcessed,
            rowsTotal: rowsTotal,
            matchedRows: matchedRows,
            titleUTF8Bytes: titleUTF8Bytes,
            bodyUTF8Bytes: bodyUTF8Bytes,
            titleMatches: titleMatches,
            bodyMatches: bodyMatches,
            exactASCIIEvaluations: exactASCIIEvaluations,
            exactFoundationEvaluations: exactFoundationEvaluations
        ))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}
#endif
