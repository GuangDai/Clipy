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

    /// R1's strict age prefix always precedes R2's additional oldest prefix.
    /// A single indexed cursor can therefore implement the same pure order
    /// without keeping, filtering, or sorting the unaffected inventory.
    /// Overrides describe only R3-affected items; total is already post-prune
    /// and post-primary/count. Pinned ∪ primary feasibility precedes selection.
    internal static func itemRetirements(
        in database: SQLiteDatabase,
        policies: HistoryRetentionPolicies,
        now: Date,
        protectedItemID: HistoryItemID?,
        alreadyRemoved: Set<HistoryItemID>,
        projectedTotalBytes: Int,
        revisionByteOverrides: [HistoryItemID: Int] = [:],
        additionalProtectedBytes: Int = 0
    ) throws -> [HistoryItemID] {
        guard projectedTotalBytes >= 0 else { throw corrupt }
        if let storage = policies.storage {
            let protectedRows = try database.prepare("""
                SELECT id,canonicalBytes,revisionBytes FROM history_items
                WHERE pinOrdinal IS NOT NULL OR id=?
                """, bindings: [.text(protectedItemID?.rawValue.uuidString ?? "")])
            defer { protectedRows.finalize() }
            var irreducible = additionalProtectedBytes
            while try protectedRows.step() {
                let id = HistoryItemID(rawValue: try HistoryItemRowHydration.uuid(protectedRows.text(at: 0)))
                guard !alreadyRemoved.contains(id) else { throw corrupt }
                let revisions = try revisionByteOverrides[id] ?? HistoryItemRowHydration.integer(protectedRows, 2)
                irreducible = try checkedAdd(irreducible,
                    checkedAdd(HistoryItemRowHydration.integer(protectedRows, 1), revisions))
            }
            guard irreducible <= storage.maxTotalBytes else {
                throw HistoryFailure.capacityExceeded(.storageBytes)
            }
        }
        let cutoff = policies.age.map { now.addingTimeInterval(-$0.maxAge).timeIntervalSinceReferenceDate }
        let requiresBytes = policies.storage.map { projectedTotalBytes > $0.maxTotalBytes } ?? false
        guard cutoff != nil || requiresBytes else { return [] }
        let agePredicate = requiresBytes ? "" : " AND lastCopiedAt < ?"
        let rows = try database.prepare("""
            SELECT id,lastCopiedAt,canonicalBytes,revisionBytes FROM history_items
            WHERE pinOrdinal IS NULL\(agePredicate)
            ORDER BY lastCopiedAt,id
            """, bindings: requiresBytes ? [] : [cutoff.map(SQLiteValue.real) ?? .null])
        defer { rows.finalize() }
        var remaining = projectedTotalBytes
        var victims: [HistoryItemID] = []
        while try rows.step() {
            let id = HistoryItemID(rawValue: try HistoryItemRowHydration.uuid(rows.text(at: 0)))
            if id == protectedItemID || alreadyRemoved.contains(id) { continue }
            let copiedAt = try rows.real(at: 1)
            guard copiedAt.isFinite else { throw corrupt }
            let aged = cutoff.map { copiedAt < $0 } ?? false
            let overBudget = policies.storage.map { remaining > $0.maxTotalBytes } ?? false
            guard aged || overBudget else { break }
            let revisions = try revisionByteOverrides[id] ?? HistoryItemRowHydration.integer(rows, 3)
            remaining = try checkedSubtract(remaining,
                checkedAdd(HistoryItemRowHydration.integer(rows, 2), revisions))
            victims.append(id)
        }
        if let storage = policies.storage, remaining > storage.maxTotalBytes { throw corrupt }
        return victims
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
        var total = try RetentionConfigLoading.checkedAdd(
            RetentionConfigLoading.totalRetainedBytes(in: database), insertedBytes)
        var countVictims = Set<HistoryItemID>()
        for mutation in v1Plan.mutations {
            guard case .retire(let id, _) = mutation else { continue }
            guard id != primaryID, countVictims.insert(id).inserted,
                  let item = try HistoryItemRowHydration.metadata(itemID: id, in: database, limits: limits),
                  item.pinOrdinal == nil else { throw HistoryFailure.persistence(.invariantViolation) }
            total = try RetentionConfigLoading.checkedSubtract(total,
                RetentionConfigLoading.checkedAdd(item.canonicalBytes, item.revisionBytes))
        }
        let victims = try RetentionConfigLoading.itemRetirements(
            in: database, policies: policies, now: prepared.domain.observedAt,
            protectedItemID: primaryID, alreadyRemoved: countVictims,
            projectedTotalBytes: total, additionalProtectedBytes: insertedBytes)
        return MutationPlan(outcome: v1Plan.outcome,
            mutations: v1Plan.mutations + victims.map { .retire(itemID: $0, reason: .retention) })
    }
}
