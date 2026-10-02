import Foundation
import HistoryCore

extension HistoryAuthority {
    internal func sourceApplications(
        _ request: HistorySourceApplicationRequest
    ) throws -> HistorySourceApplicationPage {
        guard (1...32).contains(request.limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }
        return try database.readTransaction(checkingCancellation: true) {
            let position = try readPositionInLocalContext()
            if let cursor = request.cursor {
                guard cursor.position == position, cursor.processMarker == processMarker else {
                    throw HistoryFailure.snapshotExpired(current: position)
                }
            }
            var after = request.cursor?.afterApplication ?? ""
            // Each seek skips all duplicates of the previous application in
            // the covering index. A repeated source across thousands of items
            // must not make a 32-value vocabulary page scan every occurrence.
            let query = try database.prepare("""
                SELECT application FROM copy_sources
                WHERE application IS NOT NULL AND application > ?
                ORDER BY application LIMIT 1
                """, bindings: [.text(after)])
            defer { query.finalize() }
            var applications: [String] = []
            var hasMore = false
            for index in 0...request.limit {
                try Task.checkCancellation()
                if index > 0 { try query.reset(bindings: [.text(after)]) }
                guard try query.step() else { break }
                guard try query.textByteCount(at: 0) <= limits.maximumSourceApplicationObservationUTF8Bytes else {
                    throw HistoryFailure.persistence(.corruptStoredValue)
                }
                let application = try query.text(at: 0)
                if index == request.limit { hasMore = true; break }
                applications.append(application)
                after = application
            }
            return HistorySourceApplicationPage(
                position: position, applications: applications,
                next: hasMore ? HistorySourceApplicationCursor(
                    position: position, processMarker: processMarker, afterApplication: after
                ) : nil
            )
        }
    }
}
