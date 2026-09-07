/// X.4 central audit-store proofs (`V2-05` §4.3–§4.6 / D34 / D36).
/// Tests use the real SQLite database and the package-only synchronous
/// seam that the sole HistoryAuthority writer composes inside transactions.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

enum GatewayAuditTestSupport {
    static let connectionID = ExternalConnectionID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000904"
    )!)
    static let itemID = HistoryItemID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000905"
    )!)
    static let requestedAt = Date(timeIntervalSinceReferenceDate: 900_000_000)

    static func setCounters(
        nextAuditSequence: UInt64 = 1,
        auditBytes: UInt64 = 0,
        compactionFloor: UInt64 = 1,
        in database: SQLiteDatabase
    ) throws {
        try database.execute(
            "UPDATE gateway_config SET nextAuditSequence = ?, auditBytes = ?, compactionFloor = ?",
            bindings: [.blob(sqliteUInt64(nextAuditSequence)), .blob(sqliteUInt64(auditBytes)),
                       .blob(sqliteUInt64(compactionFloor))]
        )
    }

    static func recentPayload(
        requestedAt: Date = requestedAt,
        committedAt: Date = requestedAt
    ) -> OperationRecordPayload {
        OperationRecordPayload(
            connectionID: connectionID,
            capability: .browse,
            operationKind: .readRecent,
            outcome: .succeeded,
            failureKind: nil,
            denialReason: nil,
            requestSummary: .recent(limit: 10),
            resultSummary: .page(returnedCount: 1, hasMore: false),
            requestedAt: requestedAt,
            committedAt: committedAt,
            changePosition: nil
        )
    }

    static func appendRecent(
        count: Int,
        startingAt timestamp: Date = requestedAt,
        context: SQLiteDatabase,
        limits: ExternalLimits = .standard
    ) throws {
        for offset in 0..<count {
            let date = timestamp.addingTimeInterval(TimeInterval(offset))
            _ = try GatewayAuditStore.append(
                recentPayload(requestedAt: date, committedAt: date),
                config: HistoryAuthority.loadGatewayConfig(in: context),
                in: context,
                limits: limits
            )
        }
    }

    static func limits(
        maxAuditLogSize: Int = 64 * 1_048_576,
        maxAuditAgeSeconds: Int = 31_536_000,
        compactionCadenceOps: Int = 100,
        maxAuditReadBatchSize: Int = 500
    ) -> ExternalLimits {
        ExternalLimits(
            maximumDisplayNameUTF8Bytes: 256,
            maximumConnections: 500,
            maximumGrantRowsPerConnection: 8,
            maxAffectedItemsPerRecord: 32,
            maxAuditLogSize: maxAuditLogSize,
            auditRecordAccountingOverheadBytes: 128,
            maximumAuditPayloadBlobBytes: 16 * 1_024,
            maxAuditAgeSeconds: maxAuditAgeSeconds,
            compactionCadenceOps: compactionCadenceOps,
            maxAuditReadBatchSize: maxAuditReadBatchSize,
            externalBrowseLimitLowerBound: 1,
            externalBrowseLimitUpperBound: 500
        )!
    }

    static func rows(in context: SQLiteDatabase) throws -> [OperationRecordRow] {
        try GatewayStoreSnapshot.operationRows(in: context)
    }

    static func contribution(
        of row: OperationRecordRow,
        limits: ExternalLimits = .standard
    ) throws -> UInt64 {
        guard let payloadBytes = UInt64(exactly: row.payloadBlob.count),
              let overhead = UInt64(
                exactly: limits.auditRecordAccountingOverheadBytes
              ) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let total = payloadBytes.addingReportingOverflow(overhead)
        guard !total.overflow else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return total.partialValue
    }

    static func totalContribution(
        of rows: [OperationRecordRow],
        limits: ExternalLimits = .standard
    ) throws -> UInt64 {
        var total: UInt64 = 0
        for row in rows {
            let next = total.addingReportingOverflow(
                try contribution(of: row, limits: limits)
            )
            guard !next.overflow else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            total = next.partialValue
        }
        return total
    }
}

@Suite("Gateway audit store append and read (X.4)")
struct GatewayAuditStoreTests {
    private enum RetainedDamage: CaseIterable, Sendable {
        case gap, belowFloor, aboveHead, schemaRaw, payload, byteCounter

        var expectedFailure: HistoryFailure {
            switch self {
            case .schemaRaw, .payload: .persistence(.corruptStoredValue)
            default: .persistence(.invariantViolation)
            }
        }
    }

    @Test("append mints N, advances once, and accounts exact logical bytes")
    func appendMintsAndAccountsExactly() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            let sequence = try database.writeTransaction {
                try GatewayAuditStore.append(
                    GatewayAuditTestSupport.recentPayload(),
                    config: HistoryAuthority.loadGatewayConfig(in: database), in: database
                )
            }
            let row = try #require(GatewayAuditTestSupport.rows(in: database).first)
            let config = try HistoryAuthority.loadGatewayConfig(in: database)
            #expect(sequence == 1)
            #expect(row.auditSequence == 1)
            #expect(config.nextAuditSequence == 2)
            #expect(try config.auditBytes == GatewayAuditTestSupport.contribution(of: row))
            #expect(row.connectionIDRaw == GatewayAuditTestSupport.connectionID.rawValue)
            #expect(row.capabilityRaw == ExternalCapability.browse.rawValue)
            #expect(row.operationKindRaw == ExternalOperationKind.readRecent.rawValue)
            #expect(row.outcomeRaw == ExternalOutcome.succeeded.rawValue)
        }
    }

    @Test("append overflow rejects before row or counter mutation")
    func appendOverflowHasNoPartialMutation() async throws {
        for sequenceOverflow in [true, false] {
            let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
            try await history.authority.withTestDatabase { authority in
                let database = authority.database
                try database.writeTransaction {
                    try GatewayAuditTestSupport.setCounters(
                        nextAuditSequence: sequenceOverflow ? .max : 1,
                        auditBytes: sequenceOverflow ? 0 : .max,
                        compactionFloor: sequenceOverflow ? .max : 1, in: database
                    )
                }
                let before = try GatewayStoreSnapshot.read(in: database)
                #expect(throws: ExternalFailure.persistence(.invariantViolation)) {
                    try database.writeTransaction {
                        try GatewayAuditStore.append(
                            GatewayAuditTestSupport.recentPayload(),
                            config: HistoryAuthority.loadGatewayConfig(in: database), in: database
                        )
                    }
                }
                #expect(try GatewayStoreSnapshot.read(in: database) == before)
            }
        }
    }

    @Test("bounded page is inclusive at since and exclusive at snapshot head")
    func boundedPageUsesExclusiveSnapshotHead() async throws {
        let limits = GatewayAuditTestSupport.limits(maxAuditReadBatchSize: 2)
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 3, context: database, limits: limits)
            }
            let config = try HistoryAuthority.loadGatewayConfig(in: database)
            let first = try GatewayAuditStore.readPage(
                since: 1, snapshotHead: 4, config: config, in: database, limits: limits
            )
            #expect(first.map(\.auditSequence) == [1, 2])
            let frozen = try GatewayAuditStore.readPage(
                since: 1, snapshotHead: 3, config: config, in: database, limits: limits
            )
            #expect(frozen.map(\.auditSequence) == [1, 2])
            #expect(!frozen.contains(where: { $0.auditSequence == 3 }))
        }
    }

    @Test("read below compaction floor returns the dedicated typed failure")
    func readBelowFloorIsTyped() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            try database.writeTransaction {
                try GatewayAuditTestSupport.setCounters(nextAuditSequence: 4, compactionFloor: 3, in: database)
            }
            #expect(throws: ExternalFailure.auditCompactedBefore(floor: 3)) {
                try GatewayAuditStore.readPage(
                    since: 2, snapshotHead: 4,
                    config: HistoryAuthority.loadGatewayConfig(in: database), in: database
                )
            }
        }
    }

    @Test("typed row decode projects affected IDs and rejects bad raw or blob")
    func typedDecodeIsFailClosed() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            let payload = OperationRecordPayload(
                connectionID: GatewayAuditTestSupport.connectionID, capability: .manage,
                operationKind: .manageRemove, outcome: .succeeded,
                failureKind: nil, denialReason: nil,
                requestSummary: .remove(itemID: GatewayAuditTestSupport.itemID.rawValue),
                resultSummary: .affectedItemIDs([GatewayAuditTestSupport.itemID.rawValue]),
                requestedAt: GatewayAuditTestSupport.requestedAt,
                committedAt: GatewayAuditTestSupport.requestedAt,
                changePosition: ChangePosition(rawValue: 9)
            )
            try database.writeTransaction {
                _ = try GatewayAuditStore.append(
                    payload, config: HistoryAuthority.loadGatewayConfig(in: database), in: database
                )
            }
            let config = try HistoryAuthority.loadGatewayConfig(in: database)
            let dto = try #require(GatewayAuditStore.readPage(
                since: 1, snapshotHead: 2, config: config, in: database
            ).first)
            #expect(dto.affectedItemIDs == [GatewayAuditTestSupport.itemID])
            #expect(dto.changePosition == ChangePosition(rawValue: 9))

            try database.writeTransaction {
                try database.execute("UPDATE operation_records SET operationKindRaw = 0")
            }
            #expect(throws: ExternalFailure.persistence(.corruptStoredValue)) {
                try GatewayAuditStore.readPage(since: 1, snapshotHead: 2, config: config, in: database)
            }
            try database.writeTransaction {
                try database.execute(
                    "UPDATE operation_records SET operationKindRaw = ?, payloadBlob = ?",
                    bindings: [.integer(Int64(ExternalOperationKind.manageRemove.rawValue)), .blob(Data([0]))]
                )
            }
            #expect(throws: ExternalFailure.persistence(.corruptStoredValue)) {
                try GatewayAuditStore.readPage(since: 1, snapshotHead: 2, config: config, in: database)
            }
        }
    }

    @Test("startup validation catches interval, payload, raw, and counter corruption")
    func retainedStateCorruptionFailsClosed() async throws {
        for damage in RetainedDamage.allCases {
            let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
            try await history.authority.withTestDatabase { authority in
                let database = authority.database
                try database.writeTransaction {
                    try GatewayAuditTestSupport.appendRecent(count: 3, context: database)
                    let config = try HistoryAuthority.loadGatewayConfig(in: database)
                    let rows = try GatewayAuditTestSupport.rows(in: database)
                    switch damage {
                    case .gap:
                        let bytes = config.auditBytes - (try GatewayAuditTestSupport.contribution(of: rows[1]))
                        try database.execute("DELETE FROM operation_records WHERE auditSequence = ?",
                                             bindings: [.blob(sqliteUInt64(2))])
                        try GatewayAuditTestSupport.setCounters(nextAuditSequence: 4, auditBytes: bytes, in: database)
                    case .belowFloor:
                        try GatewayAuditTestSupport.setCounters(
                            nextAuditSequence: 4, auditBytes: config.auditBytes, compactionFloor: 2, in: database
                        )
                    case .aboveHead:
                        try database.execute(
                            "UPDATE operation_records SET auditSequence = ? WHERE auditSequence = ?",
                            bindings: [.blob(sqliteUInt64(4)), .blob(sqliteUInt64(3))]
                        )
                    case .schemaRaw:
                        try database.execute("UPDATE operation_records SET auditSchemaVersion = 2 WHERE auditSequence = ?",
                                             bindings: [.blob(sqliteUInt64(1))])
                    case .payload:
                        try database.execute("UPDATE operation_records SET payloadBlob = ? WHERE auditSequence = ?",
                                             bindings: [.blob(Data([0])), .blob(sqliteUInt64(1))])
                    case .byteCounter:
                        try GatewayAuditTestSupport.setCounters(nextAuditSequence: 4, auditBytes: .max, in: database)
                    }
                }
                #expect(throws: damage.expectedFailure, "damage: \(damage)") {
                    try GatewayAuditStore.validateRetainedState(
                        config: HistoryAuthority.loadGatewayConfig(in: database),
                        in: database, limits: GatewayAuditTestSupport.limits(maxAuditReadBatchSize: 2)
                    )
                }
            }
        }
    }

    @Test("SQLite rejects duplicate audit sequences without changing durable records")
    func duplicateSequenceIsRejected() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 3, context: database)
            }
            let before = try GatewayStoreSnapshot.read(in: database)
            do {
                try database.writeTransaction {
                    try database.execute(
                        "UPDATE operation_records SET auditSequence = ? WHERE auditSequence = ?",
                        bindings: [.blob(sqliteUInt64(2)), .blob(sqliteUInt64(3))]
                    )
                }
                Issue.record("duplicate audit sequence unexpectedly accepted")
            } catch let failure as SQLiteFailure {
                #expect(failure.isConstraint)
            }
            #expect(try GatewayStoreSnapshot.read(in: database) == before)
        }
    }

    @Test("startup validation traverses sequence-keyed bounded batches")
    func retainedStateValidationUsesMultipleBatches() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        try await history.authority.withTestDatabase { authority in
            let database = authority.database
            let limits = GatewayAuditTestSupport.limits(maxAuditReadBatchSize: 2)
            try database.writeTransaction {
                try GatewayAuditTestSupport.appendRecent(count: 5, context: database, limits: limits)
            }
            try GatewayAuditStore.validateRetainedState(
                config: HistoryAuthority.loadGatewayConfig(in: database), in: database, limits: limits
            )
        }
    }
}
