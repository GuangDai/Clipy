import HistoryCore

/// Actual durable projection lengths for the scale report (V2-09 §10).
/// Keys are UTF-8 byte counts; values are retained-row frequencies. This is
/// measured after setup, outside search timing, and never copies a corpus.
package struct PerformanceProjectionLengths: Sendable {
    package let titleUTF8Bytes: [Int: Int]
    package let searchBodyUTF8Bytes: [Int: Int]
}

extension SQLiteHistory {
    package func performanceProjectionLengths() async throws -> PerformanceProjectionLengths {
        try await authority.performanceProjectionLengths()
    }
}

extension HistoryAuthority {
    internal func performanceProjectionLengths() throws -> PerformanceProjectionLengths {
        do {
            return try database.readTransaction {
                PerformanceProjectionLengths(
                    titleUTF8Bytes: try projectionLengthHistogram("titleUTF8"),
                    searchBodyUTF8Bytes: try projectionLengthHistogram("searchBodyUTF8")
                )
            }
        } catch let failure as SQLiteFailure {
            throw failure.historyFailure
        }
    }

    /// Both callers pass fixed column names. SQLite computes BLOB lengths
    /// without decoding text or fetching representation payloads. Distinct
    /// lengths are bounded by the stored projection byte limits, not row count.
    private func projectionLengthHistogram(_ column: String) throws -> [Int: Int] {
        let rows = try database.prepare("""
            SELECT length(\(column)), count(*) FROM history_items
            GROUP BY length(\(column))
            """)
        defer { rows.finalize() }
        var frequencies: [Int: Int] = [:]
        while try rows.step() {
            frequencies[try HistoryItemRowHydration.integer(rows, 0)] =
                try HistoryItemRowHydration.integer(rows, 1)
        }
        return frequencies
    }
}
