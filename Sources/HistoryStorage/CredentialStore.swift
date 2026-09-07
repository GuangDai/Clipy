/// F1 server credential custody (`V2-05` §0.3/§3.4/§6.7).
///
/// `CredentialStore` serializes the credential-file operations and exposes only
/// exact immutable bytes plus content-free failures. The injected operations
/// protocol is the true external-system seam; it is not a second credential
/// store or a product-facing interface.
import Foundation
import HistoryCore

internal enum CredentialStoreAddResult: Sendable {
    case stored
    case duplicate
    case unavailable
}

internal enum CredentialStoreCopyResult: Sendable {
    case value(Data)
    case missing
    case corruptValue
    case unavailable
}

internal enum CredentialStoreDeleteResult: Sendable {
    case deletedOrMissing
    case unavailable
}

internal protocol CredentialStoreExternalOperations: Sendable {
    mutating func connectionIDs() throws -> [ExternalConnectionID]

    mutating func addCredential(
        _ data: Data,
        for connection: ExternalConnectionID
    ) -> CredentialStoreAddResult

    mutating func copyCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreCopyResult

    mutating func deleteCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreDeleteResult
}

/// Actor-confined server copy of Local Automation credentials.
///
/// Production uses a separate current-user-only server directory; client-file
/// removal cannot destroy the verifier of a revoked connection.
/// LocalAutomationIngress's enrollment extension coordinates this server
/// copy with client-file custody and the Authority's connection transaction.
internal actor CredentialStore {
    private var operations: any CredentialStoreExternalOperations

    internal static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipy", isDirectory: true)
            .appendingPathComponent("LocalAutomationServer", isDirectory: true)
    }

    internal init() {
        operations = FileCredentialOperations(directoryURL: Self.defaultDirectoryURL)
    }

    internal init(directoryURL: URL) {
        operations = FileCredentialOperations(directoryURL: directoryURL)
    }

    internal init(operations: any CredentialStoreExternalOperations) {
        self.operations = operations
    }

    /// Account names only, for removing interrupted enrollment's server copy
    /// when its client file has already disappeared (V2-05 §0.3).
    internal func connectionIDs() throws -> [ExternalConnectionID] {
        try operations.connectionIDs()
    }

    internal func storeCredential(
        _ data: Data,
        for connection: ExternalConnectionID
    ) async throws {
        _ = try LocalAutomationCredential(
            exactBytes: data,
            for: connection
        )

        switch operations.addCredential(data, for: connection) {
        case .stored:
            return
        case .duplicate:
            throw CredentialStoreFailure.duplicateCredential
        case .unavailable:
            throw CredentialStoreFailure.unavailable
        }
    }

    internal func loadCredential(
        for connection: ExternalConnectionID
    ) async throws -> Data? {
        switch operations.copyCredential(for: connection) {
        case .value(let data):
            do {
                return try LocalAutomationCredential(
                    exactBytes: data,
                    for: connection
                ).exactBytes
            } catch {
                throw CredentialStoreFailure.corruptStoredValue
            }
        case .missing:
            return nil
        case .corruptValue:
            throw CredentialStoreFailure.corruptStoredValue
        case .unavailable:
            throw CredentialStoreFailure.unavailable
        }
    }

    internal func deleteCredential(
        for connection: ExternalConnectionID
    ) async throws {
        switch operations.deleteCredential(for: connection) {
        case .deletedOrMissing:
            return
        case .unavailable:
            throw CredentialStoreFailure.unavailable
        }
    }
}
