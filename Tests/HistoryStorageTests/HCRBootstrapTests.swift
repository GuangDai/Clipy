/// DC-25 X-HCR bootstrap/startup validation and fixed-prefix compaction proofs.
/// Owning spec: `V2-03` §0.3 and the M1 total open order.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("X-HCR bootstrap and startup validation")
struct HCRBootstrapTests {
    private static let now = Date(
        timeIntervalSinceReferenceDate: 903_000_000
    )

    private struct FixedClock: StorageClock {
        let fixed: Date
        func now() -> Date { fixed }
    }

    @Test("real Authority startup creates the exact empty config after Gateway")
    func authorityStartupWiresBootstrap() async throws {
        let container = try Self.makeContainer()
        let authority = HistoryAuthority(
            container: container,
            storageClock: FixedClock(fixed: Self.now)
        )

        _ = try await authority.performStartup(initialMaximumUnpinnedItems: 200)

        let context = ModelContext(container)
        let configs = try context.fetch(FetchDescriptor<JournalConfigRow>())
        let config = try #require(configs.first)
        #expect(configs.count == 1)
        #expect(config.key == "change-journal")
        #expect(config.compactionFloorRaw == 0)
        #expect(config.journalBytes == 0)
        #expect(config.configSchemaVersion == 1)
        #expect(try context.fetchCount(
            FetchDescriptor<HistoryChangeRecordRow>()
        ) == 0)
    }

    @Test("Gateway validation failure occurs before absent HCR bootstrap")
    func gatewayValidationPrecedesHCRBootstrap() async throws {
        let container = try Self.makeContainer()
        let firstAuthority = HistoryAuthority(
            container: container,
            storageClock: FixedClock(fixed: Self.now)
        )
        _ = try await firstAuthority.performStartup(
            initialMaximumUnpinnedItems: 200
        )
        let context = ModelContext(container)
        let journal = try #require(
            context.fetch(FetchDescriptor<JournalConfigRow>()).first
        )
        let gateway = try #require(
            context.fetch(FetchDescriptor<GatewayConfigRow>()).first
        )
        context.delete(journal)
        gateway.configSchemaVersion = 2
        try context.save()

        await #expect(
            throws: HistoryFailure.persistence(.corruptStoredValue)
        ) {
            try await firstAuthority.performStartup(
                initialMaximumUnpinnedItems: 200
            )
        }
        let oracle = ModelContext(container)
        #expect(try oracle.fetchCount(FetchDescriptor<JournalConfigRow>()) == 0)
    }

    @Test("HCR validation failure occurs before legacy projection rebuild")
    func hcrValidationPrecedesProjectionRebuild() async throws {
        let container = try Self.makeContainer()
        let firstAuthority = HistoryAuthority(
            container: container,
            storageClock: FixedClock(fixed: Self.now)
        )
        _ = try await firstAuthority.performStartup(
            initialMaximumUnpinnedItems: 200
        )
        let prepared = try await IngestPreparationActor().prepare(
            WSSupport.textCapture("hcr-open-order", observedAt: Self.now)
        )
        _ = try await firstAuthority.commitCapture(prepared)

        let context = ModelContext(container)
        let journal = try #require(
            context.fetch(FetchDescriptor<JournalConfigRow>()).first
        )
        let item = try #require(
            context.fetch(FetchDescriptor<HistoryItemRow>()).first
        )
        journal.configSchemaVersion = 2
        item.projectionSchemaVersion = 1
        try context.save()

        await #expect(
            throws: HistoryFailure.persistence(.corruptStoredValue)
        ) {
            try await firstAuthority.performStartup(
                initialMaximumUnpinnedItems: 200
            )
        }
        let oracle = ModelContext(container)
        let storedItem = try #require(
            oracle.fetch(FetchDescriptor<HistoryItemRow>()).first
        )
        #expect(storedItem.projectionSchemaVersion == 1)
    }

    @Test("migrated position bootstraps as coverage floor without backfill")
    func migratedStoreStartsAtCurrentPosition() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(LastChangePositionRow(
            key: "retained-history",
            rawValue: 19,
            maximumUnpinnedItems: 200
        ))
        try context.save()

        try HCRBootstrap.ensureReady(in: context, now: Self.now)

        let config = try #require(
            context.fetch(FetchDescriptor<JournalConfigRow>()).first
        )
        #expect(config.compactionFloorRaw == 19)
        #expect(config.journalBytes == 0)
        #expect(try context.fetchCount(
            FetchDescriptor<HistoryChangeRecordRow>()
        ) == 0)
    }

    @Test("coherent retained suffix reopens unchanged")
    func coherentSuffixIsAccepted() throws {
        let fixture = try Self.makeSuffixFixture(position: 3, floor: 0)
        let before = try Self.snapshot(in: fixture.context)

        try HCRBootstrap.ensureReady(
            in: fixture.context,
            now: Self.now
        )

        #expect(try Self.snapshot(in: fixture.context) == before)
    }

    @Test("startup compacts only the fixed oldest prefix and revalidates")
    func startupPrefixCompaction() throws {
        let fixture = try Self.makeSuffixFixture(
            position: 3,
            floor: 0,
            createdAt: [
                Self.now.addingTimeInterval(-11),
                Self.now.addingTimeInterval(-5),
                Self.now,
            ]
        )
        let limits = JournalLimits(
            maxAffectedItemsPerRecord: 5_001,
            maxJournalRecordCount: 10,
            maxJournalAgeSeconds: 10,
            maxJournalBytes: 80,
            compactionCadenceCommits: 2
        )!

        try HCRBootstrap.ensureReady(
            in: fixture.context,
            now: Self.now,
            journalLimits: limits
        )

        let snapshot = try Self.snapshot(in: fixture.context)
        #expect(snapshot.floor == 1)
        #expect(snapshot.sequences == [2, 3])
        #expect(snapshot.journalBytes == 40)
    }

    @Test("failure inside age-prefix compaction commits no delete or floor change")
    func startupPrefixCompactionRollsBack() throws {
        struct InjectedFailure: Error {}
        let fixture = try Self.makeSuffixFixture(
            position: 3,
            floor: 0,
            createdAt: [
                Self.now.addingTimeInterval(-11),
                Self.now.addingTimeInterval(-5),
                Self.now,
            ]
        )
        let limits = JournalLimits(
            maxAffectedItemsPerRecord: 5_001,
            maxJournalRecordCount: 10,
            maxJournalAgeSeconds: 10,
            maxJournalBytes: 80,
            compactionCadenceCommits: 2
        )!
        let before = try Self.snapshot(in: fixture.context)

        #expect(throws: HistoryFailure.persistence(.transaction)) {
            try HCRBootstrap.ensureReady(
                in: fixture.context,
                now: Self.now,
                journalLimits: limits,
                compactionInjection: { throw InjectedFailure() }
            )
        }
        let independentContext = ModelContext(fixture.container)
        #expect(try Self.snapshot(in: independentContext) == before)
    }

    @Test("byte-over-cap durable state fails closed instead of startup repair")
    func byteCapViolationFailsClosed() throws {
        let fixture = try Self.makeSuffixFixture(position: 3, floor: 0)
        let limits = JournalLimits(
            maxAffectedItemsPerRecord: 5_001,
            maxJournalRecordCount: 10,
            maxJournalAgeSeconds: 10,
            maxJournalBytes: 40,
            compactionCadenceCommits: 2
        )!
        let before = try Self.snapshot(in: fixture.context)

        #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try HCRBootstrap.ensureReady(
                in: fixture.context,
                now: Self.now,
                journalLimits: limits
            )
        }
        #expect(try Self.snapshot(in: fixture.context) == before)
    }

    @Test("missing config with a surviving HCR fails without repair")
    func missingConfigWithRecordFailsClosed() throws {
        let fixture = try Self.makeSuffixFixture(position: 1, floor: 0)
        let config = try #require(
            fixture.context.fetch(FetchDescriptor<JournalConfigRow>()).first
        )
        fixture.context.delete(config)
        try fixture.context.save()
        let before = try Self.snapshot(in: fixture.context)

        #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try HCRBootstrap.ensureReady(in: fixture.context, now: Self.now)
        }
        #expect(try Self.snapshot(in: fixture.context) == before)
    }

    @Test("config scalar and retained interval corruption fail without repair")
    func corruptShapesFailClosed() throws {
        try Self.expectDamage(
            expected: .persistence(.invariantViolation)
        ) { config, _, _ in
            config.key = "wrong-journal"
        }
        try Self.expectDamage(
            expected: .persistence(.corruptStoredValue)
        ) { config, _, _ in
            config.configSchemaVersion = 2
        }
        try Self.expectDamage(
            expected: .persistence(.invariantViolation)
        ) { config, _, _ in
            config.compactionFloorRaw = 4
        }
        try Self.expectDamage(
            expected: .persistence(.invariantViolation)
        ) { config, _, _ in
            config.journalBytes += 1
        }
        try Self.expectDamage(
            expected: .persistence(.invariantViolation)
        ) { _, rows, context in
            context.delete(rows[1])
        }
        try Self.expectDamage(
            expected: .persistence(.invariantViolation)
        ) { _, rows, _ in
            rows[1].changePositionRaw = 99
        }
        try Self.expectDamage(
            expected: .persistence(.corruptStoredValue)
        ) { _, rows, _ in
            rows[1].changeKindRaw = 0
        }
        try Self.expectDamage(
            expected: .persistence(.corruptStoredValue)
        ) { _, rows, _ in
            rows[1].affectedItemsBlob = Data([0, 2, 0, 0])
        }
        try Self.expectDamage(
            expected: .persistence(.corruptStoredValue)
        ) { _, rows, _ in
            rows[1].createdAt = Date(
                timeIntervalSinceReferenceDate: .infinity
            )
        }
    }

    @Test("strict post-commit count cap rejects an impossible overflow")
    func countOverflowFailsBeforeCompaction() throws {
        let fixture = try Self.makeSuffixFixture(position: 3, floor: 0)
        let limits = JournalLimits(
            maxAffectedItemsPerRecord: 5_001,
            maxJournalRecordCount: 2,
            maxJournalAgeSeconds: 10,
            maxJournalBytes: 80 * 1_048_576,
            compactionCadenceCommits: 2
        )!
        let before = try Self.snapshot(in: fixture.context)

        #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try HCRBootstrap.ensureReady(
                in: fixture.context,
                now: Self.now,
                journalLimits: limits
            )
        }
        #expect(try Self.snapshot(in: fixture.context) == before)
    }

    @Test("surviving HCR facts prevent earlier singleton repair")
    func hcrFactsRejectMissingEarlierOwnersWithoutRepair() async throws {
        for damage in EarlierOwnerDamage.allCases {
            let container = try Self.makeContainer()
            let before: Snapshot
            do {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                if damage != .position {
                    Self.insertPosition(in: context)
                }
                if damage == .gateway {
                    Self.insertRetentionConfig(in: context)
                }
                try Self.insertHCRState(in: context)
                try context.save()
                before = try Self.snapshot(in: context)
            }
            let authority = HistoryAuthority(
                container: container,
                storageClock: FixedClock(fixed: Self.now)
            )

            await #expect(
                throws: HistoryFailure.persistence(.invariantViolation)
            ) {
                _ = try await authority.performStartup(
                    initialMaximumUnpinnedItems: 200
                )
            }

            let context = ModelContext(container)
            #expect(try Self.snapshot(in: context) == before)
        }
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
    }

    private struct Snapshot: Equatable {
        struct Position: Equatable {
            let key: String
            let rawValue: UInt64
            let maximumUnpinnedItems: Int
        }

        let positions: [Position]
        let retentionConfigCount: Int
        let gatewayConfigCount: Int
        let connectionCount: Int
        let configCount: Int
        let floor: UInt64?
        let journalBytes: UInt64?
        let sequences: [UInt64]
        let rowBytes: [Data]
    }

    private enum EarlierOwnerDamage: CaseIterable, Equatable {
        case position
        case retention
        case gateway
    }

    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
    }

    private static func makeSuffixFixture(
        position: UInt64,
        floor: UInt64,
        createdAt: [Date]? = nil
    ) throws -> Fixture {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(LastChangePositionRow(
            key: "retained-history",
            rawValue: position,
            maximumUnpinnedItems: 200
        ))
        var journalBytes: UInt64 = 0
        if floor < position {
            for sequence in (floor + 1)...position {
                let blob = try AffectedItemsBlobCodec.encode(
                    [itemID(Int(sequence))],
                    for: .insert
                )
                journalBytes += UInt64(blob.count)
                let date = createdAt?[Int(sequence - floor - 1)] ?? Self.now
                context.insert(HistoryChangeRecordRow(
                    sequence: sequence,
                    changePositionRaw: sequence,
                    changeKindRaw: HistoryChangeKindRawV1.insert.rawValue,
                    affectedItemsBlob: blob,
                    createdAt: date
                ))
            }
        }
        context.insert(JournalConfigRow(
            key: "change-journal",
            compactionFloorRaw: floor,
            journalBytes: journalBytes,
            configSchemaVersion: 1
        ))
        try context.save()
        return Fixture(container: container, context: context)
    }

    private static func expectDamage(
        expected: HistoryFailure,
        mutate: (
            JournalConfigRow,
            [HistoryChangeRecordRow],
            ModelContext
        ) throws -> Void
    ) throws {
        let fixture = try makeSuffixFixture(position: 3, floor: 0)
        let config = try #require(
            fixture.context.fetch(FetchDescriptor<JournalConfigRow>()).first
        )
        let rows = try fixture.context.fetch(FetchDescriptor<
            HistoryChangeRecordRow
        >(sortBy: [SortDescriptor(\.sequence)]))
        try mutate(config, rows, fixture.context)
        try fixture.context.save()
        let before = try snapshot(in: fixture.context)

        #expect(throws: expected) {
            try HCRBootstrap.ensureReady(in: fixture.context, now: Self.now)
        }
        #expect(try snapshot(in: fixture.context) == before)
    }

    private static func snapshot(in context: ModelContext) throws -> Snapshot {
        let positions = try context.fetch(FetchDescriptor<LastChangePositionRow>())
        let configs = try context.fetch(FetchDescriptor<JournalConfigRow>())
        let rows = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>(
            sortBy: [SortDescriptor(\.sequence)]
        ))
        return Snapshot(
            positions: positions.map {
                Snapshot.Position(
                    key: $0.key,
                    rawValue: $0.rawValue,
                    maximumUnpinnedItems: $0.maximumUnpinnedItems
                )
            },
            retentionConfigCount: try context.fetchCount(
                FetchDescriptor<RetentionExpansionConfigRow>()
            ),
            gatewayConfigCount: try context.fetchCount(
                FetchDescriptor<GatewayConfigRow>()
            ),
            connectionCount: try context.fetchCount(
                FetchDescriptor<ConnectionRow>()
            ),
            configCount: configs.count,
            floor: configs.first?.compactionFloorRaw,
            journalBytes: configs.first?.journalBytes,
            sequences: rows.map(\.sequence),
            rowBytes: rows.map(\.affectedItemsBlob)
        )
    }

    private static func insertPosition(in context: ModelContext) {
        context.insert(LastChangePositionRow(
            key: HistoryAuthority.positionSingletonKey,
            rawValue: 1,
            maximumUnpinnedItems: 200
        ))
    }

    private static func insertRetentionConfig(in context: ModelContext) {
        context.insert(RetentionExpansionConfigRow(
            key: HistoryAuthority.retentionExpansionConfigKey,
            agePolicyEnabled: false,
            ageMaxSeconds: 0,
            storagePolicyEnabled: false,
            storageMaxBytes: 0,
            revisionPolicyEnabled: false,
            revisionMaxCount: nil,
            revisionMaxBytes: nil,
            configSchemaVersion: HistoryAuthority.retentionConfigSchemaVersion
        ))
    }

    private static func insertHCRState(in context: ModelContext) throws {
        let blob = try AffectedItemsBlobCodec.encode(
            [itemID(901)],
            for: .insert
        )
        context.insert(HistoryChangeRecordRow(
            sequence: 1,
            changePositionRaw: 1,
            changeKindRaw: HistoryChangeKindRawV1.insert.rawValue,
            affectedItemsBlob: blob,
            createdAt: now
        ))
        context.insert(JournalConfigRow(
            key: HCRBootstrap.configKey,
            compactionFloorRaw: 0,
            journalBytes: UInt64(blob.count),
            configSchemaVersion: HCRBootstrap.configSchemaVersion
        ))
    }

    private static func itemID(_ value: Int) -> HistoryItemID {
        let raw = UInt64(value).bigEndian
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: raw) { rawBytes in
            bytes.replaceSubrange(8..<16, with: rawBytes)
        }
        return HistoryItemID(rawValue: UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }
}
