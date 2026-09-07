import Foundation
import HistoryCore

/// The one production server store for the account-wide Local Automation
/// promise. Each connection has a separate credential file, so deleting the
/// client's active file never destroys a revoked connection's verifier.
internal struct FileCredentialOperations: CredentialStoreExternalOperations {
    private let directoryURL: URL

    internal init(directoryURL: URL) { self.directoryURL = directoryURL }

    internal func connectionIDs() throws -> [ExternalConnectionID] {
        do {
            guard try rootCustody.validateDirectoryIfPresent() else { return [] }
            let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            var connections: [ExternalConnectionID] = []
            for name in names {
                guard let uuid = UUID(uuidString: name), uuid.uuidString == name else { continue }
                let connection = ExternalConnectionID(rawValue: uuid)
                let custody = custody(for: connection)
                guard try custody.validateDirectoryIfPresent() else { continue }
                guard !Self.isSymbolicLink(custody.credentialFileURL) else {
                    throw CredentialStoreFailure.unavailable
                }
                guard FileManager.default.fileExists(atPath: custody.credentialFileURL.path) else {
                    continue
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: custody.credentialFileURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw CredentialStoreFailure.unavailable
                }
                connections.append(connection)
            }
            return connections
        } catch {
            throw CredentialStoreFailure.unavailable
        }
    }

    internal func addCredential(_ data: Data, for connection: ExternalConnectionID) -> CredentialStoreAddResult {
        do {
            // The fixed application-support parent may not exist on first
            // launch. Creation never changes an existing parent's permissions.
            try FileManager.default.createDirectory(
                at: directoryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try rootCustody.prepareDirectory()
            try custody(for: connection).installNewCredential(data)
            return .stored
        } catch LocalAutomationClientCredentialCustodyFailure.credentialAlreadyExists {
            return .duplicate
        } catch {
            return .unavailable
        }
    }

    internal func copyCredential(for connection: ExternalConnectionID) -> CredentialStoreCopyResult {
        do {
            guard try rootCustody.validateDirectoryIfPresent() else { return .missing }
            guard let data = try custody(for: connection).loadCredential() else { return .missing }
            // CredentialStore checks the embedded UUID against this exact
            // requested account before returning the immutable 48-byte value.
            return .value(data)
        } catch LocalAutomationClientCredentialCustodyFailure.malformedCredential {
            return .corruptValue
        } catch {
            return .unavailable
        }
    }

    internal func deleteCredential(for connection: ExternalConnectionID) -> CredentialStoreDeleteResult {
        do {
            guard try rootCustody.validateDirectoryIfPresent() else { return .deletedOrMissing }
            let custody = custody(for: connection)
            guard try custody.validateDirectoryIfPresent() else { return .deletedOrMissing }
            guard !Self.isSymbolicLink(custody.credentialFileURL) else { return .unavailable }
            // Never remove a directory or sweep other files. Empty account
            // directories do not appear in connectionIDs().
            return custody.removeCredential() ? .deletedOrMissing : .unavailable
        } catch {
            return .unavailable
        }
    }

    private var rootCustody: LocalAutomationClientCredentialCustody {
        LocalAutomationClientCredentialCustody(directoryURL: directoryURL)
    }

    private func custody(for connection: ExternalConnectionID) -> LocalAutomationClientCredentialCustody {
        LocalAutomationClientCredentialCustody(directoryURL:
            directoryURL.appendingPathComponent(connection.rawValue.uuidString, isDirectory: true)
        )
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
