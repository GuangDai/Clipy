/// FORMAT-3 / PLAY-FORMAT-A1 and 05-ART5: eligible, single-item opaque
/// representations retain their exact identifiers and bytes through the real
/// adapter, in-memory History, and paste replay (03a §4; 03b §9).
/// These synthetic fixtures establish raw fidelity, not producer-specific
/// interoperability or support for decoding a private format.
import AppKit
import Foundation
import HistoryCore
import PasteboardAdapter
import PresentationUI
import Testing

struct OpaquePasteboardRoundTripTests {
    @Test(arguments: [
        "com.clipy.tests.opaque.unknown",
        "dyn.clipy-opaque-roundtrip",
        "com.clipy.tests.opaque.private",
    ])
    @MainActor
    func opaqueIdentifierAndBinaryBytesSurviveTheComposedRoundTrip(
        typeIdentifier: String
    ) async throws {
        // Embedded NUL, invalid UTF-8, and high bytes must survive as Data.
        // A private representation is distinct from a concealment marker.
        try await roundTrip([
            CapturedRepresentation(
                typeIdentifier: typeIdentifier,
                bytes: Data([0x00, 0xFF, 0x80, 0x41, 0x00, 0x0A, 0xFE])
            ),
        ])
    }

    @Test @MainActor
    func multipleOpaqueRepresentationsKeepTheirBytesAndDiscardEmptySibling() async throws {
        // Readable text/JSON in an unknown type does not grant Preview text
        // semantics. A one-byte NUL is retained; zero bytes are not (02 §2.1).
        try await roundTrip([
            CapturedRepresentation(
                typeIdentifier: "com.clipy.tests.opaque.unknown",
                bytes: Data("{\"message\":\"opaque text must stay opaque\"}".utf8)
            ),
            CapturedRepresentation(
                typeIdentifier: "dyn.clipy-opaque-roundtrip",
                bytes: Data([0x00])
            ),
            CapturedRepresentation(
                typeIdentifier: "com.clipy.tests.opaque.private",
                bytes: Data([0xFF, 0xFE, 0x00, 0x80])
            ),
            CapturedRepresentation(
                typeIdentifier: "com.clipy.tests.opaque.empty",
                bytes: Data()
            ),
        ])
    }

    @MainActor
    private func roundTrip(_ input: [CapturedRepresentation]) async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let source = ComposedSupport.makePasteboard()
        let destination = ComposedSupport.makePasteboard()
        defer {
            source.releaseGlobally()
            destination.releaseGlobally()
        }

        let sourceItem = NSPasteboardItem()
        for representation in input {
            try #require(sourceItem.setData(
                representation.bytes,
                forType: NSPasteboard.PasteboardType(representation.typeIdentifier)
            ))
        }
        source.clearContents()
        try #require(source.writeObjects([sourceItem]))
        // Assert the actual provider fixture, including the empty sibling,
        // before asking the adapter to freeze it.
        let publishedSource = try #require(source.pasteboardItems?.first)
        #expect(Set(publishedSource.types.map(\.rawValue)) == Set(input.map(\.typeIdentifier)))
        for representation in input {
            #expect(publishedSource.data(
                forType: NSPasteboard.PasteboardType(representation.typeIdentifier)
            ) == representation.bytes)
        }

        let expected = input.filter { !$0.bytes.isEmpty }
        let capture = try #require(PasteboardAdapter(pasteboard: source).capture(
            observedAt: Date(timeIntervalSinceReferenceDate: 710_000_000)
        ))
        #expect(Set(capture.representations) == Set(expected))
        let receipt = try await history.perform(.capture(capture))
        let inserted = try #require(ComposedSupport.insertedReference(
            from: receipt,
            "opaque round-trip capture"
        ))
        let details = try await history.details(for: inserted.id)
        expectRepresentations(details.canonical, equalTo: expected)
        expectRepresentations(details.effective, equalTo: expected)

        // Exercise the production preview loader and public thumbnail read
        // with these stored bytes. Neither grants semantics by sniffing.
        let preview = await PreviewLoaderDebugDriver(history: history).load(inserted)
        #expect(preview.kind == .unsupported)
        #expect(preview.textCharacterCount == nil)
        #expect(preview.rasterWidth == nil)
        #expect(preview.rasterHeight == nil)
        let thumbnail = try await history.thumbnail(
            for: inserted,
            pixels: PixelSize(width: 72, height: 72)
        )
        #expect(thumbnail == nil)

        let payload = try await history.pastePayload(for: inserted.id)
        #expect(payload.item == inserted)
        #expect(payload.lineageHint == inserted.id)
        expectRepresentations(payload.representations, equalTo: expected)
        ComposedSupport.setPasteboardContents("previous destination content", on: destination)
        let destinationAdapter = PasteboardAdapter(pasteboard: destination)
        try destinationAdapter.write(payload)

        let pastedItems = try #require(destination.pasteboardItems)
        #expect(pastedItems.count == 1)
        let pastedItem = try #require(pastedItems.first)
        #expect(Set(pastedItem.types.map(\.rawValue)) == Set(
            expected.map(\.typeIdentifier) + ["com.clipy.lineageHint"]
        ))
        for representation in expected {
            #expect(pastedItem.data(
                forType: NSPasteboard.PasteboardType(representation.typeIdentifier)
            ) == representation.bytes)
        }

        let recapture = try #require(destinationAdapter.capture(
            observedAt: Date(timeIntervalSinceReferenceDate: 710_000_001)
        ))
        #expect(Set(recapture.representations) == Set(expected))
        #expect(recapture.origin.lineageHint == inserted.id)
        let recaptureReceipt = try await history.perform(.capture(recapture))
        let coalesced = try #require(ComposedSupport.coalescedReference(
            from: recaptureReceipt,
            "opaque paste replay"
        ))
        #expect(coalesced == inserted)
        let finalDetails = try await history.details(for: inserted.id)
        expectRepresentations(finalDetails.canonical, equalTo: expected)
        expectRepresentations(finalDetails.effective, equalTo: expected)
        #expect(finalDetails.occurrence.count == 2)
        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(page.rows.map(\.item) == [inserted])
    }

    private func expectRepresentations(
        _ actual: [HistoryRepresentation],
        equalTo expected: [CapturedRepresentation]
    ) {
        #expect(actual.count == expected.count)
        #expect(Set(actual.map {
            CapturedRepresentation(typeIdentifier: $0.typeIdentifier, bytes: $0.bytes)
        }) == Set(expected))
    }
}
