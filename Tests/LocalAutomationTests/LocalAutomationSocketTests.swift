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
                #expect(Set(content.keys) == ["locator", "representations"])
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

    @Test func stopClosesIncompleteClientsAndRemovesItsEndpoint() async throws {
        try await withFixture { fixture in
            let client = try await LocalAutomationClient.connect(endpointURL: fixture.endpoint)
            await fixture.service.stop()
            let output = await client.request(try Self.json(arguments: ["limit": 1]), credential: fixture.credential)
            #expect(output.exitCode == 5)
            #expect(!FileManager.default.fileExists(atPath: fixture.endpoint.path))
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
