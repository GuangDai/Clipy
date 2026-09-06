import ClipyCLIContract
import Darwin
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage
@testable import LocalAutomation

@Suite("Local Automation real socket and History")
struct LocalAutomationSocketTests {
    @Test func grantsProtectContentAndRevocationIsVisibleAcrossRealConnections() async throws {
        try await withFixture { fixture in
            let request = try Self.json(arguments: ["query": "wire-secret", "mode": "exact", "limit": 1])
            let denied = try await fixture.send(request)
            #expect(denied.exitCode == 3)
            #expect(String(decoding: denied.stderr, as: UTF8.self) == "clipyctl: not_granted\n")
            #expect(!String(decoding: denied.stdout, as: UTF8.self).contains("wire-secret"))
            let wrong = try await fixture.send(request, credential: Data(repeating: 0, count: 48))
            #expect(wrong.exitCode == 3)
            #expect(String(decoding: wrong.stderr, as: UTF8.self) == "clipyctl: authentication_failed\n")

            try await fixture.history.grantCapability(.browsePreview, to: fixture.connection)
            let allowed = try await fixture.send(request)
            #expect(allowed.exitCode == 0)
            #expect(allowed.stderr.isEmpty)
            #expect(String(decoding: allowed.stdout, as: UTF8.self).contains("wire-secret"))
            try await fixture.history.revokeConnection(fixture.connection)
            let revoked = try await fixture.send(request)
            #expect(revoked.exitCode == 3)
            #expect(String(decoding: revoked.stderr, as: UTF8.self) == "clipyctl: connection_revoked\n")
        }
    }

    @Test func browsePaginationAndSevenOperationsUseTheSameLiveHistory() async throws {
        try await withFixture { fixture in
            for capability in [ExternalCapability.browsePreview, .readEffectiveContent, .organize, .deleteItem] {
                try await fixture.history.grantCapability(capability, to: fixture.connection)
            }
            let first = try Self.result(await fixture.send(Self.json(arguments: ["limit": 1])))
            let items = try #require(first["items"] as? [[String: Any]])
            let locator = try #require(items.first?["locator"] as? String)
            let cursor = try #require(first["nextCursor"] as? String)
            let second = try Self.result(await fixture.send(Self.json(arguments: ["limit": 1, "cursor": cursor])))
            let nextItems = try #require(second["items"] as? [[String: Any]])
            #expect(nextItems.first?["locator"] as? String != locator)
            let mismatched = try await fixture.send(Self.json(arguments: [
                "query": "wire-secret", "mode": "exact", "limit": 1, "cursor": cursor
            ]))
            #expect(mismatched.exitCode == 4)

            let current = try await fixture.history.browse(.init(kind: .recent, limit: 1))
            let item = try #require(current.rows.first?.item)
            _ = try await fixture.history.perform(.revise(.init(
                itemID: item.id, expected: item.contentVersion,
                intent: .replace(.init(decisions: [
                    .init(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("revised-only".utf8))),
                    .init(typeIdentifier: "com.clipy.tests.binary", action: .inheritCanonical),
                ]))
            )))
            for operation in ["detailsEffective", "pasteEffective"] {
                let content = try Self.result(await fixture.send(Self.json(operation: operation, arguments: ["locator": locator])))
                #expect(Set(content.keys) == ["contentVersion", "locator", "representations"])
                #expect(content["contentVersion"] as? UInt64 == 2)
                let representations = try #require(content["representations"] as? [[String: Any]])
                #expect(representations.count == 2)
                let text = try #require(representations.first { $0["typeIdentifier"] as? String == "public.utf8-plain-text" })
                let encoded = try #require(text["bytesBase64"] as? String)
                #expect(Data(base64Encoded: encoded) == Data("revised-only".utf8))
                let binary = try #require(representations.first { $0["typeIdentifier"] as? String == "com.clipy.tests.binary" })
                let binaryEncoded = try #require(binary["bytesBase64"] as? String)
                #expect(Data(base64Encoded: binaryEncoded) == Data([0, 255, 10]))
            }
            for operation in ["pin", "unpin", "delete"] {
                let changed = try Self.result(await fixture.send(Self.json(operation: operation, arguments: ["locator": locator])))
                #expect(changed["changed"] as? Bool == true)
            }
            let remaining = try await fixture.history.browse(.init(kind: .recent, limit: 10))
            #expect(remaining.rows.count == 2)
        }
    }

    @Test func partialAndOversizedFramesCloseWithoutDispatchingHistory() async throws {
        try await withFixture { fixture in
            for oversized in [false, true] {
                let descriptor = try LocalAutomationSocket.make()
                defer { _ = Darwin.close(descriptor) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                try await LocalAutomationSocket.connect(descriptor, to: fixture.endpoint, deadline: deadline)
                let header = LocalAutomationFrames.requestHeader(
                    credential: fixture.credential,
                    jsonCount: oversized ? ClipyCLIContract.maximumRequestBytes + 1 : 100
                )
                // Split the header itself: the service must read the complete
                // prefix before interpreting its lengths or credential.
                try await LocalAutomationSocket.send(Data(header.prefix(7)), to: descriptor, deadline: deadline)
                try await LocalAutomationSocket.send(Data(header.dropFirst(7)), to: descriptor, deadline: deadline)
                if !oversized {
                    try await LocalAutomationSocket.send(Data("{".utf8), to: descriptor, deadline: deadline)
                }
                _ = Darwin.shutdown(descriptor, SHUT_WR)
                do {
                    _ = try await LocalAutomationSocket.receive(1, from: descriptor, deadline: deadline)
                    Issue.record("malformed private request must close without a partial JSON response")
                } catch let failure as LocalAutomationSocket.Failure {
                    #expect(failure == .disconnected)
                }
            }
            let current = try await fixture.history.browse(.init(kind: .recent, limit: 10))
            #expect(current.rows.count == 3)
        }
    }

    @Test func revisionRequiresItsOwnGrantAndPreservesExactBytesWithOCC() async throws {
        try await withFixture { fixture in
            for capability in [ExternalCapability.browsePreview, .readEffectiveContent, .organize, .deleteItem] {
                try await fixture.history.grantCapability(capability, to: fixture.connection)
            }
            let page = try Self.result(await fixture.send(Self.json(arguments: ["limit": 1])))
            let rows = try #require(page["items"] as? [[String: Any]])
            let locator = try #require(rows.first?["locator"] as? String)
            let readRequest = try Self.json(operation: "detailsEffective", arguments: ["locator": locator])
            let before = try Self.result(await fixture.send(readRequest))
            let version = try #require(before["contentVersion"] as? UInt64)
            let literal = Data("literal\u{0}\nreplacement e\u{301}".utf8)
            let binary = Data([0, 255, 10, 0, 92])
            let desired: [[String: String]] = [
                ["typeIdentifier": "public.utf8-plain-text", "bytesBase64": literal.base64EncodedString()],
                ["typeIdentifier": "com.clipy.tests.binary", "bytesBase64": binary.base64EncodedString()],
            ]
            let writeRequest = try Self.json(operation: "reviseContent", arguments: [
                "locator": locator, "expectedContentVersion": version, "representations": desired,
            ])
            let denied = try await fixture.send(writeRequest)
            #expect(denied.exitCode == 3)
            #expect(String(decoding: denied.stderr, as: UTF8.self) == "clipyctl: not_granted\n")

            try await fixture.history.grantCapability(.reviseContent, to: fixture.connection)
            let changed = try Self.result(await fixture.send(writeRequest))
            #expect(changed["changed"] as? Bool == true)
            let after = try Self.result(await fixture.send(readRequest))
            #expect(after["contentVersion"] as? UInt64 == version + 1)
            let representations = try #require(after["representations"] as? [[String: String]])
            #expect(representations.count == 2)
            for (type, expected) in [("public.utf8-plain-text", literal), ("com.clipy.tests.binary", binary)] {
                let encoded = try #require(representations.first { $0["typeIdentifier"] == type }?["bytesBase64"])
                #expect(Data(base64Encoded: encoded) == expected)
            }
            let stale = try await fixture.send(writeRequest)
            #expect(stale.exitCode == 4)
            #expect(String(decoding: stale.stderr, as: UTF8.self) == "clipyctl: content_stale\n")
            let stillCurrent = try Self.result(await fixture.send(readRequest))
            #expect(stillCurrent["contentVersion"] as? UInt64 == version + 1)

            let freshRequest = try Self.json(operation: "reviseContent", arguments: [
                "locator": locator, "expectedContentVersion": version + 1, "representations": desired,
            ])
            let noChange = try Self.result(await fixture.send(freshRequest))
            #expect(noChange["changed"] as? Bool == false)
            let binaryOnly = [[
                "typeIdentifier": "com.clipy.tests.binary", "bytesBase64": binary.base64EncodedString(),
            ]]
            let hideRequest = try Self.json(operation: "reviseContent", arguments: [
                "locator": locator, "expectedContentVersion": version + 1, "representations": binaryOnly,
            ])
            let hidden = try Self.result(await fixture.send(hideRequest))
            #expect(hidden["changed"] as? Bool == true)
            let hiddenRead = try Self.result(await fixture.send(readRequest))
            #expect(hiddenRead["contentVersion"] as? UInt64 == version + 2)
            #expect(hiddenRead["representations"] as? [[String: String]] == binaryOnly)
            let afterHideRequest = try Self.json(operation: "reviseContent", arguments: [
                "locator": locator, "expectedContentVersion": version + 2, "representations": binaryOnly,
            ])
            try await fixture.history.revokeCapability(.reviseContent, of: fixture.connection)
            let revokedGrant = try await fixture.send(afterHideRequest)
            #expect(revokedGrant.exitCode == 3)
            #expect(String(decoding: revokedGrant.stderr, as: UTF8.self) == "clipyctl: not_granted\n")
            try await fixture.history.revokeConnection(fixture.connection)
            let revokedConnection = try await fixture.send(afterHideRequest)
            #expect(revokedConnection.exitCode == 3)
            #expect(String(decoding: revokedConnection.stderr, as: UTF8.self) == "clipyctl: connection_revoked\n")
        }
    }

    @Test func rejectedRevisionEncodingAndOversizedRequestsNeverModifyHistory() async throws {
        try await withFixture { fixture in
            try await fixture.history.grantCapability(.browsePreview, to: fixture.connection)
            try await fixture.history.grantCapability(.reviseContent, to: fixture.connection)
            let page = try Self.result(await fixture.send(Self.json(arguments: ["limit": 1])))
            let rows = try #require(page["items"] as? [[String: Any]])
            let locator = try #require(rows.first?["locator"] as? String)
            for encoded in ["AA", "AB==", "AA==\n", "not base64"] {
                let output = try await fixture.send(Self.json(operation: "reviseContent", arguments: [
                    "locator": locator, "expectedContentVersion": 1,
                    "representations": [["typeIdentifier": "com.clipy.tests.binary", "bytesBase64": encoded]],
                ]))
                #expect(output.exitCode == 2)
                #expect(String(decoding: output.stderr, as: UTF8.self) == "clipyctl: invalid_request\n")
            }
            let oversized = try await fixture.send(Self.json(operation: "reviseContent", arguments: [
                "locator": locator, "expectedContentVersion": 1,
                "representations": [["typeIdentifier": "com.clipy.tests.binary", "bytesBase64":
                    Data(repeating: 0, count: 50_000).base64EncodedString()]],
            ]))
            #expect(oversized.exitCode == 2)
            #expect(String(decoding: oversized.stderr, as: UTF8.self) == "clipyctl: request_too_large\n")
            let current = try await fixture.history.browse(.init(kind: .recent, limit: 10))
            #expect(current.rows.count == 3)
            #expect(current.rows.allSatisfy { $0.item.contentVersion.rawValue == 1 })
        }
    }

    @Test func stopClosesIncompleteClientsAndRemovesItsEndpoint() async throws {
        try await withFixture { fixture in
            let client = try await LocalAutomationClient.connect(endpointURL: fixture.endpoint)
            await fixture.service.stop()
            let output = await client.request(try Self.json(arguments: ["limit": 1]), credential: fixture.credential)
            #expect(output.exitCode == 5)
            #expect(!FileManager.default.fileExists(atPath: fixture.endpoint.path))
        }
    }

    @Test func interruptedRevisionReturnsUnknownOutcomeWithoutRetrying() async throws {
        try await withFixture { fixture in
            let client = try await LocalAutomationClient.connect(endpointURL: fixture.endpoint)
            await fixture.service.stop()
            let request = try Self.json(operation: "reviseContent", arguments: [
                "locator": "i1_interrupted", "expectedContentVersion": 1,
                "representations": [["typeIdentifier": "public.utf8-plain-text", "bytesBase64": "AA=="]],
            ])
            let output = await client.request(request, credential: fixture.credential)
            #expect(output.exitCode == 5)
            #expect(String(decoding: output.stderr, as: UTF8.self) == "clipyctl: outcome_unknown\n")
            let current = try await fixture.history.browse(.init(kind: .recent, limit: 10))
            #expect(current.rows.allSatisfy { $0.item.contentVersion.rawValue == 1 })
        }
    }

    private struct Fixture: Sendable {
        let history: SwiftDataHistory
        let connection: ExternalConnectionID
        let credential: Data
        let endpoint: URL
        let service: LocalAutomationService

        func send(_ request: Data, credential override: Data? = nil) async throws -> LocalAutomationOutput {
            let client = try await LocalAutomationClient.connect(endpointURL: endpoint)
            return await client.request(request, credential: override ?? credential)
        }
    }

    private func withFixture(_ body: @Sendable (Fixture) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/tmp/clipy-wire-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("automation.sock")
        let history = try await SwiftDataHistory.open(configuration: .init(persistence: .memory))
        for index in 0..<3 {
            _ = try await history.perform(.capture(.init(
                representations: [
                    .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("wire-secret-\(index)".utf8)),
                    .init(typeIdentifier: "com.clipy.tests.binary", bytes: Data([0, 255, 10])),
                ],
                origin: .init(sourceApplication: nil, lineageHint: nil),
                observedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            )))
        }
        let connection = ExternalConnectionID(rawValue: UUID())
        let credential = try LocalAutomationCredential(connection: connection, secret: Data(repeating: 0x57, count: 32))
        try await history.authority.publishVerifiedLocalAutomationEnrollment(connection, displayName: "Real socket test")
        let ingress = LocalAutomationIngress(
            authority: history.authority, gateway: history.externalGateway,
            credentialStore: CredentialStore(operations: MemoryCredentials(values: [connection: credential.exactBytes]))
        )
        let service = LocalAutomationService(ingress: ingress, endpointURL: endpoint)
        try await service.start()
        do {
            try await body(Fixture(history: history, connection: connection, credential: credential.exactBytes, endpoint: endpoint, service: service))
        } catch {
            await service.stop()
            throw error
        }
        await service.stop()
    }

    private static func json(operation: String = "browsePreview", arguments: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 1,
            "requestID": "9bd92054-bd3f-4d20-8f8a-5d77aa63b726",
            "operation": operation, "arguments": arguments,
        ])
    }

    private static func result(_ output: LocalAutomationOutput) throws -> [String: Any] {
        #expect(output.exitCode == 0)
        #expect(output.stderr.isEmpty)
        let envelope = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        return try #require(envelope["result"] as? [String: Any])
    }
}

private struct MemoryCredentials: CredentialStoreExternalOperations {
    var values: [ExternalConnectionID: Data]
    func connectionIDs() throws -> [ExternalConnectionID] { Array(values.keys) }
    mutating func addCredential(_ data: Data, for connection: ExternalConnectionID) -> CredentialStoreAddResult {
        values[connection] = data
        return .stored
    }
    func copyCredential(for connection: ExternalConnectionID) -> CredentialStoreCopyResult {
        values[connection].map(CredentialStoreCopyResult.value) ?? .missing
    }
    mutating func deleteCredential(for connection: ExternalConnectionID) -> CredentialStoreDeleteResult {
        values.removeValue(forKey: connection)
        return .deletedOrMissing
    }
}
