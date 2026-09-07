/// V2-09 §4/§6: committed logical content-byte totals and retained counts
/// are maintained atomically with each History write. They exclude physical
/// SQLite/APFS allocation and are read without loading any item or blob.
import HistoryCore

extension HistoryAuthority {
    internal func usage() async throws -> HistoryUsage {
        await suspendIfRequested(.readEntry)

        do {
            let statement = try database.prepare("""
                SELECT key, changePosition, retainedItemCount, pinnedItemCount,
                       canonicalBytes, revisionBytes
                FROM history_state LIMIT 2
                """)
            defer { statement.finalize() }
            guard try statement.step(),
                  try statement.text(at: 0) == Self.positionSingletonKey else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let position = ChangePosition(rawValue: try sqliteUInt64(statement.blob(at: 1)))
            guard let itemCount = Int(exactly: try statement.integer(at: 2)),
                  let pinnedItemCount = Int(exactly: try statement.integer(at: 3)),
                  let canonicalBytes = Int(exactly: try statement.integer(at: 4)),
                  let revisionBytes = Int(exactly: try statement.integer(at: 5)),
                  itemCount >= 0,
                  pinnedItemCount >= 0,
                  pinnedItemCount <= itemCount,
                  canonicalBytes >= itemCount,
                  revisionBytes >= 0,
                  itemCount != 0 || revisionBytes == 0,
                  !canonicalBytes.addingReportingOverflow(revisionBytes).overflow,
                  try !statement.step() else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            return HistoryUsage(
                position: position,
                itemCount: itemCount,
                pinnedItemCount: pinnedItemCount,
                canonicalBytes: canonicalBytes,
                revisionBytes: revisionBytes
            )
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
    }
}
