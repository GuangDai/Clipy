/// X.4 central audit-store proofs (`V2-05` §4.3–§4.6 / D34 / D36).
/// Tests use the real V3 SwiftData models and the package-only synchronous
/// seam that the sole HistoryAuthority writer composes inside transactions.
import Foundation
import HistoryCore
import SwiftData
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

    static func makeContext(
        nextAuditSequence: UInt64 = 1,
        auditBytes: UInt64 = 0,
        compactionFloor: UInt64 = 1
    ) throws -> (ModelContext, GatewayConfigRow) {
        let schema = Schema(versionedSchema: HistorySchemaV3.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = GatewayConfigRow(
            key: HistoryAuthority.gatewayConfigKey,
            appIntentsConnectionID: connectionID.rawValue,
            nextAuditSequence: nextAuditSequence,
            auditBytes: auditBytes,
            compactionFloor: compactionFloor,
            configSchemaVersion: HistoryAuthority.gatewayConfigSchemaVersion
        )
        context.insert(config)
        return (context, config)
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
        config: GatewayConfigRow,
        context: ModelContext,
        limits: ExternalLimits = .standard
    ) throws {
        for offset in 0..<count {
            let date = timestamp.addingTimeInterval(TimeInterval(offset))
            _ = try GatewayAuditStore.append(
                recentPayload(requestedAt: date, committedAt: date),
                config: config,
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

    static func rows(in context: ModelContext) throws -> [OperationRecordRow] {
        var descriptor = FetchDescriptor<OperationRecordRow>(
            sortBy: [SortDescriptor(\.auditSequence)]
        )
        descriptor.fetchLimit = 10_000
        return try context.fetch(descriptor)
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
    private enum RetainedDamage: CaseIterable {
        case gap
        case belowFloor
        case aboveHead
        case duplicate
        case schemaRaw
        case payload
        case byteCounter

        var expectedFailure: HistoryFailure {
            switch self {
            case .schemaRaw, .payload:
                .persistence(.corruptStoredValue)
            case .gap, .belowFloor, .aboveHead, .duplicate, .byteCounter:
                .persistence(.invariantViolation)
            }
        }
    }

    @Test("append mints N, advances once, and accounts exact logical bytes")
    func appendMintsAndAccountsExactly() throws {
        let (context, config) = try GatewayAuditTestSupport.makeContext()

        let sequence = try GatewayAuditStore.append(
            GatewayAuditTestSupport.recentPayload(),
            config: config,
            in: context
        )

        let row = try #require(GatewayAuditTestSupport.rows(in: context).first)
        let expectedContribution = try GatewayAuditTestSupport.contribution(
            of: row
        )
        #expect(sequence == 1)
        #expect(row.auditSequence == 1)
        #expect(config.nextAuditSequence == 2)
        #expect(config.auditBytes == expectedContribution)
        #expect(row.connectionIDRaw == GatewayAuditTestSupport.connectionID.rawValue)
        #expect(row.capabilityRaw == ExternalCapability.browse.rawValue)
        #expect(row.operationKindRaw == ExternalOperationKind.readRecent.rawValue)
        #expect(row.outcomeRaw == ExternalOutcome.succeeded.rawValue)
    }

    @Test("append overflow rejects before row or counter mutation")
    func appendOverflowHasNoPartialMutation() throws {
        let (sequenceContext, sequenceConfig) = try GatewayAuditTestSupport.makeContext(
            nextAuditSequence: .max,
            compactionFloor: .max
        )
        #expect(throws: ExternalFailure.persistence(.invariantViolation)) {
            try GatewayAuditStore.append(
                GatewayAuditTestSupport.recentPayload(),
                config: sequenceConfig,
                in: sequenceContext
            )
        }
        #expect(sequenceConfig.nextAuditSequence == .max)
        #expect(sequenceConfig.auditBytes == 0)
        #expect(try GatewayAuditTestSupport.rows(in: sequenceContext).isEmpty)

        let (bytesContext, bytesConfig) = try GatewayAuditTestSupport.makeContext(
            auditBytes: .max
        )
        #expect(throws: ExternalFailure.persistence(.invariantViolation)) {
            try GatewayAuditStore.append(
                GatewayAuditTestSupport.recentPayload(),
                config: bytesConfig,
                in: bytesContext
            )
        }
        #expect(bytesConfig.nextAuditSequence == 1)
        #expect(bytesConfig.auditBytes == .max)
        #expect(try GatewayAuditTestSupport.rows(in: bytesContext).isEmpty)
    }

    @Test("bounded page is inclusive at since and exclusive at snapshot head")
    func boundedPageUsesExclusiveSnapshotHead() throws {
        let limits = GatewayAuditTestSupport.limits(maxAuditReadBatchSize: 2)
        let (context, config) = try GatewayAuditTestSupport.makeContext()
        try GatewayAuditTestSupport.appendRecent(
            count: 3,
            config: config,
            context: context,
            limits: limits
        )

        let firstPage = try GatewayAuditStore.readPage(
            since: 1,
            snapshotHead: 4,
            config: config,
            in: context,
            limits: limits
        )
        #expect(firstPage.map(\.auditSequence) == [1, 2])

        let frozenPage = try GatewayAuditStore.readPage(
            since: 1,
            snapshotHead: 3,
            config: config,
            in: context,
            limits: limits
        )
        #expect(frozenPage.map(\.auditSequence) == [1, 2])
        #expect(!frozenPage.contains(where: { $0.auditSequence == 3 }))
    }

    @Test("read below compaction floor returns the dedicated typed failure")
    func readBelowFloorIsTyped() throws {
        let (context, config) = try GatewayAuditTestSupport.makeContext(
            nextAuditSequence: 4,
            compactionFloor: 3
        )

        #expect(throws: ExternalFailure.auditCompactedBefore(floor: 3)) {
            try GatewayAuditStore.readPage(
                since: 2,
                snapshotHead: 4,
                config: config,
                in: context
            )
        }
    }

    @Test("typed row decode projects affected IDs and rejects bad raw or blob")
    func typedDecodeIsFailClosed() throws {
        let (context, config) = try GatewayAuditTestSupport.makeContext()
        let payload = OperationRecordPayload(
            connectionID: GatewayAuditTestSupport.connectionID,
            capability: .manage,
            operationKind: .manageRemove,
            outcome: .succeeded,
            failureKind: nil,
            denialReason: nil,
            requestSummary: .remove(
                itemID: GatewayAuditTestSupport.itemID.rawValue
            ),
            resultSummary: .affectedItemIDs([
                GatewayAuditTestSupport.itemID.rawValue
            ]),
            requestedAt: GatewayAuditTestSupport.requestedAt,
            committedAt: GatewayAuditTestSupport.requestedAt,
            changePosition: ChangePosition(rawValue: 9)
        )
        _ = try GatewayAuditStore.append(payload, config: config, in: context)

        let dto = try #require(GatewayAuditStore.readPage(
            since: 1,
            snapshotHead: 2,
            config: config,
            in: context
        ).first)
        #expect(dto.affectedItemIDs == [GatewayAuditTestSupport.itemID])
        #expect(dto.changePosition == ChangePosition(rawValue: 9))

        let row = try #require(GatewayAuditTestSupport.rows(in: context).first)
        row.operationKindRaw = 0
        #expect(throws: ExternalFailure.persistence(.corruptStoredValue)) {
            try GatewayAuditStore.readPage(
                since: 1,
                snapshotHead: 2,
                config: config,
                in: context
            )
        }
        row.operationKindRaw = ExternalOperationKind.manageRemove.rawValue
        row.payloadBlob = Data([0])
        #expect(throws: ExternalFailure.persistence(.corruptStoredValue)) {
            try GatewayAuditStore.readPage(
                since: 1,
                snapshotHead: 2,
                config: config,
                in: context
            )
        }
    }

    @Test("startup validation catches interval, payload, raw, and counter corruption")
    func retainedStateCorruptionFailsClosed() throws {
        for damage in RetainedDamage.allCases {
            let (context, config) = try GatewayAuditTestSupport.makeContext()
            try GatewayAuditTestSupport.appendRecent(
                count: 3,
                config: config,
                context: context
            )
            let rows = try GatewayAuditTestSupport.rows(in: context)
            switch damage {
            case .gap:
                let removedContribution = try GatewayAuditTestSupport.contribution(
                    of: rows[1]
                )
                let remainingBytes = config.auditBytes
                    .subtractingReportingOverflow(removedContribution)
                #expect(!remainingBytes.overflow)
                context.delete(rows[1])
                config.auditBytes = remainingBytes.partialValue
            case .belowFloor:
                config.compactionFloor = 2
            case .aboveHead:
                rows[2].auditSequence = config.nextAuditSequence
            case .duplicate:
                rows[2].auditSequence = rows[1].auditSequence
            case .schemaRaw:
                rows[0].auditSchemaVersion = 2
            case .payload:
                rows[0].payloadBlob = Data([0])
            case .byteCounter:
                config.auditBytes = .max
            }

            #expect(throws: damage.expectedFailure, "damage: \(damage)") {
                try GatewayAuditStore.validateRetainedState(
                    config: config,
                    in: context,
                    limits: GatewayAuditTestSupport.limits(
                        maxAuditReadBatchSize: 2
                    )
                )
            }
        }
    }

    @Test("startup validation traverses sequence-keyed bounded batches")
    func retainedStateValidationUsesMultipleBatches() throws {
        let limits = GatewayAuditTestSupport.limits(maxAuditReadBatchSize: 2)
        let (context, config) = try GatewayAuditTestSupport.makeContext()
        try GatewayAuditTestSupport.appendRecent(
            count: 5,
            config: config,
            context: context,
            limits: limits
        )

        try GatewayAuditStore.validateRetainedState(
            config: config,
            in: context,
            limits: limits
        )
    }
}
