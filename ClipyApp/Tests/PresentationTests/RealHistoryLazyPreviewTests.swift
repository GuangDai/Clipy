import Foundation
@testable import HistoryCore
@testable import HistoryStorage
import Testing
@testable import ClipyApp

@MainActor
struct RealHistoryLazyPreviewTests {
    @Test func dwellPreparesTheRealPreviewAndDisplayDoesNotReadItAgain() async throws {
        let store = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture([
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("Already prepared".utf8))
        ], in: store)
        let history = PreviewReadRecorder(store)
        let loader = PreviewContentLoader(history: history)
        let pane = PreviewPaneState(autoOpenDelay: .seconds(3_600))
        var preparation: Task<Void, Never>?
        pane.onPreparationTargetChanged = { item in
            if let item {
                preparation = loader.prepare(item: item, textConfiguration: .init())
            } else {
                loader.clear()
            }
        }
        defer { pane.panelClosed() }
        pane.handleSelectionChange(item)
        let prepared = try #require(preparation)
        await prepared.value
        #expect(!pane.isOpen)
        #expect(loader.phase == .content(.text("Already prepared")))

        await loader.loadForDisplay(item: item, pdfPage: 1, textConfiguration: .init(), isRetry: false)
        #expect(await history.reads().representations.count == 1)
        #expect(loader.phase == .content(.text("Already prepared")))

        // A changed user preference cannot reuse the old prepared prefix.
        await loader.loadForDisplay(item: item, pdfPage: 1,
            textConfiguration: .init(maximumCharacters: 7), isRetry: false)
        #expect(await history.reads().representations.count == 2)
        #expect(loader.phase == .content(.text("Already", wasTruncated: true)))
        pane.panelClosed()
        #expect(loader.requestedItem == nil)
        #expect(loader.textSegments.isEmpty)
    }

    @Test func validPlainTextDoesNotReadRichOrOpaqueSiblings() async throws {
        let store = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture([
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("selected text".utf8)),
            .init(typeIdentifier: "public.rtf", bytes: Data(repeating: 0x41, count: 2 * 1_048_576)),
            .init(typeIdentifier: "dyn.private", bytes: Data(repeating: 0x42, count: 128 * 1_024)),
        ], in: store)
        let history = PreviewReadRecorder(store)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        #expect(loader.phase == .content(.text("selected text")))
        let reads = await history.reads()
        #expect(reads.paste == 0)
        #expect(reads.representations == [HistoryRepresentationRequest(
            item: item, basis: .effective, typeIdentifier: "public.utf8-plain-text"
        )])
    }

    @Test(arguments: [false, true])
    func unsupportedOrOverBudgetMetadataFinishesBeforePayloadIO(overBudget: Bool) async throws {
        let store = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture([.init(
            typeIdentifier: overBudget ? "public.rtf" : "dyn.private",
            bytes: Data(repeating: 0x41, count: 1_048_577)
        )], in: store)
        let history = PreviewReadRecorder(store)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        #expect(loader.phase == (overBudget ? .failed : .unsupported))
        #expect(!loader.canRetryFailure)
        let reads = await history.reads()
        #expect(reads.paste == 0)
        #expect(reads.representations.isEmpty)
    }

    @Test func malformedPrimaryImageDoesNotReadAPlainTextFallback() async throws {
        let store = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture([
            .init(typeIdentifier: "public.png", bytes: Data("not an image".utf8)),
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("must not display".utf8)),
        ], in: store)
        let history = PreviewReadRecorder(store)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        #expect(loader.phase == .failed)
        let reads = await history.reads()
        #expect(reads.representations.map(\.typeIdentifier) == ["public.png"])
        #expect(reads.paste == 0)
    }

    @Test func invalidPlainTextReadsOnlyTheNextSupportedCandidate() async throws {
        let store = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture([
            .init(typeIdentifier: "public.utf16-plain-text", bytes: Data([0x41])),
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("valid fallback".utf8)),
            .init(typeIdentifier: "public.rtf", bytes: Data(#"{\rtf1 unneeded}"#.utf8)),
        ], in: store)
        let history = PreviewReadRecorder(store)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        #expect(loader.phase == .content(.text("valid fallback")))
        let reads = await history.reads()
        #expect(reads.representations.map(\.typeIdentifier) == ["public.utf16-plain-text", "public.utf8-plain-text"])
        #expect(reads.paste == 0)
    }

    private func capture(_ representations: [CapturedRepresentation], in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: representations, origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_500_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}

/// Observes caller demand while every operation runs against real SQLite.
/// It neither fabricates content nor supplies an alternate persistence writer.
private actor PreviewReadRecorder: ClipboardHistory {
    func backup(to directory: URL) async throws -> HistoryBackupReceipt {
        try await history.backup(to: directory)
    }

    private let history: SQLiteHistory
    private var pasteRequests = 0
    private var representationRequests: [HistoryRepresentationRequest] = []

    init(_ history: SQLiteHistory) { self.history = history }
    func reads() -> (paste: Int, representations: [HistoryRepresentationRequest]) {
        (pasteRequests, representationRequests)
    }
    func perform(_ action: HistoryAction) async throws -> HistoryReceipt { try await history.perform(action) }
    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage { try await history.browse(request) }
    func observe(_ request: HistoryObservationRequest) async -> AsyncThrowingStream<HistoryPage, Error> {
        await history.observe(request)
    }
    func copySources(
        for id: HistoryItemID, expectedCopyCount: UInt64, offset: Int
    ) async throws -> HistoryCopySourcePage {
        try await history.copySources(for: id, expectedCopyCount: expectedCopyCount, offset: offset)
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails { try await history.details(for: id) }
    func representation(_ request: HistoryRepresentationRequest) async throws -> HistoryRepresentation {
        representationRequests.append(request)
        return try await history.representation(request)
    }
    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        pasteRequests += 1
        return try await history.pastePayload(for: id)
    }
    func thumbnail(for item: HistoryItemReference, pixels: PixelSize) async throws -> ThumbnailPayload? {
        try await history.thumbnail(for: item, pixels: pixels)
    }
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration { try await history.retentionConfiguration() }
    func usage() async throws -> HistoryUsage { try await history.usage() }
}
