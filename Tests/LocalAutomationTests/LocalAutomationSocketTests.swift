import ClipyCLIContract
import Darwin
import Foundation
import HistoryCore
import XCTest
@testable import HistoryStorage
@testable import LocalAutomation

/// These tests exercise real wall-clock transport deadlines. XCTest runs its
/// cases serially before Swift Testing starts the large parallel package suite,
/// so unrelated synchronous fixtures cannot consume a request's entire deadline
/// while its task is waiting to run (CI 34066411438).
@MainActor
final class LocalAutomationSocketTests: XCTestCase {
    func testGrantsProtectContentAndRevocationIsVisibleAcrossRealConnections() async throws {
        try await withFixture { fixture in
            let request = try Self.json(arguments: ["query": "wire-secret", "mode": "exact", "limit": 1])
            let denied = try await fixture.send(request)
            XCTAssertEqual(denied.exitCode, 3)
            XCTAssertEqual(String(decoding: denied.stderr, as: UTF8.self), "clipyctl: not_granted\n")
            XCTAssertTrue(!String(decoding: denied.stdout, as: UTF8.self).contains("wire-secret"))
            let wrong = try await fixture.send(request, credential: Data(repeating: 0, count: 48))
            XCTAssertTrue(wrong.exitCode == 3)
            XCTAssertTrue(String(decoding: wrong.stderr, as: UTF8.self) == "clipyctl: authentication_failed\n")

            try await fixture.history.grantCapability(.browsePreview, to: fixture.connection)
            let allowed = try await fixture.send(request)
            XCTAssertTrue(allowed.exitCode == 0)
            XCTAssertTrue(allowed.stderr.isEmpty)
            XCTAssertTrue(String(decoding: allowed.stdout, as: UTF8.self).contains("wire-secret"))
            try await fixture.history.revokeConnection(fixture.connection)
            let revoked = try await fixture.send(request)
            XCTAssertTrue(revoked.exitCode == 3)
            XCTAssertTrue(String(decoding: revoked.stderr, as: UTF8.self) == "clipyctl: connection_revoked\n")
        }
    }

    func testBrowsePaginationAndSevenOperationsUseTheSameLiveHistory() async throws {
        try await withFixture { fixture in
            for capability in [ExternalCapability.browsePreview, .readEffectiveContent, .organize, .deleteItem] {
                try await fixture.history.grantCapability(capability, to: fixture.connection)
            }
            let firstOutput = try await fixture.send(Self.json(arguments: ["limit": 1]))
            let first = try Self.result(firstOutput)
            let items = try XCTUnwrap(first["items"] as? [[String: Any]])
            let locator = try XCTUnwrap(items.first?["locator"] as? String)
            let cursor = try XCTUnwrap(first["nextCursor"] as? String)
            let secondOutput = try await fixture.send(Self.json(arguments: ["limit": 1, "cursor": cursor]))
            let second = try Self.result(secondOutput)
            let nextItems = try XCTUnwrap(second["items"] as? [[String: Any]])
            XCTAssertTrue(nextItems.first?["locator"] as? String != locator)
            let mismatched = try await fixture.send(Self.json(arguments: [
                "query": "wire-secret", "mode": "exact", "limit": 1, "cursor": cursor
            ]))
            XCTAssertTrue(mismatched.exitCode == 4)

            let current = try await fixture.history.browse(.init(kind: .recent, limit: 1))
            let item = try XCTUnwrap(current.rows.first?.item)
            _ = try await fixture.history.perform(.revise(.init(
                itemID: item.id, expected: item.contentVersion,
                intent: .replace(.init(decisions: [
                    .init(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("revised-only".utf8))),
                    .init(typeIdentifier: "com.clipy.tests.binary", action: .inheritCanonical),
                ]))
            )))
            for operation in ["detailsEffective", "pasteEffective"] {
                let contentOutput = try await fixture.send(Self.json(operation: operation, arguments: ["locator": locator]))
                let content = try Self.result(contentOutput)
                XCTAssertTrue(Set(content.keys) == ["contentVersion", "locator", "representations"])
                XCTAssertTrue(content["contentVersion"] as? UInt64 == 2)
                let representations = try XCTUnwrap(content["representations"] as? [[String: Any]])
                XCTAssertTrue(representations.count == 2)
                let text = try XCTUnwrap(representations.first { $0["typeIdentifier"] as? String == "public.utf8-plain-text" })
                let encoded = try XCTUnwrap(text["bytesBase64"] as? String)
                XCTAssertTrue(Data(base64Encoded: encoded) == Data("revised-only".utf8))
                let binary = try XCTUnwrap(representations.first { $0["typeIdentifier"] as? String == "com.clipy.tests.binary" })
                let binaryEncoded = try XCTUnwrap(binary["bytesBase64"] as? String)
                XCTAssertTrue(Data(base64Encoded: binaryEncoded) == Data([0, 255, 10]))
            }
            for operation in ["pin", "unpin", "delete"] {
                let changedOutput = try await fixture.send(Self.json(operation: operation, arguments: ["locator": locator]))
                let changed = try Self.result(changedOutput)
                XCTAssertTrue(changed["changed"] as? Bool == true)
            }
            let remaining = try await fixture.history.browse(.init(kind: .recent, limit: 10))
            XCTAssertTrue(remaining.rows.count == 2)
        }
    }

    func testPartialAndOversizedFramesCloseWithoutDispatchingHistory() async throws {
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
                    XCTFail("malformed private request must close without a partial JSON response")
                } catch let failure as LocalAutomationSocket.Failure {
                    XCTAssertTrue(failure == .disconnected)
                }
            }
            let current = try await fixture.history.browse(.init(kind: .recent, limit: 10))
            XCTAssertTrue(current.rows.count == 3)
        }
    }

    func testRevisionRequiresItsOwnGrantAndPreservesExactBytesWithOCC() async throws {
        try await withFixture { fixture in
            for capability in [ExternalCapability.browsePreview, .readEffectiveContent, .organize, .deleteItem] {
                try await fixture.history.grantCapability(capability, to: fixture.connection)
            }
            let pageOutput = try await fixture.send(Self.json(arguments: ["limit": 1]))
            let page = try Self.result(pageOutput)
            let rows = try XCTUnwrap(page["items"] as? [[String: Any]])
            let locator = try XCTUnwrap(rows.first?["locator"] as? String)
            let readRequest = try Self.json(operation: "detailsEffective", arguments: ["locator": locator])
            let beforeOutput = try await fixture.send(readRequest)
            let before = try Self.result(beforeOutput)
            let version = try XCTUnwrap(before["contentVersion"] as? UInt64)
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
            XCTAssertTrue(denied.exitCode == 3)
            XCTAssertTrue(String(decoding: denied.stderr, as: UTF8.self) == "clipyctl: not_granted\n")

            try await fixture.history.grantCapability(.reviseContent, to: fixture.connection)
            let changedOutput = try await fixture.send(writeRequest)
            let changed = try Self.result(changedOutput)
            XCTAssertTrue(changed["changed"] as? Bool == true)
            let afterOutput = try await fixture.send(readRequest)
            let after = try Self.result(afterOutput)
            XCTAssertTrue(after["contentVersion"] as? UInt64 == version + 1)
            let representations = try XCTUnwrap(after["representations"] as? [[String: String]])
            XCTAssertTrue(representations.count == 2)
            for (type, expected) in [("public.utf8-plain-text", literal), ("com.clipy.tests.binary", binary)] {
                let encoded = try XCTUnwrap(representations.first { $0["typeIdentifier"] == type }?["bytesBase64"])
                XCTAssertTrue(Data(base64Encoded: encoded) == expected)
            }
            let stale = try await fixture.send(writeRequest)
            XCTAssertTrue(stale.exitCode == 4)
            XCTAssertTrue(String(decoding: stale.stderr, as: UTF8.self) == "clipyctl: content_stale\n")
            let stillCurrentOutput = try await fixture.send(readRequest)
            let stillCurrent = try Self.result(stillCurrentOutput)
            XCTAssertTrue(stillCurrent["contentVersion"] as? UInt64 == version + 1)

            let freshRequest = try Self.json(operation: "reviseContent", arguments: [
                "locator": locator, "expectedContentVersion": version + 1, "representations": desired,
            ])
            let noChangeOutput = try await fixture.send(freshRequest)
            let noChange = try Self.result(noChangeOutput)
            XCTAssertTrue(noChange["changed"] as? Bool == false)
            let binaryOnly = [[
                "typeIdentifier": "com.clipy.tests.binary", "bytesBase64": binary.base64EncodedString(),
            ]]
            let hideRequest = try Self.json(operation: "reviseContent", arguments: [
                "locator": locator, "expectedContentVersion": version + 1, "representations": binaryOnly,
            ])
            let hiddenOutput = try await fixture.send(hideRequest)
            let hidden = try Self.result(hiddenOutput)
            XCTAssertTrue(hidden["changed"] as? Bool == true)
            let hiddenReadOutput = try await fixture.send(readRequest)
            let hiddenRead = try Self.result(hiddenReadOutput)
            XCTAssertTrue(hiddenRead["contentVersion"] as? UInt64 == version + 2)
            XCTAssertTrue(hiddenRead["representations"] as? [[String: String]] == binaryOnly)
            let afterHideRequest = try Self.json(operation: "reviseContent", arguments: [
                "locator": locator, "expectedContentVersion": version + 2, "representations": binaryOnly,
            ])
            try await fixture.history.revokeCapability(.reviseContent, of: fixture.connection)
            let revokedGrant = try await fixture.send(afterHideRequest)
            XCTAssertTrue(revokedGrant.exitCode == 3)
            XCTAssertTrue(String(decoding: revokedGrant.stderr, as: UTF8.self) == "clipyctl: not_granted\n")
            try await fixture.history.revokeConnection(fixture.connection)
            let revokedConnection = try await fixture.send(afterHideRequest)
            XCTAssertTrue(revokedConnection.exitCode == 3)
            XCTAssertTrue(String(decoding: revokedConnection.stderr, as: UTF8.self) == "clipyctl: connection_revoked\n")
        }
    }

    func testRejectedRevisionEncodingAndOversizedRequestsNeverModifyHistory() async throws {
        try await withFixture { fixture in
            try await fixture.history.grantCapability(.browsePreview, to: fixture.connection)
            try await fixture.history.grantCapability(.reviseContent, to: fixture.connection)
            let pageOutput = try await fixture.send(Self.json(arguments: ["limit": 1]))
            let page = try Self.result(pageOutput)
            let rows = try XCTUnwrap(page["items"] as? [[String: Any]])
            let locator = try XCTUnwrap(rows.first?["locator"] as? String)
            for encoded in ["AA", "AB==", "AA==\n", "not base64"] {
                let output = try await fixture.send(Self.json(operation: "reviseContent", arguments: [
                    "locator": locator, "expectedContentVersion": 1,
                    "representations": [["typeIdentifier": "com.clipy.tests.binary", "bytesBase64": encoded]],
                ]))
                XCTAssertTrue(output.exitCode == 2)
                XCTAssertTrue(String(decoding: output.stderr, as: UTF8.self) == "clipyctl: invalid_request\n")
            }
            let oversized = try await fixture.send(Self.json(operation: "reviseContent", arguments: [
                "locator": locator, "expectedContentVersion": 1,
                "representations": [["typeIdentifier": "com.clipy.tests.binary", "bytesBase64":
                    Data(repeating: 0, count: 50_000).base64EncodedString()]],
            ]))
            XCTAssertTrue(oversized.exitCode == 2)
            XCTAssertTrue(String(decoding: oversized.stderr, as: UTF8.self) == "clipyctl: request_too_large\n")
            let current = try await fixture.history.browse(.init(kind: .recent, limit: 10))
            XCTAssertTrue(current.rows.count == 3)
            XCTAssertTrue(current.rows.allSatisfy { $0.item.contentVersion.rawValue == 1 })
        }
    }

    func testStopClosesIncompleteClientsAndRemovesItsEndpoint() async throws {
        try await withFixture { fixture in
            let client = try await LocalAutomationClient.connect(endpointURL: fixture.endpoint)
            await fixture.service.stop()
            let output = await client.request(try Self.json(arguments: ["limit": 1]), credential: fixture.credential)
            XCTAssertTrue(output.exitCode == 5)
            XCTAssertTrue(!FileManager.default.fileExists(atPath: fixture.endpoint.path))
        }
    }

    func testInterruptedRevisionReturnsUnknownOutcomeWithoutRetrying() async throws {
        try await withFixture { fixture in
            let client = try await LocalAutomationClient.connect(endpointURL: fixture.endpoint)
            await fixture.service.stop()
            let request = try Self.json(operation: "reviseContent", arguments: [
                "locator": "i1_interrupted", "expectedContentVersion": 1,
                "representations": [["typeIdentifier": "public.utf8-plain-text", "bytesBase64": "AA=="]],
            ])
            let output = await client.request(request, credential: fixture.credential)
            XCTAssertTrue(output.exitCode == 5)
            XCTAssertTrue(String(decoding: output.stderr, as: UTF8.self) == "clipyctl: outcome_unknown\n")
            let current = try await fixture.history.browse(.init(kind: .recent, limit: 10))
            XCTAssertTrue(current.rows.allSatisfy { $0.item.contentVersion.rawValue == 1 })
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

    private func withFixture(_ body: @MainActor @Sendable (Fixture) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/tmp/clipy-wire-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let endpoint = directory.appendingPathComponent("automation.sock")
        let serverDirectory = directory.appendingPathComponent("server-credentials", isDirectory: true)
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
        let credentialWriter = CredentialStore(directoryURL: serverDirectory)
        try await credentialWriter.storeCredential(credential.exactBytes, for: connection)
        // Authentication uses a second actor opening the real server files,
        // not an in-memory map or the writer's retained state.
        let credentialReader = CredentialStore(directoryURL: serverDirectory)
        let restoredCredential = try await credentialReader.loadCredential(for: connection)
        XCTAssertEqual(restoredCredential, credential.exactBytes)
        try await history.authority.publishVerifiedLocalAutomationEnrollment(connection, displayName: "Real socket test")
        let ingress = LocalAutomationIngress(
            authority: history.authority, gateway: history.externalGateway,
            credentialStore: credentialReader
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
        XCTAssertEqual(output.exitCode, 0, String(decoding: output.stderr, as: UTF8.self))
        XCTAssertEqual(output.stderr, Data())
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }
}
