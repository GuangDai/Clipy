/// Inert URL/file reference previews through real History storage and the
/// exact-reference loader. File targets are deliberately not created; this
/// proves preview does not require their existence, not a measured I/O count.
import ContentPreview
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

@MainActor
struct RealHistoryReferencePreviewTests {
    @Test(arguments: [false, true])
    func previewPreservesStoredReferenceBytesAndReadableTitle(isFile: Bool) async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let directoryName = UUID().uuidString
        let address = isFile
            ? "file:///clipy-preview-uncreated/\(directoryName)/Report%20caf%C3%A9.txt"
            : "https://EXAMPLE.invalid/%63af%C3%A9?q=%2F#part"
        let identifier = isFile ? "public.file-url" : "public.url"
        let bytes = Data(address.utf8)
        let item = try await capture(bytes, type: identifier, in: history)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        let artifact = try #require(reference(in: loader))
        #expect(loader.requestedItem == item)
        #expect(artifact.kind == (isFile ? .file : .url))
        #expect(Data(artifact.address.utf8) == bytes)
        if isFile {
            let expectedPath = "/clipy-preview-uncreated/\(directoryName)/Report café.txt"
            #expect(artifact.filePath.map { Data($0.utf8) } == Data(expectedPath.utf8))
        } else {
            #expect(artifact.filePath == nil)
        }
        #expect(loader.raster == nil)
        #expect(!loader.canRetryFailure)

        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(page.position.rawValue == 1)
        #expect(page.rows.map(\.item) == [item])
        #expect(page.rows.map(\.title) == [isFile ? "Report café.txt" : address])
        #expect(page.rows.map(\.typeIdentifiers) == [[identifier]])
        let details = try await history.details(for: item.id)
        let canonical = try await history.representation(.init(item: item, basis: .canonical, typeIdentifier: identifier))
        #expect(canonical.bytes == bytes)
        #expect(details.canonical.map(\.byteCount) == [bytes.count])
        #expect(details.effective == details.canonical)
        #expect(details.effectiveMatchesCanonical)
        let paste = try await history.pastePayload(for: item.id)
        #expect(paste.item == item)
        #expect(paste.representations == [canonical])
        #expect(paste.representations.map(\.bytes) == [bytes])
        #expect(try await history.usage().position == page.position)
    }

    @Test func revisedURLRetargetsTheLoaderWithoutPublishingNewBytesUnderTheOldReference() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let originalBytes = Data("https://example.invalid/old%20address?x=%2F".utf8)
        let revisedAddress = "https://EXAMPLE.invalid/new%20address?x=%25#new"
        let revisedBytes = Data(revisedAddress.utf8)
        let original = try await capture(originalBytes, type: "public.url", in: history)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: original)
        let originalArtifact = try #require(reference(in: loader))
        #expect(Data(originalArtifact.address.utf8) == originalBytes)

        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: original.id, expected: original.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.url", action: .replace(bytes: revisedBytes)
            )]))
        )))
        guard case let .committed(commit) = receipt,
              case let .revised(revised) = commit.outcome else {
            Issue.record("Expected the URL replacement to append a revision")
            return
        }
        #expect(revised.id == original.id)
        #expect(revised.contentVersion.rawValue == 2)
        #expect(commit.position.rawValue == 2)
        await loader.load(item: revised)
        let revisedArtifact = try #require(reference(in: loader))
        #expect(loader.requestedItem == revised)
        #expect(revisedArtifact.kind == .url)
        #expect(revisedArtifact.filePath == nil)
        #expect(Data(revisedArtifact.address.utf8) == revisedBytes)
        #expect(Data(originalArtifact.address.utf8) == originalBytes)

        // details(for:) is current-by-ID. The loader must reject its newer
        // answer when explicitly asked for the retired original reference.
        await loader.load(item: original)
        #expect(loader.phase == .failed)
        #expect(reference(in: loader) == nil)
        #expect(loader.raster == nil)
        #expect(!loader.canRetryFailure)
        await loader.load(item: revised)
        #expect(reference(in: loader) == revisedArtifact)

        let details = try await history.details(for: original.id)
        #expect(details.item == revised)
        let canonical = try await history.representation(.init(item: revised, basis: .canonical, typeIdentifier: "public.url"))
        let effective = try await history.representation(.init(item: revised, basis: .effective, typeIdentifier: "public.url"))
        #expect(canonical.bytes == originalBytes)
        #expect(effective.bytes == revisedBytes)
        #expect(!details.effectiveMatchesCanonical)
        #expect(details.revisions.map(\.title) == [revisedAddress])
        let paste = try await history.pastePayload(for: original.id)
        #expect(paste.item == revised)
        #expect(paste.representations.map(\.bytes) == [revisedBytes])
        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(page.position == commit.position)
        #expect(page.rows.map(\.title) == [revisedAddress])
    }

    @Test func clearingLoadedFileReferenceSurvivesCancelledQueuedReloadAndCanReopen() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let address = "file:///clipy-preview-uncreated/\(UUID().uuidString)/Private%20notes.txt"
        let bytes = Data(address.utf8)
        let item = try await capture(bytes, type: "public.file-url", in: history)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        let loaded = try #require(reference(in: loader))
        #expect(loaded.kind == .file)
        #expect(Data(loaded.address.utf8) == bytes)

        // These steps run without a MainActor suspension: the queued task
        // cannot start before cancellation and the synchronous close/clear.
        // This is queued-work cancellation, not native-read preemption.
        let queuedReload = Task { await loader.load(item: item) }
        queuedReload.cancel()
        loader.clear()
        #expect(loader.phase == .unsupported)
        #expect(loader.requestedItem == nil)
        #expect(reference(in: loader) == nil)
        await queuedReload.value
        #expect(loader.phase == .unsupported)
        #expect(loader.requestedItem == nil)
        #expect(reference(in: loader) == nil)
        #expect(loader.raster == nil)

        // Closing the preview does not remove the retained item or poison its
        // next legitimate load. The reopened artifact keeps the same spelling.
        await loader.load(item: item)
        let reopened = try #require(reference(in: loader))
        #expect(loader.requestedItem == item)
        #expect(reopened.kind == .file)
        #expect(Data(reopened.address.utf8) == bytes)
        #expect(reopened.filePath == loaded.filePath)
        let paste = try await history.pastePayload(for: item.id)
        #expect(paste.representations.map(\.bytes) == [bytes])
    }

    private func reference(in loader: PreviewContentLoader) -> PreviewReference? {
        guard case let .content(.reference(artifact)) = loader.phase else { return nil }
        return artifact
    }

    private func capture(_ bytes: Data, type: String, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: bytes)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_080_000)
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}
