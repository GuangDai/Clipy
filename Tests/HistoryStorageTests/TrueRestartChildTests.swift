/// Evidence Card 1C-1 plus the REVIEW §4.3 Retention-config restart tail —
/// public-open, normally terminated process tracers over one StoreRoot.
///
/// The normal restart paths leave every `ModelContainer`, model, facade, item
/// ID, and content manifest in a child process. The corruption-only retention
/// fixture temporarily owns a `ModelContainer` solely to create an impossible
/// stored shape between two terminated public-API probe owners. The
/// Package.swift test-target dependency guarantees the probe is already built;
/// the test launches the same `.build/debug` product convention used by the
/// existing migration-abort child, without nesting another SwiftPM process
/// inside `swift test`.
import Foundation
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("True child-process restart")
struct TrueRestartChildTests {
    private enum FixtureError: Error {
        case childFailed
    }

    private static func runChild(
        phase: String,
        storeURL: URL,
        probeURL: URL
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
        // Framework diagnostics can contain the store path. They are neither
        // evidence nor useful parent output, so keep the tracer channel fixed
        // and content-free.
        process.standardError = FileHandle.nullDevice

        try process.run()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        let expected = Data("\(phase.uppercased())_OK\n".utf8)
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS,
              result == expected else {
            throw FixtureError.childFailed
        }
    }

    private static func probeURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/HistoryRestartProbe")
    }

    private enum RetentionConfigDamage: CaseIterable {
        case malformedVersion
        case wrongKey

        var label: String {
            switch self {
            case .malformedVersion: "malformed-version"
            case .wrongKey: "wrong-key"
            }
        }

        var rejectionPhase: String {
            switch self {
            case .malformedVersion: "retentionRejectMalformed"
            case .wrongKey: "retentionRejectWrongKey"
            }
        }
    }

    private static func damageRetentionConfig(
        _ damage: RetentionConfigDamage,
        at storeURL: URL
    ) throws {
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: HistoryMigrationPlan.self,
            configurations: [ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let rows = try context.fetch(
            FetchDescriptor<RetentionExpansionConfigRow>()
        )
        let config = try #require(rows.first)
        #expect(rows.count == 1)
        switch damage {
        case .malformedVersion:
            config.configSchemaVersion = 2
        case .wrongKey:
            config.key = "wrong-retention-config"
        }
        try context.save()
    }

    @Test("seed, operate, and verify use three terminated owners")
    func seedOperateVerifyAcrossThreeProcesses() throws {
        let probeURL = Self.probeURL()
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-true-restart-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let storeURL = storeRoot.appendingPathComponent("history.store")

        try Self.runChild(
            phase: "seed",
            storeURL: storeURL,
            probeURL: probeURL
        )
        try Self.runChild(
            phase: "operate",
            storeURL: storeURL,
            probeURL: probeURL
        )
        try Self.runChild(
            phase: "verify",
            storeURL: storeURL,
            probeURL: probeURL
        )
    }

    /// Four sequential owners close the true-restart half of the frozen §4.3
    /// Retention singleton tail: A writes exact count + R1/R2/R3 values, B
    /// fresh-opens and reads them, C fresh-opens, rechecks, and updates them,
    /// and D fresh-opens and reads the updated values. Every child has
    /// normally terminated before the next starts; this proves reopen
    /// persistence, not migration, full-disk, SIGKILL, crash/power-loss, or
    /// external-storage durability.
    @Test("retention write, read, update, and read use four terminated owners")
    func retentionWriteReadUpdateReadAcrossFourProcesses() throws {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-retention-restart-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let storeURL = storeRoot.appendingPathComponent("history.store")
        let probeURL = Self.probeURL()
        for phase in [
            "retentionSeed",
            "retentionVerify",
            "retentionUpdate",
            "retentionVerifyUpdated",
        ] {
            try Self.runChild(
                phase: phase,
                storeURL: storeURL,
                probeURL: probeURL
            )
        }
    }

    /// This adds only the missing process boundary to the existing singleton
    /// validation matrix. A first child creates and configures a current V4
    /// store through public History actions, then terminates. The test fixture
    /// changes one stored scalar, and a second fresh child must receive the
    /// exact public-open failure. Same-process owner tests separately prove
    /// durable zero-repair; this test does not claim V1/V2 migration coverage.
    @Test("fresh owner rejects malformed and wrong-key retention configs")
    func malformedAndWrongKeyConfigsFailClosedAcrossProcesses() throws {
        let probeURL = Self.probeURL()
        for damage in RetentionConfigDamage.allCases {
            let storeRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "clipy-retention-reject-\(damage.label)-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: storeRoot,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: storeRoot) }

            let storeURL = storeRoot.appendingPathComponent("history.store")
            try Self.runChild(
                phase: "retentionSeed",
                storeURL: storeURL,
                probeURL: probeURL
            )
            try Self.damageRetentionConfig(damage, at: storeURL)
            try Self.runChild(
                phase: damage.rejectionPhase,
                storeURL: storeURL,
                probeURL: probeURL
            )
        }
    }
}
