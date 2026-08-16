/// M1.4 / DC-02 proof (`V2-roadmap` §5 M1.2–M1.4; `V2-02` §3.3 Stage
/// topology, Record 5, `RET-PLATFORM-1b`): the single custom `V1 → V2` hop
/// migrates an on-disk v1 store byte-identically while backfilling the exact
/// `RetainedBytesRow` projection, `open` bootstraps (never migrates) the
/// all-disabled config singleton, and the backfill is idempotent by
/// construction.
///
/// Valid v1 payloads are built through the production preparation/stamping
/// helpers — `IngestPreparationActor.prepare` (the §6.1 normalized capture
/// pipeline) for Canonical/signature/projection values, and the production
/// codecs (`CanonicalBlobCodec`, `SignatureBlobCodec`,
/// `RevisionStateBlobCodec`, `EffectiveTypeIdentifiersBlobCodec`) for the
/// durable blobs — mirroring `ProjectionCorruptionTests.seedRow`; no blob is
/// hand-crafted. Expected scalars are recomputed in the test through the
/// same codecs from the migrated rows (`RET-PLATFORM-1b(b)`) and
/// cross-checked against literal fixture-byte arithmetic.
///
/// On-disk temp stores create their directories upfront per AGENTS §6 (via
/// `WSSupport.tempStoreURL`).
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("V1 → V2 migration (M1.4, DC-02)")
struct HistoryMigrationTests {

    // MARK: - Fixtures

    /// One seeded v1 item: the insertable durable row plus the pre-migration
    /// copies and expected byte-projection scalars.
    private struct SeededItem {
        let row: HistoryItemRow
        let id: UUID
        let contentVersionRaw: UInt64
        let canonicalBlob: Data
        let revisionStateBlob: Data
        let canonicalSignatureBlob: Data
        let expectedCanonicalBytes: Int
        let expectedRevisionCount: Int
        let expectedRevisionBytes: Int
    }

    /// Builds three valid v1 items through the production preparation
    /// pipeline: A (single text representation, Canonical state), B (text +
    /// PNG Canonical with TWO stored revisions — the revision-bearing shape),
    /// and C (single text representation, Canonical state). Item B's
    /// revision list is encoded through the production
    /// `RevisionStateBlobCodec.encode(revisions:activeRevisionID:)` from
    /// Domain values, exactly as the commit stamper would stamp two appends.
    private static func makeSeededItems() async throws -> [SeededItem] {
        let ingest = IngestPreparationActor()
        let source = "com.example.migration"
        let observedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)

        let textAlpha = "migration item alpha"
        let alphaBundle = try await ingest.prepare(
            WSSupport.textCapture(textAlpha, observedAt: observedAt, source: source)
        )
        let alphaRow = try HistoryItemRow(
            id: alphaBundle.domain.candidateID.rawValue,
            contentVersionRaw: 1,
            canonicalBlob: CanonicalBlobCodec.encode(alphaBundle.domain.canonical),
            revisionStateBlob: RevisionStateBlobCodec.encode(
                revisions: [],
                activeRevisionID: nil
            ),
            canonicalSignatureBlob: SignatureBlobCodec.encode(alphaBundle.signatureEntries),
            projectionSchemaVersion: alphaBundle.projection.schemaVersion,
            title: alphaBundle.projection.title,
            searchBody: alphaBundle.projection.searchBody,
            effectiveTypeIdentifiersBlob: EffectiveTypeIdentifiersBlobCodec.encode(
                alphaBundle.projection.effectiveTypeIdentifiers
            ),
            firstCopiedAt: observedAt,
            lastCopiedAt: observedAt,
            copyCount: 1,
            firstSource: source,
            lastSource: source,
            pinOrdinal: nil
        )

        let textBeta = "migration item beta body"
        let betaPNGBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]
        let betaBundle = try await ingest.prepare(
            WSSupport.textCapture(
                textBeta,
                observedAt: observedAt,
                source: source,
                extra: [("public.png", betaPNGBytes)]
            )
        )
        let betaRevisionOneText = "beta revision one"
        let betaRevisionTwoText = "beta revision two body"
        let betaRevisionOne = ContentRevision(
            id: RevisionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_001),
            content: EffectiveContent(representations: [
                ContentRepresentation(
                    typeIdentifier: "public.utf8-plain-text",
                    bytes: Data(betaRevisionOneText.utf8)
                )
            ])
        )
        let betaRevisionTwo = ContentRevision(
            id: RevisionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_002),
            content: EffectiveContent(representations: [
                ContentRepresentation(
                    typeIdentifier: "public.utf8-plain-text",
                    bytes: Data(betaRevisionTwoText.utf8)
                )
            ])
        )
        let betaRevisionBlob = try RevisionStateBlobCodec.encode(
            revisions: [betaRevisionOne, betaRevisionTwo],
            activeRevisionID: betaRevisionTwo.id
        )
        // Two appends over the initial version: Content Version 3.
        let betaRow = try HistoryItemRow(
            id: betaBundle.domain.candidateID.rawValue,
            contentVersionRaw: 3,
            canonicalBlob: CanonicalBlobCodec.encode(betaBundle.domain.canonical),
            revisionStateBlob: betaRevisionBlob,
            canonicalSignatureBlob: SignatureBlobCodec.encode(betaBundle.signatureEntries),
            projectionSchemaVersion: betaBundle.projection.schemaVersion,
            title: betaBundle.projection.title,
            searchBody: betaBundle.projection.searchBody,
            effectiveTypeIdentifiersBlob: EffectiveTypeIdentifiersBlobCodec.encode(
                betaBundle.projection.effectiveTypeIdentifiers
            ),
            firstCopiedAt: observedAt,
            lastCopiedAt: observedAt,
            copyCount: 1,
            firstSource: source,
            lastSource: source,
            pinOrdinal: nil
        )

        let textGamma = "migration item gamma"
        let gammaBundle = try await ingest.prepare(
            WSSupport.textCapture(textGamma, observedAt: observedAt, source: source)
        )
        let gammaRow = try HistoryItemRow(
            id: gammaBundle.domain.candidateID.rawValue,
            contentVersionRaw: 1,
            canonicalBlob: CanonicalBlobCodec.encode(gammaBundle.domain.canonical),
            revisionStateBlob: RevisionStateBlobCodec.encode(
                revisions: [],
                activeRevisionID: nil
            ),
            canonicalSignatureBlob: SignatureBlobCodec.encode(gammaBundle.signatureEntries),
            projectionSchemaVersion: gammaBundle.projection.schemaVersion,
            title: gammaBundle.projection.title,
            searchBody: gammaBundle.projection.searchBody,
            effectiveTypeIdentifiersBlob: EffectiveTypeIdentifiersBlobCodec.encode(
                gammaBundle.projection.effectiveTypeIdentifiers
            ),
            firstCopiedAt: observedAt,
            lastCopiedAt: observedAt,
            copyCount: 1,
            firstSource: source,
            lastSource: source,
            pinOrdinal: nil
        )

        return [
            SeededItem(
                row: alphaRow,
                id: alphaRow.id,
                contentVersionRaw: alphaRow.contentVersionRaw,
                canonicalBlob: alphaRow.canonicalBlob,
                revisionStateBlob: alphaRow.revisionStateBlob,
                canonicalSignatureBlob: alphaRow.canonicalSignatureBlob,
                // Literal fixture arithmetic (independent of the codecs):
                // one text representation, empty revision list.
                expectedCanonicalBytes: Data(textAlpha.utf8).count,
                expectedRevisionCount: 0,
                expectedRevisionBytes: 0
            ),
            SeededItem(
                row: betaRow,
                id: betaRow.id,
                contentVersionRaw: betaRow.contentVersionRaw,
                canonicalBlob: betaRow.canonicalBlob,
                revisionStateBlob: betaRow.revisionStateBlob,
                canonicalSignatureBlob: betaRow.canonicalSignatureBlob,
                // text + PNG Canonical; two text revisions.
                expectedCanonicalBytes: Data(textBeta.utf8).count + betaPNGBytes.count,
                expectedRevisionCount: 2,
                expectedRevisionBytes: Data(betaRevisionOneText.utf8).count
                    + Data(betaRevisionTwoText.utf8).count
            ),
            SeededItem(
                row: gammaRow,
                id: gammaRow.id,
                contentVersionRaw: gammaRow.contentVersionRaw,
                canonicalBlob: gammaRow.canonicalBlob,
                revisionStateBlob: gammaRow.revisionStateBlob,
                canonicalSignatureBlob: gammaRow.canonicalSignatureBlob,
                expectedCanonicalBytes: Data(textGamma.utf8).count,
                expectedRevisionCount: 0,
                expectedRevisionBytes: 0
            )
        ]
    }

    /// Seeds a complete v1 store (items + position singleton) into `context`
    /// and returns the pre-migration copies.
    private static func seedV1Store(into context: ModelContext) async throws -> [SeededItem] {
        let items = try await makeSeededItems()
        for item in items {
            context.insert(item.row)
        }
        context.insert(LastChangePositionRow(
            key: HistoryAuthority.positionSingletonKey,
            rawValue: 3,
            maximumUnpinnedItems: 200
        ))
        try context.save()
        return items
    }

    /// An old-schema (v1, no migration plan) container over the store URL.
    private static func makeV1Container(storeURL: URL) throws -> ModelContainer {
        try ModelContainer(
            for: v1Schema,
            configurations: [ModelConfiguration(schema: v1Schema, url: storeURL)]
        )
    }

    /// A migration-plan container over the same URL: the V2 schema plus
    /// `HistoryMigrationPlan` — the exact construction `SwiftDataHistory.open`
    /// step 2 performs.
    private static func makeMigrationContainer(storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HistorySchemaV2.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: HistoryMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
    }

    /// One comparable `RetainedBytesRow` projection snapshot.
    private struct RetainedBytesSnapshot: Equatable {
        let itemID: UUID
        let canonicalBytes: Int
        let revisionCount: Int
        let revisionBytes: Int
        let bytesSchemaVersion: UInt16
    }

    /// Every `RetainedBytesRow`, deterministically ordered by item ID.
    private static func bytesSnapshots(_ context: ModelContext) throws -> [RetainedBytesSnapshot] {
        try context.fetch(FetchDescriptor<RetainedBytesRow>())
            .map {
                RetainedBytesSnapshot(
                    itemID: $0.itemID,
                    canonicalBytes: $0.canonicalBytes,
                    revisionCount: $0.revisionCount,
                    revisionBytes: $0.revisionBytes,
                    bytesSchemaVersion: $0.bytesSchemaVersion
                )
            }
            .sorted { $0.itemID.uuidString < $1.itemID.uuidString }
    }

    /// Independently recomputes the byte projection of one durable row
    /// through the same production codecs (`RET-PLATFORM-1b(b)`), WITHOUT
    /// touching the backfill under test.
    private static func recomputedScalars(
        for row: HistoryItemRow
    ) throws -> (canonicalBytes: Int, revisionCount: Int, revisionBytes: Int) {
        let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
        let entries = try SignatureBlobCodec.decode(row.canonicalSignatureBlob)
        let state = try RevisionStateBlobCodec.decode(
            row.revisionStateBlob,
            canonical: canonical
        )
        let canonicalBytes = entries.reduce(0) { $0 + $1.byteCount }
        let revisionBytes = state.revisions.reduce(0) { total, revision in
            revision.content.representations.reduce(total) { $0 + $1.bytes.count }
        }
        return (canonicalBytes, state.revisions.count, revisionBytes)
    }

    // MARK: - (a) Fresh store through the full open path

    /// A fresh store via `SwiftDataHistory.open(configuration:)` succeeds and
    /// holds exactly one all-disabled config row after the total open order
    /// step 5 (`V2-roadmap` §5; `V2-02` §3.3: created at open, all policies
    /// disabled). A fresh store runs no migration stage and — before
    /// projection stamping (slice R.3) — holds no retained-bytes rows. Row
    /// assertions go through an INDEPENDENT container over the same URL
    /// (`WSSupport.makeContainer`), never the Authority's actor-isolated
    /// container; a fresh persistent store proves the fresh path (the
    /// `.memory` medium is covered by the open-path WS suites).
    @Test("(a) fresh open bootstraps exactly one all-disabled config row")
    func freshOpenBootstrapsAllDisabledConfig() async throws {
        let storeURL = WSSupport.tempStoreURL("v2-migration-fresh-open")
        defer { WSSupport.removeStore(storeURL) }

        _ = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL),
                initialMaximumUnpinnedItems: 200
            )
        )

        let context = ModelContext(try WSSupport.makeContainer(storeURL: storeURL))
        let configs = try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
        #expect(configs.count == 1)
        let config = try #require(configs.first)
        // All-disabled literals from V2-02 §3.3, not from the bootstrap code.
        #expect(config.key == "retention-expansion")
        #expect(config.agePolicyEnabled == false)
        #expect(config.ageMaxSeconds == 0)
        #expect(config.storagePolicyEnabled == false)
        #expect(config.storageMaxBytes == 0)
        #expect(config.revisionPolicyEnabled == false)
        #expect(config.revisionMaxCount == nil)
        #expect(config.revisionMaxBytes == nil)
        #expect(config.configSchemaVersion == 1)

        // Fresh store: zero items, zero byte rows (fresh stores run no
        // stage; rows arrive via capture-insert stamping, slice R.3).
        #expect(try context.fetchCount(FetchDescriptor<HistoryItemRow>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RetainedBytesRow>()) == 0)
    }

    // MARK: - (b) On-disk v1 store migration

    /// `RET-PLATFORM-1b(a)`–(c): migrating a seeded on-disk v1 store through
    /// the single custom stage leaves every item byte-identical (ids,
    /// Content Version, blobs), creates NO config row (bootstrap is `open`,
    /// not migration), and backfills exactly one `RetainedBytesRow` per item
    /// (both directions) whose scalars equal an independently recomputed
    /// value from the same codecs, each stamped `bytesSchemaVersion == 1`.
    @Test("(b) on-disk v1 store migrates byte-identical with exact 1:1 backfill and no config row")
    func onDiskV1StoreMigratesByteIdenticalWithExactBackfill() async throws {
        let storeURL = WSSupport.tempStoreURL("v2-migration-v1-to-v2")
        defer { WSSupport.removeStore(storeURL) }

        // Seed a genuine v1 store with the OLD schema and no migration plan.
        let v1Container = try Self.makeV1Container(storeURL: storeURL)
        let v1Context = ModelContext(v1Container)
        v1Context.autosaveEnabled = false
        let seeded = try await Self.seedV1Store(into: v1Context)

        // RET-PLATFORM-1 (`V2-02` Record 3: "v1 rows, `LastChangePositionRow`,
        // the Signature Index, and the singleton position are untouched"):
        // capture the seeded position singleton's values BEFORE the
        // migration container opens, so the survival assertion below
        // compares against the pre-hop values (scalar copies — a `@Model`
        // stays bound to the context that fetched it).
        let seededPositionRows = try v1Context.fetch(
            FetchDescriptor<LastChangePositionRow>()
        )
        #expect(seededPositionRows.count == 1)
        let seededPosition = try #require(seededPositionRows.first)
        let seededPositionKey = seededPosition.key
        let seededPositionValue = seededPosition.rawValue
        let seededPositionMaximumUnpinned = seededPosition.maximumUnpinnedItems

        // Open a NEW container for the SAME url WITH the migration plan —
        // the exact construction of SwiftDataHistory.open step 2.
        let migratedContainer = try Self.makeMigrationContainer(storeURL: storeURL)
        let migratedContext = ModelContext(migratedContainer)

        // RET-PLATFORM-1b(c): every item still present, byte-identical — no
        // v1 blob/id/version was mutated (expected values copied above).
        let rows = try migratedContext.fetch(FetchDescriptor<HistoryItemRow>())
        #expect(rows.count == seeded.count)
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(Set(rowsByID.keys) == Set(seeded.map(\.id)))
        for item in seeded {
            let row = try #require(rowsByID[item.id])
            #expect(row.contentVersionRaw == item.contentVersionRaw)
            #expect(row.canonicalBlob == item.canonicalBlob)
            #expect(row.revisionStateBlob == item.revisionStateBlob)
            #expect(row.canonicalSignatureBlob == item.canonicalSignatureBlob)
        }

        // The migration does NOT create the config singleton (V2-02 §3.3 /
        // Record 5: "migration adds schema and backfills the projection,
        // not config" — `SwiftDataHistory.open` creates it).
        #expect(
            try migratedContext.fetchCount(
                FetchDescriptor<RetentionExpansionConfigRow>()
            ) == 0
        )

        // RET-PLATFORM-1: the singleton position survived the hop
        // byte-identically — still exactly ONE row, its key, rawValue, and
        // maximumUnpinnedItems equal to the captured pre-migration values
        // (the v1 count policy stays on `LastChangePositionRow`, §1; the
        // hop rewrites no v1 row).
        let migratedPositionRows = try migratedContext.fetch(
            FetchDescriptor<LastChangePositionRow>()
        )
        #expect(migratedPositionRows.count == 1)
        let migratedPosition = try #require(migratedPositionRows.first)
        #expect(migratedPosition.key == seededPositionKey)
        #expect(migratedPosition.rawValue == seededPositionValue)
        #expect(migratedPosition.maximumUnpinnedItems == seededPositionMaximumUnpinned)

        // RET-PLATFORM-1b(a): every item has exactly one RetainedBytesRow
        // AND every RetainedBytesRow names a retained item (both directions).
        let bytesRows = try migratedContext.fetch(FetchDescriptor<RetainedBytesRow>())
        #expect(bytesRows.count == seeded.count)
        #expect(Set(bytesRows.map(\.itemID)) == Set(seeded.map(\.id)))

        // RET-PLATFORM-1b(b): each scalar equals an independently recomputed
        // value from the same codecs, and the literal fixture arithmetic.
        let bytesByItemID = Dictionary(uniqueKeysWithValues: bytesRows.map { ($0.itemID, $0) })
        for item in seeded {
            let recomputed = try Self.recomputedScalars(for: try #require(rowsByID[item.id]))
            // The literal cross-check first: the fixture arithmetic must
            // itself equal the codec recomputation.
            #expect(recomputed.canonicalBytes == item.expectedCanonicalBytes)
            #expect(recomputed.revisionCount == item.expectedRevisionCount)
            #expect(recomputed.revisionBytes == item.expectedRevisionBytes)

            let bytesRow = try #require(bytesByItemID[item.id])
            #expect(bytesRow.canonicalBytes == recomputed.canonicalBytes)
            #expect(bytesRow.revisionCount == recomputed.revisionCount)
            #expect(bytesRow.revisionBytes == recomputed.revisionBytes)
            #expect(bytesRow.bytesSchemaVersion == 1)
        }
    }

    // MARK: - (c) Re-open idempotence through the full open path

    /// After migration, re-opening the SAME url through the full
    /// `SwiftDataHistory.open` path succeeds: an already-V2 store runs no
    /// stage (DC-02 / roadmap §5 step 2), the config row now exists
    /// all-disabled (created by open, not by migration), and the item /
    /// `RetainedBytesRow` counts and scalars are unchanged.
    @Test("(c) re-opened V2 store runs no stage and bootstraps the all-disabled config")
    func reopenedV2StoreRunsNoStageAndBootstrapsConfig() async throws {
        let storeURL = WSSupport.tempStoreURL("v2-migration-reopen")
        defer { WSSupport.removeStore(storeURL) }

        let v1Container = try Self.makeV1Container(storeURL: storeURL)
        let v1Context = ModelContext(v1Container)
        v1Context.autosaveEnabled = false
        let seeded = try await Self.seedV1Store(into: v1Context)

        // Migrate once; snapshot the post-migration projection.
        let migratedContainer = try Self.makeMigrationContainer(storeURL: storeURL)
        let migratedContext = ModelContext(migratedContainer)
        let migratedItems = try migratedContext.fetch(FetchDescriptor<HistoryItemRow>())
        let migratedBytes = try Self.bytesSnapshots(migratedContext)
        #expect(migratedItems.count == seeded.count)
        #expect(migratedBytes.count == seeded.count)

        // Full open path over the SAME url: construct + startup (steps 1–10).
        _ = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL),
                initialMaximumUnpinnedItems: 200
            )
        )
        // Assertions go through the independent container (never the
        // Authority's actor-isolated one).
        let context = ModelContext(try WSSupport.makeContainer(storeURL: storeURL))

        // The config row now exists — all-disabled (open bootstrap).
        let configs = try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
        #expect(configs.count == 1)
        let config = try #require(configs.first)
        #expect(config.key == "retention-expansion")
        #expect(config.agePolicyEnabled == false)
        #expect(config.ageMaxSeconds == 0)
        #expect(config.storagePolicyEnabled == false)
        #expect(config.storageMaxBytes == 0)
        #expect(config.revisionPolicyEnabled == false)
        #expect(config.revisionMaxCount == nil)
        #expect(config.revisionMaxBytes == nil)
        #expect(config.configSchemaVersion == 1)

        // Counts and scalars unchanged: the stage does not re-run on an
        // already-V2 store (idempotent by construction either way).
        #expect(try context.fetchCount(FetchDescriptor<HistoryItemRow>()) == seeded.count)
        let reopenedBytes = try Self.bytesSnapshots(context)
        #expect(reopenedBytes.count == seeded.count)
        #expect(reopenedBytes == migratedBytes)
    }

    // MARK: - (d) Direct backfill idempotence (RET-PLATFORM-1b(e) model)

    /// On a V2-schema in-memory container with items, running
    /// `RetainedBytesBackfill.backfill` twice yields identical rows with no
    /// duplicates and unchanged scalars; rows already present with WRONG
    /// scalars (and a wrong `bytesSchemaVersion`) are corrected — full
    /// recompute, never a resumed partial write.
    @Test("(d) backfill is idempotent by construction and corrects wrong scalars")
    func backfillIsIdempotentAndCorrectsWrongScalars() async throws {
        let schema = Schema(versionedSchema: HistorySchemaV2.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let seeded = try await Self.seedV1Store(into: context)
        #expect(seeded.count == 3)

        try RetainedBytesBackfill.backfill(in: context)
        let firstPass = try Self.bytesSnapshots(context)
        #expect(firstPass.count == seeded.count)

        try RetainedBytesBackfill.backfill(in: context)
        let secondPass = try Self.bytesSnapshots(context)
        #expect(secondPass == firstPass)
        #expect(secondPass.count == seeded.count)

        // Corrupt every scalar (and the fence); a full recompute corrects it.
        for row in try context.fetch(FetchDescriptor<RetainedBytesRow>()) {
            row.canonicalBytes += 1_000
            row.revisionCount += 7
            row.revisionBytes += 9_000
            row.bytesSchemaVersion = 99
        }
        try context.save()
        try RetainedBytesBackfill.backfill(in: context)
        let thirdPass = try Self.bytesSnapshots(context)
        #expect(thirdPass == firstPass)
    }
}
