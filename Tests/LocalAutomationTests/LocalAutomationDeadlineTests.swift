import Darwin
import Foundation
import XCTest
@testable import LocalAutomation

/// Deadline behavior is tested on real connected descriptors without History,
/// actor readiness, or the parallel Swift Testing fixture workload.
@MainActor
final class LocalAutomationDeadlineTests: XCTestCase {
    func testExpiredReadDoesNotConsumeAlreadyBufferedBytes() async throws {
        try await withSocketPair { sender, receiver in
            let bytes = Data([0x41])
            let sent = bytes.withUnsafeBytes { Darwin.send(sender, $0.baseAddress, $0.count, 0) }
            XCTAssertEqual(sent, 1)

            do {
                _ = try await LocalAutomationSocket.receive(
                    1, from: receiver,
                    deadline: ContinuousClock.now.advanced(by: .seconds(-1))
                )
                XCTFail("an expired deadline must not become a successful read")
            } catch let failure as LocalAutomationSocket.Failure {
                XCTAssertEqual(failure, .timeout)
            }

            var byte: UInt8 = 0
            XCTAssertEqual(Darwin.recv(receiver, &byte, 1, 0), 1)
            XCTAssertEqual(byte, 0x41)
        }
    }

    func testExpiredWriteDoesNotSendBytes() async throws {
        try await withSocketPair { sender, receiver in
            var bytesSent = 0
            do {
                try await LocalAutomationSocket.send(
                    Data([0x41]), to: sender,
                    deadline: ContinuousClock.now.advanced(by: .seconds(-1)),
                    bytesSent: &bytesSent
                )
                XCTFail("an expired deadline must not send a request")
            } catch let failure as LocalAutomationSocket.Failure {
                XCTAssertEqual(failure, .timeout)
            }
            XCTAssertEqual(bytesSent, 0)

            var byte: UInt8 = 0
            let received = Darwin.recv(receiver, &byte, 1, 0)
            let receiveError = errno
            XCTAssertEqual(received, -1)
            XCTAssertEqual(receiveError, EAGAIN)
        }
    }

    func testCancelledPartialWriteKeepsItsTransmittedByteCount() async throws {
        try await withSocketPair { sender, receiver in
            var bufferSize: Int32 = 1_024
            XCTAssertEqual(Darwin.setsockopt(
                sender, SOL_SOCKET, SO_SNDBUF, &bufferSize,
                socklen_t(MemoryLayout<Int32>.size)
            ), 0)
            let payload = Data(repeating: 0x41, count: 1_048_576)
            let sending = Task {
                var bytesSent = 0
                do {
                    try await LocalAutomationSocket.send(
                        payload, to: sender,
                        deadline: .now.advanced(by: .seconds(2)), bytesSent: &bytesSent
                    )
                    XCTFail("the peer did not drain enough bytes to complete this send")
                } catch is CancellationError {
                    // The peer's first byte establishes transmission before cancel.
                } catch {
                    XCTFail("expected cancellation, got \(error)")
                }
                return bytesSent
            }
            _ = try await LocalAutomationSocket.receive(
                1, from: receiver, deadline: .now.advanced(by: .seconds(2))
            )
            sending.cancel()
            let bytesSent = await sending.value
            XCTAssertGreaterThan(bytesSent, 0)
            XCTAssertLessThan(bytesSent, payload.count)
        }
    }

    func testLocallyDisabledWriteFailsWithoutCountingOrSendingBytes() async throws {
        try await withSocketPair { sender, receiver in
            // Disable this descriptor's writes synchronously. Unlike a peer
            // shutdown, this guarantees the next send cannot accept bytes.
            XCTAssertEqual(Darwin.shutdown(sender, SHUT_WR), 0)
            var bytesSent = 0
            do {
                try await LocalAutomationSocket.send(
                    Data([0x41]), to: sender,
                    deadline: .now.advanced(by: .seconds(2)), bytesSent: &bytesSent
                )
                XCTFail("a locally closed write side must reject the send")
            } catch let failure as LocalAutomationSocket.Failure {
                XCTAssertEqual(failure, .disconnected)
            }
            XCTAssertEqual(bytesSent, 0)
            var byte: UInt8 = 0
            XCTAssertEqual(Darwin.recv(receiver, &byte, 1, 0), 0)
        }
    }

    func testPartialInputStillTimesOutWithoutACompleteFrame() async throws {
        try await withSocketPair { sender, receiver in
            let bytes = Data([0x41])
            let sent = bytes.withUnsafeBytes { Darwin.send(sender, $0.baseAddress, $0.count, 0) }
            XCTAssertEqual(sent, 1)
            do {
                _ = try await LocalAutomationSocket.receive(
                    2, from: receiver,
                    deadline: ContinuousClock.now.advanced(by: .milliseconds(50))
                )
                XCTFail("one available byte must not complete a two-byte read")
            } catch let failure as LocalAutomationSocket.Failure {
                XCTAssertEqual(failure, .timeout)
            }
        }
    }

    func testExpiredConnectDoesNotReachTheListener() async throws {
        try await withListener { endpoint, listener in
            let descriptor = try LocalAutomationSocket.make()
            defer { _ = Darwin.close(descriptor) }
            do {
                try await LocalAutomationSocket.connect(
                    descriptor, to: endpoint,
                    deadline: .now.advanced(by: .seconds(-1))
                )
                XCTFail("an expired deadline must not establish a connection")
            } catch let failure as LocalAutomationSocket.Failure {
                XCTAssertEqual(failure, .timeout)
            }
            Self.expectNoPendingConnection(listener)
        }
    }

    func testCancelledClientConnectDoesNotReachTheListener() async throws {
        try await withListener { endpoint, listener in
            let invocation = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    let client = try await LocalAutomationClient.connect(endpointURL: endpoint)
                    await client.close()
                    XCTFail("a cancelled task must not establish a connection")
                } catch LocalAutomationClientFailure.cancelled {
                    // The public client preserves cancellation from the socket.
                } catch {
                    XCTFail("expected cancellation, got \(error)")
                }
            }
            await invocation.value
            Self.expectNoPendingConnection(listener)
        }
    }

    private static func expectNoPendingConnection(_ listener: Int32) {
        let accepted = Darwin.accept(listener, nil, nil)
        let acceptError = errno
        if accepted >= 0 { _ = Darwin.close(accepted) }
        XCTAssertEqual(accepted, -1)
        XCTAssertTrue(acceptError == EAGAIN || acceptError == EWOULDBLOCK)
    }

    private func withListener(
        _ body: @MainActor @Sendable (URL, Int32) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/clipy-deadline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("automation.sock")
        let listener = try LocalAutomationSocket.make()
        defer { _ = Darwin.close(listener) }
        let bound = try LocalAutomationSocket.withAddress(endpoint) { Darwin.bind(listener, $0, $1) }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)
        try await body(endpoint, listener)
    }

    private func withSocketPair(
        _ body: @MainActor @Sendable (Int32, Int32) async throws -> Void
    ) async throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            XCTFail("the local socketpair fixture could not be created")
            return
        }
        defer {
            _ = Darwin.close(descriptors[0])
            _ = Darwin.close(descriptors[1])
        }
        try LocalAutomationSocket.configure(descriptors[0])
        try LocalAutomationSocket.configure(descriptors[1])
        try await body(descriptors[0], descriptors[1])
    }
}
