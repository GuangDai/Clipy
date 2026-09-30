import Foundation
import HistoryCore
import Synchronization
import Testing
@testable import HistoryStorage

struct GatewayLifecycleClockTests {
    private final class AdjustableClock: StorageClock, Sendable {
        private let instant: Mutex<Date>

        init(_ instant: Date) { self.instant = Mutex(instant) }

        func now() -> Date { instant.withLock { $0 } }

        func set(_ value: Date) { instant.withLock { $0 = value } }
    }

    @Test("wall-clock rollback keeps grant lifecycle coherent without changing audit clock samples")
    func rollbackDoesNotPersistInvalidGrantTimes() async throws {
        let epoch = Date(timeIntervalSinceReferenceDate: 900_300_000)
        let clock = AdjustableClock(epoch)
        let authority = try HistoryAuthority(
            storeLocation: try HistoryStoreLocation(persistence: .temporary), storageClock: clock
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        let id = ExternalConnectionID(rawValue: UUID())
        try await authority.publishVerifiedLocalAutomationEnrollment(id, displayName: "Clock rollback")

        clock.set(epoch.addingTimeInterval(-30))
        try await authority.grantCapability(.organize, to: id)
        var grants = try await authority.grants(for: id)
        #expect(try #require(grants.first).grantedAt == epoch)

        let contentGrantedAt = epoch.addingTimeInterval(10)
        clock.set(contentGrantedAt)
        try await authority.grantCapability(.readEffectiveContent, to: id)
        clock.set(epoch.addingTimeInterval(-30))
        try await authority.revokeCapability(.readEffectiveContent, of: id)
        grants = try await authority.grants(for: id)
        let content = try #require(grants.first { $0.capability == .readEffectiveContent })
        #expect(content.revokedAt == contentGrantedAt)

        let organizeRevokedAt = epoch.addingTimeInterval(20)
        clock.set(organizeRevokedAt)
        try await authority.revokeCapability(.organize, of: id)
        let correctedClock = epoch.addingTimeInterval(-60)
        clock.set(correctedClock)
        try await authority.grantCapability(.organize, to: id)
        grants = try await authority.grants(for: id)
        let organize = try #require(grants.first { $0.capability == .organize })
        #expect(organize.grantedAt == organizeRevokedAt)
        #expect(organize.revokedAt == nil)

        try await authority.revokeConnection(id)
        let persisted = try await GatewayStoreSnapshot.read(from: authority)
        let audit = try #require(persisted.operations.last)
        #expect(audit.operationKindRaw == ExternalOperationKind.adminRevoke.rawValue)
        #expect(audit.requestedAt == correctedClock)
        #expect(audit.committedAt == correctedClock)
        let connection = try #require(try await authority.connections().first { $0.id == id })
        #expect(connection.status == .revoked)
        #expect(connection.revokedAt == organizeRevokedAt)
        grants = try await authority.grants(for: id)
        #expect(grants.allSatisfy { grant in
            grant.revokedAt.map { $0 >= grant.grantedAt } ?? false
        })
        #expect(grants.first { $0.capability == .organize }?.revokedAt == organizeRevokedAt)
        #expect(try await authority.currentPosition().rawValue == 0)
    }
}
