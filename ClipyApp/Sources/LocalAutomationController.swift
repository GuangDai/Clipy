import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import LocalAutomation

/// The app owns one enrolled ingress and one listener after opening History.
/// Settings and startup share these instances; a disabled connection creates
/// no socket. Clipboard reads and mutations remain owned by HistoryStorage.
@MainActor
final class LocalAutomationController {
    private let ingress: LocalAutomationIngress
    private let service: LocalAutomationService
    private let clientDirectory: URL
    private var isStopped = false

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
        await service.stop()
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
        let state = try await ingress.state(clientDirectory: clientDirectory)
        try checkRunning()
        if state.connection != nil {
            try await service.start()
            // Shutdown can interleave while the actor starts its listener.
            if isStopped { await service.stop(); throw CancellationError() }
        }
        return presentation(state)
    }

    private func enable() async throws -> LocalAutomationSettingsState {
        try checkRunning()
        try FileManager.default.createDirectory(
            at: clientDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let state = try await ingress.enable(clientDirectory: clientDirectory)
        try checkRunning()
        try await service.start()
        if isStopped { await service.stop(); throw CancellationError() }
        return presentation(state)
    }

    private func revoke() async throws -> LocalAutomationSettingsState {
        try checkRunning()
        // Revocation becomes authoritative before closing the listener, so
        // an already-connected request cannot retain the old grants.
        let state = try await ingress.revoke(clientDirectory: clientDirectory)
        await service.stop()
        return presentation(state)
    }

    private func setCapability(
        _ capability: ExternalCapability, enabled: Bool
    ) async throws -> LocalAutomationSettingsState {
        try checkRunning()
        let state = try await ingress.setCapability(
            capability, enabled: enabled, clientDirectory: clientDirectory
        )
        return presentation(state)
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
