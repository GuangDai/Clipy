/// Card 5B observer retry acceptance: one ownership race receives one
/// immediate retry at the public observation seam. The tests use a named
/// private pasteboard and the existing DEBUG item-read boundary; they do not
/// wait for the observer timer or inspect observer internals.
import AppKit
import Foundation
import HistoryCore
import Synchronization
import Testing
@testable import PasteboardAdapter

#if DEBUG
/// Exercise reentry during either the first freeze or its one ownership
/// retry. The nested poll consumes the newer generation; returning to the
/// outer stack must neither read it again nor issue a second callback.
@Test(arguments: [1, 2]) @MainActor
func nestedPollSupersedesAnOuterFreezeWithoutDuplicateDelivery(nestedOnRead: Int) throws {
    let pasteboard = makeRetryPasteboard()
    defer { pasteboard.releaseGlobally() }
    replaceString(on: pasteboard, with: "generation-0")
    var payloadReads = 0
    weak var activeObserver: PasteboardObserver?
    var adapter = PasteboardAdapter(pasteboard: pasteboard)
    adapter.payloadReadCompletionHook = { _ in
        payloadReads += 1
        guard payloadReads <= nestedOnRead else { return }
        replaceString(on: pasteboard, with: "generation-\(payloadReads)")
        if payloadReads == nestedOnRead {
            activeObserver?.pollForTesting()
        }
    }
    let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
    activeObserver = observer
    defer { observer.stop() }
    var received: [CaptureOutcome] = []
    observer.start { received.append($0) }

    #expect(payloadReads == nestedOnRead + 1)
    #expect(received.count == 1)
    guard case let .complete(complete) = try #require(received.first) else {
        Issue.record("only the nested poll's complete generation should be delivered")
        return
    }
    #expect(complete.changeCount == pasteboard.changeCount)
    #expect(complete.capture.representations == [CapturedRepresentation(
        typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
        bytes: Data("generation-\(nestedOnRead)".utf8)
    )])
    observer.pollForTesting()
    #expect(payloadReads == nestedOnRead + 1)
    #expect(received.count == 1)
}

@MainActor
private func makeRetryPasteboard() -> NSPasteboard {
    NSPasteboard(
        name: NSPasteboard.Name(
            "com.clipy.pasteboardobserverretrytests." + UUID().uuidString
        )
    )
}

@MainActor
private func replaceString(
    on pasteboard: NSPasteboard,
    with value: String
) {
    pasteboard.clearContents()
    pasteboard.setData(Data(value.utf8), forType: .string)
}

@Test @MainActor
func observerRetriesChangedFreezeOnceAndEmitsOnlyStableCompleteOutcome() throws {
    let pasteboard = makeRetryPasteboard()
    replaceString(on: pasteboard, with: "old-generation")

    var payloadReads = 0
    var replacedInitialGeneration = false
    var adapter = PasteboardAdapter(pasteboard: pasteboard)
    adapter.payloadReadCompletionHook = { _ in
        payloadReads += 1
        guard !replacedInitialGeneration else { return }
        replacedInitialGeneration = true
        replaceString(on: pasteboard, with: "stable-generation")
    }
    let observer = PasteboardObserver(adapter: adapter)
    var received: [CaptureOutcome] = []

    observer.start { received.append($0) }
    defer { observer.stop() }

    #expect(received.count == 1)
    let outcome = try #require(received.first)
    #expect(payloadReads == 2)
    guard case let .complete(value) = outcome else {
        Issue.record("expected the stable retry to be the only complete outcome")
        return
    }
    #expect(value.changeCount == pasteboard.changeCount)
    #expect(value.capture.representations == [
        CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            bytes: Data("stable-generation".utf8)
        )
    ])
}

@Test @MainActor
func observerStopsAfterOneRetryAndEmitsOneTerminalContentFreeOutcome() throws {
    let pasteboard = makeRetryPasteboard()
    replaceString(on: pasteboard, with: "generation-0")

    var payloadReads = 0
    var adapter = PasteboardAdapter(pasteboard: pasteboard)
    adapter.payloadReadCompletionHook = { _ in
        payloadReads += 1
        replaceString(on: pasteboard, with: "generation-\(payloadReads)")
    }
    let observer = PasteboardObserver(adapter: adapter)
    var received: [CaptureOutcome] = []

    observer.start { received.append($0) }
    defer { observer.stop() }

    #expect(received.count == 1)
    let outcome = try #require(received.first)
    #expect(payloadReads == 2)
    guard case let .changedDuringRead(value) = outcome else {
        Issue.record("expected one terminal content-free ownership-race outcome")
        return
    }
    #expect(value.endChangeCount == pasteboard.changeCount)
    observer.pollForTesting()
    #expect(payloadReads == 2)
    #expect(received.count == 1)
}

@Test @MainActor
func observerChecksRevocationBeforeReadingChangedPasteboardItems() {
    let pasteboard = makeRetryPasteboard()
    replaceString(on: pasteboard, with: "allowed-generation")
    let accessBehavior = Mutex(PasteboardAccessBehavior.allowed)
    var payloadReads = 0
    var adapter = PasteboardAdapter(pasteboard: pasteboard)
    adapter.payloadReadObserver = { _ in payloadReads += 1 }
    let observer = PasteboardObserver(adapter: adapter)
    observer.setAccessBehaviorProviderForTesting {
        accessBehavior.withLock { $0 }
    }
    var accessEvents: [PasteboardAccessBehavior] = []
    var received: [CaptureOutcome] = []

    observer.start(
        onAccessBehaviorChanged: { accessEvents.append($0) },
        handler: { received.append($0) }
    )
    defer { observer.stop() }
    #expect(accessEvents == [.allowed])
    #expect(payloadReads == 1)
    #expect(received.count == 1)

    accessBehavior.withLock { $0 = .denied }
    replaceString(on: pasteboard, with: "denied-generation")
    observer.pollForTesting()

    #expect(accessEvents == [.allowed, .denied])
    #expect(payloadReads == 1)
    #expect(received.count == 1)
}
#endif
