import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct LocalAutomationCommandLineDiscoveryTests {
    @Test func discoversExecutableInTheRunningAppBundle() throws {
        let appExecutable = try #require(Bundle.main.executableURL)
        let tool = try #require(LocalAutomationController.commandLineURL())
        #expect(tool == appExecutable.deletingLastPathComponent().appendingPathComponent("clipyctl"))
        #expect(FileManager.default.isExecutableFile(atPath: tool.path))
    }

    @Test(arguments: [
        "/Applications/Clipy.app/Contents/MacOS/clipyctl",
        "/Applications/My Clipy.app/Contents/MacOS/clipyctl",
        "/Applications/O'Brien $(printf changed).app/Contents/MacOS/clipyctl",
    ])
    func copiedCommandPreservesMovedAppPathsInTheShell(path: String) throws {
        let command = LocalAutomationController.helpCommand(executableURL: URL(fileURLWithPath: path))
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Parse the actual copied command without executing the application.
        process.arguments = ["-c", "set -- \(command); printf '%s\\n' \"$@\""]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(bytes == Data("\(path)\n--help\n".utf8))
    }
}
