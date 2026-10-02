import Darwin
import Foundation
@testable import HistoryStorage
import LocalAutomation
import Testing
@testable import ClipyApp

struct LocalAutomationCompositionTests {
#if DEBUG
    @Test(arguments: [false, true], [false, true]) @MainActor
    func staleEnrollmentCannotRestartRevokedListener(delayedEnable: Bool, reenable: Bool) async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let directory = URL(fileURLWithPath: "/tmp/clipy-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let clientDirectory = directory.appendingPathComponent("client")
        let endpoint = directory.appendingPathComponent("automation.sock")
        let ingress = LocalAutomationIngress(
            authority: history.authority, gateway: history.externalGateway,
            credentialStore: CredentialStore(directoryURL: directory.appendingPathComponent("server"))
        )
        let controller = LocalAutomationController(
            ingress: ingress, endpointURL: endpoint, clientDirectory: clientDirectory
        )
        let boundary = ControllerEnrollmentBoundary()
        do {
            _ = try await controller.settings.enable()
            let stale = LocalAutomationControllerDebugInstrumentation.$beforeServiceReconciliation.withValue({
                await boundary.park()
            }) {
                Task {
                    do {
                        let state: LocalAutomationSettingsState
                        if delayedEnable { state = try await controller.settings.enable() }
                        else { state = try await controller.settings.load() }
                        await boundary.invocationFinished()
                        return state
                    } catch {
                        await boundary.invocationFinished()
                        throw error
                    }
                }
            }
            do {
                try #require(await boundary.waitUntilParked())
                let revoked = try await controller.settings.revoke()
                #expect(!revoked.enabled)
                #expect(!FileManager.default.fileExists(atPath: endpoint.path))
                if reenable { _ = try await controller.settings.enable() }
                await boundary.release()
                let refreshed = try await stale.value
                #expect(refreshed.enabled == reenable)
                if reenable {
                    // A stale startup must also leave the newly enabled real
                    // listener intact. New enrollment begins without grants.
                    let credential = try Data(contentsOf: clientDirectory.appendingPathComponent("local-automation.credential"))
                    let client = try await LocalAutomationClient.connect(endpointURL: endpoint)
                    let output = await client.request(Data(
                        "{\"protocolVersion\":1,\"requestID\":\"12345678-1234-1234-1234-123456789abc\",\"operation\":\"browsePreview\",\"arguments\":{\"limit\":1}}".utf8
                    ), credential: credential)
                    #expect(output.stderr == Data("clipyctl: not_granted\n".utf8))
                } else {
                    #expect(!FileManager.default.fileExists(atPath: endpoint.path))
                    do {
                        let client = try await LocalAutomationClient.connect(endpointURL: endpoint)
                        await client.close()
                        Issue.record("Revoked Local Automation unexpectedly accepted a connection")
                    } catch LocalAutomationClientFailure.notReady {
                        // The removed endpoint has no listener behind it.
                    }
                }
            } catch {
                await boundary.release()
                _ = await stale.result
                throw error
            }
        } catch {
            await controller.stop()
            throw error
        }
        await controller.stop()
    }

    @Test(arguments: [false, true]) @MainActor
    func serviceShutdownPublishesOnlyTheLatestEnrollment(revokeAgain: Bool) async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        _ = try await history.perform(.capture(ComposedSupport.textCapture("controller lifecycle", observedAt: Date())))
        let directory = URL(fileURLWithPath: "/tmp/clipy-shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("automation.sock")
        let clientDirectory = directory.appendingPathComponent("client")
        let boundary = ControllerEnrollmentBoundary()
        let ingress = LocalAutomationIngress(
            authority: history.authority, gateway: history.externalGateway,
            credentialStore: CredentialStore(directoryURL: directory.appendingPathComponent("server")),
            onCommittedRemoval: { _ in await boundary.park() }
        )
        let controller = LocalAutomationController(
            ingress: ingress, endpointURL: endpoint, clientDirectory: clientDirectory
        )
        var deletion: Task<LocalAutomationOutput, any Error>?
        var updates: [Task<LocalAutomationSettingsState, any Error>] = []
        do {
            let enabled = try await controller.settings.enable()
            try #require(enabled.enabled)
            _ = try await controller.settings.setCapability(.browsePreview, true)
            _ = try await controller.settings.setCapability(.deleteItem, true)
            let credential = try Data(contentsOf: clientDirectory.appendingPathComponent("local-automation.credential"))
            let client = try await LocalAutomationClient.connect(endpointURL: endpoint)
            let browse = try Self.request("browsePreview", arguments: ["limit": 1])
            let output = await client.request(browse, credential: credential)
            try #require(output.exitCode == 0)
            let envelope = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
            let result = try #require(envelope["result"] as? [String: Any])
            let rows = try #require(result["items"] as? [[String: Any]])
            let locator = try #require(rows.first?["locator"] as? String)
            let removal = try Self.request("delete", arguments: ["locator": locator])
            let removing = Task {
                do {
                    let connection = try await LocalAutomationClient.connect(endpointURL: endpoint)
                    let result = await connection.request(removal, credential: credential)
                    await boundary.invocationFinished()
                    return result
                } catch {
                    await boundary.invocationFinished()
                    throw error
                }
            }
            deletion = removing
            try #require(await boundary.waitUntilParked())
            let revoking = Task { try await controller.settings.revoke() }
            updates.append(revoking)
            // The real listener removes its endpoint before joining the
            // committed removal's still-running callback. Its stop is live.
            try #require(await ComposedSupport.waitFor(timeout: 5) {
                controller.pendingServiceUpdatesForTesting == 1
                    && !FileManager.default.fileExists(atPath: endpoint.path)
            })
            let enabling = Task { try await controller.settings.enable() }
            updates.append(enabling)
            try #require(await ComposedSupport.waitFor(timeout: 5) {
                controller.pendingServiceUpdatesForTesting == 2
            })
            let loading = Task { try await controller.settings.load() }
            updates.append(loading)
            try #require(await ComposedSupport.waitFor(timeout: 5) {
                controller.pendingServiceUpdatesForTesting == 3
            })
            let finalRevoke: Task<LocalAutomationSettingsState, any Error>?
            if revokeAgain {
                let final = Task { try await controller.settings.revoke() }
                finalRevoke = final
                updates.append(final)
                try #require(await ComposedSupport.waitFor(timeout: 5) {
                    controller.pendingServiceUpdatesForTesting == 4
                })
            } else { finalRevoke = nil }
            await boundary.release()
            let revokeResult = try await revoking.value
            let enableResult = try await enabling.value
            let loadResult = try await loading.value
            #expect(revokeResult.enabled == !revokeAgain)
            #expect(enableResult.enabled == !revokeAgain)
            #expect(loadResult.enabled == !revokeAgain)
            if let finalRevoke {
                let finalState = try await finalRevoke.value
                #expect(!finalState.enabled)
                #expect(!FileManager.default.fileExists(atPath: endpoint.path))
            } else {
                let live = try await LocalAutomationClient.connect(endpointURL: endpoint)
                await live.close()
            }
            let removedOutput = try await removing.value
            #expect(removedOutput.stderr == Data("clipyctl: outcome_unknown\n".utf8))
            #expect(try await history.usage().itemCount == 0, "Listener cancellation cannot undo the committed removal")
        } catch {
            await boundary.release()
            for update in updates { _ = await update.result }
            if let deletion { _ = await deletion.result }
            await controller.stop()
            throw error
        }
        await controller.stop()
    }

    @Test @MainActor
    func delayedRevocationReplyPreservesAReenrollmentAlreadyCommitted() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let directory = URL(fileURLWithPath: "/tmp/clipy-reenrollment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("automation.sock")
        let clientDirectory = directory.appendingPathComponent("client")
        let ingress = LocalAutomationIngress(
            authority: history.authority, gateway: history.externalGateway,
            credentialStore: CredentialStore(directoryURL: directory.appendingPathComponent("server"))
        )
        let controller = LocalAutomationController(
            ingress: ingress, endpointURL: endpoint, clientDirectory: clientDirectory
        )
        let boundary = ControllerEnrollmentBoundary()
        var delayed: Task<LocalAutomationSettingsState, any Error>?
        do {
            _ = try await controller.settings.enable()
            let revoking = LocalAutomationControllerDebugInstrumentation.$beforeServiceReconciliation.withValue({
                await boundary.park()
            }) {
                Task {
                    do {
                        let state = try await controller.settings.revoke()
                        await boundary.invocationFinished()
                        return state
                    } catch {
                        await boundary.invocationFinished()
                        throw error
                    }
                }
            }
            delayed = revoking
            try #require(await boundary.waitUntilParked())
            let reenabled = try await controller.settings.enable()
            try #require(reenabled.enabled)
            await boundary.release()
            let refreshed = try await revoking.value
            #expect(refreshed.enabled, "An older revoke receipt must read the newer authoritative enrollment")
            let credential = try Data(contentsOf: clientDirectory.appendingPathComponent("local-automation.credential"))
            let client = try await LocalAutomationClient.connect(endpointURL: endpoint)
            let output = await client.request(try Self.request("browsePreview", arguments: ["limit": 1]), credential: credential)
            #expect(output.stderr == Data("clipyctl: not_granted\n".utf8))
        } catch {
            await boundary.release()
            if let delayed { _ = await delayed.result }
            await controller.stop()
            throw error
        }
        await controller.stop()
    }

    private static func request(_ operation: String, arguments: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 1, "requestID": "12345678-1234-1234-1234-123456789abc",
            "operation": operation, "arguments": arguments,
        ])
    }
#endif

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

#if DEBUG
private actor ControllerEnrollmentBoundary {
    private var parked = false
    private var finished = false
    private var released = false
    private var didPark: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    func park() async {
        guard !released else { return }
        parked = true
        didPark?.resume()
        didPark = nil
        await withCheckedContinuation { resume = $0 }
    }

    func waitUntilParked() async -> Bool {
        guard !parked, !finished else { return parked }
        await withCheckedContinuation { didPark = $0 }
        return parked
    }

    func invocationFinished() {
        finished = true
        didPark?.resume()
        didPark = nil
    }

    func release() {
        released = true
        resume?.resume()
        resume = nil
    }
}
#endif
