import ContentPreview
import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import PresentationUI

/// Exercises the same one-row preview read used by Details, with real SQLite
/// content and a read recorder. Export remains a separate complete byte read.
@MainActor
struct DetailsLazyRepresentationTests {
    @Test(arguments: ["public.rtf", "com.example.opaque"])
    func unavailablePreviewDoesNotReadBytesButExportRemainsComplete(type: String) async throws {
        let bytes = Data(repeating: 0x41, count: 1_048_577)
        let (store, item) = try await capture(type: type, bytes: bytes)
        let history = DetailsReadRecorder(store)
        let details = try await store.details(for: item.id)
        let metadata = try #require(details.canonical.first)
        let request = HistoryRepresentationRequest(item: item, basis: .canonical, typeIdentifier: type)
        let presentation = try await DetailsRepresentationPresentation.load(
            request, metadata: metadata, history: history, renderer: ContentPreview()
        )
        #expect(presentation == .metadataOnly)
        #expect(await history.requests.isEmpty)
        let exported = try await history.representation(request)
        #expect(exported.bytes == bytes)
        #expect(await history.requests == [request])
    }

    @Test(arguments: ["public.utf8-plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text"])
    func oversizedPlainTextMetadataRejectsBeforeTheEditorCodecReadsBytes(type: String) async throws {
        // Metadata demand is a UI decision. An unscripted read would fail;
        // no 64 MiB payload allocation is needed to prove zero read demand.
        let history = ScriptedHistory()
        let item = HistoryItemReference(id: HistoryItemID(rawValue: UUID()), contentVersion: .initial)
        let presentation = try await DetailsRepresentationPresentation.load(
            HistoryRepresentationRequest(item: item, basis: .effective, typeIdentifier: type),
            metadata: HistoryRepresentationMetadata(typeIdentifier: type, byteCount: 64 * 1_048_576 + 1),
            history: history, renderer: ContentPreview()
        )
        #expect(presentation == .metadataOnly)
        #expect(await history.representationRequests.isEmpty)
    }

    @Test func previewReadsSelectedBasisAndKeepsExportBytesBeyondItsExcerpt() async throws {
        let type = "public.utf8-plain-text"
        let text = "\u{FEFF}" + String(repeating: "🌿e\u{301}", count: 400)
        let bytes = Data(text.utf8)
        let (store, item) = try await capture(type: type, bytes: bytes)
        _ = try await store.perform(.revise(RevisionRequest(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: type, action: .replace(bytes: Data("edited".utf8)))
            ]))
        )))
        let history = DetailsReadRecorder(store)
        let details = try await store.details(for: item.id)
        for (basis, metadata, expected) in [
            (HistoryContentBasis.canonical, details.canonical[0], String(text.prefix(500))),
            (.effective, details.effective[0], "edited")
        ] {
            let request = HistoryRepresentationRequest(item: details.item, basis: basis, typeIdentifier: type)
            let presentation = try await DetailsRepresentationPresentation.load(
                request, metadata: metadata, history: history, renderer: ContentPreview()
            )
            #expect(presentation == .plainText(expected, wasTruncated: basis == .canonical))
        }
        #expect(await history.requests.map(\.basis) == [.canonical, .effective])
        let original = try await history.representation(HistoryRepresentationRequest(
            item: details.item, basis: .canonical, typeIdentifier: type
        ))
        #expect(original.bytes == bytes)
    }

    @Test func cancelledNoncooperativeReadCannotReturnPreviewContent() async throws {
        let type = "public.utf8-plain-text"
        let (store, item) = try await capture(type: type, bytes: Data("sensitive text".utf8))
        let history = DetailsReadRecorder(store, holdsRead: true)
        let details = try await store.details(for: item.id)
        let metadata = try #require(details.effective.first)
        let task = Task {
            try await DetailsRepresentationPresentation.load(
                HistoryRepresentationRequest(item: item, basis: .effective, typeIdentifier: type),
                metadata: metadata, history: history, renderer: ContentPreview()
            )
        }
        let suspended = await pollUntil { await history.isSuspended }
        #expect(suspended)
        task.cancel()
        await history.releaseRead()
        do {
            _ = try await task.value
            Issue.record("Cancelled Details preview returned content")
        } catch is CancellationError {
            // The underlying History read deliberately returned its full
            // value after cancellation; the production preview discards it.
        }
    }

    @Test func staleRepresentationReadStaysTypedAndRetryCanUseFreshMetadata() async throws {
        let type = "public.utf8-plain-text"
        let (store, item) = try await capture(type: type, bytes: Data("original".utf8))
        let details = try await store.details(for: item.id)
        _ = try await store.perform(.revise(RevisionRequest(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: type, action: .replace(bytes: Data("latest".utf8)))
            ]))
        )))
        do {
            _ = try await DetailsRepresentationPresentation.load(
                HistoryRepresentationRequest(item: item, basis: .effective, typeIdentifier: type),
                metadata: details.effective[0], history: store, renderer: ContentPreview()
            )
            Issue.record("An old Details reference returned content")
        } catch let failure as HistoryFailure {
            guard case .staleContent = failure else { throw failure }
        }
        let latest = try await store.details(for: item.id)
        let retried = try await DetailsRepresentationPresentation.load(
            HistoryRepresentationRequest(item: latest.item, basis: .effective, typeIdentifier: type),
            metadata: latest.effective[0], history: store, renderer: ContentPreview()
        )
        #expect(retried == .plainText("latest"))
    }

    private func capture(type: String, bytes: Data) async throws -> (SQLiteHistory, HistoryItemReference) {
        let store = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let receipt = try await store.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: bytes)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSince1970: 1)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return (store, item)
    }
}

private actor DetailsReadRecorder: ClipboardHistory {
    func backup(to directory: URL) async throws -> HistoryBackupReceipt {
        try await history.backup(to: directory)
    }

    private let history: SQLiteHistory
    private let holdsRead: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var requests: [HistoryRepresentationRequest] = []
    var isSuspended: Bool { continuation != nil }

    init(_ history: SQLiteHistory, holdsRead: Bool = false) {
        self.history = history
        self.holdsRead = holdsRead
    }
    func releaseRead() {
        released = true
        continuation?.resume()
        continuation = nil
    }
    func representation(_ request: HistoryRepresentationRequest) async throws -> HistoryRepresentation {
        requests.append(request)
        let result = try await history.representation(request)
        if holdsRead, !released {
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }
    func perform(_ action: HistoryAction) async throws -> HistoryReceipt { try await history.perform(action) }
    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage { try await history.browse(request) }
    func observe(_ request: HistoryObservationRequest) async -> AsyncThrowingStream<HistoryPage, Error> {
        await history.observe(request)
    }
    func details(for id: HistoryItemID) async throws -> HistoryDetails { try await history.details(for: id) }
    func pastePayload(for id: HistoryItemID) async throws -> PastePayload { try await history.pastePayload(for: id) }
    func thumbnail(for item: HistoryItemReference, pixels: PixelSize) async throws -> ThumbnailPayload? {
        try await history.thumbnail(for: item, pixels: pixels)
    }
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration { try await history.retentionConfiguration() }
    func usage() async throws -> HistoryUsage { try await history.usage() }
}
