/// V2-02 §4.1–§4.4: scalar retention composition over SQLite's durable
/// eviction order. Only actual victims enter the commit plan; no complete
/// inventory or content bytes are materialized for R1/R2.
import Foundation
import HistoryCore
import HistoryDomain

internal enum RetentionConfigLoading {
    internal static func loadValidatedPolicies(in database: SQLiteDatabase) throws -> HistoryRetentionPolicies {
        let row = try database.prepare("""
            SELECT ageMaxSeconds,storageMaxBytes,revisionMaxCount,revisionMaxBytes
            FROM retention_policies WHERE key=?
            """, bindings: [.text(HistoryAuthority.retentionExpansionConfigKey)])
        defer { row.finalize() }
        guard try row.step() else { throw corrupt }
        let age = try row.isNull(at: 0) ? nil : row.real(at: 0)
        let storage = try optionalInt(row, 1)
        let count = try optionalInt(row, 2)
        let bytes = try optionalInt(row, 3)
        if let age, !age.isFinite { throw HistoryFailure.persistence(.corruptStoredValue) }
        let result = HistoryRetentionPolicies(
            age: age.map { AgeRetention(maxAge: $0) },
            storage: storage.map { StorageRetention(maxTotalBytes: $0) },
            revisions: RevisionRetention(maxRevisionsPerItem: count, maxRevisionBytesPerItem: bytes)
        )
        guard RetentionPolicyBounds.validate(result) == nil else { throw corrupt }
        return result
    }

    internal static func loadCaptureLanePolicies(in database: SQLiteDatabase) throws -> HistoryRetentionPolicies? {
        let policies = try loadValidatedPolicies(in: database)
        return policies.age != nil || policies.storage != nil ? policies : nil
    }

    internal static func loadReviseLanePolicies(in database: SQLiteDatabase) throws -> HistoryRetentionPolicies? {
        let policies = try loadValidatedPolicies(in: database)
        return policies.storage != nil || policies.revisions != nil ? policies : nil
    }

    internal static func totalRetainedBytes(in database: SQLiteDatabase) throws -> Int {
        let row = try database.prepare("SELECT canonicalBytes,revisionBytes FROM history_state WHERE key=?",
            bindings: [.text(HistoryAuthority.positionSingletonKey)])
        defer { row.finalize() }
        guard try row.step() else { throw corrupt }
        return try checkedAdd(HistoryItemRowHydration.integer(row, 0), HistoryItemRowHydration.integer(row, 1))
    }

    /// Fold the indexed eligible lane into one cutoff and scalar totals.
    /// A projection callback is needed only for the R3-before-R2 sweep.
    internal static func retirementPrefix(
        in database: SQLiteDatabase,
        policies: HistoryRetentionPolicies,
        now: Date,
        protectedItemID: HistoryItemID?,
        projectedTotalBytes: Int,
        minimumRetiredItems: Int = 0,
        projectRevisionBytes: ((RetentionExpansionItemSummary) throws -> Int)? = nil
    ) throws -> RetentionRetirementPrefix? {
        guard projectedTotalBytes >= 0, minimumRetiredItems >= 0 else { throw corrupt }
        let overBudget = policies.storage.map { projectedTotalBytes > $0.maxTotalBytes } ?? false
        guard policies.age != nil || overBudget || minimumRetiredItems > 0 else { return nil }
        let rows = try database.prepare("""
            SELECT id,lastCopiedAt,canonicalBytes,revisionCount,revisionBytes
            FROM history_items WHERE pinOrdinal IS NULL AND id != ?
            ORDER BY lastCopiedAt,id
            """, bindings: [.text(protectedItemID?.rawValue.uuidString ?? "")])
        defer { rows.finalize() }
        var selection = OrderedRetentionSelection(
            policies: policies, now: now, protectedItemID: protectedItemID,
            projectedTotalBytes: projectedTotalBytes, minimumRetiredItems: minimumRetiredItems
        )
        do {
            while try rows.step() {
                let candidate = try RetentionExpansionItemSummary(
                    id: HistoryItemID(rawValue: HistoryItemRowHydration.uuid(rows.text(at: 0))),
                    lastCopiedAt: Date(timeIntervalSinceReferenceDate: rows.real(at: 1)),
                    pinOrdinal: nil,
                    canonicalBytes: HistoryItemRowHydration.integer(rows, 2),
                    revisionCount: HistoryItemRowHydration.integer(rows, 3),
                    revisionBytes: HistoryItemRowHydration.integer(rows, 4)
                )
                let revisions = try projectRevisionBytes?(candidate)
                if try !selection.consider(candidate, projectedRevisionBytes: revisions) { break }
            }
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }
        guard selection.remainingRequiredItems == 0 else {
            throw HistoryFailure.capacityExceeded(.retainedItems)
        }
        if let budget = policies.storage?.maxTotalBytes, selection.remainingBytes > budget {
            throw HistoryFailure.capacityExceeded(.storageBytes)
        }
        return selection.prefix
    }
    internal static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !overflow else { throw corrupt }
        return result
    }

    internal static func checkedSubtract(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !overflow, result >= 0 else { throw corrupt }
        return result
    }

    private static func optionalInt(_ row: SQLiteStatement, _ column: Int32) throws -> Int? {
        try row.isNull(at: column) ? nil : HistoryItemRowHydration.integer(row, column)
    }
    private static var corrupt: HistoryFailure { .persistence(.invariantViolation) }
}

extension HistoryAuthority {
    internal func composeRetentionExpansionForCapture(
        _ v1Plan: MutationPlan,
        prepared: PreparedCaptureBundle,
        in database: SQLiteDatabase
    ) throws -> MutationPlan {
        guard let policies = try RetentionConfigLoading.loadCaptureLanePolicies(in: database) else { return v1Plan }
        let primaryID: HistoryItemID
        let insertedBytes: Int
        switch v1Plan.mutations.first {
        case .create(let item):
            primaryID = item.id
            insertedBytes = item.canonical.representations.reduce(0) { $0 + $1.content.bytes.count }
        case .recordCopy(let itemID, _):
            primaryID = itemID
            insertedBytes = 0
        default: throw HistoryFailure.persistence(.invariantViolation)
        }
        let total = try RetentionConfigLoading.checkedAdd(
            RetentionConfigLoading.totalRetainedBytes(in: database), insertedBytes)
        var countVictims = 0
        let primaryMutations = v1Plan.mutations.filter { mutation in
            if case .retirePrefix(let prefix) = mutation {
                countVictims = prefix.itemCount
                return false
            }
            return true
        }
        let prefix = try RetentionConfigLoading.retirementPrefix(
            in: database, policies: policies, now: prepared.domain.observedAt,
            protectedItemID: primaryID, projectedTotalBytes: total,
            minimumRetiredItems: countVictims
        )
        return MutationPlan(
            outcome: v1Plan.outcome,
            mutations: primaryMutations + (prefix.map { [.retirePrefix($0)] } ?? [])
        )
    }
}
