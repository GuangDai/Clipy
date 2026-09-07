import Foundation
import HistoryCore

/// The in-app enable/grant controls receive only durable connection facts.
/// Neither credential copy crosses into observable Settings state (V2-05 §0.3).
public struct LocalAutomationEnrollmentState: Sendable, Equatable {
    public let connection: ExternalConnectionID?
    public let grants: Set<ExternalCapability>
}

public enum LocalAutomationEnrollmentFailure: Error, Sendable {
    case busy
    case credentialUnavailable
    case cleanupFailed
}

extension LocalAutomationIngress {
    /// Reconciles interrupted enrollment before reporting configured access.
    /// Revoked server copies are retained for truthful connection_revoked replies.
    public func state(clientDirectory: URL) async throws -> LocalAutomationEnrollmentState {
        guard !isChangingEnrollment else { throw LocalAutomationEnrollmentFailure.busy }
        isChangingEnrollment = true
        defer { isChangingEnrollment = false }
        return try await enrollmentState(clientDirectory: clientDirectory)
    }

    /// Client custody, then server custody, then the sole Authority transaction.
    /// A newly published connection always has zero grants (V2-05 §0.3).
    public func enable(clientDirectory: URL) async throws -> LocalAutomationEnrollmentState {
        guard !isChangingEnrollment else { throw LocalAutomationEnrollmentFailure.busy }
        isChangingEnrollment = true
        defer { isChangingEnrollment = false }
        let current = try await enrollmentState(clientDirectory: clientDirectory)
        if current.connection != nil { return current }
        // A disabled Settings read need not access server credential files. Explicit
        // Enable cleans every server orphan, even if its client file vanished.
        let retained = Set(try await authority.connections().filter {
            $0.enrollKind == .localAutomation
        }.map(\.id))
        for connection in try await credentialStore.connectionIDs() where !retained.contains(connection) {
            try await credentialStore.deleteCredential(for: connection)
        }
        let custody = LocalAutomationClientCredentialCustody(directoryURL: clientDirectory)
        let connection = ExternalConnectionID(rawValue: UUID())
        let credential = try LocalAutomationCredential.generate(for: connection)
        do {
            try custody.installCredential(credential.exactBytes)
            try await credentialStore.storeCredential(credential.exactBytes, for: connection)
            guard try await credentialStore.loadCredential(for: connection) == credential.exactBytes else {
                throw LocalAutomationEnrollmentFailure.credentialUnavailable
            }
            try Task.checkCancellation()
            try await authority.publishVerifiedLocalAutomationEnrollment(
                connection, displayName: "Local Automation"
            )
        } catch {
            // The publication transaction either committed or threw without a
            // connection. Removing either powerless copy never infers a row.
            do { try await credentialStore.deleteCredential(for: connection) }
            catch { throw LocalAutomationEnrollmentFailure.cleanupFailed }
            guard custody.removeCredential() else {
                throw LocalAutomationEnrollmentFailure.cleanupFailed
            }
            throw error
        }
        return LocalAutomationEnrollmentState(connection: connection, grants: [])
    }

    /// Revoke durable access before best-effort client-file removal. This also
    /// works if a lost/malformed client file prevented Settings from loading.
    public func revoke(clientDirectory: URL) async throws -> LocalAutomationEnrollmentState {
        guard !isChangingEnrollment else { throw LocalAutomationEnrollmentFailure.busy }
        isChangingEnrollment = true
        defer { isChangingEnrollment = false }
        let connections = try await authority.connections()
        for connection in connections where connection.enrollKind == .localAutomation
            && connection.status == .active {
            try await authority.revokeConnection(connection.id)
        }
        LocalAutomationClientCredentialCustody(directoryURL: clientDirectory).removeCredential()
        return LocalAutomationEnrollmentState(connection: nil, grants: [])
    }

    public func setCapability(
        _ capability: ExternalCapability,
        enabled: Bool,
        clientDirectory: URL
    ) async throws -> LocalAutomationEnrollmentState {
        guard !isChangingEnrollment else { throw LocalAutomationEnrollmentFailure.busy }
        isChangingEnrollment = true
        defer { isChangingEnrollment = false }
        let current = try await enrollmentState(clientDirectory: clientDirectory)
        guard let connection = current.connection else {
            throw LocalAutomationEnrollmentFailure.credentialUnavailable
        }
        // The existing Authority owns the connection-kind capability matrix.
        if enabled {
            try await authority.grantCapability(capability, to: connection)
        } else {
            try await authority.revokeCapability(capability, of: connection)
        }
        let grants = try await authority.grants(for: connection)
        return LocalAutomationEnrollmentState(
            connection: connection,
            grants: Set(grants.filter { $0.revokedAt == nil }.map(\.capability))
        )
    }

    private func enrollmentState(clientDirectory: URL) async throws -> LocalAutomationEnrollmentState {
        let connections = try await authority.connections().filter { $0.enrollKind == .localAutomation }
        let custody = LocalAutomationClientCredentialCustody(directoryURL: clientDirectory)
        guard let bytes = try custody.loadCredential() else {
            if connections.contains(where: { $0.status == .active }) {
                throw LocalAutomationEnrollmentFailure.credentialUnavailable
            }
            return LocalAutomationEnrollmentState(connection: nil, grants: [])
        }
        let credential = try LocalAutomationCredential(exactBytes: bytes)
        guard let connection = connections.first(where: { $0.id == credential.connection }),
              connection.status == .active else {
            if !connections.contains(where: { $0.id == credential.connection }) {
                try await credentialStore.deleteCredential(for: credential.connection)
            }
            guard custody.removeCredential() else { throw LocalAutomationEnrollmentFailure.cleanupFailed }
            return LocalAutomationEnrollmentState(connection: nil, grants: [])
        }
        guard try await credentialStore.loadCredential(for: connection.id) == bytes else {
            throw LocalAutomationEnrollmentFailure.credentialUnavailable
        }
        let grants = try await authority.grants(for: connection.id)
        return LocalAutomationEnrollmentState(
            connection: connection.id,
            grants: Set(grants.filter { $0.revokedAt == nil }.map(\.capability))
        )
    }
}
