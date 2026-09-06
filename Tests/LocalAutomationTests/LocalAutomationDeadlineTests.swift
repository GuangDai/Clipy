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
            do {
                try await LocalAutomationSocket.send(
                    Data([0x41]), to: sender,
                    deadline: ContinuousClock.now.advanced(by: .seconds(-1))
                )
                XCTFail("an expired deadline must not send a request")
            } catch let failure as LocalAutomationSocket.Failure {
                XCTAssertEqual(failure, .timeout)
            }

            var byte: UInt8 = 0
            let received = Darwin.recv(receiver, &byte, 1, 0)
            let receiveError = errno
            XCTAssertEqual(received, -1)
            XCTAssertEqual(receiveError, EAGAIN)
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
