/// Public X.4 Gateway administration facade conformance proof.
/// Owning spec: `V2-05` §3.3 and roadmap X.4/GW3.
import HistoryCore
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
        let beforeConnections = try await admin.connections()
        let bootstrapped = try #require(beforeConnections.first)
        let beforeGrants = try await admin.grants(for: bootstrapped.id)

        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            _ = try await admin.enrollConnection(
                kind: .localAutomation,
                displayName: "Must use F1 coordinator"
            )
        }

        let afterConnections = try await admin.connections()
        let afterGrants = try await admin.grants(for: bootstrapped.id)
        let audit = try await admin.auditLog(since: 1)
        #expect(afterConnections == beforeConnections)
        #expect(afterGrants == beforeGrants)
        #expect(!audit.contains(where: { $0.operationKind == .adminEnroll }))
    }
}
