import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import LocalAutomation

#if DEBUG
enum LocalAutomationControllerDebugInstrumentation {
    @TaskLocal static var beforeServiceReconciliation: (@Sendable () async -> Void)?
}
#endif

/// The app owns one enrolled ingress and one listener after opening History.
/// Settings and startup share these instances; a disabled connection creates
/// no socket. Clipboard reads and mutations remain owned by HistoryStorage.
@MainActor
final class LocalAutomationController {
    private let ingress: LocalAutomationIngress
    private let service: LocalAutomationService
    private let clientDirectory: URL
    private var isStopped = false
    private var pendingEnrollmentChanges = 0
    private var enrollmentChangeWaiter: CheckedContinuation<Void, Never>?
    private var needsServiceUpdate = false
    private var latestEnrollment: LocalAutomationEnrollmentState?
    private var serviceUpdate: Task<Void, any Error>?
#if DEBUG
    private(set) var pendingServiceUpdatesForTesting = 0
#endif

    init(
        ingress: LocalAutomationIngress,
        endpointURL: URL = LocalAutomationPaths.endpointURL,
        clientDirectory: URL = LocalAutomationPaths.clientDirectory
    ) {
        self.ingress = ingress
        service = LocalAutomationService(ingress: ingress, endpointURL: endpointURL)
        self.clientDirectory = clientDirectory
    }

    func startIfEnabled() async throws {
        _ = try await load()
    }

    func stop() async {
        isStopped = true
        enrollmentChangeWaiter?.resume()
        enrollmentChangeWaiter = nil
        _ = try? await reconcileListener()
    }

    var settings: LocalAutomationSettings {
        LocalAutomationSettings(
            load: { [self] in try await load() },
            enable: { [self] in try await enable() },
            revoke: { [self] in try await revoke() },
            setCapability: { [self] capability, enabled in
                try await setCapability(capability, enabled: enabled)
            },
            commandLine: Self.commandLineSettings()
        )
    }

    /// Resolve the tool beside this running app, including renamed/moved app
    /// bundles. Finder and pasteboard writes only follow explicit user actions.
    static func commandLineURL(in bundle: Bundle = .main) -> URL? {
        guard let appExecutable = bundle.executableURL else { return nil }
        let tool = appExecutable.deletingLastPathComponent().appendingPathComponent("clipyctl")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    static func helpCommand(executableURL: URL) -> String {
        // POSIX shell single quoting keeps spaces, quotes and shell metacharacters
        // in a moved application's path literal when pasted into Terminal.
        "'" + executableURL.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "' --help"
    }

    private static func commandLineSettings() -> LocalAutomationCommandLine? {
        guard let executable = commandLineURL() else { return nil }
        let command = helpCommand(executableURL: executable)
        return LocalAutomationCommandLine(
            executablePath: executable.path,
            helpCommand: command,
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([executable]) },
            copyHelpCommand: {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(command, forType: .string)
            }
        )
    }

    private func load() async throws -> LocalAutomationSettingsState {
        try checkRunning()
#if DEBUG
        await LocalAutomationControllerDebugInstrumentation.beforeServiceReconciliation?()
#endif
        return presentation(try await reconcileListener())
    }

    private func enable() async throws -> LocalAutomationSettingsState {
        try checkRunning()
        try FileManager.default.createDirectory(
            at: clientDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try await performEnrollmentChange {
            try await ingress.enable(clientDirectory: clientDirectory)
        }
#if DEBUG
        await LocalAutomationControllerDebugInstrumentation.beforeServiceReconciliation?()
#endif
        return presentation(try await reconcileListener())
    }

    private func revoke() async throws -> LocalAutomationSettingsState {
        try checkRunning()
        // Revocation becomes authoritative before closing the listener, so
        // an already-connected request cannot retain the old grants.
        try await performEnrollmentChange {
            try await ingress.revoke(clientDirectory: clientDirectory)
        }
#if DEBUG
        await LocalAutomationControllerDebugInstrumentation.beforeServiceReconciliation?()
#endif
        return presentation(try await reconcileListener())
    }

    /// The socket follows current custody and durable enrollment, independently
    /// of which mutation's continuation reaches the MainActor first. One task
    /// joins each start/stop, then proves the latest state before publication.
    private func reconcileListener() async throws -> LocalAutomationEnrollmentState {
#if DEBUG
        pendingServiceUpdatesForTesting += 1
        defer { pendingServiceUpdatesForTesting -= 1 }
#endif
        needsServiceUpdate = true
        while true {
            let update: Task<Void, any Error>
            if let serviceUpdate { update = serviceUpdate }
            else {
                update = Task { [self] in
                    defer { serviceUpdate = nil }
                    while true {
                        if isStopped { await service.stop(); return }
                        await waitForEnrollmentChanges()
                        if isStopped { continue }
                        needsServiceUpdate = false
                        let before = try await ingress.stateWhenAvailable(clientDirectory: clientDirectory)
                        if isStopped { continue }
                        if before.connection != nil { try await service.start() }
                        else { await service.stop() }
                        await waitForEnrollmentChanges()
                        if isStopped { continue }
                        let current = try await ingress.stateWhenAvailable(clientDirectory: clientDirectory)
                        guard !isStopped, pendingEnrollmentChanges == 0,
                              !needsServiceUpdate, before.connection == current.connection else { continue }
                        latestEnrollment = current
                        return
                    }
                }
                serviceUpdate = update
            }
            do { try await update.value }
            catch {
                if !isStopped, pendingEnrollmentChanges > 0 || needsServiceUpdate { continue }
                throw error
            }
            try checkRunning()
            // A newer task or mutation may have begun while this caller was
            // awaiting the previous task. Publish only the latest proved value.
            if pendingEnrollmentChanges == 0, !needsServiceUpdate, let latestEnrollment {
                return latestEnrollment
            }
        }
    }

    private func performEnrollmentChange(
        _ operation: @MainActor () async throws -> LocalAutomationEnrollmentState
    ) async throws {
        pendingEnrollmentChanges += 1
        needsServiceUpdate = true
        latestEnrollment = nil
        defer {
            pendingEnrollmentChanges -= 1
            if pendingEnrollmentChanges == 0 {
                enrollmentChangeWaiter?.resume()
                enrollmentChangeWaiter = nil
            }
        }
        _ = try await operation()
    }

    private func waitForEnrollmentChanges() async {
        while pendingEnrollmentChanges > 0 && !isStopped {
            await withCheckedContinuation { enrollmentChangeWaiter = $0 }
        }
    }

    private func setCapability(
        _ capability: ExternalCapability, enabled: Bool
    ) async throws -> LocalAutomationSettingsState {
        try checkRunning()
        try await performEnrollmentChange {
            try await ingress.setCapability(capability, enabled: enabled, clientDirectory: clientDirectory)
        }
        return presentation(try await reconcileListener())
    }

    private func checkRunning() throws {
        if isStopped || Task.isCancelled { throw CancellationError() }
    }

    private func presentation(
        _ state: LocalAutomationEnrollmentState
    ) -> LocalAutomationSettingsState {
        LocalAutomationSettingsState(enabled: state.connection != nil, grants: state.grants)
    }
}
