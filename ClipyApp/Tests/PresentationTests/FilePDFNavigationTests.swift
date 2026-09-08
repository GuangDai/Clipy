@testable import ContentPreview
import CoreGraphics
import Foundation
@testable import HistoryCore
@testable import HistoryStorage
import Testing
@testable import ClipyApp

@MainActor
struct FilePDFNavigationTests {
    @Test func confirmedPDFPagesUseOneSnapshotAndBackRequiresANewExplicitRead() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let address = "file:///not-opened/preview.pdf"
        let item = try await capture(address, in: history)
        let original = try pdfData()
        let reads = PDFFileReads(bytes: original)
        let loader = PreviewContentLoader(history: history, filePreviewSettings: .init(load: { await reads.load($0) }))
        await loader.load(item: item)
        #expect(loader.loadFilePDFPage(2) == nil)
        #expect(await reads.count == 0)
        loader.requestFilePreview()
        let firstLoad = try #require(loader.confirmFilePreview())
        await firstLoad.value
        #expect(loader.pdfPageNumber == 1)
        #expect(loader.pdfPageCount == 2)
        let firstPage = try #require(loader.raster)
#if DEBUG
        #expect(loader.filePreviewSourceByteCount == original.count)
#endif
        // The external file has changed. Navigation must still use the one
        // document the user confirmed, not quietly read the replacement.
        await reads.replace(with: Data("not a PDF anymore".utf8))
        let next = try #require(loader.loadFilePDFPage(2))
        #expect(loader.raster == nil)
        await next.value
        #expect(loader.pdfPageNumber == 2)
        let secondPage = try #require(loader.raster)
        #expect(secondPage.pixels != firstPage.pixels)
        #expect(await reads.count == 1)
        #expect(loader.loadedFileReference?.address == address)
        #expect(loader.loadFilePDFPage(3) == nil)
        #expect(loader.loadFilePDFPage(0) == nil)
        let previous = try #require(loader.loadFilePDFPage(1))
        await previous.value
        #expect(loader.raster == firstPage)
        #expect(await reads.count == 1)
        let payload = try await history.pastePayload(for: item.id)
        #expect(payload.representations == [.init(typeIdentifier: "public.file-url", bytes: Data(address.utf8))])
        #expect(try await history.usage().position.rawValue == 1)

        loader.showFileReference()
        #expect(loader.raster == nil)
        #expect(loader.loadFilePDFPage(2) == nil)
        #expect(loader.requestedPDFPage == 1)
#if DEBUG
        #expect(loader.filePreviewSourceByteCount == 0)
#endif
        loader.requestFilePreview()
        let changedFile = try #require(loader.confirmFilePreview())
        await changedFile.value
        #expect(await reads.count == 2)
        #expect(loader.phase == .failed)
#if DEBUG
        #expect(loader.filePreviewSourceByteCount == 0)
#endif
    }

#if DEBUG
    enum Retirement: Sendable { case back, close, removal, revision, selection, clearAll, clearUnpinned }

    @Test(arguments: [Retirement.back, .close, .removal, .revision, .selection, .clearAll, .clearUnpinned])
    func retiringAnInFlightPageReleasesTheSourceAndDiscardsLatePixels(_ retirement: Retirement) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("file:///not-opened/preview.pdf", in: history)
        let other = try await capture("file:///not-opened/another.pdf", in: history)
        let reads = PDFFileReads(bytes: try pdfData())
        let loader = PreviewContentLoader(history: history, filePreviewSettings: .init(load: { await reads.load($0) }))
        await loader.load(item: item)
        loader.requestFilePreview()
        let initialLoad = try #require(loader.confirmFilePreview())
        await initialLoad.value
        let suspension = FilePDFPageSuspension()
        let pending = ContentPreviewDebugInstrumentation.$renderDidStart.withValue({
            await suspension.pause()
        }) {
            loader.loadFilePDFPage(2)
        }
        let task = try #require(pending)
        await suspension.waitUntilPaused()
        switch retirement {
        case .back: loader.showFileReference()
        case .close: loader.clear()
        case .removal: loader.purgePreview(.item(item.id))
        case .revision:
            loader.purgePreview(.revision(old: item, new: .init(
                id: item.id, contentVersion: .init(rawValue: item.contentVersion.rawValue + 1)
            )))
        case .selection: await loader.load(item: other)
        case .clearAll: loader.purgePreview(.all)
        case .clearUnpinned: loader.purgePreview(.unpinned)
        }
        let expectedItem = loader.requestedItem
        let expectedPhase = loader.phase
        #expect(loader.filePreviewSourceByteCount == 0)
        #expect(loader.loadFilePDFPage(1) == nil)
        #expect(loader.loadedFileReference == nil)
        await suspension.resume()
        await task.value
        #expect(loader.requestedItem == expectedItem)
        #expect(loader.phase == expectedPhase)
        #expect(loader.raster == nil)
        #expect(loader.filePreviewSourceByteCount == 0)
        #expect(await reads.count == 1)
        let settled = await loader.rendererDebugSnapshot()
        #expect(settled.activeJobs == 0)
        #expect(settled.retainedSourceBytes == 0)
    }
#endif

    private func pdfData() throws -> Data {
        let output = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let consumer = try #require(CGDataConsumer(data: output))
        var box = CGRect(x: 0, y: 0, width: 80, height: 60)
        let writer = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for gray in [CGFloat(0), CGFloat(1)] {
            writer.beginPDFPage(nil)
            writer.setFillColor(gray: gray, alpha: 1)
            writer.fill(box)
            writer.endPDFPage()
        }
        writer.closePDF()
        return output as Data
    }

    private func capture(_ address: String, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [.init(typeIdentifier: "public.file-url", bytes: Data(address.utf8))],
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_801_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}

private actor PDFFileReads {
    private var bytes: Data
    private(set) var count = 0
    init(bytes: Data) { self.bytes = bytes }
    func replace(with bytes: Data) { self.bytes = bytes }
    func load(_ address: String) -> HistoryRepresentation {
        count += 1
        return .init(typeIdentifier: "com.adobe.pdf", bytes: bytes)
    }
}

#if DEBUG
private actor FilePDFPageSuspension {
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
#endif
