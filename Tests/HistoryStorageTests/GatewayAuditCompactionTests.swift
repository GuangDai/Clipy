/// X.4 audit maintenance proofs (`V2-05` §4.5/§5.6).
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Gateway audit compaction and rebase (X.4)")
struct GatewayAuditCompactionTests {
    private enum InjectedFailure: Error { case afterMaintenance }

    @Test("size compaction appends marker and removes exactly one oldest prefix")
    func sizeCompactionPreservesOneContiguousSuffix() throws {
        let limits = GatewayAuditTestSupport.limits(
            maxAuditLogSize: 450,
            compactionCadenceOps: 1
        )
        let (context, config) = try GatewayAuditTestSupport.makeContext()
        try GatewayAuditTestSupport.appendRecent(
            count: 4,
            config: config,
            context: context,
            limits: limits
        )

        let compacted = try GatewayAuditStore.compactIfNeeded(
            now: GatewayAuditTestSupport.requestedAt.addingTimeInterval(10),
            config: config,
            in: context,
            limits: limits
        )

        #expect(compacted)
        let rows = try GatewayAuditTestSupport.rows(in: context)
        #expect(rows.map(\.auditSequence) == [3, 4, 5])
        #expect(config.compactionFloor == 3)
        #expect(config.nextAuditSequence == 6)
        let expectedBytes = try GatewayAuditTestSupport.totalContribution(
            of: rows,
            limits: limits
        )
        #expect(config.auditBytes == expectedBytes)
        #expect(rows.last?.operationKindRaw == ExternalOperationKind.adminCompact.rawValue)
        try GatewayAuditStore.validateRetainedState(
            config: config,
            in: context,
            limits: limits
        )
    }

    @Test("age compaction trims only the expired oldest prefix")
    func ageCompactionTrimsExpiredPrefix() throws {
        let limits = GatewayAuditTestSupport.limits(
            maxAuditAgeSeconds: 10,
            compactionCadenceOps: 1
        )
        let (context, config) = try GatewayAuditTestSupport.makeContext()
        try GatewayAuditTestSupport.appendRecent(
            count: 2,
            startingAt: GatewayAuditTestSupport.requestedAt,
            config: config,
            context: context,
            limits: limits
        )
        try GatewayAuditTestSupport.appendRecent(
            count: 1,
            startingAt: GatewayAuditTestSupport.requestedAt.addingTimeInterval(20),
            config: config,
            context: context,
            limits: limits
        )

        #expect(try GatewayAuditStore.compactIfNeeded(
            now: GatewayAuditTestSupport.requestedAt.addingTimeInterval(21),
            config: config,
            in: context,
            limits: limits
        ))
        #expect(try GatewayAuditTestSupport.rows(in: context).map(\.auditSequence)
            == [3, 4])
        #expect(config.compactionFloor == 3)
    }

    @Test("completed compaction does not immediately retrigger on its marker")
    func compactionMarkerDoesNotRetrigger() throws {
        let limits = GatewayAuditTestSupport.limits(
            maxAuditLogSize: 450,
            compactionCadenceOps: 1
        )
        let (context, config) = try GatewayAuditTestSupport.makeContext()
        try GatewayAuditTestSupport.appendRecent(
            count: 4,
            config: config,
            context: context,
            limits: limits
        )
        let now = GatewayAuditTestSupport.requestedAt.addingTimeInterval(10)
        #expect(try GatewayAuditStore.compactIfNeeded(
            now: now,
            config: config,
            in: context,
            limits: limits
        ))
        let firstState = try GatewayAuditTestSupport.rows(in: context)

        let retriggered = try GatewayAuditStore.compactIfNeeded(
            now: now,
            config: config,
            in: context,
            limits: limits
        )
        #expect(!retriggered)
        #expect(try GatewayAuditTestSupport.rows(in: context).map(\.auditSequence)
            == firstState.map(\.auditSequence))
    }

    @Test("maintenance participates in caller transaction rollback")
    func compactionRollsBackWithCallerTransaction() throws {
        let limits = GatewayAuditTestSupport.limits(
            maxAuditLogSize: 450,
            compactionCadenceOps: 1
        )
        let (context, config) = try GatewayAuditTestSupport.makeContext()
        try GatewayAuditTestSupport.appendRecent(
            count: 4,
            config: config,
            context: context,
            limits: limits
        )
        try context.save()
        let originalSequences = try GatewayAuditTestSupport.rows(in: context)
            .map(\.auditSequence)
        let originalHead = config.nextAuditSequence
        let originalFloor = config.compactionFloor
        let originalBytes = config.auditBytes

        #expect(throws: InjectedFailure.afterMaintenance) {
            try context.transaction {
                _ = try GatewayAuditStore.compactIfNeeded(
                    now: GatewayAuditTestSupport.requestedAt.addingTimeInterval(10),
                    config: config,
                    in: context,
                    limits: limits
                )
                throw InjectedFailure.afterMaintenance
            }
        }

        let durableConfig = try #require(
            context.fetch(FetchDescriptor<GatewayConfigRow>()).first
        )
        #expect(try GatewayAuditTestSupport.rows(in: context).map(\.auditSequence)
            == originalSequences)
        #expect(durableConfig.nextAuditSequence == originalHead)
        #expect(durableConfig.compactionFloor == originalFloor)
        #expect(durableConfig.auditBytes == originalBytes)
    }

    @Test("rebase discards the named prefix, preserves head, and appends marker")
    func rebasePreservesMonotoneHeadAndSuffix() async throws {
        let container = try GatewayAuditTestSupport.makeContainer()
        do {
            let (context, config) = try GatewayAuditTestSupport.makeContext(
                in: container
            )
            try GatewayAuditTestSupport.appendRecent(
                count: 3,
                config: config,
                context: context
            )
            try context.save()
        }
        let authority = HistoryAuthority(container: container)

        let markerSequence = try await authority.rebaseGatewayAudit(
            reason: .adminForced,
            newFloor: 3,
            requestedAt: GatewayAuditTestSupport.requestedAt,
            committedAt: GatewayAuditTestSupport.requestedAt.addingTimeInterval(4)
        )

        let context = ModelContext(container)
        let config = try #require(
            context.fetch(FetchDescriptor<GatewayConfigRow>()).first
        )
        #expect(markerSequence == 4)
        #expect(config.compactionFloor == 3)
        #expect(config.nextAuditSequence == 5)
        let rows = try GatewayAuditTestSupport.rows(in: context)
        #expect(rows.map(\.auditSequence) == [3, 4])
        #expect(rows.last?.operationKindRaw == ExternalOperationKind.adminRebase.rawValue)
        try GatewayAuditStore.validateRetainedState(config: config, in: context)
    }

    @Test("rebase can quarantine a corrupt prefix but requires a valid suffix")
    func rebaseValidatesOnlyRetainedSuffix() async throws {
        let container = try GatewayAuditTestSupport.makeContainer()
        do {
            let (context, config) = try GatewayAuditTestSupport.makeContext(
                in: container
            )
            try GatewayAuditTestSupport.appendRecent(
                count: 3,
                config: config,
                context: context
            )
            let rows = try GatewayAuditTestSupport.rows(in: context)
            rows[0].payloadBlob = Data([0])
            config.auditBytes = .max
            try context.save()
        }
        let authority = HistoryAuthority(container: container)

        _ = try await authority.rebaseGatewayAudit(
            reason: .corruptionDetected,
            newFloor: 2,
            requestedAt: GatewayAuditTestSupport.requestedAt,
            committedAt: GatewayAuditTestSupport.requestedAt.addingTimeInterval(4)
        )

        let context = ModelContext(container)
        let config = try #require(
            context.fetch(FetchDescriptor<GatewayConfigRow>()).first
        )
        try GatewayAuditStore.validateRetainedState(config: config, in: context)

        let retained = try GatewayAuditTestSupport.rows(in: context)
        #expect(retained.map(\.auditSequence) == [2, 3, 4])
        #expect(config.compactionFloor == 2)
    }

    @Test("corruption rebase rejects anomalous rows below the declared floor")
    func corruptionRebaseRejectsRowsBelowOldFloor() async throws {
        let container = try GatewayAuditTestSupport.makeContainer()
        do {
            let (context, config) = try GatewayAuditTestSupport.makeContext(
                in: container
            )
            try GatewayAuditTestSupport.appendRecent(
                count: 2,
                config: config,
                context: context
            )
            config.compactionFloor = 2
            config.auditBytes = try GatewayAuditTestSupport.contribution(
                of: try #require(GatewayAuditTestSupport.rows(in: context).last)
            )
            try context.save()
        }
        let authority = HistoryAuthority(container: container)

        await #expect(
            throws: ExternalFailure.persistence(.invariantViolation)
        ) {
            try await authority.rebaseGatewayAudit(
                reason: .corruptionDetected,
                newFloor: 2,
                requestedAt: GatewayAuditTestSupport.requestedAt,
                committedAt: GatewayAuditTestSupport.requestedAt
            )
        }
        let context = ModelContext(container)
        #expect(try GatewayAuditTestSupport.rows(in: context).map(\.auditSequence)
            == [1, 2])
    }

    @Test("invalid rebase floor and byte underflow do not partially mutate")
    func invalidRebaseHasNoPartialMutation() async throws {
        let container = try GatewayAuditTestSupport.makeContainer()
        let originalRows: [UInt64]
        let originalBytes: UInt64
        do {
            let (context, config) = try GatewayAuditTestSupport.makeContext(
                in: container
            )
            try GatewayAuditTestSupport.appendRecent(
                count: 2,
                config: config,
                context: context
            )
            originalRows = try GatewayAuditTestSupport.rows(in: context)
                .map(\.auditSequence)
            originalBytes = config.auditBytes
            try context.save()
        }
        let authority = HistoryAuthority(container: container)

        await #expect(
            throws: ExternalFailure.persistence(.invariantViolation)
        ) {
            try await authority.rebaseGatewayAudit(
                reason: .adminForced,
                newFloor: 4,
                requestedAt: GatewayAuditTestSupport.requestedAt,
                committedAt: GatewayAuditTestSupport.requestedAt
            )
        }
        do {
            let context = ModelContext(container)
            let config = try #require(
                context.fetch(FetchDescriptor<GatewayConfigRow>()).first
            )
            #expect(config.compactionFloor == 1)
            #expect(config.nextAuditSequence == 3)
            #expect(config.auditBytes == originalBytes)
            #expect(try GatewayAuditTestSupport.rows(in: context)
                .map(\.auditSequence) == originalRows)
            config.auditBytes = 0
            try context.save()
        }

        await #expect(
            throws: ExternalFailure.persistence(.invariantViolation)
        ) {
            try await authority.rebaseGatewayAudit(
                reason: .adminForced,
                newFloor: 2,
                requestedAt: GatewayAuditTestSupport.requestedAt,
                committedAt: GatewayAuditTestSupport.requestedAt
            )
        }
        let context = ModelContext(container)
        let config = try #require(
            context.fetch(FetchDescriptor<GatewayConfigRow>()).first
        )
        #expect(config.compactionFloor == 1)
        #expect(config.nextAuditSequence == 3)
        #expect(try GatewayAuditTestSupport.rows(in: context).map(\.auditSequence)
            == originalRows)
    }
}
