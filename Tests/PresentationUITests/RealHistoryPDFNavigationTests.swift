import ContentPreview
import CoreGraphics
import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import PresentationUI

@MainActor
struct RealHistoryPDFNavigationTests {
    @Test func explicitPagesRenderDifferentPixelsAndCopyKeepsTheWholeDocument() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let bytes = try pdfData()
        let item = try await capture(bytes, in: history)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item)
        let first = try #require(loader.raster)
        #expect(loader.pdfPageNumber == 1)
        #expect(loader.pdfPageCount == 2)

        await loader.load(item: item, pdfPage: 2)
        let second = try #require(loader.raster)
        #expect(loader.pdfPageNumber == 2)
        #expect(loader.pdfPageCount == 2)
        #expect(first.pixels != second.pixels)
        #expect(loader.appliedRasterNotice() == PreviewCopy.pdfPageDisclosure(pageNumber: 2, pageCount: 2))
        #expect(loader.appliedImageAccessibilityLabel == PreviewCopy.pdfPageAccessibilityLabel(pageNumber: 2, pageCount: 2))
        #expect(try await history.pastePayload(for: item.id).representations.map(\.bytes) == [bytes])

        await loader.load(item: item, pdfPage: 1)
        #expect(loader.raster == first)
        #expect(loader.pdfPageNumber == 1)
        await loader.load(item: item, pdfPage: 3)
        #expect(loader.phase == .unsupported)
        #expect(loader.raster == nil)
        #expect(loader.pdfPageNumber == nil)
        #expect(!loader.canRetryFailure)
    }

    @Test func revisedDocumentStartsAtFirstPageAndOldVersionCannotPublish() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture(try pdfData(), in: history)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: item, pdfPage: 2)
        #expect(loader.pdfPageNumber == 2)
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "com.adobe.pdf", action: .replace(bytes: try pdfData(pageCount: 1))
            )]))
        )))
        guard case .committed(let commit) = receipt, case .revised(let revised) = commit.outcome else {
            Issue.record("Expected PDF revision")
            return
        }
        loader.purgePreview(.revision(old: item, new: revised))
        #expect(loader.raster == nil)
        #expect(loader.pdfPageNumber == nil)
        await loader.load(item: revised)
        #expect(loader.requestedPDFPage == 1)
        #expect(loader.pdfPageNumber == 1)
        #expect(loader.pdfPageCount == 1)
        await loader.load(item: item, pdfPage: 2)
        #expect(loader.phase == .failed)
        #expect(loader.raster == nil)
    }

#if DEBUG
    @Test func supersedingPageDiscardsTheOldPageBeforeNativeWorkCompletes() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture(try pdfData(), in: history)
        let loader = PreviewContentLoader(history: history)
        let suspension = PDFNavigationSuspension()
        let hook: @Sendable () async -> Void = { await suspension.pauseFirst() }
        await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            let first = Task { await loader.load(item: item) }
            await suspension.waitUntilPaused()
            let second = Task { await loader.load(item: item, pdfPage: 2) }
            #expect(await pollUntil { loader.requestedPDFPage == 2 })
            #expect(loader.phase == .loading)
            #expect(loader.raster == nil)
            await suspension.resume()
            await first.value
            await second.value
        }
        #expect(loader.requestedItem == item)
        #expect(loader.pdfPageNumber == 2)
        #expect(loader.pdfPageCount == 2)
        let settled = await loader.rendererDebugSnapshot()
        #expect(settled.activeJobs == 0)
        #expect(settled.retainedSourceBytes == 0)
    }

    @Test(arguments: [false, true])
    func closeOrRemovalDiscardsAnInFlightPage(removal: Bool) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture(try pdfData(), in: history)
        let loader = PreviewContentLoader(history: history)
        let suspension = PDFNavigationSuspension()
        let hook: @Sendable () async -> Void = { await suspension.pauseFirst() }
        await ContentPreviewDebugInstrumentation.$renderDidStart.withValue(hook) {
            let load = Task { await loader.load(item: item, pdfPage: 2) }
            await suspension.waitUntilPaused()
            if removal { loader.purgePreview(.item(item.id)) } else { loader.clear() }
            load.cancel()
            await suspension.resume()
            await load.value
        }
        #expect(loader.requestedItem == nil)
        #expect(loader.requestedPDFPage == 1)
        #expect(loader.raster == nil)
        #expect(loader.pdfPageNumber == nil)
        #expect(loader.pdfPageCount == nil)
        #expect(loader.phase == .unsupported)
    }
#endif

    private func pdfData(pageCount: Int = 2) throws -> Data {
        let bytes = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let consumer = try #require(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 80, height: 60)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(gray: CGFloat(page), alpha: 1)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }

    private func capture(_ bytes: Data, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [.init(typeIdentifier: "com.adobe.pdf", bytes: bytes)],
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_800_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}

#if DEBUG
private actor PDFNavigationSuspension {
    private var paused = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pauseFirst() async {
        guard !paused else { return }
        paused = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
#endif
