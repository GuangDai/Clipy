import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct MultiItemPreparationTests {
    private func capture(_ representations: [CapturedRepresentation]) -> ClipboardCapture {
        ClipboardCapture(
            representations: representations,
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
    }

    @Test func normalizationPreservesItemOrderAndRepeatedTypesThroughEveryCodec() async throws {
        let prepared = try await IngestPreparationActor(fingerprint: { _ in 7 }).prepare(capture([
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("beta".utf8), pasteboardItemIndex: 1),
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("alpha".utf8)),
            .init(typeIdentifier: "public.html", bytes: Data("<b>alpha</b>".utf8)),
        ]))
        let canonical = prepared.domain.canonical
        #expect(canonical.pasteboardItemCount == 2)
        #expect(canonical.representations.map(\.content.pasteboardItemIndex) == [0, 0, 1])
        #expect(canonical.representations.map(\.content.typeIdentifier) == [
            "public.html", "public.utf8-plain-text", "public.utf8-plain-text",
        ])
        #expect(prepared.projection.title.hasPrefix("2 items: "))
        #expect(prepared.projection.effectiveTypeIdentifiers == ["public.html", "public.utf8-plain-text"])
        #expect(prepared.projection.searchBody.contains("alpha"))
        #expect(prepared.projection.searchBody.contains("beta"))

        let decoded = try CanonicalBlobCodec.decode(CanonicalBlobCodec.encode(canonical))
        #expect(decoded == canonical)
        let entries = try SignatureBlobCodec.decode(SignatureBlobCodec.encode(prepared.signatureEntries))
        #expect(entries == prepared.signatureEntries)
        try SignatureBlobCodec.validateCoverage(canonical: decoded, entries: entries)

        let revisionID = RevisionID(rawValue: UUID())
        let content = EffectiveContent(representations: canonical.representations.map(\.content))
        let revision = ContentRevision(id: revisionID, createdAt: Date(), content: content)
        let wire = try RevisionStateBlobCodec.encode(revisions: [revision], activeRevisionID: revisionID)
        let restored = try RevisionStateBlobCodec.decode(wire, canonical: decoded)
        #expect(restored.revisions == [revision])
        #expect(restored.activeRevisionID == revisionID)
    }

    @Test func everyFileItemContributesSearchMetadataWithoutChangingItsURLBytes() async throws {
        let representations: [CapturedRepresentation] = [
            .init(typeIdentifier: "public.file-url", bytes: Data("file:///tmp/alpha.txt".utf8)),
            .init(typeIdentifier: "public.file-url", bytes: Data("file:///tmp/beta.txt".utf8), pasteboardItemIndex: 1),
        ]
        let prepared = try await IngestPreparationActor().prepare(capture(representations))
        #expect(prepared.projection.title == "2 items: alpha.txt")
        #expect(prepared.projection.searchBody.contains("beta.txt"))
        #expect(prepared.domain.canonical.representations.map(\.content.bytes) == representations.map(\.bytes))
    }

    @Test func repeatedTypeInSameItemRemainsInvalid() async {
        await #expect(throws: HistoryFailure.invalidInput(.duplicateRepresentationType("public.text"))) {
            try await IngestPreparationActor().prepare(capture([
                .init(typeIdentifier: "public.text", bytes: Data([1])),
                .init(typeIdentifier: "public.text", bytes: Data([2])),
                .init(typeIdentifier: "public.text", bytes: Data([3]), pasteboardItemIndex: 1),
            ]))
        }
    }

    @Test(arguments: [-1, 2, Int.max])
    func gapsAndInvalidItemPositionsAreRejectedBeforeFingerprinting(index: Int) async {
        await #expect(throws: HistoryFailure.invalidInput(.emptyCapture)) {
            try await IngestPreparationActor(fingerprint: { _ in
                Issue.record("Invalid item position reached fingerprinting")
                return 0
            }).prepare(capture([
                .init(typeIdentifier: "public.text", bytes: Data([1])),
                .init(typeIdentifier: "public.text", bytes: Data([2]), pasteboardItemIndex: index),
            ]))
        }
    }

    @Test func privateSecondItemRejectsTheWholeGestureBeforeFingerprinting() async {
        await #expect(throws: HistoryFailure.invalidInput(.excludedFromHistory)) {
            try await IngestPreparationActor(fingerprint: { _ in
                Issue.record("Private multi-item capture reached fingerprinting")
                return 0
            }).prepare(capture([
                .init(typeIdentifier: "public.text", bytes: Data([1])),
                .init(typeIdentifier: "org.nspasteboard.ConcealedType", bytes: Data([2]), pasteboardItemIndex: 1),
            ]))
        }
    }

    @Test func codecsRejectAnItemGapWithoutRepairingThePayload() throws {
        let wire = CanonicalBlobV1(formatVersion: 1, representations: [
            .init(typeIdentifier: "public.text", bytes: Data([1]), fingerprint: 7),
            .init(typeIdentifier: "public.text", bytes: Data([2]), fingerprint: 7, pasteboardItemIndex: 2),
        ])
        #expect(throws: CodecRejection.nonNormalizedOrder) {
            try CanonicalBlobCodec.decode(CanonicalBlobCodec.encodeWire(wire))
        }
        let signature = SignatureBlobV1(formatVersion: 1, entries: [
            .init(typeIdentifier: "public.text", fingerprint: 7, byteCount: 1),
            .init(typeIdentifier: "public.text", fingerprint: 7, byteCount: 1, pasteboardItemIndex: 2),
        ])
        #expect(throws: CodecRejection.nonNormalizedOrder) {
            try SignatureBlobCodec.decode(SignatureBlobCodec.encodeWire(signature))
        }
    }
}
