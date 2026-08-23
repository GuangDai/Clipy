/// F1 server credential custody (`V2-05` §0.3/§3.4/§6.7).
///
/// `CredentialStore` serializes the blocking Security calls and exposes only
/// exact immutable bytes plus content-free failures. The injected operations
/// protocol is the true external-system seam; it is not a second credential
/// store or a product-facing interface.
import Foundation
import HistoryCore
import Security

internal enum CredentialStoreAddResult: Sendable {
    case stored
    case duplicate
    case unavailable
}

internal enum CredentialStoreCopyResult: Sendable {
    case value(Data)
    case missing
    case unavailable
}

internal enum CredentialStoreDeleteResult: Sendable {
    case deletedOrMissing
    case unavailable
}

internal protocol CredentialStoreExternalOperations: Sendable {
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
/// The production operations use the app-private Data Protection Keychain.
/// The client-side owner-only file and enrollment/revocation coordination are
/// separate future F1 leaves and are intentionally absent here.
internal actor CredentialStore {
    private var operations: any CredentialStoreExternalOperations

    internal init() {
        operations = DataProtectionKeychainCredentialOperations()
    }

    internal init(operations: any CredentialStoreExternalOperations) {
        self.operations = operations
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

/// Stateless Security adapter. Every query explicitly selects the Data
/// Protection Keychain; omitting an access group keeps the item app-private.
private struct DataProtectionKeychainCredentialOperations:
    CredentialStoreExternalOperations
{
    private static let service =
        "com.clipy.Clipy.local-automation.server-credential"

    func addCredential(
        _ data: Data,
        for connection: ExternalConnectionID
    ) -> CredentialStoreAddResult {
        var query = lookupQuery(for: connection)
        query[kSecAttrAccessible] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData] = data

        switch SecItemAdd(query as CFDictionary, nil) {
        case errSecSuccess:
            return .stored
        case errSecDuplicateItem:
            return .duplicate
        default:
            return .unavailable
        }
    }

    func copyCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreCopyResult {
        var query = lookupQuery(for: connection)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else {
                return .unavailable
            }
            return .value(data)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable
        }
    }

    func deleteCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreDeleteResult {
        switch SecItemDelete(lookupQuery(for: connection) as CFDictionary) {
        case errSecSuccess, errSecItemNotFound:
            return .deletedOrMissing
        default:
            return .unavailable
        }
    }

    private func lookupQuery(
        for connection: ExternalConnectionID
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: connection.rawValue.uuidString,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}
