/// Startup validation for an existing retention-expansion config singleton.
/// A correct key and cardinality do not make the row trusted: the complete
/// stored unit must pass the V2-02 §3.3 decoder before the facade is
/// published (05 §13). This is the same-process public-open wiring proof;
/// Card 1C's true child-process restart evidence remains a separate gate.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

struct RetentionConfigSingletonStartupValidationTests {
    private enum Corruption: CaseIterable {
        case olderSchemaVersion
        case newerSchemaVersion
        case positiveInfiniteAge
        case negativeInfiniteAge
        case ageBelowRange
        case ageAboveRange
        case storageBelowRange
        case storageAboveRange
        case enabledRevisionsWithoutThreshold
        case revisionCountBelowRange
        case revisionCountAboveRange
        case revisionBytesBelowRange
        case revisionBytesAboveRange

        var label: String {
            switch self {
            case .olderSchemaVersion: "schema-version-0"
            case .newerSchemaVersion: "schema-version-2"
            case .positiveInfiniteAge: "age-positive-infinity"
            case .negativeInfiniteAge: "age-negative-infinity"
            case .ageBelowRange: "age-below-range"
            case .ageAboveRange: "age-above-range"
            case .storageBelowRange: "storage-below-range"
            case .storageAboveRange: "storage-above-range"
            case .enabledRevisionsWithoutThreshold: "revision-enabled-without-threshold"
            case .revisionCountBelowRange: "revision-count-below-range"
            case .revisionCountAboveRange: "revision-count-above-range"
            case .revisionBytesBelowRange: "revision-bytes-below-range"
            case .revisionBytesAboveRange: "revision-bytes-above-range"
            }
        }

        var expectedFailure: HistoryFailure {
            switch self {
            case .olderSchemaVersion,
                 .newerSchemaVersion,
                 .positiveInfiniteAge,
                 .negativeInfiniteAge:
                .persistence(.corruptStoredValue)
            default:
                .persistence(.invariantViolation)
            }
        }

        func apply(to row: RetentionExpansionConfigRow) {
            switch self {
            case .olderSchemaVersion:
                row.configSchemaVersion = 0
            case .newerSchemaVersion:
                row.configSchemaVersion = 2
            case .positiveInfiniteAge:
                row.ageMaxSeconds = .infinity
            case .negativeInfiniteAge:
                row.ageMaxSeconds = -.infinity
            case .ageBelowRange:
                row.ageMaxSeconds = 0.5
            case .ageAboveRange:
                row.ageMaxSeconds = 315_360_001
            case .storageBelowRange:
                row.storageMaxBytes = 0
            case .storageAboveRange:
                row.storageMaxBytes = 2_013_265_920_001
            case .enabledRevisionsWithoutThreshold:
                row.revisionMaxCount = nil
                row.revisionMaxBytes = nil
            case .revisionCountBelowRange:
                row.revisionMaxCount = 0
            case .revisionCountAboveRange:
                row.revisionMaxCount = 101
            case .revisionBytesBelowRange:
                row.revisionMaxBytes = 0
            case .revisionBytesAboveRange:
                row.revisionMaxBytes = 268_435_457
            }
        }
    }

    private struct ConfigScalars: Equatable {
        let key: String
        let agePolicyEnabled: Bool
        let ageMaxSeconds: Double
        let storagePolicyEnabled: Bool
        let storageMaxBytes: Int
        let revisionPolicyEnabled: Bool
        let revisionMaxCount: Int?
        let revisionMaxBytes: Int?
        let configSchemaVersion: UInt16

        init(_ row: RetentionExpansionConfigRow) {
            key = row.key
            agePolicyEnabled = row.agePolicyEnabled
            ageMaxSeconds = row.ageMaxSeconds
            storagePolicyEnabled = row.storagePolicyEnabled
            storageMaxBytes = row.storageMaxBytes
            revisionPolicyEnabled = row.revisionPolicyEnabled
            revisionMaxCount = row.revisionMaxCount
            revisionMaxBytes = row.revisionMaxBytes
            configSchemaVersion = row.configSchemaVersion
        }
    }

    private struct SeededState {
        let config: ConfigScalars
        let itemID: UUID
    }

    private static func seedSingletons(
        at storeURL: URL,
        corruption: Corruption? = nil
    ) async throws -> SeededState {
        // Prepare immutable values before any ModelContext/@Model exists;
        // no SwiftData object survives a suspension point (05 §2).
        let seededItems = try await MigrationSeeding.makeSeededItems()
        let item = try #require(seededItems.first)
        let schema = Schema(versionedSchema: HistorySchemaV2.self)
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(LastChangePositionRow(
            key: "retained-history",
            rawValue: 17,
            maximumUnpinnedItems: 321
        ))
        let config = RetentionExpansionConfigRow(
            key: "retention-expansion",
            agePolicyEnabled: true,
            ageMaxSeconds: 86_400,
            storagePolicyEnabled: true,
            storageMaxBytes: 536_870_912,
            revisionPolicyEnabled: true,
            revisionMaxCount: 20,
            revisionMaxBytes: 16_777_216,
            configSchemaVersion: 1
        )
        corruption?.apply(to: config)
        context.insert(config)
        // One production-codec-valid item deliberately has no
        // RetainedBytesRow. Reaching the later startup projection bootstrap
        // would repair that missing derived row, so its continued absence
        // after config rejection is non-vacuous ordering evidence.
        context.insert(item.row)
        try context.save()
        return SeededState(config: ConfigScalars(config), itemID: item.id)
    }

    private static func fetchConfig(
        from context: ModelContext
    ) throws -> RetentionExpansionConfigRow {
        let rows = try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
        #expect(rows.count == 1)
        return try #require(rows.first)
    }

    @Test("invalid existing config fails before publication without repair")
    func invalidExistingConfigFailsClosedWithoutRepair() async throws {
        for corruption in Corruption.allCases {
            let storeURL = WSSupport.tempStoreURL(
                "config-singleton-corrupt-\(corruption.label)"
            )
            defer { WSSupport.removeStore(storeURL) }
            let seeded = try await Self.seedSingletons(
                at: storeURL,
                corruption: corruption
            )

            do {
                _ = try await SwiftDataHistory.open(
                    configuration: HistoryConfiguration(
                        persistence: .persistent(storeURL: storeURL),
                        initialMaximumUnpinnedItems: 200
                    )
                )
                Issue.record("\(corruption.label): expected startup failure")
            } catch let failure as HistoryFailure {
                #expect(failure == corruption.expectedFailure)
            } catch {
                Issue.record("\(corruption.label): unexpected error \(error)")
            }

            // Inspect through an independent container after the public open
            // failed. Startup must preserve both authoritative singletons and
            // must not insert any unrelated bootstrap row.
            let context = ModelContext(try WSSupport.makeContainer(storeURL: storeURL))
            let positions = try context.fetch(FetchDescriptor<LastChangePositionRow>())
            let position = try #require(positions.first)
            #expect(positions.count == 1)
            #expect(position.key == "retained-history")
            #expect(position.rawValue == 17)
            #expect(position.maximumUnpinnedItems == 321)
            #expect(ConfigScalars(try Self.fetchConfig(from: context)) == seeded.config)
            let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
            #expect(items.count == 1)
            #expect(items.first?.id == seeded.itemID)
            #expect(try context.fetchCount(FetchDescriptor<RetainedBytesRow>()) == 0)
        }
    }

    @Test("valid existing config is published and never replaced by defaults")
    func validExistingConfigIsPreserved() async throws {
        let storeURL = WSSupport.tempStoreURL("config-singleton-valid-existing")
        defer { WSSupport.removeStore(storeURL) }
        let seeded = try await Self.seedSingletons(at: storeURL)

        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL),
                initialMaximumUnpinnedItems: 200
            )
        )

        let published = try await history.retentionConfiguration()
        #expect(published.maximumUnpinnedItems == 321)
        #expect(published.policies == HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 86_400),
            storage: StorageRetention(maxTotalBytes: 536_870_912),
            revisions: RevisionRetention(
                maxRevisionsPerItem: 20,
                maxRevisionBytesPerItem: 16_777_216
            )
        ))

        let context = ModelContext(try WSSupport.makeContainer(storeURL: storeURL))
        #expect(ConfigScalars(try Self.fetchConfig(from: context)) == seeded.config)
        #expect(try context.fetchCount(FetchDescriptor<RetainedBytesRow>()) == 1)
    }
}
