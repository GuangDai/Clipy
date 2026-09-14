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
