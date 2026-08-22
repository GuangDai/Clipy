/// DATA-1 startup-shape proofs (`05` §13; deep review Card 1A-1).
///
/// The production seam is a persistent `SwiftDataHistory.open`: each fixture
/// first creates a real V2 store and captures one item through the public
/// boundary, then an independent container damages only one singleton shape.
/// A second public open must reject the shape. A fresh independent inspector
/// compares durable singleton, item/blob, and retained-byte values before and
/// after that rejection; this is a durable-value oracle, not instrumentation
/// claiming that no framework transaction was attempted.
/// This is a same-process reopen proof; coordinator teardown in a true child
/// process remains Card 1C evidence rather than an implied claim here.
///
/// The absent-config shape is deliberately not claimed here. After migration
/// has completed, a genuine V1 -> V2 store awaiting its documented config
/// bootstrap and an existing V2 store whose config was deleted have the same
/// persisted rows. Without migration provenance, startup cannot distinguish
/// those causes while preserving the real V1 migration path; wrong-key and
/// extra-row shapes remain unambiguous and are closed below. The same ceiling
/// applies to an existing, user-cleared V2 store after both singleton rows are
/// deleted: its four-table empty shape is indistinguishable from a fresh
/// store. DATA-1 therefore remains partial until provenance is approved.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Authoritative singleton startup shape (DATA-1)")
struct SingletonShapeStartupClassifierTests {
    private enum Damage: CaseIterable {
        case deletePosition
        case wrongKeyPosition
        case extraWrongKeyPosition
        case wrongKeyConfig
        case extraWrongKeyConfig

        var label: String {
            switch self {
            case .deletePosition: "missing-position"
            case .wrongKeyPosition: "wrong-key-position"
            case .extraWrongKeyPosition: "extra-wrong-key-position"
            case .wrongKeyConfig: "wrong-key-config"
            case .extraWrongKeyConfig: "extra-wrong-key-config"
            }
        }
    }

    private struct PositionSnapshot: Equatable {
        let key: String
        let rawValue: UInt64
        let maximumUnpinnedItems: Int

        init(_ row: LastChangePositionRow) {
            key = row.key
            rawValue = row.rawValue
            maximumUnpinnedItems = row.maximumUnpinnedItems
        }
    }

    private struct ConfigSnapshot: Equatable {
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

    private struct ItemSnapshot: Equatable {
        let id: UUID
        let contentVersionRaw: UInt64
        let canonicalBlob: Data
        let revisionStateBlob: Data
        let canonicalSignatureBlob: Data

        init(_ row: HistoryItemRow) {
            id = row.id
            contentVersionRaw = row.contentVersionRaw
            canonicalBlob = row.canonicalBlob
            revisionStateBlob = row.revisionStateBlob
            canonicalSignatureBlob = row.canonicalSignatureBlob
        }
    }

    private struct RetainedBytesSnapshot: Equatable {
        let itemID: UUID
        let canonicalBytes: Int
        let revisionCount: Int
        let revisionBytes: Int
        let bytesSchemaVersion: UInt16

        init(_ row: RetainedBytesRow) {
            itemID = row.itemID
            canonicalBytes = row.canonicalBytes
            revisionCount = row.revisionCount
            revisionBytes = row.revisionBytes
            bytesSchemaVersion = row.bytesSchemaVersion
        }
    }

    private struct StoreSnapshot: Equatable {
        let positions: [PositionSnapshot]
        let configs: [ConfigSnapshot]
        let items: [ItemSnapshot]
        let retainedBytes: [RetainedBytesSnapshot]
    }

    private static func makeContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HistorySchemaV2.self)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
    }

    private static func seedExistingV2(at storeURL: URL) async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL),
                initialMaximumUnpinnedItems: 321
            )
        )
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "singleton-shape",
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )))
    }

    private static func damage(_ damage: Damage, at storeURL: URL) throws {
        let context = ModelContext(try makeContainer(at: storeURL))
        context.autosaveEnabled = false
        let positions = try context.fetch(FetchDescriptor<LastChangePositionRow>())
        let position = try #require(positions.first)
        let configs = try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
        let config = try #require(configs.first)

        switch damage {
        case .deletePosition:
            context.delete(position)
        case .wrongKeyPosition:
            position.key = "wrong-position"
        case .extraWrongKeyPosition:
            context.insert(LastChangePositionRow(
                key: "wrong-position",
                rawValue: 41,
                maximumUnpinnedItems: 444
            ))
        case .wrongKeyConfig:
            config.key = "wrong-config"
        case .extraWrongKeyConfig:
            context.insert(RetentionExpansionConfigRow(
                key: "wrong-config",
                agePolicyEnabled: true,
                ageMaxSeconds: 86_400,
                storagePolicyEnabled: false,
                storageMaxBytes: 0,
                revisionPolicyEnabled: false,
                revisionMaxCount: nil,
                revisionMaxBytes: nil,
                configSchemaVersion: 1
            ))
        }
        try context.save()
    }

    private static func snapshot(at storeURL: URL) throws -> StoreSnapshot {
        let context = ModelContext(try makeContainer(at: storeURL))
        let positions = try context.fetch(FetchDescriptor<LastChangePositionRow>())
            .map(PositionSnapshot.init)
            .sorted { $0.key < $1.key }
        let configs = try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
            .map(ConfigSnapshot.init)
            .sorted { $0.key < $1.key }
        let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
            .map(ItemSnapshot.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let retainedBytes = try context.fetch(FetchDescriptor<RetainedBytesRow>())
            .map(RetainedBytesSnapshot.init)
            .sorted { $0.itemID.uuidString < $1.itemID.uuidString }
        return StoreSnapshot(
            positions: positions,
            configs: configs,
            items: items,
            retainedBytes: retainedBytes
        )
    }

    @Test("non-fresh singleton corruption is rejected without durable mutation")
    func nonFreshSingletonCorruptionIsRejectedWithoutDurableMutation() async throws {
        for damage in Damage.allCases {
            let storeURL = WSSupport.tempStoreURL(
                "singleton-shape-\(damage.label)"
            )
            defer { WSSupport.removeStore(storeURL) }
            try await Self.seedExistingV2(at: storeURL)
            try Self.damage(damage, at: storeURL)
            let before = try Self.snapshot(at: storeURL)

            do {
                _ = try await SwiftDataHistory.open(
                    configuration: HistoryConfiguration(
                        persistence: .persistent(storeURL: storeURL),
                        initialMaximumUnpinnedItems: 200
                    )
                )
                Issue.record("\(damage.label): expected startup rejection")
            } catch let failure as HistoryFailure {
                #expect(
                    failure == .persistence(.invariantViolation),
                    "\(damage.label): wrong typed failure \(failure)"
                )
            } catch {
                Issue.record("\(damage.label): unexpected error \(error)")
            }

            let after = try Self.snapshot(at: storeURL)
            #expect(
                after == before,
                "\(damage.label): rejected startup must not repair or mutate durable state"
            )
        }
    }
}
