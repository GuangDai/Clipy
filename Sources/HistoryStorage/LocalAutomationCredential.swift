/// F1 Local Automation credential value (`V2-05` §0.3/§3.4).
///
/// The value is not a digest or derived identity. Its first 16 bytes are the
/// preassigned connection UUID and its remaining 32 bytes are the opaque
/// bearer secret. Secret bytes never enter SwiftData or audit payloads.
import Foundation
import HistoryCore
import Security

internal enum CredentialStoreFailure: Error, Sendable, Equatable {
    case malformedCredential
    case duplicateCredential
    case corruptStoredValue
    case unavailable
}

internal struct LocalAutomationCredential: Sendable, Equatable {
    internal static let connectionByteCount = 16
    internal static let secretByteCount = 32
    internal static let byteCount = connectionByteCount + secretByteCount

    internal let connection: ExternalConnectionID
    internal let exactBytes: Data

    internal init(
        connection: ExternalConnectionID,
        secret: Data
    ) throws {
        guard secret.count == Self.secretByteCount else {
            throw CredentialStoreFailure.malformedCredential
        }

        var bytes = Self.connectionBytes(connection)
        bytes.append(secret)
        self.connection = connection
        exactBytes = bytes
    }

    internal init(exactBytes: Data) throws {
        guard exactBytes.count == Self.byteCount else {
            throw CredentialStoreFailure.malformedCredential
        }
        let bytes = [UInt8](exactBytes.prefix(Self.connectionByteCount))
        connection = ExternalConnectionID(rawValue: UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )))
        self.exactBytes = exactBytes
    }

    internal init(
        exactBytes: Data,
        for connection: ExternalConnectionID
    ) throws {
        let expectedPrefix = Self.connectionBytes(connection)
        guard exactBytes.count == Self.byteCount,
              exactBytes.starts(with: expectedPrefix) else {
            throw CredentialStoreFailure.malformedCredential
        }
        self.connection = connection
        self.exactBytes = exactBytes
    }

    /// The only production secret-minting path. The connection identifier is
    /// preassigned by the future enrollment coordinator; randomness supplies
    /// only the exact 32-byte secret suffix (`V2-05` §0.3).
    internal static func generate(
        for connection: ExternalConnectionID
    ) throws -> Self {
        var secret = Data(count: secretByteCount)
        let status = secret.withUnsafeMutableBytes {
            (buffer: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(
                kSecRandomDefault,
                secretByteCount,
                baseAddress
            )
        }
        guard status == errSecSuccess else {
            throw CredentialStoreFailure.unavailable
        }
        return try Self(connection: connection, secret: secret)
    }

    private static func connectionBytes(
        _ connection: ExternalConnectionID
    ) -> Data {
        let bytes = connection.rawValue.uuid
        return Data([
            bytes.0, bytes.1, bytes.2, bytes.3,
            bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11,
            bytes.12, bytes.13, bytes.14, bytes.15,
        ])
    }
}
