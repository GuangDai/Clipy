import AppKit
import Foundation
import HistoryCore
import Testing
@testable import PasteboardAdapter

#if DEBUG
@MainActor
private final class EmptyPublicationAccess {
    var behavior = PasteboardAccessBehavior.allowed
}

private final class EmptyPublicationProvider: NSObject, NSPasteboardItemDataProvider {
    private let bytes: Data

    init(bytes: Data) { self.bytes = bytes }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        _ = item.setData(bytes, forType: type)
    }
}

@Suite("Pasteboard publication after empty ownership")
@MainActor
struct PasteboardObserverEmptyPublicationTests {
    enum Reentry: CaseIterable, Equatable, Sendable {
        case sameGeneration, newerValue, newerEmpty
    }

    @Test(arguments: Reentry.allCases)
    func delayedPromisedReadDoesNotReenterItsOwnGenerationOrOverwriteANewerPoll(reentry: Reentry) throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let promisedBytes = Data("promised value".utf8)
        let newerBytes = Data("newer value".utf8)
        let provider = EmptyPublicationProvider(bytes: promisedBytes)
        let promisedItem = NSPasteboardItem()
        try #require(promisedItem.setDataProvider(provider, forTypes: [.string]))
        weak var activeObserver: PasteboardObserver?
        var payloadReads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadCompletionHook = { _ in
            payloadReads += 1
            guard payloadReads == 1 else { return }
            if reentry != .sameGeneration {
                pasteboard.clearContents()
                if reentry == .newerValue {
                    let item = NSPasteboardItem()
                    #expect(item.setData(newerBytes, forType: .string))
                    #expect(pasteboard.writeObjects([item]))
                }
            }
            activeObserver?.pollForTesting()
        }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        activeObserver = observer
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }
        pasteboard.clearContents()
        observer.pollForTesting()
        try #require(pasteboard.writeObjects([promisedItem]))
        withExtendedLifetime(provider) { observer.pollForTesting() }

        if reentry == .newerEmpty {
            #expect(received.isEmpty)
            #expect(payloadReads == 1)
            let generation = pasteboard.changeCount
            let item = NSPasteboardItem()
            try #require(item.setData(newerBytes, forType: .string))
            try #require(pasteboard.writeObjects([item]))
            #expect(pasteboard.changeCount == generation)
            observer.pollForTesting()
        }

        guard case let .complete(complete) = try #require(received.first) else {
            Issue.record("Only the surviving generation may produce a complete capture")
            return
        }
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            bytes: reentry == .sameGeneration ? promisedBytes : newerBytes
        )])
        #expect(complete.changeCount == pasteboard.changeCount)
        #expect(payloadReads == (reentry == .sameGeneration ? 1 : 2))
        observer.pollForTesting()
        #expect(received.count == 1)
        #expect(payloadReads == (reentry == .sameGeneration ? 1 : 2))
    }

    @Test(arguments: [0, 100])
    func emptyOwnershipCanPublishPNGWithoutAnotherChangeCount(emptyPolls: Int) throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        ))
        let item = NSPasteboardItem()
        try #require(item.setData(png, forType: .png))
        var payloadReads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadObserver = { _ in payloadReads += 1 }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }

        let clearedCount = pasteboard.clearContents()
        observer.pollForTesting()
        for _ in 0..<emptyPolls { observer.pollForTesting() }
        #expect(received.isEmpty)
        #expect(payloadReads == 0)
        try #require(pasteboard.writeObjects([item]))
        let publishedCount = pasteboard.changeCount
        print("CLIPY_PB_EMPTY_PUBLISH cleared_count=\(clearedCount) published_count=\(publishedCount)")
        #expect(publishedCount == clearedCount)

        observer.pollForTesting()
        guard case let .complete(complete) = try #require(received.first) else {
            Issue.record("A payload published after empty ownership must be captured")
            return
        }
        #expect(complete.changeCount == publishedCount)
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue, bytes: png
        )])
        observer.pollForTesting()
        #expect(received.count == 1)
        #expect(payloadReads == 1)
    }

    @Test
    func aBaselineRestartExcludesPublicationIntoTheStoppedEmptyGeneration() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let observer = PasteboardObserver(adapter: PasteboardAdapter(pasteboard: pasteboard), pollInterval: 60)
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }
        let emptyGeneration = pasteboard.clearContents()
        observer.pollForTesting()
        observer.stop()

        let excluded = NSPasteboardItem()
        try #require(excluded.setData(Data("excluded while stopped".utf8), forType: .string))
        try #require(pasteboard.writeObjects([excluded]))
        #expect(pasteboard.changeCount == emptyGeneration)
        observer.pollForTesting()
        #expect(received.isEmpty)
        observer.start(captureCurrent: false) { received.append($0) }
        observer.pollForTesting()
        #expect(received.isEmpty)

        let later = NSPasteboardItem()
        let bytes = Data("copied after restart".utf8)
        try #require(later.setData(bytes, forType: .string))
        pasteboard.clearContents()
        try #require(pasteboard.writeObjects([later]))
        observer.pollForTesting()
        guard case let .complete(complete) = try #require(received.first) else {
            Issue.record("The first copy in the new session must be captured")
            return
        }
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, bytes: bytes
        )])
        #expect(received.count == 1)
    }

    @Test(arguments: [PasteboardAccessBehavior.denied, .ask, .systemDefault, .unavailable])
    func delayedPublicationStillRequiresAllowedAccess(revokedBehavior: PasteboardAccessBehavior) throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let access = EmptyPublicationAccess()
        var payloadReads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadObserver = { _ in payloadReads += 1 }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        observer.setAccessBehaviorProviderForTesting { access.behavior }
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }
        let emptyGeneration = pasteboard.clearContents()
        observer.pollForTesting()
        access.behavior = revokedBehavior
        let item = NSPasteboardItem()
        try #require(item.setData(Data("later declaration".utf8), forType: .string))
        try #require(pasteboard.writeObjects([item]))
        #expect(pasteboard.changeCount == emptyGeneration)

        observer.pollForTesting()
        #expect(received.isEmpty)
        #expect(payloadReads == 0)
        access.behavior = .allowed
        observer.pollForTesting()
        #expect(received.count == 1)
        #expect(payloadReads == 1)
        observer.pollForTesting()
        #expect(received.count == 1)
        #expect(payloadReads == 1)
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("com.clipy.empty-publication." + UUID().uuidString))
    }
}
#endif
