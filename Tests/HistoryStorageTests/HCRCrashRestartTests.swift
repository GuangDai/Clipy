/// X-HCR.2 / V2-WS-J1-5 crash-after-success proof.
///
/// Child A seeds, child B receives a committed coalesce and then terminates by
/// an intentional fatal signal, and child C fresh-opens through the public
/// facade. Only after every child has terminated does this test inspect the V4
/// HCR rows, config, and position with an assertion-only container.
import Foundation
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("HCR crash restart")
struct HCRCrashRestartTests {
    private enum FixtureError: Error {
        case childFailed
        case childDidNotCrash
    }

    @Test("commit survives abnormal child termination with exact HCR head")
    func committedChildCrashReopensConsistently() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let probeURL = packageRoot
            .appendingPathComponent(".build/debug/HistoryRestartProbe")
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-hcr-crash-restart-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let storeURL = storeRoot.appendingPathComponent("history.store")

        try Self.runSuccessfulChild(
            phase: "seed",
            storeURL: storeURL,
            probeURL: probeURL
        )
        try Self.runCrashingChild(
            storeURL: storeURL,
            probeURL: probeURL
        )
        try Self.runSuccessfulChild(
            phase: "verify",
            storeURL: storeURL,
            probeURL: probeURL
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let position = try #require(
            context.fetch(FetchDescriptor<LastChangePositionRow>()).first
        )
        let config = try #require(
            context.fetch(FetchDescriptor<JournalConfigRow>()).first
        )
        let records = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>(
            sortBy: [SortDescriptor(\.sequence)]
        ))
        #expect(position.rawValue == 3)
        #expect(config.key == HCRBootstrap.configKey)
        #expect(config.compactionFloorRaw == 0)
        #expect(config.configSchemaVersion == HCRBootstrap.configSchemaVersion)
        #expect(records.map(\.sequence) == [1, 2, 3])
        #expect(records.map(\.changePositionRaw) == [1, 2, 3])
        #expect(records.map(\.changeKindRaw) == [
            HistoryChangeKindRawV1.insert.rawValue,
            HistoryChangeKindRawV1.insert.rawValue,
            HistoryChangeKindRawV1.coalesce.rawValue,
        ])
        var exactBytes: UInt64 = 0
        for row in records {
            let kind = try #require(
                HistoryChangeKindRawV1(rawValue: row.changeKindRaw)
            )
            _ = try AffectedItemsBlobCodec.decode(
                row.affectedItemsBlob,
                for: kind
            )
            let (next, overflow) = exactBytes.addingReportingOverflow(
                UInt64(row.affectedItemsBlob.count)
            )
            #expect(!overflow)
            exactBytes = next
        }
        #expect(config.journalBytes == exactBytes)
    }

    private static func runSuccessfulChild(
        phase: String,
        storeURL: URL,
        probeURL: URL
    ) throws {
        let process = Self.makeProcess(
            phase: phase,
            storeURL: storeURL,
            probeURL: probeURL
        )
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS,
              result == Data("\(phase.uppercased())_OK\n".utf8) else {
            throw FixtureError.childFailed
        }
    }

    private static func runCrashingChild(
        storeURL: URL,
        probeURL: URL
    ) throws {
        let process = Self.makeProcess(
            phase: "crashCommit",
            storeURL: storeURL,
            probeURL: probeURL
        )
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .uncaughtSignal else {
            throw FixtureError.childDidNotCrash
        }
    }

    private static func makeProcess(
        phase: String,
        storeURL: URL,
        probeURL: URL
    ) -> Process {
        let process = Process()
        process.executableURL = probeURL
        process.arguments = [phase, storeURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}
