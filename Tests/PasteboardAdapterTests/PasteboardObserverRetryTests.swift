/// Card 5B observer retry acceptance: one ownership race receives one
/// immediate retry at the public observation seam. The tests use a named
/// private pasteboard and the existing DEBUG item-read boundary; they do not
/// wait for the observer timer or inspect observer internals.
import AppKit
import Foundation
import HistoryCore
import Testing
@testable import PasteboardAdapter

#if DEBUG
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
}
#endif
