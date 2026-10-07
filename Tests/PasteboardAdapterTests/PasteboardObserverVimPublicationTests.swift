import AppKit
import Foundation
import HistoryCore
import Testing
@testable import PasteboardAdapter

#if DEBUG
/// Vim's native macOS writer declares both formats before filling either
/// payload, then publishes its motion/text property list before plain text:
/// https://github.com/vim/vim/blob/master/src/os_macosx.m
/// These private pasteboards exercise the real AppKit declaration API. Each
/// manual poll represents a complete timer interval; no sleeps or general
/// pasteboard access are needed.
@Suite("Vim pasteboard publication")
@MainActor
struct PasteboardObserverVimPublicationTests {
    enum PublicationInterruption: CaseIterable, Equatable, Sendable {
        case afterDeclarations
        case afterPrivateFormat
        case afterBoth
    }

    private static let vimType = NSPasteboard.PasteboardType("VimPboardType")

    @Test(arguments: PublicationInterruption.allCases)
    func vimPublishesBothFormatsAfterAnIncompleteObservation(
        interruption: PublicationInterruption
    ) throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        var payloadReads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadObserver = { _ in payloadReads += 1 }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }

        let text = "Vim copied 中文\nsecond line\n"
        let generation = pasteboard.declareTypes([Self.vimType, .string], owner: nil)
        if interruption != .afterPrivateFormat {
            observer.pollForTesting()
        }
        let selection: [Any] = [NSNumber(value: 1), text]
        try #require(pasteboard.setPropertyList(selection, forType: Self.vimType))
        if interruption != .afterDeclarations {
            observer.pollForTesting()
        }
        try #require(payloadReads > 0)
        try #require(completeOutcomes(in: received).isEmpty)
        try #require(received.contains { outcome in
            if case .declaredUnavailable = outcome { return true }
            return false
        })

        try #require(pasteboard.setString(text, forType: .string))
        try #require(pasteboard.changeCount == generation)
        let item = try #require(pasteboard.pasteboardItems?.first)
        try #require(item.types.count == 2)
        let expected = try item.types.map { type in
            CapturedRepresentation(
                typeIdentifier: type.rawValue,
                bytes: try #require(item.data(forType: type))
            )
        }
        try #require(pasteboard.data(forType: .string) == Data(text.utf8))
        try #require(pasteboard.data(forType: Self.vimType)?.isEmpty == false)

        for _ in 0..<16 {
            if !completeOutcomes(in: received).isEmpty { break }
            observer.pollForTesting()
        }
        let complete = try #require(completeOutcomes(in: received).first)
        #expect(complete.changeCount == generation)
        #expect(Set(complete.capture.representations) == Set(expected))

        let readsAfterCompletion = payloadReads
        for _ in 0..<16 { observer.pollForTesting() }
        #expect(completeOutcomes(in: received).count == 1)
        #expect(payloadReads == readsAfterCompletion)
    }

    @Test
    func declaredEmptyTextCanBeFilledWithoutAnotherOwnershipChange() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        var payloadReads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadObserver = { _ in payloadReads += 1 }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        defer { observer.stop() }
        var received: [CaptureOutcome] = []
        observer.start(captureCurrent: false) { received.append($0) }

        let generation = pasteboard.declareTypes([.string], owner: nil)
        try #require(pasteboard.setData(Data(), forType: .string))
        try #require(pasteboard.pasteboardItems?.isEmpty == false)
        try #require(pasteboard.data(forType: .string) == Data())
        observer.pollForTesting()
        try #require(payloadReads > 0)
        try #require(completeOutcomes(in: received).isEmpty)

        let text = "text published after an empty representation"
        try #require(pasteboard.setString(text, forType: .string))
        try #require(pasteboard.changeCount == generation)
        for _ in 0..<16 {
            if !completeOutcomes(in: received).isEmpty { break }
            observer.pollForTesting()
        }
        let complete = try #require(completeOutcomes(in: received).first)
        #expect(complete.changeCount == generation)
        #expect(complete.capture.representations == [CapturedRepresentation(
            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
            bytes: Data(text.utf8)
        )])

        let readsAfterCompletion = payloadReads
        for _ in 0..<16 { observer.pollForTesting() }
        #expect(completeOutcomes(in: received).count == 1)
        #expect(payloadReads == readsAfterCompletion)
    }

    private func completeOutcomes(in outcomes: [CaptureOutcome]) -> [CaptureOutcome.Complete] {
        outcomes.compactMap { outcome in
            if case let .complete(value) = outcome { return value }
            return nil
        }
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("com.clipy.vim-publication." + UUID().uuidString))
    }
}
#endif
