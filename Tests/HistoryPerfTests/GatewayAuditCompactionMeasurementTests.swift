import Foundation
import HistoryCore
@testable import HistoryStorage
import Testing

/// Opt-in helpers evidence over the real Authority connection. Fixture setup
/// seeds codec-valid uniform audit rows directly; timings measure maintenance,
/// not append throughput, gateway authorization, cold I/O or percentile tails.
@Suite(.serialized)
struct GatewayAuditCompactionMeasurementTests {
    @Test(arguments: [false, true], [false, true])
    func measuresSmallAndNearCapacityAuditIntervals(nearCapacity: Bool, trimExpiredPrefix: Bool) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let fixture = try await history.authority.seedCompactionMeasurement(nearCapacity: nearCapacity)
        for sample in 0...5 {
            try Task.checkCancellation()
            let measurement = try await history.authority.measureAuditCompaction(
                fixture, trimExpiredPrefix: trimExpiredPrefix, sample: sample
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = try encoder.encode(measurement)
            print("gateway-audit-compaction " + String(decoding: json, as: UTF8.self))
            #expect(measurement.compacted == trimExpiredPrefix)
        }
    }
}

private struct CompactionMeasurementFixture: Sendable {
    let rows: Int
    let auditBytes: UInt64
    let payloadBytesPerRow: Int
    let now: Date
}

private struct AuditCompactionMeasurement: Codable, Sendable {
    let configuration: String
    let retainedRowsBefore: Int
    let logicalAuditBytesBefore: UInt64
    let payloadBytesBefore: UInt64
    let expiredPrefixRows: Int
    let sampleIndex: Int
    let isWarmup: Bool
    let elapsedMilliseconds: Double
    let cacheHits: Int
    let cacheMisses: Int
    let sqliteCancellationChecks: Bool
    let compacted: Bool
    let retainedRowsAfter: Int
    let logicalAuditBytesAfter: UInt64
}

private struct AuditMeasurementRollback: Error {
    let measurement: AuditCompactionMeasurement
}

private extension HistoryAuthority {
    func seedCompactionMeasurement(nearCapacity: Bool) throws -> CompactionMeasurementFixture {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        do {
            return try database.writeTransaction(checkingCancellation: true) {
                let initial = try Self.loadGatewayConfig(in: database)
                guard initial.compactionFloor == 1, initial.nextAuditSequence == 1, initial.auditBytes == 0 else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                let payload = OperationRecordPayload(
                    connectionID: .init(rawValue: initial.appIntentsConnectionID), capability: .browse,
                    operationKind: .readRecent, outcome: .succeeded, failureKind: nil, denialReason: nil,
                    requestSummary: .recent(limit: 10), resultSummary: .page(returnedCount: 1, hasMore: false),
                    requestedAt: now, committedAt: now, changePosition: nil
                )
                _ = try GatewayAuditStore.append(payload, config: initial, in: database)
                let prototype = try database.prepare("SELECT payloadBlob FROM operation_records WHERE auditSequence=?",
                                                     bindings: [.blob(sqliteUInt64(1))])
                let bytes: Data
                do {
                    defer { prototype.finalize() }
                    guard try prototype.step() else { throw HistoryFailure.persistence(.invariantViolation) }
                    bytes = try prototype.blob(at: 0)
                }
                let contribution = try Self.loadGatewayConfig(in: database).auditBytes
                guard contribution > 0 else { throw HistoryFailure.persistence(.invariantViolation) }
                let capacityRows = UInt64(ExternalLimits.standard.maxAuditLogSize) / contribution
                guard let rows = Int(exactly: nearCapacity ? capacityRows : 10_000), rows > 1 else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                let (auditBytes, overflow) = UInt64(rows).multipliedReportingOverflow(by: contribution)
                guard !overflow, auditBytes <= UInt64(ExternalLimits.standard.maxAuditLogSize) else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                var bindings: [SQLiteValue] = [
                    .blob(sqliteUInt64(2)), .text(initial.appIntentsConnectionID.uuidString),
                    .integer(Int64(ExternalCapability.browse.rawValue)), .integer(Int64(ExternalOperationKind.readRecent.rawValue)),
                    .integer(Int64(ExternalOutcome.succeeded.rawValue)), .blob(bytes),
                    .real(now.timeIntervalSinceReferenceDate), .real(now.timeIntervalSinceReferenceDate),
                ]
                let insert = try database.prepare("""
                    INSERT INTO operation_records
                        (auditSequence, connectionIDRaw, capabilityRaw, operationKindRaw,
                         outcomeRaw, failureKindRaw, denialReasonRaw, payloadBlob,
                         requestedAt, committedAt, changePositionRaw, auditSchemaVersion)
                    VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, NULL, 1)
                    """, bindings: bindings)
                do {
                    defer { insert.finalize() }
                    for sequence in 2...rows {
                        try Task.checkCancellation()
                        if sequence > 2 {
                            bindings[0] = .blob(sqliteUInt64(UInt64(sequence)))
                            try insert.reset(bindings: bindings)
                        }
                        _ = try insert.step()
                    }
                }
                try database.execute("UPDATE gateway_config SET nextAuditSequence=?, auditBytes=?",
                                     bindings: [.blob(sqliteUInt64(UInt64(rows) + 1)), .blob(sqliteUInt64(auditBytes))])
                let config = try Self.loadGatewayConfig(in: database)
                // The actual complete production validator proves the seeded
                // interval before measurements. This warms the same-process store.
                try GatewayAuditStore.validateRetainedState(config: config, in: database)
                let count = try database.prepare("SELECT count(*) FROM operation_records")
                defer { count.finalize() }
                guard try count.step(), try count.integer(at: 0) == Int64(rows) else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                return CompactionMeasurementFixture(rows: rows, auditBytes: auditBytes,
                                                    payloadBytesPerRow: bytes.count, now: now)
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    func measureAuditCompaction(
        _ fixture: CompactionMeasurementFixture, trimExpiredPrefix: Bool, sample: Int
    ) throws -> AuditCompactionMeasurement {
        do {
            return try database.writeTransaction(checkingCancellation: true) {
                let expiredRows = trimExpiredPrefix ? fixture.rows / 2 : 0
                if expiredRows > 0 {
                    let expiredAt = fixture.now.addingTimeInterval(-TimeInterval(ExternalLimits.standard.maxAuditAgeSeconds) - 1)
                    try database.execute("""
                        UPDATE operation_records SET requestedAt=?, committedAt=? WHERE auditSequence<?
                        """, bindings: [.real(expiredAt.timeIntervalSinceReferenceDate), .real(expiredAt.timeIntervalSinceReferenceDate),
                                        .blob(sqliteUInt64(UInt64(expiredRows) + 1))])
                }
                let before = try Self.loadGatewayConfig(in: database)
                guard before.auditBytes == fixture.auditBytes else { throw HistoryFailure.persistence(.invariantViolation) }
                let cacheBefore = try database.cacheReadWork
                let started = ContinuousClock.now
                let compacted = try GatewayAuditStore.compactIfNeeded(now: fixture.now, config: before, in: database)
                let duration = started.duration(to: ContinuousClock.now).components
                let elapsed = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
                let cacheAfter = try database.cacheReadWork
                let after = try Self.loadGatewayConfig(in: database)
                let totals = try database.prepare("SELECT count(*), sum(length(payloadBlob)) FROM operation_records")
                let rowsAfter: Int
                let payloadBytesAfter: UInt64
                do {
                    defer { totals.finalize() }
                    guard try totals.step(), let count = Int(exactly: try totals.integer(at: 0)),
                          let payloadBytes = UInt64(exactly: try totals.integer(at: 1)) else {
                        throw HistoryFailure.persistence(.invariantViolation)
                    }
                    rowsAfter = count
                    payloadBytesAfter = payloadBytes
                }
                let overhead = UInt64(rowsAfter) * UInt64(ExternalLimits.standard.auditRecordAccountingOverheadBytes)
                guard compacted == trimExpiredPrefix,
                      rowsAfter == fixture.rows - expiredRows + (compacted ? 1 : 0),
                      after.compactionFloor == UInt64(expiredRows) + 1,
                      after.nextAuditSequence == before.nextAuditSequence + (compacted ? 1 : 0),
                      after.auditBytes == payloadBytesAfter + overhead else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
#if DEBUG
                let configuration = "Debug"
#else
                let configuration = "Release"
#endif
                let measurement = AuditCompactionMeasurement(
                    configuration: configuration, retainedRowsBefore: fixture.rows,
                    logicalAuditBytesBefore: fixture.auditBytes,
                    payloadBytesBefore: UInt64(fixture.rows) * UInt64(fixture.payloadBytesPerRow),
                    expiredPrefixRows: expiredRows, sampleIndex: sample, isWarmup: sample == 0,
                    elapsedMilliseconds: elapsed,
                    cacheHits: Int(cacheAfter.hits &- cacheBefore.hits), cacheMisses: Int(cacheAfter.misses &- cacheBefore.misses),
                    sqliteCancellationChecks: true, compacted: compacted,
                    retainedRowsAfter: rowsAfter, logicalAuditBytesAfter: after.auditBytes
                )
                // Each sample sees the exact original rows and counters.
                // Rolling back the private fixture happens after its timer.
                try Task.checkCancellation()
                throw AuditMeasurementRollback(measurement: measurement)
            }
        } catch let rollback as AuditMeasurementRollback {
            try Task.checkCancellation()
            return rollback.measurement
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}
