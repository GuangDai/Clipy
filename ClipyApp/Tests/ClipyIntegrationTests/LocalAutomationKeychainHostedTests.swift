import Foundation
import HistoryCore
import Security
import Testing
@testable import HistoryStorage

struct LocalAutomationKeychainHostedTests {
    /// Runs the actual default Security adapter in the ordinary app host. No
    /// entitlement/signature changes or injected operations are involved.
    /// Unsupported access is a failure, not a skipped or simulated success.
    @Test func productionCredentialStorePersistsAndDeletesInTheAppHost() async throws {
        // The app host is outside the Swift package and cannot mint package-
        // scoped connection IDs. An isolated in-memory store's public admin
        // read supplies its freshly generated bootstrap UUID without exposing
        // a constructor or depending on successful credential enrollment.
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let connection = try #require(try await history.connections().first).id
        let credential = try LocalAutomationCredential(
            connection: connection, secret: Data((0..<32).map { UInt8($0) })
        )
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.clipy.Clipy.local-automation.server-credential",
            kSecAttrAccount: connection.rawValue.uuidString,
            kSecUseDataProtectionKeychain: true,
        ]
        // Both the normal deletion and this failure cleanup name this one
        // synthetic UUID account. No service-wide delete or orphan sweep.
        defer { _ = SecItemDelete(query as CFDictionary) }
        let store = CredentialStore()
        do {
            try await store.storeCredential(credential.exactBytes, for: connection)
        } catch {
            var add = query
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecValueData] = credential.exactBytes
            // The product deliberately exposes a content-free typed failure,
            // not an OSStatus. Repeat only this failed operation to diagnose
            // the runner; even a successful repeat cannot pass the test.
            let status = SecItemAdd(add as CFDictionary, nil)
            Issue.record("Production CredentialStore add failed; diagnostic repeat SecItemAdd OSStatus: \(status).")
            return
        }

        // A second default actor must read the Keychain value; retaining bytes
        // in the first actor cannot satisfy this assertion.
        let reopened = CredentialStore()
        do {
            let loaded = try await reopened.loadCredential(for: connection)
            let matches = loaded == credential.exactBytes
            try #require(matches, "Production Keychain did not return the exact synthetic credential.")
        } catch {
            let status = copyStatus(for: query)
            Issue.record("Production CredentialStore read failed; diagnostic repeat SecItemCopyMatching OSStatus: \(status).")
            return
        }

        do {
            try await reopened.deleteCredential(for: connection)
        } catch {
            let status = SecItemDelete(query as CFDictionary)
            Issue.record("Production CredentialStore delete failed; diagnostic repeat SecItemDelete OSStatus: \(status).")
            return
        }
        do {
            let remains = try await store.loadCredential(for: connection) != nil
            #expect(!remains, "Production Keychain still contains the synthetic credential after deletion.")
        } catch {
            let status = copyStatus(for: query)
            Issue.record("Production CredentialStore post-delete read failed; diagnostic repeat SecItemCopyMatching OSStatus: \(status).")
        }
    }

    private func copyStatus(for query: [CFString: Any]) -> OSStatus {
        var lookup = query
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        lookup[kSecReturnData] = true
        var result: CFTypeRef?
        return SecItemCopyMatching(lookup as CFDictionary, &result)
    }
}
