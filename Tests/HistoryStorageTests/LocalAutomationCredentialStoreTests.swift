/// F1 server-custody tracer (`V2-05` §0.3/§3.4/§6.7).
///
/// Literal grammar and injected external-failure checks complement
/// FileCredentialStoreTests, which exercises production file custody in real
/// temporary directories, including cross-instance reads and enrollment.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("Local Automation server credential custody (F1)")
struct LocalAutomationCredentialStoreTests {
    private static let connection = ExternalConnectionID(rawValue: UUID(
        uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
    )!)

    private static let connectionPrefix = Data([
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    ])

    private static let secret = Data([
        0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF,
        0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7,
        0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF,
    ])

    private static let exactCredential = Data([
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF,
        0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7,
        0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF,
    ])

    @Test("literal secret forms exact UUID16 plus secret32 bytes")
    func literalShapeAndPrefixAreExact() throws {
        let credential = try LocalAutomationCredential(
            connection: Self.connection,
            secret: Self.secret
        )

        #expect(credential.exactBytes == Self.exactCredential)
        #expect(credential.exactBytes.count == 48)
        #expect(
            Data(credential.exactBytes.prefix(16)) == Self.connectionPrefix
        )
    }

    @Test("system generation preserves the preassigned UUID prefix")
    func generatedCredentialHasExactShape() throws {
        let credential = try LocalAutomationCredential.generate(
            for: Self.connection
        )

        #expect(credential.exactBytes.count == 48)
        #expect(
            Data(credential.exactBytes.prefix(16)) == Self.connectionPrefix
        )
    }

    @Test("malformed or mismatched bytes never reach storage")
    func malformedCredentialIsRejected() async throws {
        let store = CredentialStore(
            operations: MemoryCredentialStoreOperations()
        )
        let short = Data(Self.exactCredential.dropLast())
        var wrongPrefix = Self.exactCredential
        wrongPrefix[0] = 0xFF

        await #expect(throws: CredentialStoreFailure.malformedCredential) {
            try await store.storeCredential(short, for: Self.connection)
        }
        await #expect(throws: CredentialStoreFailure.malformedCredential) {
            try await store.storeCredential(
                wrongPrefix,
                for: Self.connection
            )
        }
        #expect(try await store.loadCredential(for: Self.connection) == nil)
    }

    @Test("corrupt stored bytes fail closed")
    func corruptStoredValueIsRejected() async {
        var wrongPrefix = Self.exactCredential
        wrongPrefix[0] = 0xFF
        let corruptValues = [
            Data(Self.exactCredential.dropLast()),
            wrongPrefix,
        ]

        for corrupt in corruptValues {
            let store = CredentialStore(
                operations: MemoryCredentialStoreOperations(
                    values: [Self.connection: corrupt]
                )
            )
            await #expect(throws: CredentialStoreFailure.corruptStoredValue) {
                try await store.loadCredential(for: Self.connection)
            }
        }
    }

    @Test("external operation failures expose no status, identity, or bytes")
    func unavailableFailureIsContentFree() async {
        let store = CredentialStore(
            operations: MemoryCredentialStoreOperations(isUnavailable: true)
        )

        await #expect(throws: CredentialStoreFailure.unavailable) {
            try await store.storeCredential(
                Self.exactCredential,
                for: Self.connection
            )
        }
        await #expect(throws: CredentialStoreFailure.unavailable) {
            try await store.loadCredential(for: Self.connection)
        }
        await #expect(throws: CredentialStoreFailure.unavailable) {
            try await store.deleteCredential(for: Self.connection)
        }
    }
}

private struct MemoryCredentialStoreOperations:
    CredentialStoreExternalOperations
{
    private var values: [ExternalConnectionID: Data]
    private let isUnavailable: Bool

    init(
        values: [ExternalConnectionID: Data] = [:],
        isUnavailable: Bool = false
    ) {
        self.values = values
        self.isUnavailable = isUnavailable
    }

    func connectionIDs() throws -> [ExternalConnectionID] {
        guard !isUnavailable else { throw CredentialStoreFailure.unavailable }
        return Array(values.keys)
    }

    mutating func addCredential(
        _ data: Data,
        for connection: ExternalConnectionID
    ) -> CredentialStoreAddResult {
        guard !isUnavailable else { return .unavailable }
        guard values[connection] == nil else { return .duplicate }
        values[connection] = data
        return .stored
    }

    mutating func copyCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreCopyResult {
        guard !isUnavailable else { return .unavailable }
        guard let value = values[connection] else { return .missing }
        return .value(value)
    }

    mutating func deleteCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreDeleteResult {
        guard !isUnavailable else { return .unavailable }
        values.removeValue(forKey: connection)
        return .deletedOrMissing
    }
}
