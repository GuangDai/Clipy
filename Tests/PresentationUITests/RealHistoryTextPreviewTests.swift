import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

@MainActor
struct RealHistoryTextPreviewTests {
    @Test func switchingTextPreviewsUpdatesTruncationWithoutChangingPasteBytes() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let displayedPrefix = String(repeating: "x", count: 50_000)
        let completeLongBytes = Data((displayedPrefix + "z").utf8)
        let shortText = "short\n\n…"
        let shortBytes = Data(shortText.utf8)
        let longItem = try await capture(completeLongBytes, at: 100, in: history)
        let shortItem = try await capture(shortBytes, at: 200, in: history)
        let loader = PreviewContentLoader(history: history)

        await loader.load(item: longItem)
        guard case .content(.text(let longPreview, let longTruncated)) = loader.phase else {
            Issue.record("Expected the stored long text to produce a text preview")
            return
        }
        #expect(loader.requestedItem == longItem)
        #expect(longTruncated)
        #expect(Data(longPreview.utf8) == Data(displayedPrefix.utf8))
        let longPaste = try await history.pastePayload(for: longItem.id)
        #expect(longPaste.item == longItem)
        #expect(longPaste.representations.map(\.bytes) == [completeLongBytes])
        #expect(longPaste.representations.first?.bytes.count == 50_001)

        // An ellipsis copied by the user is literal content, not evidence
        // of truncation. The previous target's flag must not leak across.
        await loader.load(item: shortItem)
        guard case .content(.text(let shortPreview, let shortTruncated)) = loader.phase else {
            Issue.record("Expected the stored short text to produce a text preview")
            return
        }
        #expect(loader.requestedItem == shortItem)
        #expect(!shortTruncated)
        #expect(Data(shortPreview.utf8) == shortBytes)
        let shortPaste = try await history.pastePayload(for: shortItem.id)
        #expect(shortPaste.item == shortItem)
        #expect(shortPaste.representations.map(\.bytes) == [shortBytes])

        await loader.load(item: longItem)
        #expect(loader.phase == .content(.text(displayedPrefix, wasTruncated: true)))
        #expect(try await history.pastePayload(for: longItem.id) == longPaste)
    }

    private func capture(
        _ bytes: Data, at seconds: Double, in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: bytes)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: seconds)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}
