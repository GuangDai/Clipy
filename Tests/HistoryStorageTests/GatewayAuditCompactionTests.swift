/// X.4 audit maintenance proofs (`V2-05` §4.5/§5.6).
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("Gateway audit compaction and rebase (X.4)")
struct GatewayAuditCompactionTests {
    private enum InjectedFailure: Error { case afterMaintenance }

    @Test("size compaction appends marker and removes exactly one oldest prefix")
    func sizeCompactionPreservesOneContiguousSuffix() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            let limits = GatewayAuditTestSupport.limits(maxAuditLogSize: 450, compactionCadenceOps: 1)
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 4, context: database, limits: limits)
            }
            let compacted = try database.writeTransaction {
                try GatewayAuditStore.compactIfNeeded(
                    now: GatewayAuditTestSupport.requestedAt.addingTimeInterval(10),
                    config: HistoryAuthority.loadGatewayConfig(in: database), in: database, limits: limits
                )
            }
            #expect(compacted)
            let rows = try GatewayAuditTestSupport.rows(in: database)
            let config = try HistoryAuthority.loadGatewayConfig(in: database)
            #expect(rows.map(\.auditSequence) == [3, 4, 5])
            #expect(config.compactionFloor == 3)
            #expect(config.nextAuditSequence == 6)
            #expect(try config.auditBytes == GatewayAuditTestSupport.totalContribution(of: rows, limits: limits))
            #expect(rows.last?.operationKindRaw == ExternalOperationKind.adminCompact.rawValue)
            try GatewayAuditStore.validateRetainedState(config: config, in: database, limits: limits)
        }
    }

    @Test("age compaction trims only the expired oldest prefix")
    func ageCompactionTrimsExpiredPrefix() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            let limits = GatewayAuditTestSupport.limits(maxAuditAgeSeconds: 10, compactionCadenceOps: 1)
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 2, context: database, limits: limits)
                try GatewayAuditTestSupport.appendRecent(
                    count: 1, startingAt: GatewayAuditTestSupport.requestedAt.addingTimeInterval(20),
                    context: database, limits: limits
                )
            }
            let compacted = try database.writeTransaction {
                try GatewayAuditStore.compactIfNeeded(
                    now: GatewayAuditTestSupport.requestedAt.addingTimeInterval(21),
                    config: HistoryAuthority.loadGatewayConfig(in: database), in: database, limits: limits
                )
            }
            #expect(compacted)
            #expect(try GatewayAuditTestSupport.rows(in: database).map(\.auditSequence) == [3, 4])
            #expect(try HistoryAuthority.loadGatewayConfig(in: database).compactionFloor == 3)
        }
    }

    @Test("completed compaction does not immediately retrigger on its marker")
    func compactionMarkerDoesNotRetrigger() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            let limits = GatewayAuditTestSupport.limits(maxAuditLogSize: 450, compactionCadenceOps: 1)
            let now = GatewayAuditTestSupport.requestedAt.addingTimeInterval(10)
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 4, context: database, limits: limits)
            }
            let first = try database.writeTransaction {
                try GatewayAuditStore.compactIfNeeded(
                    now: now, config: HistoryAuthority.loadGatewayConfig(in: database), in: database, limits: limits
                )
            }
            #expect(first)
            let before = try GatewayStoreSnapshot.read(in: database)
            let retriggered = try database.writeTransaction {
                try GatewayAuditStore.compactIfNeeded(
                    now: now, config: HistoryAuthority.loadGatewayConfig(in: database), in: database, limits: limits
                )
            }
            #expect(!retriggered)
            #expect(try GatewayStoreSnapshot.read(in: database) == before)
        }
    }

    @Test("maintenance participates in caller transaction rollback")
    func compactionRollsBackWithCallerTransaction() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            let limits = GatewayAuditTestSupport.limits(maxAuditLogSize: 450, compactionCadenceOps: 1)
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 4, context: database, limits: limits)
            }
            let before = try GatewayStoreSnapshot.read(in: database)
            #expect(throws: InjectedFailure.afterMaintenance) {
                try database.writeTransaction {
                    _ = try GatewayAuditStore.compactIfNeeded(
                        now: GatewayAuditTestSupport.requestedAt.addingTimeInterval(10),
                        config: HistoryAuthority.loadGatewayConfig(in: database), in: database, limits: limits
                    )
                    throw InjectedFailure.afterMaintenance
                }
            }
            #expect(try GatewayStoreSnapshot.read(in: database) == before)
        }
    }

    @Test("rebase discards the named prefix, preserves head, and appends marker")
    func rebasePreservesMonotoneHeadAndSuffix() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 3, context: database)
            }
            let marker = try authority.rebaseGatewayAudit(
                reason: .adminForced, newFloor: 3,
                requestedAt: GatewayAuditTestSupport.requestedAt,
                committedAt: GatewayAuditTestSupport.requestedAt.addingTimeInterval(4)
            )
            let config = try HistoryAuthority.loadGatewayConfig(in: database)
            let rows = try GatewayAuditTestSupport.rows(in: database)
            #expect(marker == 4)
            #expect(config.compactionFloor == 3)
            #expect(config.nextAuditSequence == 5)
            #expect(rows.map(\.auditSequence) == [3, 4])
            #expect(rows.last?.operationKindRaw == ExternalOperationKind.adminRebase.rawValue)
            try GatewayAuditStore.validateRetainedState(config: config, in: database)
        }
    }

    @Test("rebase can quarantine a corrupt prefix but requires a valid suffix")
    func rebaseValidatesOnlyRetainedSuffix() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 3, context: database)
                try database.execute("UPDATE operation_records SET payloadBlob = ? WHERE auditSequence = ?",
                                     bindings: [.blob(Data([0])), .blob(sqliteUInt64(1))])
                try GatewayAuditTestSupport.setCounters(nextAuditSequence: 4, auditBytes: .max, in: database)
            }
            _ = try authority.rebaseGatewayAudit(
                reason: .corruptionDetected, newFloor: 2,
                requestedAt: GatewayAuditTestSupport.requestedAt,
                committedAt: GatewayAuditTestSupport.requestedAt.addingTimeInterval(4)
            )
            let config = try HistoryAuthority.loadGatewayConfig(in: database)
            try GatewayAuditStore.validateRetainedState(config: config, in: database)
            #expect(try GatewayAuditTestSupport.rows(in: database).map(\.auditSequence) == [2, 3, 4])
            #expect(config.compactionFloor == 2)
        }
    }

    @Test("corruption rebase rejects anomalous rows below the declared floor")
    func corruptionRebaseRejectsRowsBelowOldFloor() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 2, context: database)
                let last = try #require(GatewayAuditTestSupport.rows(in: database).last)
                try GatewayAuditTestSupport.setCounters(
                    nextAuditSequence: 3, auditBytes: GatewayAuditTestSupport.contribution(of: last),
                    compactionFloor: 2, in: database
                )
            }
            let before = try GatewayStoreSnapshot.read(in: database)
            #expect(throws: ExternalFailure.persistence(.invariantViolation)) {
                try authority.rebaseGatewayAudit(
                    reason: .corruptionDetected, newFloor: 2,
                    requestedAt: GatewayAuditTestSupport.requestedAt,
                    committedAt: GatewayAuditTestSupport.requestedAt
                )
            }
            #expect(try GatewayStoreSnapshot.read(in: database) == before)
        }
    }

    @Test("invalid rebase floor and byte underflow do not partially mutate")
    func invalidRebaseHasNoPartialMutation() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 2, context: database)
            }
            let original = try GatewayStoreSnapshot.read(in: database)
            #expect(throws: ExternalFailure.persistence(.invariantViolation)) {
                try authority.rebaseGatewayAudit(
                    reason: .adminForced, newFloor: 4,
                    requestedAt: GatewayAuditTestSupport.requestedAt,
                    committedAt: GatewayAuditTestSupport.requestedAt
                )
            }
            #expect(try GatewayStoreSnapshot.read(in: database) == original)
            try database.writeTransaction {
                try GatewayAuditTestSupport.setCounters(nextAuditSequence: 3, auditBytes: 0, in: database)
            }
            let damaged = try GatewayStoreSnapshot.read(in: database)
            #expect(throws: ExternalFailure.persistence(.invariantViolation)) {
                try authority.rebaseGatewayAudit(
                    reason: .adminForced, newFloor: 2,
                    requestedAt: GatewayAuditTestSupport.requestedAt,
                    committedAt: GatewayAuditTestSupport.requestedAt
                )
            }
            #expect(try GatewayStoreSnapshot.read(in: database) == damaged)
        }
    }
}
