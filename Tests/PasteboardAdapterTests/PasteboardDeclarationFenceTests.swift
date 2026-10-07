import AppKit
import Foundation
import HistoryCore
import Testing
@testable import PasteboardAdapter

#if DEBUG
@MainActor
struct PasteboardDeclarationFenceTests {
    @Test(arguments: [false, true])
    func declarationsAddedDuringAReadDiscardTheEarlierFreeze(concealed: Bool) throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let initialBytes = Data("initial content".utf8)
        try #require(pasteboard.setData(initialBytes, forType: .string))
        let generation = pasteboard.changeCount
        let addedType = NSPasteboard.PasteboardType(concealed
            ? "org.nspasteboard.ConcealedType"
            : "com.clipy.tests.later-declaration")
        let addedBytes = Data([0x00, 0xFF, 0x81])
        var didAddDeclaration = false
        var reads: [String] = []
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadCompletionHook = { typeIdentifier in
            reads.append(typeIdentifier)
            guard !didAddDeclaration else { return }
            didAddDeclaration = true
            _ = pasteboard.addTypes([addedType], owner: nil)
            #expect(pasteboard.setData(addedBytes, forType: addedType))
        }

        let outcome = try #require(adapter.captureOutcome())
        try #require(pasteboard.changeCount == generation)
        try #require(didAddDeclaration)
        guard case let .changedDuringRead(changed) = outcome else {
            Issue.record("A declaration added during a read must discard the earlier freeze")
            return
        }
        #expect(changed.startChangeCount == generation)
        #expect(changed.endChangeCount == generation)
        #expect(reads == [NSPasteboard.PasteboardType.string.rawValue])

        let readCountBeforeRetry = reads.count
        let retry = try #require(adapter.captureOutcome())
        if concealed {
            guard case let .concealed(value) = retry else {
                Issue.record("A newly declared privacy marker must exclude the whole gesture")
                return
            }
            #expect(value.markerTypeIdentifier == addedType.rawValue)
            #expect(reads.count == readCountBeforeRetry)
        } else {
            guard case let .complete(value) = retry else {
                Issue.record("A stable retry must freeze every declaration")
                return
            }
            #expect(Set(value.capture.representations) == Set([
                CapturedRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    bytes: initialBytes
                ),
                CapturedRepresentation(typeIdentifier: addedType.rawValue, bytes: addedBytes),
            ]))
        }
    }

    @Test
    func anItemAddedDuringAReadMustBeIncludedInAWholeGestureRetry() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let initial = NSPasteboardItem()
        let later = NSPasteboardItem()
        let initialBytes = Data("first item".utf8)
        let laterBytes = Data("later item".utf8)
        try #require(initial.setData(initialBytes, forType: .string))
        try #require(later.setData(laterBytes, forType: .string))
        try #require(pasteboard.writeObjects([initial]))
        let generation = pasteboard.changeCount
        var didAppendItem = false
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadCompletionHook = { _ in
            guard !didAppendItem else { return }
            didAppendItem = true
            #expect(pasteboard.writeObjects([later]))
        }

        let outcome = try #require(adapter.captureOutcome())
        try #require(pasteboard.changeCount == generation)
        try #require(didAppendItem)
        guard case let .changedDuringRead(changed) = outcome else {
            Issue.record("A newly appended item must discard the incomplete gesture")
            return
        }
        #expect(changed.startChangeCount == generation)
        #expect(changed.endChangeCount == generation)
        let capture = try #require(adapter.capture())
        #expect(capture.representations == [
            CapturedRepresentation(
                typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                bytes: initialBytes, pasteboardItemIndex: 0
            ),
            CapturedRepresentation(
                typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                bytes: laterBytes, pasteboardItemIndex: 1
            ),
        ])
    }

    @Test(arguments: [1, 2])
    func onlyEmptyContentRequestsALaterPayloadRead(itemCount: Int) throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let items = try (0..<itemCount).map { _ in
            let item = NSPasteboardItem()
            try #require(item.setData(Data(), forType: .string))
            return item
        }
        try #require(pasteboard.writeObjects(items))
        let generation = pasteboard.changeCount
        var emptyDeclarations: [Int] = []
        var emptyContent: [Int] = []
        let outcome = PasteboardAdapter(pasteboard: pasteboard).captureOutcome(
            shouldContinue: { true },
            didObserveEmptyPasteboard: { emptyDeclarations.append($0) },
            didObserveNoRetainableContent: { emptyContent.append($0) }
        )

        #expect(outcome == nil)
        #expect(emptyDeclarations.isEmpty)
        #expect(emptyContent == [generation])
    }

    @Test
    func optionalLineageWithoutContentWaitsForDeclarationsWithoutPayloadRetry() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        let hintID = HistoryItemID(rawValue: UUID())
        try #require(item.setData(
            PasteboardLineageHint.encode(hintID),
            forType: .init(PasteboardLineageHint.typeIdentifier)
        ))
        try #require(pasteboard.writeObjects([item]))
        let generation = pasteboard.changeCount
        var emptyDeclarations: [Int] = []
        var emptyContent: [Int] = []
        let outcome = PasteboardAdapter(pasteboard: pasteboard).captureOutcome(
            shouldContinue: { true },
            didObserveEmptyPasteboard: { emptyDeclarations.append($0) },
            didObserveNoRetainableContent: { emptyContent.append($0) }
        )

        #expect(outcome == nil)
        #expect(emptyDeclarations == [generation])
        #expect(emptyContent.isEmpty)
    }

    @Test
    func incompleteConstituentContentRecoversWithoutPublishingPartialBytes() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let observer = PasteboardObserver(
            adapter: PasteboardAdapter(pasteboard: pasteboard), pollInterval: 0.5
        )
        observer.setAccessBehaviorProviderForTesting { .allowed }
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }
        let first = NSPasteboardItem()
        let second = NSPasteboardItem()
        let firstBytes = Data("first published item".utf8)
        let secondBytes = Data("second published item".utf8)
        try #require(first.setData(firstBytes, forType: .string))
        try #require(second.setData(Data(), forType: .string))
        pasteboard.clearContents()
        try #require(pasteboard.writeObjects([first, second]))
        let generation = pasteboard.changeCount

        observer.pollForTesting()
        #expect(received.isEmpty)
        try #require(second.setData(secondBytes, forType: .string))
        try #require(pasteboard.changeCount == generation)
        observer.pollForTesting()

        guard case let .complete(value) = try #require(received.first) else {
            Issue.record("Every constituent item must be present before History receives the gesture")
            return
        }
        #expect(value.capture.representations == [
            CapturedRepresentation(
                typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                bytes: firstBytes, pasteboardItemIndex: 0
            ),
            CapturedRepresentation(
                typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                bytes: secondBytes, pasteboardItemIndex: 1
            ),
        ])
        #expect(received.count == 1)
        observer.pollForTesting()
        #expect(received.count == 1)
    }

    @Test
    func contentDeclaredAfterOptionalLineageRecoversWithoutRereadingMetadataPayload() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        var payloadReads: [String] = []
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadObserver = { payloadReads.append($0) }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 0.5)
        observer.setAccessBehaviorProviderForTesting { .allowed }
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }
        let hintID = HistoryItemID(rawValue: UUID())
        pasteboard.clearContents()
        try #require(pasteboard.setData(
            PasteboardLineageHint.encode(hintID),
            forType: .init(PasteboardLineageHint.typeIdentifier)
        ))
        let generation = pasteboard.changeCount

        observer.pollForTesting()
        #expect(received.isEmpty)
        #expect(payloadReads == [PasteboardLineageHint.typeIdentifier])
        observer.pollForTesting()
        observer.pollForTesting()
        #expect(payloadReads == [PasteboardLineageHint.typeIdentifier])

        let contentBytes = Data("content declared later".utf8)
        _ = pasteboard.addTypes([.string], owner: nil)
        try #require(pasteboard.setData(contentBytes, forType: .string))
        try #require(pasteboard.changeCount == generation)
        observer.pollForTesting()
        guard case let .complete(value) = try #require(received.first) else {
            Issue.record("Content declared after metadata must remain eligible for capture")
            return
        }
        #expect(value.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, bytes: contentBytes
        )])
        #expect(value.capture.origin.lineageHint == hintID)
        #expect(received.count == 1)
        let readCountAfterCapture = payloadReads.count
        observer.pollForTesting()
        #expect(payloadReads.count == readCountAfterCapture)
        #expect(received.count == 1)
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("com.clipy.declaration-fence." + UUID().uuidString))
    }
}
#endif
