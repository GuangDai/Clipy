import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("Gateway refuses damaged grant state before releasing History")
struct GatewayGrantIntegrityTests {
    enum Damage: CaseIterable, Sendable {
        case unknownCapability
        case wrongConnectionKind
        case grantedBeforeEnrollment
        case revokedBeforeGrant

        var expectedFailure: ExternalFailure {
            switch self {
            case .unknownCapability: .persistence(.corruptStoredValue)
            case .wrongConnectionKind, .grantedBeforeEnrollment, .revokedBeforeGrant:
                .persistence(.invariantViolation)
            }
        }
    }

    private struct Fixture {
        let history: SQLiteHistory
        let facade: ExternalHistoryFacade
        let connection: ConnectionDTO
        let item: HistoryItemReference
    }

    private static func fixture() async throws -> Fixture {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let connection = try #require(try await history.connections().first)
        for capability in [ExternalCapability.browse, .readContent, .manage] {
            try await history.grantCapability(capability, to: connection.id)
        }
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            "private-content-with-damaged-unused-grant",
            observedAt: Date(timeIntervalSinceReferenceDate: 990_000_000)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return Fixture(
            history: history, facade: history.makeAppIntentsHistoryFacade(),
            connection: connection, item: item
        )
    }

    private static func damageUnusedReadGrant(_ damage: Damage, in fixture: Fixture) async throws {
        let connection = fixture.connection
        try await fixture.history.authority.withTestDatabase { authority in
            let database = authority.database
            let key = GatewayAdministration.canonicalGrantKey(
                connectionID: connection.id.rawValue, capability: .readContent
            )
            try database.writeTransaction {
                switch damage {
                case .unknownCapability:
                    try database.execute(
                        "UPDATE grants SET capabilityRaw = 0 WHERE grantKey = ?", bindings: [.text(key)]
                    )
                case .wrongConnectionKind:
                    try database.execute(
                        "UPDATE grants SET capabilityRaw = ?, grantKey = ? WHERE grantKey = ?",
                        bindings: [
                            .integer(Int64(ExternalCapability.organize.rawValue)),
                            .text(GatewayAdministration.canonicalGrantKey(
                                connectionID: connection.id.rawValue, capability: .organize
                            )),
                            .text(key)
                        ]
                    )
                case .grantedBeforeEnrollment:
                    try database.execute(
                        "UPDATE grants SET grantedAt = ? WHERE grantKey = ?",
                        bindings: [
                            .real(connection.enrolledAt.addingTimeInterval(-1).timeIntervalSinceReferenceDate),
                            .text(key)
                        ]
                    )
                case .revokedBeforeGrant:
                    try database.execute(
                        "UPDATE grants SET revokedAt = grantedAt - 1 WHERE grantKey = ?", bindings: [.text(key)]
                    )
                }
            }
        }
    }

    @Test(arguments: Damage.allCases)
    func matchingBrowseGrantCannotHideDamageInAnotherGrant(_ damage: Damage) async throws {
        let fixture = try await Self.fixture()
        guard case .page(let initial) = try await fixture.facade.read(.recent(limit: 1)) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(initial.rows.first?.row.item.id == fixture.item.id)
        try await Self.damageUnusedReadGrant(damage, in: fixture)
        await #expect(throws: damage.expectedFailure) {
            _ = try await fixture.facade.read(.recent(limit: 1))
        }
    }

    @Test
    func matchingManageGrantCannotHideDamageOrCommitPinning() async throws {
        let fixture = try await Self.fixture()
        let before = try await fixture.history.browse(.init(kind: .recent, limit: 1))
        try await Self.damageUnusedReadGrant(.unknownCapability, in: fixture)
        await #expect(throws: ExternalFailure.persistence(.corruptStoredValue)) {
            _ = try await fixture.facade.perform(.pin(fixture.item.id))
        }
        let after = try await fixture.history.browse(.init(kind: .recent, limit: 1))
        #expect(after == before)
    }

    @Test
    func validlyRevokedReadGrantDoesNotDisableBrowse() async throws {
        let fixture = try await Self.fixture()
        try await fixture.history.revokeCapability(.readContent, of: fixture.connection.id)
        guard case .page(let page) = try await fixture.facade.read(.recent(limit: 1)) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(page.rows.first?.row.item.id == fixture.item.id)
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .readContent, connectionID: fixture.connection.id
        )) {
            _ = try await fixture.facade.read(.pastePayload(fixture.item.id))
        }
    }
}
