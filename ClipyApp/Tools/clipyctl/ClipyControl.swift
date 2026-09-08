import AppKit
import Darwin
import Foundation
import LocalAutomation

/// One invocation builds a shell command request or consumes bounded UTF-8
/// JSON stdin, then writes its reply. Only connection establishment may retry: after
/// sending a mutation, uncertainty is returned to its caller (V2-05).
@main
struct ClipyControl {
    static func main() async {
        // A closed stdout pipe must become an ordinary write failure instead
        // of terminating in the middle of reporting a completed operation.
        signal(SIGPIPE, SIG_IGN)
        let output = await run()
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            try await CLIStandardStreams.write(output.stdout, to: STDOUT_FILENO, deadline: deadline)
            try await CLIStandardStreams.write(output.stderr, to: STDERR_FILENO, deadline: deadline)
            exit(output.exitCode)
        } catch {
            // stdout may already contain a prefix: appending a second JSON
            // reply would corrupt it. Report only a bounded, content-free
            // diagnostic and never execute the request again.
            try? await CLIStandardStreams.write(
                Data("clipyctl: timeout\n".utf8), to: STDERR_FILENO,
                deadline: .now.advanced(by: .seconds(1))
            )
            exit(5)
        }
    }

    private static func run() async -> CLIOutput {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            let help = CLIArguments.help(executablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments[0])
            return .init(exitCode: 0, stdout: Data(help.utf8), stderr: Data())
        }
        if arguments == ["--version"] {
            let bundle = containingApplicationURL.flatMap { Bundle(url: $0) }
            let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            return .init(exitCode: 0, stdout: Data("clipyctl \(version) (protocol 1)\n".utf8), stderr: Data())
        }
        guard let mode = CLIArguments(arguments) else {
            return CLIOutput.failure(.invalidRequest, raw: arguments.contains("--raw"))
        }
        return mode.output(await request(mode: mode))
    }

    private static func request(mode: CLIArguments) async -> LocalAutomationOutput {
        let request: Data
        do {
            if let generated = mode.requestJSON { request = generated }
            else { request = try await CLIStandardStreams.readRequest() }
        } catch CLIStandardStreams.Failure.timeout {
            return LocalAutomationClient.failure(.timeout)
        } catch is CancellationError {
            return LocalAutomationClient.failure(.cancelled)
        } catch {
            return LocalAutomationClient.failure(.notReady)
        }
        if let failure = LocalAutomationClient.validateRequest(request) {
            return failure
        }
        guard mode.accepts(request) else {
            return LocalAutomationClient.failure(.invalidRequest, request: request)
        }
        let credential: Data
        do {
            guard let loaded = try LocalAutomationPaths.readCredential() else {
                return LocalAutomationClient.failure(.notEnrolled, request: request)
            }
            credential = loaded
        } catch {
            return LocalAutomationClient.failure(.notEnrolled, request: request)
        }
        if let client = try? await LocalAutomationClient.connect(
            endpointURL: LocalAutomationPaths.endpointURL
        ) {
            return await client.request(request, credential: credential)
        }
        guard await launchContainingApplication() else {
            return LocalAutomationClient.failure(.notReady, request: request)
        }
        // Store opening is asynchronous after LaunchServices reports the app
        // launched. These retries establish a connection and send no bytes.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if let client = try? await LocalAutomationClient.connect(
                endpointURL: LocalAutomationPaths.endpointURL, timeout: 1
            ) {
                return await client.request(request, credential: credential)
            }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return LocalAutomationClient.failure(.cancelled, request: request) }
        }
        return LocalAutomationClient.failure(.notReady, request: request)
    }

    private static var containingApplicationURL: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let url = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return url.pathExtension == "app" ? url : nil
    }

    @MainActor
    private static func launchContainingApplication() async -> Bool {
        // The bundled executable lives beside Clipy in Contents/MacOS.
        // Resolve a user-created symlink without consulting PATH or bundle-ID
        // registration, which could select a different installed Clipy copy.
        guard let appURL = containingApplicationURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
