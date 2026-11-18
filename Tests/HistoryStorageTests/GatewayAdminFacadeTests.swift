/// The public administration facade cannot enroll a Local Automation client
/// without the credential-aware enrollment path.
import HistoryCore
import Testing
import HistoryStorage

struct GatewayAdminFacadeTests {
    @Test("generic facade rejects Local Automation before durable state")
    func genericFacadeCannotPublishLocalAutomationEnrollment() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let admin: any GatewayAdminHistory = history
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
