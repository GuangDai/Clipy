import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
@testable import HistoryStorage

/// Shared V1-store seeding and byte-projection recomputation for the V1 → V2
/// migration proof suites — extracted verbatim from `HistoryMigrationTests`
/// so the RET-PLATFORM-1b(e) engine-level interruption fixture
/// (`HistoryMigrationInterruptionTests`) seeds the IDENTICAL three-item v1
/// store the model-level suites prove against.
///
/// Valid v1 payloads are built through the production preparation/stamping
/// helpers — `IngestPreparationActor.prepare` (the §6.1 normalized capture
/// pipeline) for Canonical/signature/projection values, and the production
/// codecs (`CanonicalBlobCodec`, `SignatureBlobCodec`,
/// `RevisionStateBlobCodec`, `EffectiveTypeIdentifiersBlobCodec`) for the
/// durable blobs — mirroring `ProjectionCorruptionTests.seedRow`; no blob is
/// hand-crafted. Expected scalars carry the literal fixture-byte arithmetic
/// (`RET-PLATFORM-1b(b)`).
enum MigrationSeeding {

    /// Test-oracle-only failure. The migration proof must not call the
    /// production coverage helper it is intended to check; this sentinel
    /// keeps the oracle's independently written comparison fail-loud.
    private enum SignatureCoverageOracleFailure: Error {
        case mismatch
    }

    /// One seeded v1 item: the insertable durable row plus the pre-migration
    /// copies and expected byte-projection scalars.
    struct SeededItem {
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
    static func makeSeededItems() async throws -> [SeededItem] {
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
            projectionSchemaVersion: ContentProjector.legacySchemaVersion,
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
            projectionSchemaVersion: ContentProjector.legacySchemaVersion,
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
            projectionSchemaVersion: ContentProjector.legacySchemaVersion,
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
    static func seedV1Store(into context: ModelContext) async throws -> [SeededItem] {
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
    static func makeV1Container(storeURL: URL) throws -> ModelContainer {
        try ModelContainer(
            for: v1Schema,
            configurations: [ModelConfiguration(schema: v1Schema, url: storeURL)]
        )
    }

    /// A migration-plan container over the same URL: the current V4 schema plus
    /// `HistoryMigrationPlan` — the exact construction `SwiftDataHistory.open`
    /// step 2 performs.
    static func makeMigrationContainer(storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: HistoryMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
    }

    /// One comparable `RetainedBytesRow` projection snapshot.
    struct RetainedBytesSnapshot: Equatable {
        let itemID: UUID
        let canonicalBytes: Int
        let revisionCount: Int
        let revisionBytes: Int
        let bytesSchemaVersion: UInt16
    }

    /// Every `RetainedBytesRow`, deterministically ordered by item ID.
    static func bytesSnapshots(
        _ context: ModelContext
    ) throws -> [RetainedBytesSnapshot] {
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
    /// through the production decoders (`RET-PLATFORM-1b(b)`), WITHOUT
    /// touching the backfill under test or calling its production signature
    /// coverage helper. Coverage is compared field-by-field below so a
    /// missing production check cannot make both implementation and oracle
    /// accept the same corrupt fixture (DATA-11).
    static func recomputedScalars(
        for row: HistoryItemRow
    ) throws -> (canonicalBytes: Int, revisionCount: Int, revisionBytes: Int) {
        let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
        let entries = try SignatureBlobCodec.decode(row.canonicalSignatureBlob)
        try validateSignatureCoverageIndependently(
            canonical: canonical,
            entries: entries
        )
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

    private static func validateSignatureCoverageIndependently(
        canonical: CanonicalContent,
        entries: [ContentSignatureEntry]
    ) throws {
        guard canonical.representations.count == entries.count else {
            throw SignatureCoverageOracleFailure.mismatch
        }
        // Both production decoders have independently proved normalized,
        // unique type order. Equal counts plus pairwise equality therefore
        // proves both directions without a second lookup structure.
        for (representation, entry) in zip(canonical.representations, entries) {
            guard entry.typeIdentifier == representation.content.typeIdentifier,
                  entry.fingerprint.rawValue == representation.fingerprint.rawValue,
                  entry.byteCount == representation.content.bytes.count
            else {
                throw SignatureCoverageOracleFailure.mismatch
            }
        }
    }
}
