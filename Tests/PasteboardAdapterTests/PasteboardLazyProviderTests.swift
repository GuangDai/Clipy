/// Card 5B / 05-ART5: real promised-data callbacks, object-level replay,
/// and ownership movement after a promised representation is materialized.
/// Each private pasteboard belongs to one test; no timer deadlines or
/// provider-specific timeout behavior are inferred (01 §5.1; 03b §9).
import AppKit
import Foundation
import HistoryCore
import Testing
@testable import PasteboardAdapter

/// Bytes are set only when AppKit invokes its real data-provider callback.
/// Immutable fixture data needs no shared counter or synchronization hook.
private final class LazyPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    private let bytesByType: [String: Data]

    init(bytesByType: [String: Data]) {
        self.bytesByType = bytesByType
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        if let bytes = bytesByType[type.rawValue] {
            _ = item.setData(bytes, forType: type)
        }
    }
}

struct PasteboardLazyProviderTests {
    enum PromisedLineage: CaseIterable, Equatable, Sendable {
        case valid
        case malformed
        case unavailable
    }

    /// Unknown/private identifiers remain raw data when supplied lazily.
    /// Lineage is optional metadata: an unavailable promised hint must not
    /// turn otherwise complete opaque content into a partial freeze (03a §4).
    @Test(arguments: PromisedLineage.allCases) @MainActor
    func promisedOpaqueBytesReplayIndependentlyOfOptionalLineage(
        lineage: PromisedLineage
    ) throws {
        let source = Self.makePasteboard()
        let destination = Self.makePasteboard()
        defer {
            source.releaseGlobally()
            destination.releaseGlobally()
        }
        let expected = [
            CapturedRepresentation(
                typeIdentifier: "com.clipy.fixture.lazy.unknown", bytes: Data([0xFF, 0x00, 0x80])
            ),
            CapturedRepresentation(
                typeIdentifier: "dyn.clipy-lazy-opaque", bytes: Data([0x00])
            ),
            CapturedRepresentation(
                typeIdentifier: "com.clipy.fixture.lazy.private", bytes: Data([0xFE, 0x42, 0x00, 0x0A])
            ),
        ]
        let sourceID = HistoryItemID(rawValue: UUID())
        var bytesByType = Dictionary(uniqueKeysWithValues: expected.map { ($0.typeIdentifier, $0.bytes) })
        switch lineage {
        case .valid:
            bytesByType[PasteboardLineageHint.typeIdentifier] = PasteboardLineageHint.encode(sourceID)
        case .malformed:
            bytesByType[PasteboardLineageHint.typeIdentifier] = Data([0xFF, 0x00])
        case .unavailable:
            break // The provider declares this type but never supplies it.
        }
        let provider = LazyPasteboardProvider(bytesByType: bytesByType)
        let item = NSPasteboardItem()
        let declaredTypes = expected.map(\.typeIdentifier) + [PasteboardLineageHint.typeIdentifier]
        try #require(item.setDataProvider(provider, forTypes: declaredTypes.map {
            NSPasteboard.PasteboardType($0)
        }))
        source.clearContents()
        try #require(source.writeObjects([item]))
        let generation = source.changeCount
        let outcome = try #require(withExtendedLifetime(provider) {
            PasteboardAdapter(pasteboard: source).captureOutcome()
        })
        guard case let .complete(complete) = outcome else {
            Issue.record("optional promised lineage must not prevent complete opaque capture")
            return
        }
        #expect(complete.changeCount == generation)
        #expect(source.changeCount == generation)
        #expect(complete.capture.representations.count == expected.count)
        #expect(Set(complete.capture.representations) == Set(expected))
        #expect(complete.capture.origin.lineageHint == (lineage == .valid ? sourceID : nil))

        // The source no longer publishes this promised item before replay.
        // The destination must contain the frozen bytes, plus its new hint.
        source.clearContents()
        let pastedID = HistoryItemID(rawValue: UUID())
        let destinationAdapter = PasteboardAdapter(pasteboard: destination)
        try destinationAdapter.write(PastePayload(
            item: HistoryItemReference(id: pastedID, contentVersion: ContentVersion(rawValue: 1)),
            representations: complete.capture.representations.map {
                HistoryRepresentation(typeIdentifier: $0.typeIdentifier, bytes: $0.bytes)
            },
            lineageHint: pastedID
        ))
        let pastedItems = try #require(destination.pasteboardItems)
        #expect(pastedItems.count == 1)
        let pastedItem = try #require(pastedItems.first)
        #expect(Set(pastedItem.types.map(\.rawValue)) == Set(declaredTypes))
        for representation in expected {
            #expect(pastedItem.data(forType: NSPasteboard.PasteboardType(representation.typeIdentifier)) == representation.bytes)
        }
        let replay = try #require(destinationAdapter.capture())
        #expect(Set(replay.representations) == Set(expected))
        #expect(replay.origin.lineageHint == pastedID)
    }

    @Test @MainActor
    func promisedStringAndURLFreezeAndReplayAsNativeObjects() throws {
        let source = Self.makePasteboard()
        let destination = Self.makePasteboard()
        defer {
            source.releaseGlobally()
            destination.releaseGlobally()
        }
        let text = "Promised clipboard text — 剪贴板\nsecond line"
        let url = "https://example.invalid/clipboard?q=two%20words#fragment"
        let expected = [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8)),
            CapturedRepresentation(typeIdentifier: "public.url", bytes: Data(url.utf8)),
        ]
        let provider = try Self.publishPromised(expected, on: source)
        let generation = source.changeCount
        let capture = try #require(withExtendedLifetime(provider) {
            PasteboardAdapter(pasteboard: source).capture()
        })
        #expect(source.changeCount == generation)
        #expect(Set(capture.representations) == Set(expected))

        // Adapter-owner tests construct a payload from frozen values; the
        // real History path is covered by OpaquePasteboardRoundTripTests.
        let id = HistoryItemID(rawValue: UUID())
        let payload = PastePayload(
            item: HistoryItemReference(id: id, contentVersion: ContentVersion(rawValue: 1)),
            representations: capture.representations.map {
                HistoryRepresentation(typeIdentifier: $0.typeIdentifier, bytes: $0.bytes)
            },
            lineageHint: id
        )
        try PasteboardAdapter(pasteboard: destination).write(payload)
        let strings = try #require(destination.readObjects(
            forClasses: [NSString.self], options: nil
        ) as? [NSString])
        #expect(strings.map { $0 as String } == [text])
        let urls = try #require(destination.readObjects(
            forClasses: [NSURL.self], options: nil
        ) as? [NSURL])
        #expect(urls.map(\.absoluteString) == [url])
        let replay = try #require(PasteboardAdapter(pasteboard: destination).capture())
        #expect(Set(replay.representations) == Set(expected))
        #expect(replay.origin.lineageHint == id)
    }

    #if DEBUG
    @Test(arguments: [false, true]) @MainActor
    func stoppingDuringAPromisedReadAbandonsRemainingItemsAndMetadata(restart: Bool) throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let types = ["public.utf8-plain-text", "com.clipy.fixture.lazy", PasteboardLineageHint.typeIdentifier]
        let provider = LazyPasteboardProvider(bytesByType: [
            types[0]: Data("old text".utf8), types[1]: Data([0x01, 0x02]),
            types[2]: PasteboardLineageHint.encode(HistoryItemID(rawValue: UUID())),
        ])
        let items = try (0..<2).map { _ in
            let item = NSPasteboardItem()
            try #require(item.setDataProvider(provider, forTypes: types.map { NSPasteboard.PasteboardType($0) }))
            return item
        }
        try #require(pasteboard.writeObjects(items))
        let generation = pasteboard.changeCount
        var reads = 0
        var received: [CaptureOutcome] = []
        weak var activeObserver: PasteboardObserver?
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadCompletionHook = { _ in
            reads += 1
            guard reads == 1 else { return }
            // Model the observer stop allowed by a promised provider's
            // nested main run loop. Ownership stays unchanged, so the
            // changeCount checks alone cannot suppress the five next reads.
            activeObserver?.stop()
            if restart {
                activeObserver?.start(captureCurrent: false) { received.append($0) }
            }
        }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        activeObserver = observer
        defer { observer.stop() }
        withExtendedLifetime(provider) {
            observer.start { received.append($0) }
        }
        #expect(pasteboard.changeCount == generation)
        #expect(reads == 1)
        #expect(received.isEmpty)
        if !restart { observer.start(captureCurrent: false) { received.append($0) } }
        observer.pollForTesting()
        #expect(reads == 1)
        #expect(received.isEmpty)

        pasteboard.clearContents()
        try #require(pasteboard.setString("after resume", forType: .string))
        observer.pollForTesting()
        #expect(reads == 2)
        #expect(received.count == 1)
        guard case let .complete(complete) = try #require(received.first) else {
            Issue.record("Only the complete generation copied after resume should be delivered")
            return
        }
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: "public.utf8-plain-text", bytes: Data("after resume".utf8)
        )])
    }

    @Test @MainActor
    func ownerReplacementAfterLazyReadRetriesWholeItemAndDoesNotRedeliver() throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let old = [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("old text".utf8)),
            CapturedRepresentation(typeIdentifier: "com.clipy.fixture.lazy", bytes: Data([0x01, 0x00, 0xFF])),
        ]
        let replacement = [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("new text".utf8)),
            CapturedRepresentation(typeIdentifier: "com.clipy.fixture.lazy", bytes: Data([0x02, 0x00, 0xFF])),
        ]
        let provider = try Self.publishPromised(old, on: pasteboard)
        var replaced = false
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadCompletionHook = { _ in
            guard !replaced else { return }
            replaced = true
            let newItem = NSPasteboardItem()
            for representation in replacement {
                #expect(newItem.setData(
                    representation.bytes,
                    forType: NSPasteboard.PasteboardType(representation.typeIdentifier)
                ))
            }
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([newItem]))
        }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        withExtendedLifetime(provider) {
            observer.start { received.append($0) }
        }
        #expect(replaced)
        #expect(received.count == 1)
        guard case let .complete(complete) = try #require(received.first) else {
            Issue.record("the stable retry must contain the complete replacement item")
            return
        }
        #expect(complete.changeCount == pasteboard.changeCount)
        #expect(Set(complete.capture.representations) == Set(replacement))

        // The retry consumed the new generation, so the next timer tick
        // cannot deliver it twice or revisit the old promised bytes.
        observer.pollForTesting()
        #expect(received.count == 1)
    }
    #endif

    @MainActor
    private static func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.clipy.lazy-provider." + UUID().uuidString))
    }

    @MainActor
    private static func publishPromised(
        _ representations: [CapturedRepresentation],
        on pasteboard: NSPasteboard
    ) throws -> LazyPasteboardProvider {
        let provider = LazyPasteboardProvider(bytesByType: Dictionary(
            uniqueKeysWithValues: representations.map { ($0.typeIdentifier, $0.bytes) }
        ))
        let item = NSPasteboardItem()
        try #require(item.setDataProvider(
            provider,
            forTypes: representations.map { NSPasteboard.PasteboardType($0.typeIdentifier) }
        ))
        pasteboard.clearContents()
        try #require(pasteboard.writeObjects([item]))
        return provider
    }
}
