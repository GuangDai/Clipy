/// DATA-11 authoritative Signature Index coverage proofs. The current
/// hard-capped startup and capture-time rebuild paths may use durable
/// signature metadata as negative dedup evidence only after recomputing xxh3
/// from Canonical bytes and requiring both stored fingerprint copies to agree
/// with that recomputation (docs/05-authority-kernel.md §12–§13).
///
/// Both fixtures use the public History seam for the behavior under test.
/// Their only internal setup is the established corruption-fixture stance:
/// damage one durable row through an independent container and, for the
/// capture slice, drop the actor-owned derived index to its existing
/// `.unready` state so the next public capture must take the rebuild path.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Signature Index authoritative coverage (DATA-11)")
struct SignatureIndexAuthoritativeCoverageTests {
    /// Pinned xxHash v0.8.3 known-answer vector (`XXH3FingerprintTests`):
    /// xxh3-64("Clipy") is `0xE406_7A4D_3059_0056`. Flipping the low bit
    /// gives a deterministic wrong literal without deriving the expected
    /// result through the production validation under test.
    private static let canonicalText = "Clipy"
    private static let consistentlyWrongFingerprint: UInt64 = 0xE406_7A4D_3059_0057

    @discardableResult
    private static func capture(
        _ text: String,
        at seconds: Double,
        source: String,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                text,
                observedAt: Date(timeIntervalSinceReferenceDate: seconds),
                source: source
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome
        else {
            Issue.record("DATA-11 setup expected an inserted commit, got \(receipt)")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference
    }

    /// Rewrites both fingerprint copies to the same wrong literal while
    /// preserving the authoritative type and bytes. The two blobs remain
    /// individually decodable and pass the legacy stored-copy coverage check;
    /// only recomputing xxh3 over the bytes can reject this shape.
    private static func storeConsistentlyWrongFingerprint(
        for itemID: HistoryItemID,
        at storeURL: URL
    ) throws {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let uuid = itemID.rawValue
        let rows = try context.fetch(FetchDescriptor<HistoryItemRow>(
            predicate: #Predicate { row in row.id == uuid }
        ))
        let row = try #require(rows.first)
        #expect(rows.count == 1)

        let decoded = try CanonicalBlobCodec.decode(row.canonicalBlob)
        let representation = try #require(decoded.representations.first)
        #expect(decoded.representations.count == 1)
        #expect(representation.content.bytes == Data(canonicalText.utf8))

        let wrongFingerprint = ContentFingerprint(
            rawValue: consistentlyWrongFingerprint
        )
        let corruptedCanonical = try CanonicalContent(representations: [
            CanonicalRepresentation(
                content: representation.content,
                fingerprint: wrongFingerprint
            ),
        ])
        let corruptedSignatures = [ContentSignatureEntry(
            typeIdentifier: representation.content.typeIdentifier,
            fingerprint: wrongFingerprint,
            byteCount: representation.content.bytes.count
        )]
        row.canonicalBlob = try CanonicalBlobCodec.encode(corruptedCanonical)
        row.canonicalSignatureBlob = try SignatureBlobCodec.encode(corruptedSignatures)
        try context.save()

        // Fixture canary: stored-copy equality still passes, proving a later
        // rejection cannot be attributed to ordinary bidirectional coverage.
        try SignatureBlobCodec.validateCoverage(
            canonical: CanonicalBlobCodec.decode(row.canonicalBlob),
            entries: SignatureBlobCodec.decode(row.canonicalSignatureBlob)
        )
    }

    @Test("public reopen rejects fingerprints that agree only with each other")
    func publicReopenRejectsConsistentlyWrongStoredFingerprint() async throws {
        let storeURL = WSSupport.tempStoreURL("data11-authoritative-startup")
        defer { WSSupport.removeStore(storeURL) }

        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let reference = try await Self.capture(
            Self.canonicalText,
            at: 700_300_000,
            source: "com.example.data11.startup",
            in: history
        )
        try Self.storeConsistentlyWrongFingerprint(
            for: reference.id,
            at: storeURL
        )
        let before = try TransactionStoreSnapshot.read(from: storeURL)

        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            _ = try await WSSupport.openHistory(storeURL: storeURL)
        }

        // Startup validation is read-only: rejecting the facade does not
        // repair either wrong fingerprint or mutate any other durable field.
        #expect(try TransactionStoreSnapshot.read(from: storeURL) == before)
    }

    @Test("an unready capture rebuild rejects bad fingerprints before mutation")
    func captureTimeUnreadyRebuildRejectsBeforePublicStateChanges() async throws {
        let storeURL = WSSupport.tempStoreURL("data11-authoritative-capture-rebuild")
        defer { WSSupport.removeStore(storeURL) }

        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let reference = try await Self.capture(
            Self.canonicalText,
            at: 700_300_100,
            source: "com.example.data11.capture",
            in: history
        )
        try Self.storeConsistentlyWrongFingerprint(
            for: reference.id,
            at: storeURL
        )
        await history.authority.markSignatureIndexUnreadyForDATA11Test()

        let request = HistoryBrowseRequest(kind: .recent, limit: 10)
        let publicPageBefore = try await history.browse(request)
        let publicDetailsBefore = try await history.details(for: reference.id)
        let durableBefore = try TransactionStoreSnapshot.read(from: storeURL)

        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            _ = try await history.perform(.capture(
                WSSupport.textCapture(
                    "DATA-11 rejected capture",
                    observedAt: Date(timeIntervalSinceReferenceDate: 700_300_200),
                    source: "com.example.data11.capture"
                )
            ))
        }

        let publicPageAfter = try await history.browse(request)
        let publicDetailsAfter = try await history.details(for: reference.id)
        #expect(publicPageAfter == publicPageBefore)
        #expect(publicDetailsAfter == publicDetailsBefore)
        #expect(try TransactionStoreSnapshot.read(from: storeURL) == durableBefore)
    }
}

private extension HistoryAuthority {
    /// Test-target-only arrangement over existing internal state; no public or
    /// production seam is added. The next public capture must execute the
    /// production `.unready` rebuild branch.
    func markSignatureIndexUnreadyForDATA11Test() {
        signatureIndex.markUnready()
    }
}
