/// DATA-11's first migration slice: the V1 -> V2 retained-bytes backfill
/// must reject a structurally valid Signature blob unless it covers the
/// row's authoritative Canonical blob exactly. These fixtures are literal
/// wire values; expected coverage is not derived through the production
/// `validateCoverage` helper under test.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Retained-bytes backfill signature coverage")
struct RetainedBytesBackfillTests {
    private let rtfType = "public.rtf"
    private let textType = "public.utf8-plain-text"
    private let extraType = "public.tiff"
    private let rtfFingerprint: UInt64 = 0x1111_2222_3333_4444
    private let textFingerprint: UInt64 = 0xAAAA_BBBB_CCCC_DDDD
    private let forcedCollision: UInt64 = 0xC011_1510_5EED_C0DE

    @Test("missing Canonical type rejects before projection write")
    func missingCanonicalTypeRejectsBeforeProjectionWrite() throws {
        let signatureBlob = try makeSignatureBlob([
            signature(rtfType, fingerprint: rtfFingerprint, byteCount: 4),
        ])

        try expectCorruptBackfill(signatureBlob: signatureBlob)
    }

    @Test("extra Signature type rejects even when fingerprint and byte count collide")
    func extraSignatureTypeRejectsEvenUnderForcedCollision() throws {
        let canonicalBlob = try makeCanonicalBlob(
            rtfFingerprint: forcedCollision,
            textFingerprint: forcedCollision
        )
        // `public.tiff` has the same fingerprint and byte count as the
        // missing three-byte text representation. Collision evidence alone
        // cannot satisfy exact type coverage.
        let signatureBlob = try makeSignatureBlob([
            signature(rtfType, fingerprint: forcedCollision, byteCount: 4),
            signature(extraType, fingerprint: forcedCollision, byteCount: 3),
        ])

        try expectCorruptBackfill(
            canonicalBlob: canonicalBlob,
            signatureBlob: signatureBlob
        )
    }

    @Test("wrong Signature fingerprint rejects before projection write")
    func wrongFingerprintRejectsBeforeProjectionWrite() throws {
        let signatureBlob = try makeSignatureBlob([
            signature(rtfType, fingerprint: rtfFingerprint, byteCount: 4),
            signature(textType, fingerprint: textFingerprint + 1, byteCount: 3),
        ])

        try expectCorruptBackfill(signatureBlob: signatureBlob)
    }

    @Test("wrong Signature byte count rejects before projection write")
    func wrongByteCountRejectsBeforeProjectionWrite() throws {
        let signatureBlob = try makeSignatureBlob([
            signature(rtfType, fingerprint: rtfFingerprint, byteCount: 4),
            signature(textType, fingerprint: textFingerprint, byteCount: 4),
        ])

        try expectCorruptBackfill(signatureBlob: signatureBlob)
    }

    @Test("exact literal coverage writes the boundary projection")
    func exactLiteralCoverageWritesProjection() throws {
        let context = try makeContext()
        let row = try makeRow(signatureBlob: makeSignatureBlob([
            signature(rtfType, fingerprint: rtfFingerprint, byteCount: 4),
            signature(textType, fingerprint: textFingerprint, byteCount: 3),
        ]))
        context.insert(row)
        try context.save()

        try RetainedBytesBackfill.backfill(in: context)

        let projections = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        let projection = try #require(projections.first)
        #expect(projections.count == 1)
        #expect(projection.itemID == row.id)
        // Literal Canonical payload sizes: 4 RTF bytes + 3 text bytes.
        #expect(projection.canonicalBytes == 7)
        #expect(projection.revisionCount == 0)
        #expect(projection.revisionBytes == 0)
        #expect(projection.bytesSchemaVersion == 1)
    }

    private func expectCorruptBackfill(
        canonicalBlob: Data? = nil,
        signatureBlob: Data
    ) throws {
        let context = try makeContext()
        context.insert(try makeRow(
            canonicalBlob: canonicalBlob,
            signatureBlob: signatureBlob
        ))
        try context.save()

        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try RetainedBytesBackfill.backfill(in: context)
        }
        #expect(try context.fetchCount(FetchDescriptor<RetainedBytesRow>()) == 0)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: HistorySchemaV2.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func makeRow(
        canonicalBlob: Data? = nil,
        signatureBlob: Data
    ) throws -> HistoryItemRow {
        let resolvedCanonicalBlob: Data
        if let canonicalBlob {
            resolvedCanonicalBlob = canonicalBlob
        } else {
            resolvedCanonicalBlob = try makeCanonicalBlob()
        }
        return HistoryItemRow(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000D011")!,
            contentVersionRaw: 1,
            canonicalBlob: resolvedCanonicalBlob,
            revisionStateBlob: try RevisionStateBlobCodec.encode(
                revisions: [],
                activeRevisionID: nil
            ),
            canonicalSignatureBlob: signatureBlob,
            projectionSchemaVersion: 1,
            title: "literal coverage fixture",
            searchBody: "literal coverage fixture",
            effectiveTypeIdentifiersBlob: try EffectiveTypeIdentifiersBlobCodec.encode([
                rtfType,
                textType,
            ]),
            firstCopiedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            copyCount: 1,
            firstSource: nil,
            lastSource: nil,
            pinOrdinal: nil
        )
    }

    private func makeCanonicalBlob(
        rtfFingerprint: UInt64? = nil,
        textFingerprint: UInt64? = nil
    ) throws -> Data {
        try CanonicalBlobCodec.encodeWire(CanonicalBlobV1(
            formatVersion: 1,
            representations: [
                StoredCanonicalRepresentationV1(
                    typeIdentifier: rtfType,
                    bytes: Data([0x7B, 0x5C, 0x72, 0x7D]),
                    fingerprint: rtfFingerprint ?? self.rtfFingerprint
                ),
                StoredCanonicalRepresentationV1(
                    typeIdentifier: textType,
                    bytes: Data([0x41, 0x42, 0x43]),
                    fingerprint: textFingerprint ?? self.textFingerprint
                ),
            ]
        ))
    }

    private func makeSignatureBlob(
        _ entries: [StoredSignatureEntryV1]
    ) throws -> Data {
        try SignatureBlobCodec.encodeWire(SignatureBlobV1(
            formatVersion: 1,
            entries: entries
        ))
    }

    private func signature(
        _ typeIdentifier: String,
        fingerprint: UInt64,
        byteCount: Int
    ) -> StoredSignatureEntryV1 {
        StoredSignatureEntryV1(
            typeIdentifier: typeIdentifier,
            fingerprint: fingerprint,
            byteCount: byteCount
        )
    }
}
