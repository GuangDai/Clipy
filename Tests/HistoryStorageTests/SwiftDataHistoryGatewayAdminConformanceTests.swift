/// Public X.4 Gateway administration facade conformance proof.
/// Owning spec: `V2-05` §3.3 and roadmap X.4/GW3.
import HistoryCore
import SwiftData
import Testing
import HistoryStorage

@Suite("SwiftDataHistory Gateway administration conformance (X.4)")
struct SwiftDataHistoryGatewayAdminConformanceTests {
    private func requireGatewayAdminHistory<T: GatewayAdminHistory>(
        _ value: T
    ) -> T {
        value
    }

    @Test("the public in-memory facade exposes explicit forwarding witnesses")
    func publicFacadeConformsAndForwards() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let admin = requireGatewayAdminHistory(history)

        let initial = try await admin.connections()
        let appIntents = try #require(initial.first)
        #expect(initial.count == 1)
        let initialGrants = try await admin.grants(for: appIntents.id)
        #expect(initialGrants.isEmpty)

        try await admin.grantCapability(.manage, to: appIntents.id)
        let enrolledGrants = try await admin.grants(for: appIntents.id)
        #expect(enrolledGrants.map(\.capability) == [.manage])
        try await admin.revokeCapability(.manage, of: appIntents.id)
        try await admin.revokeConnection(appIntents.id)

        let audit = try await admin.auditLog(since: 1)
        #expect(!audit.isEmpty)
        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            try await admin.rebaseAuditLog(reason: .corruptionDetected)
        }
        try await admin.rebaseAuditLog(reason: .adminForced)
    }

    @Test("generic facade rejects Local Automation before durable state")
    func genericFacadeCannotPublishLocalAutomationEnrollment() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let admin = requireGatewayAdminHistory(history)
        let container = await history.authority.container
        let before = try GatewayStoreSnapshot.read(in: ModelContext(container))

        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            _ = try await admin.enrollConnection(
                kind: .localAutomation,
                displayName: "Must use F1 coordinator"
            )
        }

        let after = try GatewayStoreSnapshot.read(in: ModelContext(container))
        #expect(after == before)
    }
}
