import Darwin
import Foundation
import HistoryCore
@testable import HistoryStorage
import LocalAutomation
import PresentationUI
import XCTest
@testable import ClipyApp

/// Actual bundled processes against the app's listener and sole History
/// writer. The real server credential files use an isolated test directory;
/// client custody, socket paths and the bundled CLI remain the product paths.
/// XCTest runs these cases serially; occupied production paths are skipped
/// rather than modifying a developer's existing automation installation.
@MainActor
final class LocalAutomationClientRuntimeTests: XCTestCase {
    func testBundledClientUsesEnrollmentGrantsAndRevisionOCC() async throws {
        let clientDirectory = LocalAutomationPaths.clientDirectory
        let socketDirectory = LocalAutomationPaths.endpointURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: clientDirectory.path),
              !FileManager.default.fileExists(atPath: socketDirectory.path) else {
            throw XCTSkip("Local Automation paths already exist; preserving the user's service and credential.")
        }
        try FileManager.default.createDirectory(
            at: clientDirectory.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard Darwin.mkdir(clientDirectory.path, 0o700) == 0 else {
            throw XCTSkip("The client directory became occupied before the fixture could create it.")
        }
        guard Darwin.mkdir(socketDirectory.path, 0o700) == 0 else {
            try? FileManager.default.removeItem(at: clientDirectory)
            throw XCTSkip("The socket directory became occupied before the fixture could create it.")
        }
        defer {
            try? FileManager.default.removeItem(at: clientDirectory)
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        let serverDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-server-credentials-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: serverDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: serverDirectory) }
        let history = try await ComposedSupport.openMemoryHistory()
        _ = try await history.perform(.capture(ComposedSupport.textCapture(
            "cli-original", observedAt: Date(timeIntervalSinceReferenceDate: 12)
        )))
        let observedHistory = PostInitialObservationSuspendingHistory(base: history)
        let viewState = HistoryViewState(history: observedHistory)
        let preview = PreviewPaneState()
        let surface = HistoryPanelSurfaceState(viewState: viewState, previewState: preview)
        let relay = PanelSurfacePurgeRelay(viewState: viewState)
        relay.install(surface)
        defer {
            viewState.deactivate()
            Task { await observedHistory.releasePostInitialObservation() }
        }
        let ingress = LocalAutomationIngress(
            authority: history.authority, gateway: history.externalGateway,
            credentialStore: CredentialStore(directoryURL: serverDirectory),
            onCommittedRevision: { old, commit in
                await relay.acceptCommittedExternalRevision(from: old, commit: commit)
            }
        )
        let state = try await ingress.enable(clientDirectory: clientDirectory)
        let connection = try XCTUnwrap(state.connection)
        XCTAssertTrue(state.grants.isEmpty)
        let credential = try XCTUnwrap(try LocalAutomationPaths.readCredential())
        let serverCopy = try await CredentialStore(directoryURL: serverDirectory)
            .loadCredential(for: connection)
        XCTAssertEqual(serverCopy, credential)
        let controller = LocalAutomationController(ingress: ingress)
        do {
            try await controller.startIfEnabled()
            let browse = try request(arguments: ["limit": 10])
            let denied = try await runClient(browse)
            XCTAssertEqual(denied.exitCode, 3)
            XCTAssertEqual(denied.stderr, Data("clipyctl: not_granted\n".utf8))

            for capability in [ExternalCapability.browsePreview, .readEffectiveContent, .organize, .deleteItem] {
                _ = try await ingress.setCapability(capability, enabled: true, clientDirectory: clientDirectory)
            }
            let page = try result(await runClient(browse))
            let items = try XCTUnwrap(page["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?["title"] as? String, "cli-original")
            let locator = try XCTUnwrap(items.first?["locator"] as? String)
            let searched = try result(await runClient(request(arguments: [
                "query": "cli-original", "mode": "exact", "limit": 10
            ])))
            XCTAssertEqual((searched["items"] as? [[String: Any]])?.count, 1)

            let current = try await history.browse(.init(kind: .recent, limit: 1))
            let reference = try XCTUnwrap(current.rows.first?.item)
            _ = try await history.perform(.revise(.init(
                itemID: reference.id, expected: reference.contentVersion,
                intent: .replace(.init(decisions: [.init(
                    typeIdentifier: "public.utf8-plain-text",
                    action: .replace(bytes: Data("cli-current".utf8))
                )]))
            )))
            for operation in ["detailsEffective", "pasteEffective"] {
                let content = try result(await runClient(request(
                    operation: operation, arguments: ["locator": locator]
                )))
                let representations = try XCTUnwrap(content["representations"] as? [[String: Any]])
                XCTAssertEqual(Set(content.keys), ["contentVersion", "locator", "representations"])
                XCTAssertEqual(content["contentVersion"] as? UInt64, 2)
                let encoded = try XCTUnwrap(representations.first?["bytesBase64"] as? String)
                XCTAssertEqual(Data(base64Encoded: encoded), Data("cli-current".utf8))
            }
            let displayed = try await history.details(for: reference.id).item
            viewState.activate()
            let initialVisible = await ComposedSupport.waitFor {
                viewState.rows.first?.item == displayed
            }
            XCTAssertTrue(initialVisible)
            guard initialVisible else { throw ProcessFailure.initialPageUnavailable }
            preview.togglePreview(for: displayed)
            XCTAssertEqual(preview.previewedItem, displayed)
            let replacement = try request(operation: "reviseContent", arguments: [
                "locator": locator,
                "expectedContentVersion": 2,
                "representations": [[
                    "typeIdentifier": "public.utf8-plain-text",
                    "bytesBase64": Data("cli-authored".utf8).base64EncodedString(),
                ]],
            ])
            let deniedRevision = try await runClient(replacement)
            XCTAssertEqual(deniedRevision.exitCode, 3)
            XCTAssertEqual(deniedRevision.stderr, Data("clipyctl: not_granted\n".utf8))
            _ = try await ingress.setCapability(.reviseContent, enabled: true, clientDirectory: clientDirectory)
            let revised = try result(await runClient(replacement))
            XCTAssertEqual(revised["changed"] as? Bool, true)
            await observedHistory.waitUntilPostInitialObservationIsHeld()
            // The actual CLI reply has returned while its replacement page
            // is held. The ingress must already have retired old UI bytes.
            let committedReference = try await history.details(for: reference.id).item
            XCTAssertTrue(viewState.rows.isEmpty)
            XCTAssertEqual(preview.previewedItem, committedReference)
            XCTAssertNotEqual(preview.previewedItem, displayed)
            XCTAssertEqual(surface.appliedPurgeGeneration, 1)
            let stale = try await runClient(replacement)
            XCTAssertEqual(stale.exitCode, 4)
            XCTAssertEqual(stale.stderr, Data("clipyctl: content_stale\n".utf8))
            XCTAssertEqual(surface.appliedPurgeGeneration, 1)
            let unchanged = try result(await runClient(request(operation: "reviseContent", arguments: [
                "locator": locator,
                "expectedContentVersion": 3,
                "representations": [[
                    "typeIdentifier": "public.utf8-plain-text",
                    "bytesBase64": Data("cli-authored".utf8).base64EncodedString(),
                ]],
            ])))
            XCTAssertEqual(unchanged["changed"] as? Bool, false)
            XCTAssertEqual(surface.appliedPurgeGeneration, 1)
            let authored = try result(await runClient(request(
                operation: "detailsEffective", arguments: ["locator": locator]
            )))
            XCTAssertEqual(authored["contentVersion"] as? UInt64, 3)
            let authoredRepresentations = try XCTUnwrap(authored["representations"] as? [[String: Any]])
            let authoredBytes = try XCTUnwrap(authoredRepresentations.first?["bytesBase64"] as? String)
            XCTAssertEqual(Data(base64Encoded: authoredBytes), Data("cli-authored".utf8))
            await observedHistory.releasePostInitialObservation()
            let replacementVisible = await ComposedSupport.waitFor {
                viewState.rows.first?.item == committedReference
            }
            XCTAssertTrue(replacementVisible)
            viewState.deactivate()
            for operation in ["pin", "unpin", "delete"] {
                let changed = try result(await runClient(request(
                    operation: operation, arguments: ["locator": locator]
                )))
                XCTAssertEqual(changed["changed"] as? Bool, true)
            }
            let remaining = try await history.browse(.init(kind: .recent, limit: 10))
            XCTAssertTrue(remaining.rows.isEmpty)

            _ = try await ingress.setCapability(.browsePreview, enabled: false, clientDirectory: clientDirectory)
            let grantRevoked = try await runClient(browse)
            XCTAssertEqual(grantRevoked.exitCode, 3)
            XCTAssertEqual(grantRevoked.stderr, Data("clipyctl: not_granted\n".utf8))
            _ = try await ingress.revoke(clientDirectory: clientDirectory)
            let revoked = try await runClient(browse)
            XCTAssertEqual(revoked.exitCode, 3)
            XCTAssertEqual(revoked.stderr, Data("clipyctl: not_enrolled\n".utf8))
            XCTAssertNil(try LocalAutomationPaths.readCredential())
            let retainedServerCopy = try await CredentialStore(directoryURL: serverDirectory)
                .loadCredential(for: connection)
            XCTAssertEqual(retainedServerCopy, credential,
                           "Revocation removes client custody but retains server verification bytes")
            let retainedClient = try await LocalAutomationClient.connect(
                endpointURL: LocalAutomationPaths.endpointURL
            )
            let revokedPresentation = await retainedClient.request(browse, credential: credential)
            XCTAssertEqual(revokedPresentation.exitCode, 3)
            XCTAssertEqual(revokedPresentation.stderr, Data("clipyctl: connection_revoked\n".utf8))
        } catch {
            await controller.stop()
            throw error
        }
        await controller.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalAutomationPaths.endpointURL.path))
    }

    func testUnclosedPartialStandardInputTimesOut() async throws {
        let output = try await runClient(Data("{".utf8), holdInputOpen: true)
        XCTAssertEqual(output.exitCode, 5)
        XCTAssertEqual(output.stderr, Data("clipyctl: timeout\n".utf8))
        XCTAssertEqual(output.stdout, Data(
            "{\"error\":{\"code\":\"timeout\"},\"ok\":false,\"protocolVersion\":1,\"requestID\":null}\n".utf8
        ))
    }

    func testBlockedStandardOutputTimesOutWithoutRetryingTheRequest() async throws {
        // Prefill the pipe to create the same backpressure as a large reply
        // whose consumer stops reading, without needing credential/content
        // fixtures. The real client's first output write must time out.
        let output = try await runClient(Data("{".utf8), fillOutput: true)
        XCTAssertEqual(output.exitCode, 5)
        XCTAssertEqual(output.stderr, Data("clipyctl: timeout\n".utf8))
        XCTAssertFalse(output.stdout.contains(0x7B)) // No second JSON reply.
    }

    private func request(
        operation: String = "browsePreview", arguments: [String: Any]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 1,
            "requestID": "12345678-1234-1234-1234-123456789abc",
            "operation": operation, "arguments": arguments,
        ])
    }

    private func result(_ output: ProcessOutput) throws -> [String: Any] {
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.stderr.isEmpty)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        return try XCTUnwrap(reply["result"] as? [String: Any])
    }

    private struct ProcessOutput {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    private func runClient(
        _ request: Data, holdInputOpen: Bool = false, fillOutput: Bool = false
    ) async throws -> ProcessOutput {
        let executable = try XCTUnwrap(Bundle.main.executableURL)
            .deletingLastPathComponent().appendingPathComponent("clipyctl")
        let process = Process()
        process.executableURL = executable
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        if fillOutput { try fillPipe(output) }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
        }
        try input.fileHandleForWriting.write(contentsOf: request)
        if !holdInputOpen { try input.fileHandleForWriting.close() }
        let completed = await ComposedSupport.waitFor(timeout: 20) { !process.isRunning }
        guard completed else {
            XCTFail("Bundled clipyctl did not finish within its process I/O deadline.")
            throw ProcessFailure.didNotExit
        }
        process.waitUntilExit()
        return ProcessOutput(
            exitCode: process.terminationStatus,
            stdout: output.fileHandleForReading.readDataToEndOfFile(),
            stderr: error.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private func fillPipe(_ pipe: Pipe) throws {
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ProcessFailure.pipeUnavailable
        }
        defer { _ = Darwin.fcntl(descriptor, F_SETFL, flags) }
        let bytes = [UInt8](repeating: 0x20, count: 4_096)
        var writeSize = bytes.count
        while true {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, writeSize) }
            if count > 0 { continue }
            if count < 0, errno == EINTR { continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                throw ProcessFailure.pipeUnavailable
            }
            // An atomic PIPE_BUF write can fail while a smaller JSON reply
            // still fits. Exhaust those remaining bytes before starting it.
            if writeSize > 1 { writeSize = 1; continue }
            return
        }
    }

    private enum ProcessFailure: Error { case didNotExit, pipeUnavailable, initialPageUnavailable }
}
