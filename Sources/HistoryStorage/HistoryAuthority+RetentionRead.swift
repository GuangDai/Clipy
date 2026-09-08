/// V2-07 §5.2/§6.3; V2-09 §4: Settings reads configured retention policies
/// from one SQLite snapshot without fetching content or per-item metadata.
import HistoryCore

extension HistoryAuthority {
    internal func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        do {
            return try database.readTransaction {
                let statement = try database.prepare("""
                    SELECT key, changePosition, maximumUnpinnedItems
                    FROM history_state LIMIT 2
                    """)
                defer { statement.finalize() }
                guard try statement.step(),
                      try statement.text(at: 0) == Self.positionSingletonKey else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                _ = try sqliteUInt64(statement.blob(at: 1))
                let maximumUnpinnedItems = try statement.isNull(at: 2) ? nil : HistoryItemRowHydration.integer(statement, 2)
                guard maximumUnpinnedItems.map(limits.userMaximumUnpinnedRange.contains) ?? true else {
                    throw HistoryFailure.persistence(.corruptStoredValue)
                }
                guard try !statement.step() else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                return HistoryRetentionConfiguration(
                    maximumUnpinnedItems: maximumUnpinnedItems,
                    policies: try RetentionConfigLoading.loadValidatedPolicies(in: database)
                )
            }
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
    }
}
