/// Leading UTF-16 text scalars that resemble byte-order markers must survive
/// immutable revision storage, projection, the real preview loader, and paste.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct UTF16LeadingScalarRoundTripTests {
    struct Fixture: Sendable {
        let type: String
        let canonical: Data
        let replacement: Data
        let leadingScalar: UInt32
    }

    // Independent wire literals for [FEFF or FFFE] + B + fox. A real BOM
    // precedes the text so the first scalar cannot be mistaken for the marker.
    static let fixtures = [
        Fixture(type: "public.utf16-plain-text", canonical: Data([0x41, 0x00]),
                replacement: Data([0xFF, 0xFE, 0xFF, 0xFE, 0x42, 0x00, 0x3E, 0xD8, 0x8A, 0xDD]),
                leadingScalar: 0xFEFF),
        Fixture(type: "public.utf16-plain-text", canonical: Data([0x41, 0x00]),
                replacement: Data([0xFF, 0xFE, 0xFE, 0xFF, 0x42, 0x00, 0x3E, 0xD8, 0x8A, 0xDD]),
                leadingScalar: 0xFFFE),
        Fixture(type: "public.utf16-external-plain-text", canonical: Data([0x00, 0x41]),
                replacement: Data([0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x42, 0xD8, 0x3E, 0xDD, 0x8A]),
                leadingScalar: 0xFEFF),
        Fixture(type: "public.utf16-external-plain-text", canonical: Data([0x00, 0x41]),
                replacement: Data([0xFE, 0xFF, 0xFF, 0xFE, 0x00, 0x42, 0xD8, 0x3E, 0xDD, 0x8A]),
                leadingScalar: 0xFFFE),
    ]

    @Test(arguments: UTF16LeadingScalarRoundTripTests.fixtures)
    @MainActor
    func leadingTextScalarsSurviveEveryRead(_ fixture: Fixture) async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let captured = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: fixture.type, bytes: fixture.canonical
            )],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_260_000)
        )))
        let original = try #require(ComposedSupport.insertedReference(from: captured, "UTF-16 seed"))
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: original.id,
            expected: original.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: fixture.type, action: .replace(bytes: fixture.replacement)
            )]))
        )))
        let revised = try #require(ComposedSupport.revisedReference(from: receipt, "UTF-16 leading scalar"))
        let expectedScalars: [UInt32] = [fixture.leadingScalar, 0x42, 0x1F98A]

        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(page.rows.map(\.item) == [revised])
        #expect(page.rows.first?.title.unicodeScalars.map(\.value) == expectedScalars)
        let details = try await history.details(for: revised.id)
        #expect(details.item == revised)
        #expect(details.canonical.map(\.bytes) == [fixture.canonical])
        #expect(details.effective.map(\.typeIdentifier) == [fixture.type])
        #expect(details.effective.map(\.bytes) == [fixture.replacement])
        #expect(details.revisions.first?.title.unicodeScalars.map(\.value) == expectedScalars)

        let paste = try await history.pastePayload(for: revised.id)
        #expect(paste.item == revised)
        #expect(paste.representations == details.effective)
        #expect(paste.lineageHint == revised.id)

        // The existing hosted driver crosses details → PreviewContentLoader
        // → ContentPreview and exposes only content-free facts. Both leading
        // scalars are separate Characters; the supplementary fox is one.
        let preview = await PreviewLoaderDebugDriver(history: history).load(revised)
        #expect(preview.kind == .text)
        #expect(preview.textCharacterCount == 3)
    }
}
