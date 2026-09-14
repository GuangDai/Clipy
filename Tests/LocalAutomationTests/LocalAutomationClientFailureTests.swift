import Darwin
import Foundation
import XCTest
@testable import LocalAutomation

/// Real connections distinguish a lost reply from a deadline and establish
/// whether cancellation happened before or after request bytes left the client.
@MainActor
final class LocalAutomationClientFailureTests: XCTestCase {
    func testCancelledMutationBeforeSendingReportsCancelledAndSendsNothing() async throws {
        try await withConnection { client, peer in
            let invocation = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await client.request(Self.mutation, credential: Self.credential)
            }
            let output = await invocation.value
            Self.expect(output, code: "cancelled")
            var byte: UInt8 = 0
            XCTAssertEqual(Darwin.recv(peer, &byte, 1, 0), 0)
        }
    }

    func testReadPeerDisconnectIsNotADeadline() async throws {
        try await withConnection { client, peer in
            XCTAssertEqual(Darwin.shutdown(peer, SHUT_WR), 0)
            let output = await client.request(Self.read, credential: Self.credential)
            Self.expect(output, code: "not_ready")
        }
    }

    func testReadDeadlineRemainsTimeout() async throws {
        try await withConnection { client, _ in
            let output = await client.request(Self.read, credential: Self.credential, timeout: 0.05)
            Self.expect(output, code: "timeout")
        }
    }

    func testMutationOnClosedClientSendsNothingAndIsNotUnknown() async throws {
        try await withConnection { client, peer in
            // A peer shutdown does not establish a zero-byte client send:
            // Darwin can still accept request bytes into the local socket.
            // Closing the client's connection establishes that condition
            // before request(), and the peer's EOF independently confirms it.
            await client.close()
            let output = await client.request(Self.mutation, credential: Self.credential)
            Self.expect(output, code: "not_ready")
            var byte: UInt8 = 0
            XCTAssertEqual(Darwin.recv(peer, &byte, 1, 0), 0)
        }
    }

    func testMutationCancelledAfterSendingRetainsUnknownOutcome() async throws {
        try await withConnection { client, peer in
            let invocation = Task {
                await client.request(Self.mutation, credential: Self.credential)
            }
            _ = try await LocalAutomationSocket.receive(
                LocalAutomationFrames.requestHeaderBytes + Self.mutation.count,
                from: peer, deadline: .now.advanced(by: .seconds(2))
            )
            invocation.cancel()
            let output = await invocation.value
            Self.expect(output, code: "outcome_unknown")
        }
    }

    func testMutationWithLostReplyRetainsUnknownOutcome() async throws {
        try await withConnection { client, peer in
            let invocation = Task {
                await client.request(Self.mutation, credential: Self.credential)
            }
            _ = try await LocalAutomationSocket.receive(
                LocalAutomationFrames.requestHeaderBytes + Self.mutation.count,
                from: peer, deadline: .now.advanced(by: .seconds(2))
            )
            XCTAssertEqual(Darwin.shutdown(peer, SHUT_WR), 0)
            let output = await invocation.value
            Self.expect(output, code: "outcome_unknown")
        }
    }

    private static let credential = Data(repeating: 0x57, count: 48)
    private static let read = Data(#"{"protocolVersion":1,"requestID":"9bd92054-bd3f-4d20-8f8a-5d77aa63b726","operation":"browsePreview","arguments":{"limit":1}}"#.utf8)
    private static let mutation = Data(#"{"protocolVersion":1,"requestID":"9bd92054-bd3f-4d20-8f8a-5d77aa63b726","operation":"pin","arguments":{"locator":"i1_interrupted"}}"#.utf8)

    private static func expect(_ output: LocalAutomationOutput, code: String) {
        XCTAssertEqual(output.exitCode, 5)
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "clipyctl: \(code)\n")
    }

    private func withConnection(
        _ body: @MainActor @Sendable (LocalAutomationClient, Int32) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/clipy-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("automation.sock")
        let listener = try LocalAutomationSocket.make()
        defer { _ = Darwin.close(listener) }
        let bound = try LocalAutomationSocket.withAddress(endpoint) { Darwin.bind(listener, $0, $1) }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)
        let client = try await LocalAutomationClient.connect(endpointURL: endpoint)
        let peer = Darwin.accept(listener, nil, nil)
        guard peer >= 0 else {
            await client.close()
            XCTFail("the local client fixture could not accept its connection")
            return
        }
        defer { _ = Darwin.close(peer) }
        try LocalAutomationSocket.configure(peer)
        do {
            try await body(client, peer)
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }
}
