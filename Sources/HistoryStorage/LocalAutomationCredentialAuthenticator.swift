/// In-process F1 credential authentication kernel (`V2-05` §3.2).
///
/// This is not an ingress facade or transport. It converts one exact bearer
/// presentation into either a durable Local Automation connection ID or a
/// content-free rejection. Only a later caller may pass an authenticated ID
/// into the unique ExternalGateway, which remains the owner of audited
/// revoked/not-granted outcomes.
import Foundation
import HistoryCore
import SwiftData

internal enum LocalAutomationCredentialComparison {
    /// Traverses every byte of the fixed 48-byte shape. Length rejection is
    /// public credential grammar; no secret-dependent early exit occurs.
    internal static func matches(_ presented: Data, _ stored: Data) -> Bool {
        guard presented.count == LocalAutomationCredential.byteCount,
              stored.count == LocalAutomationCredential.byteCount else {
            return false
        }
        let presentedBytes = [UInt8](presented)
        let storedBytes = [UInt8](stored)
        var difference: UInt8 = 0
        for index in 0..<LocalAutomationCredential.byteCount {
            difference |= presentedBytes[index] ^ storedBytes[index]
        }
        return difference == 0
    }
}

internal enum LocalAutomationDurableCredentialState: Sendable, Equatable {
    case active
    case revoked
}

extension HistoryAuthority {
    /// Unaudited trust preflight. Missing/wrong-kind rows are indistinguishable
    /// to the credential caller; active and revoked exact identities both
    /// continue so the later Gateway can own its stable audited result.
    internal func localAutomationCredentialState(
        for connection: ExternalConnectionID
    ) throws -> LocalAutomationDurableCredentialState? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)
        guard let current = try Self.loadExternalConnection(
            connection,
            config: config,
            in: context
        ), current.kind == .localAutomation else {
            return nil
        }
        switch current.status {
        case .active: return .active
        case .revoked: return .revoked
        }
    }
}

internal actor LocalAutomationCredentialAuthenticator {
    private let credentialStore: CredentialStore
    private let authority: HistoryAuthority

    internal init(
        credentialStore: CredentialStore,
        authority: HistoryAuthority
    ) {
        self.credentialStore = credentialStore
        self.authority = authority
    }

    /// Malformed, missing, wrong-secret, and custody-orphan presentations all
    /// return nil before Gateway admission and therefore append no audit.
    /// Credential-store unavailability/corruption remains a typed internal
    /// failure rather than being mislabeled as caller authentication failure.
    internal func authenticate(
        _ presentedBytes: Data
    ) async throws -> ExternalConnectionID? {
        guard let presented = try? LocalAutomationCredential(
            exactBytes: presentedBytes
        ), let stored = try await credentialStore.loadCredential(
            for: presented.connection
        ), LocalAutomationCredentialComparison.matches(
            presented.exactBytes,
            stored
        ), try await authority.localAutomationCredentialState(
            for: presented.connection
        ) != nil else {
            return nil
        }
        return presented.connection
    }
}
