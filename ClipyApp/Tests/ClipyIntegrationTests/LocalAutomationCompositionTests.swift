import Darwin
import Foundation
import HistoryStorage
import LocalAutomation
import Testing
@testable import ClipyApp

struct LocalAutomationCompositionTests {
    @Test @MainActor
    func disabledAutomationCreatesNoListenerAndShutdownCannotRestartIt() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-automation-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("automation.sock")
        let controller = LocalAutomationController(
            ingress: history.localAutomationIngress(),
            endpointURL: endpoint,
            clientDirectory: directory.appendingPathComponent("client")
        )
        try await controller.startIfEnabled()
        #expect(!FileManager.default.fileExists(atPath: endpoint.path))
        await controller.stop()
        await controller.stop()
        await #expect(throws: CancellationError.self) {
            try await controller.startIfEnabled()
        }
        #expect(!FileManager.default.fileExists(atPath: endpoint.path))
    }

    /// These are actual bundled subprocesses. Invalid requests finish before
    /// consulting the user's enrollment or launching an application, so they
    /// are independent of runner Keychain and Accessibility permissions.
    @Test(arguments: [
        (Data("{".utf8), "invalid_json"),
        (Data("{\"protocolVersion\":1,\"requestID\":\"12345678-1234-1234-1234-123456789abc\",\"operation\":\"unknown\",\"arguments\":{}}".utf8), "unknown_operation"),
        (Data(repeating: 0x20, count: 65_537), "request_too_large"),
    ])
    func bundledClientReturnsExactProtocolFailure(request: Data, code: String) throws {
        let result = try runClient(request: request)
        #expect(result.exitCode == 2)
        #expect(result.stderr == Data("clipyctl: \(code)\n".utf8))
        let requestID = code == "unknown_operation" ? "\"12345678-1234-1234-1234-123456789abc\"" : "null"
        let expected = "{\"error\":{\"code\":\"\(code)\"},\"ok\":false,\"protocolVersion\":1,\"requestID\":\(requestID)}\n"
        #expect(result.stdout == Data(expected.utf8))
    }

    private func runClient(request: Data) throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
        let executable = try #require(Bundle.main.executableURL)
            .deletingLastPathComponent().appendingPathComponent("clipyctl")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process()
        process.executableURL = executable
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }
}
