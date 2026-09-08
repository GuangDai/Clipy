@testable import ContentPreview
import Foundation
@testable import HistoryCore
@testable import HistoryStorage
import Testing
@testable import ClipyApp

@MainActor
struct FilePreviewTests {
    @Test func referenceAndCancelledConfirmationPerformNoFileReads() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("file:///not-opened/private.txt", type: "public.file-url", in: history)
        let probe = FileReadProbe()
        let loader = PreviewContentLoader(history: history, filePreviewSettings: .init(load: probe.read))
        await loader.load(item: item)
        #expect(loader.canLoadFilePreview)
        loader.confirmFilePreview() // No request/confirmation was presented.
        loader.requestFilePreview()
        #expect(loader.fileLoadConfirmation?.address == "file:///not-opened/private.txt")
        loader.cancelFilePreviewConfirmation()
        loader.confirmFilePreview()
        let count = await probe.requestCount()
        #expect(count == 0)
        #expect(loader.loadedFileReference == nil)
        #expect(loader.canLoadFilePreview)
    }

    @Test(arguments: [
        ("public.utf8-plain-text", "current file text", "current file text"),
        ("public.rtf", #"{\rtf1 current {\b file} text}"#, "current file text"),
        ("public.html", "<p>current <b>file</b> text</p>", "current file text"),
    ])
    func confirmedFileUsesExistingRendererAndKeepsOriginalPastePayload(
        type: String, source: String, expected: String
    ) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let address = "file:///not-opened/private.txt"
        let item = try await capture(address, type: "public.file-url", in: history)
        let probe = FileReadProbe(answer: HistoryRepresentation(typeIdentifier: type, bytes: Data(source.utf8)))
        let loader = PreviewContentLoader(history: history, filePreviewSettings: .init(load: probe.read))
        await loader.load(item: item)
        loader.requestFilePreview()
        loader.confirmFilePreview()
        try #require(await pollUntil { loader.phase != .loading })
        guard case .content(.text(let body, _)) = loader.phase else {
            Issue.record("Expected confirmed file text, got \(loader.phase)")
            return
        }
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        #expect(loader.loadedFileReference?.address == address)
        let requests = await probe.requestedAddresses()
        #expect(requests == [address])
        let paste = try await history.pastePayload(for: item.id)
        #expect(paste.representations == [HistoryRepresentation(
            typeIdentifier: "public.file-url", bytes: Data(address.utf8)
        )])
        #expect(try await history.usage().position.rawValue == 1)
        loader.showFileReference()
        #expect(loader.loadedFileReference == nil)
        #expect(loader.canLoadFilePreview)
        #expect(loader.raster == nil)
    }

    @Test func remoteURLNeverOffersOrStartsFileLoading() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("https://example.invalid/private", type: "public.url", in: history)
        let probe = FileReadProbe()
        let loader = PreviewContentLoader(history: history, filePreviewSettings: .init(load: probe.read))
        await loader.load(item: item)
        #expect(!loader.canLoadFilePreview)
        loader.requestFilePreview()
        loader.confirmFilePreview()
        #expect(loader.fileLoadConfirmation == nil)
        let count = await probe.requestCount()
        #expect(count == 0)
    }

    enum Retirement: Sendable { case selection, close, removal, revision, clearAll, clearUnpinned, back }

    @Test(arguments: [Retirement.selection, .close, .removal, .revision, .clearAll, .clearUnpinned, .back])
    func retiredFileReadCannotPublishLateContent(_ retirement: Retirement) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("file:///not-opened/private.txt", type: "public.file-url", in: history)
        let other = try await capture("other selected text", type: "public.utf8-plain-text", in: history)
        let probe = FileReadProbe()
        let loader = PreviewContentLoader(history: history, filePreviewSettings: .init(load: probe.read))
        await loader.load(item: item)
        loader.requestFilePreview()
        let fileTask = try #require(loader.confirmFilePreview())
        let started = await probe.waitUntilReadStarts()
        if !started { await probe.complete() }
        try #require(started)

        switch retirement {
        case .selection: await loader.load(item: other)
        case .close: loader.clear()
        case .removal: loader.purgePreview(.item(item.id))
        case .revision:
            loader.purgePreview(.revision(old: item, new: HistoryItemReference(
                id: item.id, contentVersion: ContentVersion(rawValue: 2)
            )))
        case .clearAll: loader.purgePreview(.all)
        case .clearUnpinned: loader.purgePreview(.unpinned)
        case .back: loader.showFileReference()
        }
        let expectedPhase = loader.phase
        let expectedItem = loader.requestedItem
        let cancelled = await probe.waitUntilCancelled()
        await probe.complete() // Deliberately non-cooperative late success.
        #expect(cancelled)
        await fileTask.value
        #expect(loader.phase == expectedPhase)
        #expect(loader.requestedItem == expectedItem)
        #expect(loader.loadedFileReference == nil)
        #expect(loader.raster == nil)
    }

    @Test func retargetBeforeConfirmationCannotOpenThePreviousFile() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("file:///not-opened/first.txt", type: "public.file-url", in: history)
        let other = try await capture("file:///not-opened/second.txt", type: "public.file-url", in: history)
        let probe = FileReadProbe()
        let loader = PreviewContentLoader(history: history, filePreviewSettings: .init(load: probe.read))
        await loader.load(item: item)
        loader.requestFilePreview()
        await loader.load(item: other)
        loader.confirmFilePreview()
        let count = await probe.requestCount()
        #expect(count == 0)
        #expect(loader.requestedItem == other)
    }

    @Test func unrelatedRemovalDoesNotCancelTheConfirmedFileRead() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("file:///not-opened/private.txt", type: "public.file-url", in: history)
        let other = try await capture("other item", type: "public.utf8-plain-text", in: history)
        let probe = FileReadProbe()
        let loader = PreviewContentLoader(history: history, filePreviewSettings: .init(load: probe.read))
        await loader.load(item: item)
        loader.requestFilePreview()
        let task = try #require(loader.confirmFilePreview())
        let started = await probe.waitUntilReadStarts()
        loader.purgePreview(.item(other.id))
        await probe.complete()
        await task.value
        #expect(started)
        #expect(loader.phase == .content(.text("late file text")))
        #expect(loader.requestedItem == item)
    }

    #if DEBUG
    @Test func closingDuringFileRasterizationReleasesTheLateArtifact() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("file:///not-opened/image.png", type: "public.file-url", in: history)
        let loader = PreviewContentLoader(history: history, filePreviewSettings: .init { _ in
            HistoryRepresentation(typeIdentifier: "public.png", bytes: fixturePNGData)
        })
        await loader.load(item: item)
        let pause = FileRasterPause()
        let task = ContentPreviewDebugInstrumentation.$renderDidStart.withValue({
            await pause.park()
        }) {
            loader.requestFilePreview()
            return loader.confirmFilePreview()
        }
        let fileTask = try #require(task)
        let started = await pause.waitUntilStarted()
        loader.clear()
        await pause.resume()
        await fileTask.value
        #expect(started)
        #expect(loader.phase == .unsupported)
        #expect(loader.raster == nil)
        #expect(loader.loadedFileReference == nil)
        let accounting = await loader.rendererDebugSnapshot()
        #expect(accounting.activeJobs == 0)
        #expect(accounting.retainedSourceBytes == 0)
    }
    #endif

    @Test(arguments: [FilePreviewFailure.permissionDenied, .unavailable, .tooLarge, .unsupported, .invalidReference])
    func failedFileReadKeepsReferenceRecoveryExplicit(_ failure: FilePreviewFailure) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("file:///not-opened/private.txt", type: "public.file-url", in: history)
        let loader = PreviewContentLoader(history: history, filePreviewSettings: .init { _ in throw failure })
        await loader.load(item: item)
        loader.requestFilePreview()
        loader.confirmFilePreview()
        try #require(await pollUntil { loader.phase == .failed })
        #expect(loader.filePreviewFailure == failure)
        #expect(!loader.canRetryFailure)
        loader.showFileReference()
        #expect(loader.canLoadFilePreview)
        #expect(loader.filePreviewFailure == nil)
    }

    private func capture(_ body: String, type: String, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: Data(body.utf8))],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_080_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}

#if DEBUG
private actor FileRasterPause {
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func park() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation in self.continuation = continuation }
    }
    func resume() {
        released = true
        continuation?.resume()
        continuation = nil
    }
    func waitUntilStarted() async -> Bool {
        for _ in 0..<2_000 {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return started
    }
}
#endif

private actor FileReadProbe {
    private var addresses: [String] = []
    private var answer: HistoryRepresentation?
    private var continuation: CheckedContinuation<HistoryRepresentation, Never>?
    private var cancelled = false

    init(answer: HistoryRepresentation? = nil) { self.answer = answer }
    func requestCount() -> Int { addresses.count }
    func requestedAddresses() -> [String] { addresses }

    func read(_ address: String) async throws -> HistoryRepresentation {
        addresses.append(address)
        if let answer { return answer }
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in self.continuation = continuation }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        return value
    }

    private func recordCancellation() { cancelled = true }
    func complete() {
        let value = HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("late file text".utf8))
        answer = value
        continuation?.resume(returning: value)
        continuation = nil
    }
    func waitUntilReadStarts() async -> Bool {
        for _ in 0..<2_000 {
            if !addresses.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !addresses.isEmpty
    }
    func waitUntilCancelled() async -> Bool {
        for _ in 0..<2_000 {
            if cancelled { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cancelled
    }
}
