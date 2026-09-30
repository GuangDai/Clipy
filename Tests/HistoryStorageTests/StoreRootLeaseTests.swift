/// docs/storage.md: a retained public external entry still owns the sole
/// writer after SQLiteHistory is released. Another process must be rejected
/// until that writer is released; the original process stays alive throughout.
/// SwiftPM builds the existing restart probe before this suite runs.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("StoreRoot single-writer lease")
struct StoreRootLeaseTests {
    private enum FixtureError: Error {
        case childFailed
    }

    enum OwnerKind: CaseIterable, Sendable, Equatable {
        case history, appIntentsFacade, localAutomationIngress
    }

    private enum RetainedOwner: Sendable {
        case history(SQLiteHistory)
        case appIntents(ExternalHistoryFacade)
        case localAutomation(LocalAutomationIngress)

        func readAfterFacadeRelease(clientDirectory: URL) async throws {
            switch self {
            case .history(let history):
                #expect(try await history.connections().count == 1)
            case .appIntents(let facade):
                guard case .page(let page) = try await facade.read(.recent(limit: 1)) else {
                    throw FixtureError.childFailed
                }
                #expect(page.rows.isEmpty)
            case .localAutomation(let ingress):
                let state = try await ingress.state(clientDirectory: clientDirectory)
                #expect(state.connection == nil)
            }
            // Each public read above commits its real Gateway audit, proving
            // that the retained entry still reaches a writable Authority.
        }
    }

    @Test("second process cannot open until the retained writer is released", arguments: OwnerKind.allCases)
    func secondProcessLeaseFollowsTheRetainedWriter(kind: OwnerKind) async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let probeURL = packageRoot
            .appendingPathComponent(".build/debug/HistoryRestartProbe")
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-store-lease-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let storeURL = storeRoot.appendingPathComponent("history.sqlite")

        // The helper returns only the selected owner. For the external cases
        // SQLiteHistory has already left scope, not merely lost a weak view.
        // Join startup maintenance before dropping the fixture's facade so
        // no background task hides release of the selected writer owner.
        var owner: RetainedOwner? = try await Self.makeOwner(kind, storeURL: storeURL)
        try withExtendedLifetime(owner) {
            try Self.runChild(
                phase: "openRejectLeasedStore",
                storeURL: storeURL,
                probeURL: probeURL,
                expectedOutput: "OPENREJECTLEASEDSTORE_OK\n"
            )
        }
        try await owner?.readAfterFacadeRelease(clientDirectory: storeRoot.appendingPathComponent("client"))
        owner = nil

        // This process remains alive. Reacquisition therefore proves actual
        // writer release, rather than the kernel's unconditional exit cleanup.
        try Self.runChild(
            phase: "leaseHold",
            storeURL: storeURL,
            probeURL: probeURL,
            expectedOutput: "LEASEHOLD_READY\nLEASEHOLD_OK\n"
        )
    }

    private static func makeOwner(_ kind: OwnerKind, storeURL: URL) async throws -> RetainedOwner {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .persistent(storeURL: storeURL)))
        if kind == .appIntentsFacade {
            let connection = try #require(try await history.connections().first { $0.enrollKind == .appIntents })
            try await history.grantCapability(.browse, to: connection.id)
        }
        await history.authority.waitForBlobCleanup()
        switch kind {
        case .history: return .history(history)
        case .appIntentsFacade: return .appIntents(history.makeAppIntentsHistoryFacade())
        case .localAutomationIngress: return .localAutomation(history.localAutomationIngress())
        }
    }

    private static func runChild(
        phase: String,
        storeURL: URL,
        probeURL: URL,
        expectedOutput: String
    ) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = probeURL
        process.arguments = [
            phase,
            storeURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS,
              result == Data(expectedOutput.utf8) else {
            throw FixtureError.childFailed
        }
    }
}
