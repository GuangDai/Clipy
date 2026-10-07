import AppKit
import Foundation
import HistoryCore
import Testing
@testable import PasteboardAdapter

#if DEBUG
@MainActor
private final class PendingPublicationAccess {
    var behavior = PasteboardAccessBehavior.allowed
    var revokeInAccessCallback = true
}

@Suite("Pasteboard incomplete publication recovery")
@MainActor
struct PasteboardObserverPendingPublicationTests {
    @Test(arguments: [false, true])
    func accessCallbackReentryCannotAuthorizePayloadsAfterRevocation(nestedPoll: Bool) throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let access = PendingPublicationAccess()
        access.behavior = .denied
        var reads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadObserver = { _ in reads += 1 }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        observer.setAccessBehaviorProviderForTesting { access.behavior }
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(
            captureCurrent: false,
            onAccessBehaviorChanged: { behavior in
                guard behavior == .allowed, access.revokeInAccessCallback else { return }
                access.behavior = .denied
                // The application can retry access synchronously from this
                // callback. Observation keeps the same timer during denial.
                if nestedPoll { observer.pollForTesting() }
            },
            handler: { received.append($0) }
        )
        let bytes = Data("copied while access was changing".utf8)
        pasteboard.clearContents()
        try #require(pasteboard.setData(bytes, forType: .string))
        access.behavior = .allowed
        observer.pollForTesting()
        #expect(reads == 0)
        #expect(received.isEmpty)

        access.revokeInAccessCallback = false
        access.behavior = .allowed
        observer.pollForTesting()
        guard case let .complete(complete) = try #require(received.first) else {
            Issue.record("a later stable permission grant must recover the unread value")
            return
        }
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            bytes: bytes
        )])
        observer.pollForTesting()
        #expect(reads == 1)
        #expect(received.count == 1)
    }

    @Test
    func accessCallbackGrantAfterDenialLeavesTheGenerationUnreadUntilTheNextTick() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let access = PendingPublicationAccess()
        var reads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadObserver = { _ in reads += 1 }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        observer.setAccessBehaviorProviderForTesting { access.behavior }
        defer { observer.stop() }
        var admissionAllowed = true
        var received: [CaptureOutcome] = []
        observer.start(
            captureCurrent: false,
            onAccessBehaviorChanged: { behavior in
                admissionAllowed = behavior == .allowed
                if behavior == .denied { access.behavior = .allowed }
            },
            handler: { outcome in
                if admissionAllowed { received.append(outcome) }
            }
        )
        let bytes = Data("new value requires a confirmed allowed callback".utf8)
        pasteboard.clearContents()
        try #require(pasteboard.setData(bytes, forType: .string))
        access.behavior = .denied
        observer.pollForTesting()
        #expect(reads == 0)
        #expect(received.isEmpty)
        observer.pollForTesting()
        guard case let .complete(complete) = try #require(received.first) else {
            Issue.record("permission callback recovery must not consume an unread generation")
            return
        }
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            bytes: bytes
        )])
        observer.pollForTesting()
        #expect(reads == 1)
        #expect(received.count == 1)
    }

    @Test
    func aGrantDuringTheRevocationCallbackCannotTurnAnAbortedFreezeIntoMetadataOnly() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let bytes = Data("recover the aborted freeze on a later tick".utf8)
        pasteboard.clearContents()
        try #require(pasteboard.setData(bytes, forType: .string))
        let access = PendingPublicationAccess()
        var reads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadCompletionHook = { _ in
            reads += 1
            if reads == 1 { access.behavior = .denied }
        }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        observer.setAccessBehaviorProviderForTesting { access.behavior }
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(
            onAccessBehaviorChanged: { behavior in
                if behavior == .denied { access.behavior = .allowed }
            },
            handler: { received.append($0) }
        )
        try #require(reads == 1)
        #expect(received.isEmpty)
        observer.pollForTesting()
        guard case let .complete(complete) = try #require(received.first) else {
            Issue.record("an access-aborted nil result must stay eligible after callback recovery")
            return
        }
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            bytes: bytes
        )])
        observer.pollForTesting()
        #expect(reads == 2)
        #expect(received.count == 1)
    }

    @Test
    func longUnavailablePublicationHasBoundedReadsAndRecoversInTheSameGeneration() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        var payloadReads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadObserver = { _ in payloadReads += 1 }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 0.1)
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }

        let generation = pasteboard.declareTypes([.string], owner: nil)
        observer.pollForTesting()
        try #require(received.count == 1)
        guard case .declaredUnavailable = try #require(received.first) else {
            Issue.record("unavailable declared bytes must be reported before recovery")
            return
        }
        // Each deterministic poll advances the production retry schedule by
        // one timer interval. After the initial backoff, ten seconds of ticks
        // can perform at most eleven reads, including a window boundary.
        for _ in 0..<100 { observer.pollForTesting() }
        let readsBeforeWindow = payloadReads
        for _ in 0..<100 { observer.pollForTesting() }
        #expect(payloadReads - readsBeforeWindow <= 11)
        #expect(payloadReads > readsBeforeWindow)
        #expect(received.count == 1)

        let bytes = Data("published after a long unavailable interval".utf8)
        try #require(pasteboard.setData(bytes, forType: .string))
        try #require(pasteboard.changeCount == generation)
        for _ in 0..<16 {
            if received.contains(where: isComplete) { break }
            observer.pollForTesting()
        }
        guard case let .complete(complete) = try #require(received.last) else {
            Issue.record("late bytes in the same ownership generation must be recovered")
            return
        }
        #expect(complete.changeCount == generation)
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            bytes: bytes
        )])
        #expect(received.count == 2)
        let completedReads = payloadReads
        for _ in 0..<16 { observer.pollForTesting() }
        #expect(payloadReads == completedReads)
        #expect(received.count == 2)
    }

    @Test
    func aNewGenerationImmediatelyReplacesAnUnavailableGeneration() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let observer = PasteboardObserver(
            adapter: PasteboardAdapter(pasteboard: pasteboard), pollInterval: 0.1
        )
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }
        _ = pasteboard.declareTypes([.string], owner: nil)
        for _ in 0..<100 { observer.pollForTesting() }
        try #require(!received.contains(where: isComplete))

        let bytes = Data("new owner bypasses previous retry delay".utf8)
        pasteboard.clearContents()
        try #require(pasteboard.setData(bytes, forType: .string))
        observer.pollForTesting()
        guard case let .complete(complete) = try #require(received.last) else {
            Issue.record("new ownership must be captured on its first observed tick")
            return
        }
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            bytes: bytes
        )])
        #expect(received.filter(isComplete).count == 1)
    }

    @Test
    func accessRevocationDuringAReadDoesNotConsumeTheUnchangedGeneration() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let bytes = Data("same generation after access recovery".utf8)
        pasteboard.clearContents()
        try #require(pasteboard.setData(bytes, forType: .string))
        let generation = pasteboard.changeCount
        let access = PendingPublicationAccess()
        var reads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadCompletionHook = { _ in
            reads += 1
            if reads == 1 { access.behavior = .denied }
        }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        observer.setAccessBehaviorProviderForTesting { access.behavior }
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start { received.append($0) }
        try #require(received.isEmpty)
        try #require(reads == 1)
        observer.pollForTesting()
        #expect(reads == 1)
        access.behavior = .allowed
        observer.pollForTesting()

        guard case let .complete(complete) = try #require(received.first) else {
            Issue.record("access recovery must retry the unread unchanged generation")
            return
        }
        #expect(complete.changeCount == generation)
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            bytes: bytes
        )])
        observer.pollForTesting()
        #expect(received.count == 1)
        #expect(reads == 2)
    }

    @Test(arguments: [false, true])
    func startingWithoutAccessPreservesTheRequestedInitialCapture(captureCurrent: Bool) throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let bytes = Data("present before denied startup".utf8)
        pasteboard.clearContents()
        try #require(pasteboard.setData(bytes, forType: .string))
        let access = PendingPublicationAccess()
        access.behavior = .denied
        var reads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadObserver = { _ in reads += 1 }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        observer.setAccessBehaviorProviderForTesting { access.behavior }
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        var initialFlags: [Bool] = []
        observer.start(captureCurrent: captureCurrent) {
            received.append($0)
            initialFlags.append(observer.isDeliveringInitialCapture)
        }
        observer.pollForTesting()
        #expect(reads == 0)
        #expect(received.isEmpty)
        access.behavior = .allowed
        observer.pollForTesting()
        #expect(reads == (captureCurrent ? 1 : 0))
        #expect(received.count == (captureCurrent ? 1 : 0))
        #expect(initialFlags == (captureCurrent ? [true] : []))
        observer.pollForTesting()
        #expect(reads == (captureCurrent ? 1 : 0))

        pasteboard.clearContents()
        try #require(pasteboard.setString("copied after access recovery", forType: .string))
        observer.pollForTesting()
        #expect(received.count == (captureCurrent ? 2 : 1))
        #expect(initialFlags.last == false)
    }

    @Test
    func baselineRestartDropsAnUnpublishedGeneration() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let observer = PasteboardObserver(
            adapter: PasteboardAdapter(pasteboard: pasteboard), pollInterval: 60
        )
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }
        let generation = pasteboard.declareTypes([.string], owner: nil)
        observer.pollForTesting()
        try #require(received.count == 1)
        observer.stop()
        observer.start(captureCurrent: false) { received.append($0) }
        try #require(pasteboard.setString("excluded paused publication", forType: .string))
        try #require(pasteboard.changeCount == generation)
        for _ in 0..<16 { observer.pollForTesting() }
        #expect(received.count == 1)
        #expect(!received.contains(where: isComplete))
    }

    private func isComplete(_ outcome: CaptureOutcome) -> Bool {
        if case .complete = outcome { return true }
        return false
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("com.clipy.pending-publication." + UUID().uuidString))
    }
}
#endif
