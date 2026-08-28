/// DATA-14 / REVIEW 05 §7 Q13 open-failure characterization — one fresh
/// public `SwiftDataHistory.open` owner per impossible store, each shaped by
/// the test process before its child launches.
///
/// What this pins: the CURRENT actual thrown classification of the public
/// open path (03b §10 typed-failure vocabulary) for (a) a store created at a
/// strictly future schema — one additive model beyond the shipped immutable
/// V4 (`HistorySchemaV4`, DC-25), unreachable by `HistoryMigrationPlan`
/// (`V2-02` §3.3 stage topology tops out at V4) — and (b) a fixed non-SQLite
/// byte literal at the store path. `SwiftDataHistory.open` maps every
/// `ModelContainer` construction failure to one `.persistence(.openStore)`;
/// whether those root causes are separable is exactly the open question, so
/// both children assert the SAME typed outcome and freeze today's flattened
/// behavior as evidence. DATA-14's constraint stays in force: on an
/// unclassified `.openStore` a recovery surface may offer Retry/Reveal and
/// user-confirmed recovery only — never automatic quarantine or silent
/// empty-store recreation.
///
/// What this does NOT prove: no claim that the two root causes are, or must
/// remain, distinguishable; no permission, ENOSPC, transient-I/O, WAL,
/// sidecar, or partial-corruption coverage; no migration-stage error or
/// downgrade characterization beyond "construction refuses"; no recovery-UX,
/// quarantine, or StoreRoot-move decision (REVIEW 05 §7 Q14 gates those on a
/// classification proof); no crash or durability claim. The children assert
/// only the public typed outcome, never an underlying platform error chain.
///
/// The future-schema fixture briefly owns a `ModelContainer` inside the TEST
/// process — the same temporary-fixture stance as the REVIEW §4.3 retention
/// damage fixture (`TrueRestartChildTests`) — and every observation is made
/// by a fresh, normally terminated probe child through the production public
/// facade. The `Package.swift` test-target dependency guarantees the probe is
/// already built; no SwiftPM process is nested inside `swift test`.
import Foundation
import SwiftData
import Testing
@testable import HistoryStorage

/// One additive model beyond the shipped immutable V4
/// (`HistoryChangeJournalSchema`, DC-25): exactly the shape a NEWER Clipy
/// build would leave behind for this build. Test-fixture only — the product
/// never sees this type, and no shipped schema is edited.
@Model
internal final class FutureOnlyRow {
    var futureMarker: Int = 0

    init() {}
}

/// The strictly-future schema the seeding container writes: the shipped V4
/// model set plus exactly one new row, versioned at 5.0.0 so
/// `HistoryMigrationPlan` has no stage that can reach it. Reusing internal
/// `HistorySchemaV4.models` (via `@testable`) keeps the fixture exactly one
/// additive model away from production reality instead of a divergent
/// hand-written model list.
internal enum FutureSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        HistorySchemaV4.models + [FutureOnlyRow.self]
    }
}

@Suite("Public open-failure classification child characterization")
struct StoreOpenFailureCharacterizationTests {
    private enum FixtureError: Error {
        case childFailed(phase: String)
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
        // Framework diagnostics can contain the store path, and any stderr
        // line carrying "error:" fails CI through `scripts/diagnostic_scan.py`
        // (DATA-14 keeps the evidence channel typed and content-free instead).
        process.standardError = FileHandle.nullDevice

        try process.run()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        let expected = Data("\(phase.uppercased())_OK\n".utf8)
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS,
              result == expected else {
            // Phase-tagged (not termination-detail-tagged) so the message can
            // never carry a scanner-sensitive "error:" fragment; which fixture
            // failed is the fact the Red→Green table needs first.
            throw FixtureError.childFailed(phase: phase)
        }
    }

    private static func probeURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/HistoryRestartProbe")
    }

    /// Seeds the future-schema store inside the TEST process only: one
    /// container at `FutureSchemaV5`, no migration plan, released with this
    /// scope so the only later owner of the store is the fresh probe child.
    /// Store creation is synchronous inside `ModelContainer.init`; one
    /// `FutureOnlyRow` is also inserted and saved so the store carries a
    /// MATERIALIZED extra entity — the fixture then fails V4 open through
    /// both the version metadata AND the un-migratable table, without
    /// depending on creation-time metadata bookkeeping alone.
    private static func seedFutureSchemaStore(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: FutureSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(container)
        context.insert(FutureOnlyRow())
        try context.save()
        // No container, model, or context crosses into the probe. The
        // locals leave scope with the function; the on-disk fixture — the
        // saved V5 row — is what outlives it. (An explicit lifetime
        // extension would only matter for work scheduled past this scope,
        // and none is: construction and save are synchronous.)
    }

    @Test("fresh owner maps a future-schema store to the public open failure")
    func futureSchemaStoreFailsOpenInFreshChild() throws {
        let probeURL = Self.probeURL()
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-open-reject-future-schema-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let storeURL = storeRoot.appendingPathComponent("history.store")

        try Self.seedFutureSchemaStore(at: storeURL)
        // The fixture is a real on-disk store, not an in-memory artifact:
        // the fresh child must be the process that refuses it.
        #expect(FileManager.default.fileExists(atPath: storeURL.path))

        try Self.runChild(
            phase: "openRejectFutureSchema",
            storeURL: storeURL,
            probeURL: probeURL
        )
    }

    @Test("fresh owner maps non-SQLite store bytes to the public open failure")
    func corruptBytesStoreFailsOpenInFreshChild() throws {
        let probeURL = Self.probeURL()
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-open-reject-corrupt-bytes-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let storeURL = storeRoot.appendingPathComponent("history.store")

        // Fixed literal, 19 bytes per repetition × 256 repetitions = 4_864
        // bytes of a repeated non-SQLite ASCII pattern. Never zero bytes —
        // SQLite treats a zero-byte file as a valid empty store, which would
        // let open succeed and silently destroy the fixture's point.
        let corruptBytes = Data(
            String(repeating: "not-a-sqlite-store/", count: 256).utf8
        )
        #expect(corruptBytes.count == 4_864)
        try corruptBytes.write(to: storeURL, options: .atomic)
        // The on-disk fixture is the bytes actually at the store path (the
        // symmetric read-back of the future-schema fixture's fileExists).
        #expect(try Data(contentsOf: storeURL) == corruptBytes)

        try Self.runChild(
            phase: "openRejectCorruptBytes",
            storeURL: storeURL,
            probeURL: probeURL
        )
    }
}
