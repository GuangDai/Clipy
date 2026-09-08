import ContentPreview
import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import PresentationUI

@MainActor
struct MultiItemPresentationTests {
    private let textType = "public.utf8-plain-text"

    @Test func editorReplacesOnlyTheSelectedConstituentItemAndDetailsExportAddressesIt() async throws {
        let (history, item) = try await capture([
            CapturedRepresentation(typeIdentifier: textType, bytes: Data("first".utf8)),
            CapturedRepresentation(typeIdentifier: textType, bytes: Data("second".utf8), pasteboardItemIndex: 1)
        ])
        let details = try await history.details(for: item.id)
        let presentation = try DetailsContentPresentation(details: details)
        #expect(Set(presentation.canonical.map(\.identity)).count == 2)
        var draft = ReviseEditorDraft(details: details)
        let request = try #require(draft.replacementRequest(for: textType, pasteboardItemIndex: 1))
        #expect(request.pasteboardItemIndex == 1)
        #expect(draft.installReplacementSource(try await history.representation(request)))
        draft.setChoice(.replace, for: textType, pasteboardItemIndex: 1)
        draft.setReplacementText("second edited", for: textType, pasteboardItemIndex: 1)
        #expect(draft.choice(for: textType) == .keepCurrent)
        #expect(!draft.hasReplacementSource(for: textType))
        #expect(draft.replacementText(for: textType, pasteboardItemIndex: 1) == "second edited")
        _ = try await history.perform(.revise(draft.revisionRequest()))
        let latest = try await history.details(for: item.id)
        let first = try #require(ContentBasis.effective.representation(typeIdentifier: textType, in: latest))
        let second = try #require(ContentBasis.effective.representation(
            typeIdentifier: textType, in: latest, pasteboardItemIndex: 1
        ))
        #expect(try await history.representation(first).bytes == Data("first".utf8))
        #expect(try await history.representation(second).bytes == Data("second edited".utf8))
        let original = try #require(ContentBasis.canonical.representation(
            typeIdentifier: textType, in: latest, pasteboardItemIndex: 1
        ))
        #expect(try await history.representation(original).bytes == Data("second".utf8))
        let secondMetadata = try #require(latest.effective.first { $0.pasteboardItemIndex == 1 })
        let preview = try await DetailsRepresentationPresentation.load(
            second, metadata: secondMetadata, history: history, renderer: ContentPreview()
        )
        #expect(preview == .plainText("second edited"))
    }

    @Test func editorCannotHideTheLastFormatOfOneItemWhileAnotherRemainsVisible() async throws {
        let (history, item) = try await capture([
            CapturedRepresentation(typeIdentifier: textType, bytes: Data("first".utf8)),
            CapturedRepresentation(typeIdentifier: textType, bytes: Data("second".utf8), pasteboardItemIndex: 1)
        ])
        var draft = ReviseEditorDraft(details: try await history.details(for: item.id))
        draft.setChoice(.hide, for: textType, pasteboardItemIndex: 1)
        #expect(!draft.allRepresentationsHidden)
        #expect(draft.hasEmptyPasteboardItem)
        #expect(!draft.canSubmit)
        draft.setChoice(.useOriginal, for: textType, pasteboardItemIndex: 1)
        #expect(!draft.hasEmptyPasteboardItem)
        #expect(draft.canSubmit)
    }

    @Test func previewChoosesFirstRenderableItemWithoutCollapsingRepeatedTypes() async throws {
        let (history, item) = try await capture([
            CapturedRepresentation(typeIdentifier: textType, bytes: Data([0xFF])),
            CapturedRepresentation(typeIdentifier: textType, bytes: Data("second".utf8), pasteboardItemIndex: 1),
            CapturedRepresentation(typeIdentifier: textType, bytes: Data("third".utf8), pasteboardItemIndex: 2)
        ])
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        #expect(loader.phase == .content(.text("second")))
    }

    @Test func previewKeepsTheFirstItemsFormatPrioritySeparateFromLaterItems() async throws {
        let (history, item) = try await capture([
            CapturedRepresentation(typeIdentifier: textType, bytes: Data("first".utf8)),
            CapturedRepresentation(typeIdentifier: textType, bytes: Data("second".utf8), pasteboardItemIndex: 1)
        ])
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        #expect(loader.phase == .content(.text("first")))
    }

    private func capture(_ representations: [CapturedRepresentation]) async throws -> (SQLiteHistory, HistoryItemReference) {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: representations,
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSince1970: 1)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return (history, item)
    }
}
