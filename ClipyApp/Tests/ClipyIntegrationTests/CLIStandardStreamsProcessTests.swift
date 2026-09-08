import Darwin
import Foundation
import LocalAutomation
import XCTest

/// Exercise the shipped executable's real standard streams. Every request
/// fails pure protocol validation before credential access or connection, so
/// these cases need neither enrollment fixtures nor a replacement transport.
@MainActor
final class CLIStandardStreamsProcessTests: XCTestCase {
    private let requestID = "12345678-1234-1234-1234-123456789abc"

    func testHelpAndVersionFinishWithoutReadingOpenStdin() async throws {
        for arguments in [["--help"], ["-h"], ["--version"]] {
            let invocation = try Invocation(arguments: arguments)
            defer { invocation.close() }
            // An open empty pipe would block the ordinary request path for
            // ten seconds. Informational flags must finish independently.
            let result = try await invocation.finish(timeout: 5)
            XCTAssertEqual(result.status, 0)
            XCTAssertTrue(result.stderr.isEmpty)
            let text = String(decoding: result.stdout, as: UTF8.self)
            if arguments == ["--version"] {
                let version = try XCTUnwrap(Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String)
                XCTAssertEqual(text, "clipyctl \(version) (protocol 1)\n")
            } else {
                XCTAssertTrue(text.contains("--raw --type TYPE"))
                XCTAssertTrue(text.contains("browsePreview"))
                XCTAssertTrue(text.contains("clipyctl recent [--limit N]"))
                XCTAssertTrue(text.contains("clipyctl search QUERY"))
                XCTAssertTrue(text.contains("clipyctl read LOCATOR"))
                XCTAssertTrue(text.contains("--item N"))
                XCTAssertTrue(text.contains("Settings > Automation"))
            }
        }
    }

    func testRawModeRejectsMutationsBeforeEnrollmentAndLeavesStdoutEmpty() async throws {
        for operation in ["pin", "unpin", "delete"] {
            let invocation = try Invocation(arguments: ["--raw", "--type", "public.utf8-plain-text"])
            defer { invocation.close() }
            let request = try JSONSerialization.data(withJSONObject: [
                "protocolVersion": 1, "requestID": requestID,
                "operation": operation, "arguments": ["locator": "opaque-locator"],
            ])
            try await invocation.writeInput(request)
            try invocation.input.fileHandleForWriting.close()
            let result = try await invocation.finish()
            XCTAssertEqual(result.status, 2)
            XCTAssertTrue(result.stdout.isEmpty)
            XCTAssertEqual(result.stderr, Data("clipyctl: invalid_request\n".utf8))
        }
    }

    func testIncompleteRawFlagsFailWithoutReadingStdin() async throws {
        let invocation = try Invocation(arguments: ["--raw"])
        defer { invocation.close() }
        let result = try await invocation.finish(timeout: 5)
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, Data("clipyctl: invalid_request\n".utf8))
    }

    func testInvalidShellCommandsRejectWithoutReadingOpenStdin() async throws {
        let commands = [
            ["recent", "--limit", "0"],
            ["recent", "--limit", "501"],
            ["recent", "--limit", "1", "--limit", "2"],
            ["recent", "--mode", "exact"],
            ["recent", "--cursor"],
            ["search"],
            ["search", ""],
            ["search", "query", "--mode", "unknown"],
            ["read"],
            ["delete", "locator", "--raw", "--type", "public.utf8-plain-text"],
        ]
        for command in commands {
            let invocation = try Invocation(arguments: command)
            defer { invocation.close() }
            let result = try await invocation.finish(timeout: 5)
            XCTAssertEqual(result.status, 2, "Invalid command: \(command)")
            XCTAssertEqual(result.stderr, Data("clipyctl: invalid_request\n".utf8))
            if command.contains("--raw") {
                XCTAssertTrue(result.stdout.isEmpty)
            } else {
                let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
                XCTAssertEqual(reply["ok"] as? Bool, false)
                XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "invalid_request")
            }
        }
    }

    func testRawItemIndicesRejectBeforeReadingStdin() async throws {
        let type = "public.utf8-plain-text"
        let commands = [
            ["--raw", "--type", type, "--item", "-1"],
            ["--raw", "--type", type, "--item", "32"],
            ["--raw", "--type", type, "--item", "1.5"],
            ["--raw", "--type", type, "--item"],
            ["read", "locator", "--raw", "--type", type, "--item", "32"],
            ["read", "locator", "--item", "0"],
            ["recent", "--item", "0"],
        ]
        for command in commands {
            let invocation = try Invocation(arguments: command)
            defer { invocation.close() }
            let result = try await invocation.finish(timeout: 5)
            XCTAssertEqual(result.status, 2)
            XCTAssertEqual(result.stderr, Data("clipyctl: invalid_request\n".utf8))
            if command.contains("--raw") { XCTAssertTrue(result.stdout.isEmpty) }
        }
    }

    func testExactStdinLimitIsDecodedAfterEOF() async throws {
        let invocation = try Invocation()
        defer { invocation.close() }
        var request = unknownOperationRequest()
        request.append(Data(repeating: 0x20, count: LocalAutomationClient.maximumRequestBytes - request.count))
        try await invocation.writeInput(request)
        try invocation.input.fileHandleForWriting.close()

        let result = try await invocation.finish()
        assertFailure(result, code: "unknown_operation", requestID: requestID)
    }

    func testOneByteOverStdinLimitReturnsWithoutWaitingForProducerEOF() async throws {
        let invocation = try Invocation()
        defer { invocation.close() }
        let request = Data(repeating: 0x20, count: LocalAutomationClient.maximumRequestBytes + 1)
        try await invocation.writeInput(request)
        // Keep the writer open deliberately: a cap check placed after EOF
        // would yield timeout instead of request_too_large in this process.
        let result = try await invocation.finish()
        assertFailure(result, code: "request_too_large", requestID: nil)
    }

    func testUTF8ScalarSplitAcrossConsumedPipeFragmentsIsDecodedOnlyAfterEOF() async throws {
        let invocation = try Invocation(keepInputReader: true)
        defer { invocation.close() }
        var prefix = Data("{\"protocolVersion\":1,\"requestID\":\"\(requestID)\",\"operation\":\"".utf8)
        prefix.append(Data(repeating: 0x61, count: 8_191 - prefix.count))
        // U+1F30D is F0 9F 8C 8D. End the first 8 KiB producer fragment
        // after F0, and observe the real pipe becoming empty before supplying
        // the remaining continuation bytes. No elapsed-time guess selects
        // the child's first read boundary.
        prefix.append(0xF0)
        try await invocation.writeInput(prefix)
        try await invocation.waitForInputToBeConsumed()
        try invocation.input.fileHandleForReading.close()
        XCTAssertTrue(invocation.process.isRunning)
        XCTAssertFalse(try invocation.hasAvailableOutput(),
                       "An incomplete UTF-8 prefix is not yet a complete stdin request")
        var suffix = Data([0x9F, 0x8C, 0x8D])
        suffix.append(Data("\",\"arguments\":{}}".utf8))
        try await invocation.writeInput(suffix)
        try invocation.input.fileHandleForWriting.close()

        let result = try await invocation.finish()
        // A recovered requestID and unknown_operation distinguish successful
        // whole-input UTF-8/JSON decoding from a per-chunk invalid_json error.
        assertFailure(result, code: "unknown_operation", requestID: requestID)
    }

    func testEOFInTheMiddleOfUTF8ScalarProducesOneInvalidJSONReply() async throws {
        let invocation = try Invocation()
        defer { invocation.close() }
        var request = Data("{\"protocolVersion\":1,\"requestID\":\"\(requestID)\",\"operation\":\"".utf8)
        request.append(contentsOf: [0xF0, 0x9F])
        try await invocation.writeInput(request)
        try invocation.input.fileHandleForWriting.close()

        let result = try await invocation.finish()
        assertFailure(result, code: "invalid_json", requestID: nil)
    }

    func testClosedStdoutReaderExitsNormallyWithOneDiagnosticInsteadOfSIGPIPE() async throws {
        let invocation = try Invocation(closeOutputReader: true)
        defer { invocation.close() }
        try await invocation.writeInput(unknownOperationRequest())
        try invocation.input.fileHandleForWriting.close()

        let result = try await invocation.finish()
        XCTAssertEqual(result.reason, .exit, "A vanished consumer must not kill clipyctl with SIGPIPE")
        XCTAssertEqual(result.status, 5)
        XCTAssertEqual(result.stderr, Data("clipyctl: timeout\n".utf8))
        // The consumer is gone, so stdout bytes cannot be observed here.
        // This proves sink failure reporting, not mutation replay behavior.
    }

    private func unknownOperationRequest() -> Data {
        Data("{\"protocolVersion\":1,\"requestID\":\"\(requestID)\",\"operation\":\"unsupported\",\"arguments\":{}}".utf8)
    }

    private func assertFailure(
        _ result: Output, code: String, requestID: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let identifier = requestID.map { "\"\($0)\"" } ?? "null"
        XCTAssertEqual(result.reason, .exit, file: file, line: line)
        XCTAssertEqual(result.status, 2, file: file, line: line)
        XCTAssertEqual(result.stderr, Data("clipyctl: \(code)\n".utf8), file: file, line: line)
        XCTAssertEqual(result.stdout, Data(
            "{\"error\":{\"code\":\"\(code)\"},\"ok\":false,\"protocolVersion\":1,\"requestID\":\(identifier)}\n".utf8
        ), file: file, line: line)
    }

    private struct Output {
        let reason: Process.TerminationReason
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    @MainActor
    private final class Invocation {
        let process = Process()
        let input = Pipe()
        private let output = Pipe()
        private let error = Pipe()
        private let closesOutputReader: Bool

        init(arguments: [String] = [], closeOutputReader: Bool = false, keepInputReader: Bool = false) throws {
            closesOutputReader = closeOutputReader
            process.arguments = arguments
            process.executableURL = try XCTUnwrap(Bundle.main.executableURL)
                .deletingLastPathComponent().appendingPathComponent("clipyctl")
            // Only the fragmented-input case retains a parent read handle
            // for readiness observations. Otherwise child exit must expose EPIPE to the
            // producer. Close output writers so child exit produces EOF.
            process.standardInput = input.fileHandleForReading
            process.standardOutput = output.fileHandleForWriting
            process.standardError = error.fileHandleForWriting
            if closeOutputReader { try output.fileHandleForReading.close() }
            // A broken child must report a failing fixture write rather than
            // deliver SIGPIPE to the entire hosted test process.
            let writer = input.fileHandleForWriting.fileDescriptor
            let flags = Darwin.fcntl(writer, F_GETFL)
            guard flags >= 0,
                  Darwin.fcntl(writer, F_SETFL, flags | O_NONBLOCK) == 0,
                  Darwin.fcntl(writer, F_SETNOSIGPIPE, 1) == 0 else {
                throw ProcessFailure.pipeUnavailable
            }
            try process.run()
            if !keepInputReader { try input.fileHandleForReading.close() }
            try output.fileHandleForWriting.close()
            try error.fileHandleForWriting.close()
        }

        /// Fixture writes must remain bounded even if the child stops reading
        /// before finish() can start its exit deadline. Partial writes keep
        /// their actual byte offset; backpressure yields the MainActor.
        func writeInput(_ bytes: Data) async throws {
            let descriptor = input.fileHandleForWriting.fileDescriptor
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                guard process.isRunning else { throw ProcessFailure.inputClosed }
                guard ContinuousClock.now < deadline else { throw ProcessFailure.inputWriteTimedOut }
                let count = bytes.withUnsafeBytes {
                    Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
                }
                if count > 0 {
                    offset += count
                    continue
                }
                guard count < 0 else { throw ProcessFailure.inputClosed }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw ProcessFailure.inputClosed
                }
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))), clock: .continuous
                )
            }
        }

        func waitForInputToBeConsumed() async throws {
            var observationFailure: Error?
            let consumed = await ComposedSupport.waitFor(timeout: 5) {
                do { return try !Self.hasReadableBytes(in: self.input.fileHandleForReading) }
                catch { observationFailure = error; return true }
            }
            if let observationFailure { throw observationFailure }
            guard consumed else { throw ProcessFailure.inputNotConsumed }
        }

        func hasAvailableOutput() throws -> Bool {
            try Self.hasReadableBytes(in: output.fileHandleForReading)
        }

        private static func hasReadableBytes(in handle: FileHandle) throws -> Bool {
            // Only empty/nonempty is needed. poll observes that without
            // consuming the child's input or relying on an unimported ioctl macro.
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 0) >= 0,
                  descriptor.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                throw ProcessFailure.pipeUnavailable
            }
            return descriptor.revents & Int16(POLLIN) != 0
        }

        func finish(timeout: TimeInterval = 20) async throws -> Output {
            let exited = await ComposedSupport.waitFor(timeout: timeout) { !self.process.isRunning }
            guard exited else {
                throw ProcessFailure.didNotExit
            }
            process.waitUntilExit()
            let standardOutput: Data
            if closesOutputReader { standardOutput = Data() }
            else { standardOutput = try output.fileHandleForReading.readToEnd() ?? Data() }
            return Output(
                reason: process.terminationReason, status: process.terminationStatus,
                stdout: standardOutput,
                stderr: try error.fileHandleForReading.readToEnd() ?? Data()
            )
        }

        func close() {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? input.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
        }
    }

    private enum ProcessFailure: Error {
        case pipeUnavailable, inputNotConsumed, inputClosed, inputWriteTimedOut, didNotExit
    }
}
