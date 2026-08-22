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

        let enrolled = try await admin.enrollConnection(
            kind: .localAutomation,
            displayName: "Public facade"
        )
        try await admin.grantCapability(.organize, to: enrolled)
        let enrolledGrants = try await admin.grants(for: enrolled)
        #expect(enrolledGrants.map(\.capability) == [.organize])
        try await admin.revokeCapability(.organize, of: enrolled)
        try await admin.revokeConnection(enrolled)

        let audit = try await admin.auditLog(since: 1)
        #expect(!audit.isEmpty)
        await #expect(throws: ExternalFailure.requestDenied(.invalidInput)) {
            try await admin.rebaseAuditLog(reason: .corruptionDetected)
        }
        try await admin.rebaseAuditLog(reason: .adminForced)
    }
}
