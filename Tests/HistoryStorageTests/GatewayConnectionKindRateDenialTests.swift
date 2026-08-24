/// Batch 17 follow-up: connection-kind precedence at the Authority-owned
/// external rate-denial audit seam (`V2-05` §3.1/§4.5 and roadmap X.9/F1).
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Gateway connection-kind rate denial", .serialized)
struct GatewayConnectionKindRateDenialTests {
    private static let epoch = Date(
        timeIntervalSinceReferenceDate: 916_000_000
    )

    private static let appRecentDescriptor = ExternalOperationDescriptor(
        capability: .browse,
        operationKind: .readRecent,
        requestSummary: .recent(limit: 1)
    )

    private static let localRecentDescriptor = ExternalOperationDescriptor(
        capability: .browsePreview,
        operationKind: .readRecent,
        requestSummary: .recent(limit: 1)
    )

    private struct Fixture {
        let authority: HistoryAuthority
        let container: ModelContainer
        let appIntentsConnection: ExternalConnectionID
        let localAutomationConnection: ExternalConnectionID
    }

    private struct HistorySnapshot: Equatable {
        struct Item: Equatable {
            let id: UUID
            let contentVersionRaw: UInt64
            let canonicalBlob: Data
            let revisionStateBlob: Data
            let pinOrdinal: Int?

            init(_ row: HistoryItemRow) {
                id = row.id
                contentVersionRaw = row.contentVersionRaw
                canonicalBlob = row.canonicalBlob
                revisionStateBlob = row.revisionStateBlob
                pinOrdinal = row.pinOrdinal
            }
        }

        struct Change: Equatable {
            let sequence: UInt64
            let changePositionRaw: UInt64
            let changeKindRaw: Int16
            let affectedItemsBlob: Data

            init(_ row: HistoryChangeRecordRow) {
                sequence = row.sequence
                changePositionRaw = row.changePositionRaw
                changeKindRaw = row.changeKindRaw
                affectedItemsBlob = row.affectedItemsBlob
            }
        }

        let position: UInt64
        let items: [Item]
        let changes: [Change]
    }

    @Test("wrong durable kind is unauthorized before rate audit or History")
    func wrongKindRateDenialIsUnaudited() async throws {
        let fixture = try await Self.makeFixture()
        let historyBefore = try Self.historySnapshot(in: fixture.container)
        let gatewayBefore = try Self.gatewaySnapshot(in: fixture.container)

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browsePreview,
            connectionID: fixture.appIntentsConnection
        )) {
            try await fixture.authority.commitExternalRateDenial(
                Self.localRecentDescriptor,
                as: fixture.appIntentsConnection,
                expectedConnectionKind: .localAutomation,
                requestedAt: Self.epoch
            )
        }

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browse,
            connectionID: fixture.localAutomationConnection
        )) {
            try await fixture.authority.commitExternalRateDenial(
                Self.appRecentDescriptor,
                as: fixture.localAutomationConnection,
                expectedConnectionKind: .appIntents,
                requestedAt: Self.epoch
            )
        }

        #expect(try Self.historySnapshot(in: fixture.container) == historyBefore)
        #expect(try Self.gatewaySnapshot(in: fixture.container) == gatewayBefore)
    }

    @Test("correct durable kind appends exactly one rate-denial audit")
    func correctKindRateDenialIsAuditedOnce() async throws {
        let fixture = try await Self.makeFixture()
        let historyBefore = try Self.historySnapshot(in: fixture.container)
        let gatewayBefore = try Self.gatewaySnapshot(in: fixture.container)

        try await fixture.authority.commitExternalRateDenial(
            Self.localRecentDescriptor,
            as: fixture.localAutomationConnection,
            expectedConnectionKind: .localAutomation,
            requestedAt: Self.epoch
        )

        #expect(try Self.historySnapshot(in: fixture.container) == historyBefore)
        let gatewayAfter = try Self.gatewaySnapshot(in: fixture.container)
        #expect(gatewayAfter.connections == gatewayBefore.connections)
        #expect(gatewayAfter.grants == gatewayBefore.grants)
        #expect(gatewayAfter.operations.dropLast() == gatewayBefore.operations[...])
        #expect(gatewayAfter.operations.count == gatewayBefore.operations.count + 1)

        let operation = try #require(gatewayAfter.operations.last)
        #expect(operation.connectionIDRaw
            == fixture.localAutomationConnection.rawValue)
        #expect(operation.capabilityRaw
            == ExternalCapability.browsePreview.rawValue)
        #expect(operation.operationKindRaw
            == ExternalOperationKind.readRecent.rawValue)
        #expect(operation.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(operation.failureKindRaw
            == ExternalFailureKindRaw.requestDenied.rawValue)
        #expect(operation.denialReasonRaw
            == ExternalDenialReason.rateLimited.rawValue)
        #expect(operation.changePositionRaw == nil)
        #expect(operation.requestedAt == Self.epoch)

        let configBefore = try #require(gatewayBefore.configs.first)
        let configAfter = try #require(gatewayAfter.configs.first)
        #expect(gatewayBefore.configs.count == 1)
        #expect(gatewayAfter.configs.count == 1)
        #expect(configAfter.key == configBefore.key)
        #expect(configAfter.appIntentsConnectionID
            == configBefore.appIntentsConnectionID)
        #expect(configAfter.compactionFloor == configBefore.compactionFloor)
        #expect(configAfter.configSchemaVersion
            == configBefore.configSchemaVersion)
        #expect(configAfter.nextAuditSequence
            == configBefore.nextAuditSequence + 1)
        let contribution = UInt64(operation.payloadBlob.count) + 128
        #expect(configAfter.auditBytes == configBefore.auditBytes + contribution)
    }

    private static func makeFixture() async throws -> Fixture {
        let history = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .memory)
        )
        let authority = history.authority
        let container = await authority.container
        let appIntentsConnection = try #require(
            try await history.connections().first
        ).id
        let localAutomationConnection = try await authority.enrollConnection(
            kind: .localAutomation,
            displayName: "Rate kind recheck",
            credential: nil
        )
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "rate-kind-history-sentinel",
            observedAt: Self.epoch
        )))
        return Fixture(
            authority: authority,
            container: container,
            appIntentsConnection: appIntentsConnection,
            localAutomationConnection: localAutomationConnection
        )
    }

    private static func historySnapshot(
        in container: ModelContainer
    ) throws -> HistorySnapshot {
        let context = ModelContext(container)
        let position = try #require(
            context.fetch(FetchDescriptor<LastChangePositionRow>()).first
        )
        let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
            .map(HistorySnapshot.Item.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let changes = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>())
            .map(HistorySnapshot.Change.init)
            .sorted { $0.sequence < $1.sequence }
        return HistorySnapshot(
            position: position.rawValue,
            items: items,
            changes: changes
        )
    }

    private static func gatewaySnapshot(
        in container: ModelContainer
    ) throws -> GatewayStoreSnapshot {
        try GatewayStoreSnapshot.read(in: ModelContext(container))
    }
}
