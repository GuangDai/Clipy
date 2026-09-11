/// PreviewContentLoader.swift — metadata and selected-representation reads,
/// rendering, and exact-reference publication for both preview surfaces.
///
/// Owning spec: docs/01-architecture.md §5.2/§6 (main-actor UI over
/// HistoryCore DTOs only — no AppKit, no SwiftData, no MainActor image
/// decode), §5.7 (image handling); docs/03b-instruction-set.md §9
/// (Effective Content representations); review TYPE-2 / 08 §7 (structured
/// and encoding-unspecified text stays opaque; exact plain siblings win).
/// Async load law: audit
/// docs/reviews/2026-08-20-clipy-maccy-audit/02-spec-implementation.md
/// §SPEC-IMPL-007 and 05-recommended-target-design.md §4.1 PREVIEW-FENCE-1
/// (exact-reference fence; late results never publish).
import ContentPreview
import CoreGraphics
import Foundation
import HistoryCore
import Observation

/// The preview column's content loader (audit 02 §SPEC-IMPL-007; 05 §4.1
/// PREVIEW-FENCE-1): owns metadata and selected-representation reads, renderer invocation, and
/// exact-reference fence. ContentPreview owns the off-MainActor bounded
/// decode itself.
///
/// Fence law: a load captures its `HistoryItemReference` at start; after
/// EVERY await it re-checks cancellation AND that its reference is still
/// the requested one. The metadata must also carry that same
/// reference: `details(for:)` reads by ID, so a concurrent revision that
/// advanced the Content Version is invisible to the request — the
/// `details.item == item` check pins the version before an exact representation request (04 §9's caller-side fence
/// convention). A late or superseded result is DISCARDED without touching
/// any published state (the newer load owns the phase and applied content).
/// Starting a new exact reference invalidates the previous publication
/// before the first suspension, so old sensitive content is not retained as
/// a loading placeholder.
///
/// Retention: only the REQUESTED item's applied content lives here — a
/// bounded decoded image or a capped text body. Only selected representation
/// bytes enter the concurrent metadata-to-render function, never the
/// MainActor load frame. Unselected payloads remain in storage. An explicitly
/// loaded local PDF retains one bounded immutable source while its preview is
/// open, so page navigation never rereads a destination or changes documents.
@MainActor @Observable
final class PreviewContentLoader {

    /// What the preview column renders for the requested item. Raster pixels
    /// stay in the framework-neutral `raster` value below.
    enum AppliedContent: Equatable {
        /// Body text, capped by ContentPreview's history-pane profile, with
        /// truncation kept separate from the literal preview body.
        case text(String, wasTruncated: Bool = false)
        /// A bounded decoded image is published on `image`.
        case image
        /// An inert copied address; rendering never follows its destination.
        case reference(PreviewReference)
    }

    /// The loader's closed presentation phase (review Card 9D). A valid type
    /// without a renderer is stable `.unsupported`; load/decoder failures
    /// are `.failed` episodes and the separate typed recovery fact decides
    /// whether the real Retry control is admitted.
    enum Phase: Equatable {
        case loading
        case content(AppliedContent)
        case failed
        case unsupported
    }

    /// The current phase — always fenced to `requestedItem`.
    private(set) var phase: Phase = .unsupported

    /// Whether the current failed episode admits the real Retry control.
    /// History's public taxonomy grants that only to
    /// `.temporarilyUnavailable`; stable/invalid failures and deterministic
    /// malformed/resource rejections must not loop the same exact request.
    /// ContentPreview's `.renderer` case denotes failure to create the native
    /// platform rendering resources and remains retryable (03b §10;
    /// review Card 9D).
    private(set) var canRetryFailure = false

    /// The exact reference the loader is serving — set synchronously at the
    /// head of every `load(item:)`; late completions compare against it.
    private(set) var requestedItem: HistoryItemReference?

    /// A confirmation never performs I/O. Only confirmFilePreview starts the
    /// app-owned read, and every retarget/clear retires both steps.
    private(set) var fileLoadConfirmation: PreviewReference?
    private(set) var loadedFileReference: PreviewReference?
    private(set) var filePreviewFailure: FilePreviewFailure?
    private let filePreviewSettings: FilePreviewSettings?
    private var fileLoadTask: Task<Void, Never>?
    /// Only a successful bounded PDF decode admits this source. It belongs
    /// to the confirmed file preview, never to History or a shared cache.
    @ObservationIgnored private var loadedFilePDFSource: (
        representation: PreviewRepresentation, pageCount: Int
    )?

    var canLoadFilePreview: Bool {
        guard filePreviewSettings != nil,
              case .content(.reference(let reference)) = phase else { return false }
        return reference.kind == .file
    }

    /// Distinguishes overlapping load episodes even when they request the
    /// same exact reference. Reference equality alone cannot tell an older
    /// retry from the current request (review Card 9A).
    private var requestGeneration = 0

    /// Eager bounded pixels; no ImageIO/CoreGraphics object is retained in
    /// observable state or crosses the renderer actor seam.
    private(set) var raster: PreviewRaster?
    /// Prepared by ContentPreview off the main actor, for lazy text layout.
    private(set) var textSegments: [Substring] = []

    /// PDF uses the same bitmap surface, but its page count must not be
    /// mistaken for an image source's frame count. Other formats keep nil.
    private(set) var pdfPageCount: Int?
    private(set) var pdfPageNumber: Int?
    private(set) var requestedPDFPage = 1

    /// The applied image's pixel dimensions — the package-observable proof
    /// of a decode without exposing the image itself.
    var appliedImageSize: CGSize? {
        raster.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Literal semantic dimensions for Card 15C. The value comes from the
    /// bounded eager artifact, never by retaining or introspecting a
    /// `CGImage`/`NSImage` accessibility object.
    var appliedImageAccessibilityLabel: String? {
        imageAccessibilityLabel(locale: .current)
    }

    func imageAccessibilityLabel(locale: Locale) -> String? {
        guard let raster else { return nil }
        if let pdfPageCount, let pdfPageNumber {
            return PreviewCopy.pdfPageAccessibilityLabel(pageNumber: pdfPageNumber, pageCount: pdfPageCount, locale: locale)
        }
        return PreviewCopy.imageDimensions(width: raster.width, height: raster.height, locale: locale)
    }

    func appliedRasterNotice(locale: Locale = .current) -> String? {
        guard phase == .content(.image), let raster else { return nil }
        if let pdfPageCount, let pdfPageNumber {
            return PreviewCopy.pdfPageDisclosure(pageNumber: pdfPageNumber, pageCount: pdfPageCount, locale: locale)
        }
        return raster.sourceImageCount > 1 ? PreviewCopy.multiImageDisclosure() : nil
    }

    private let history: any ClipboardHistory

    private let renderer = ContentPreview()
    private var textConfiguration = PreviewTextConfiguration()

#if DEBUG
    /// Running-app acceptance can make only this loader's first metadata read
    /// transiently unavailable. The one-shot is instance-local: Retry still
    /// replays the same exact reference through the production History read
    /// and ContentPreview renderer, while Release has no failure switch
    /// (review Card 9D / Card 15 runtime acceptance).
    private var shouldFailNextPayloadReadForRunningUITest =
        ProcessInfo.processInfo.environment["CLIPY_RUNNING_UI_TEST"] == "1"
            && ProcessInfo.processInfo.environment[
                "CLIPY_UI_TEST_PREVIEW_FAILURE"
            ] == "transient-details-once"
#endif

    init(history: any ClipboardHistory, filePreviewSettings: FilePreviewSettings? = nil) {
        self.history = history
        self.filePreviewSettings = filePreviewSettings
    }

    #if DEBUG
    /// Content-free renderer accounting for deterministic lifecycle proofs.
    /// The concrete renderer remains private and Release exposes no hook.
    func rendererDebugSnapshot() async -> ContentPreviewDebugSnapshot {
        await renderer.debugSnapshot()
    }

    var filePreviewSourceByteCount: Int {
        loadedFilePDFSource?.representation.bytes.count ?? 0
    }
    #endif

    /// Starts a fresh episode for the same exact reference. The loader owns
    /// the generation/reference transition, so the view never reconstructs
    /// a request from an ID after a retryable failure (review Card 9D).
    func retry() async {
        guard phase == .failed,
              canRetryFailure,
              let requestedItem
        else { return }
        await load(item: requestedItem, pdfPage: requestedPDFPage, textConfiguration: textConfiguration)
    }

    /// View disappearance releases applied content immediately, including
    /// when SwiftUI retains this state for a later appearance. In-flight
    /// reads/renders cannot publish after the pane or Quick Look closes
    /// (PREVIEW-FENCE-1).
    func clear() {
        retireFileLoad()
        requestGeneration += 1
        requestedItem = nil
        requestedPDFPage = 1
        raster = nil
        textSegments = []
        pdfPageCount = nil
        pdfPageNumber = nil
        canRetryFailure = false
        phase = .unsupported
    }

    /// Loads one requested PDF page, or the ordinary preview for other types.
    /// `nil` clears the pane. Driven by the view's reference/page/retry task: a
    /// retarget cancels the previous load's task, and the fence covers the
    /// case where cancellation arrives late or the awaited work does not
    /// throw on cancellation.
    func load(item: HistoryItemReference?, pdfPage: Int = 1,
              textConfiguration: PreviewTextConfiguration = .init()) async {
        guard !Task.isCancelled else { return }
        guard let item else {
            clear()
            return
        }
        retireFileLoad()
        self.textConfiguration = textConfiguration
        requestGeneration += 1
        let generation = requestGeneration
        requestedItem = item
        requestedPDFPage = pdfPage
        raster = nil
        textSegments = []
        pdfPageCount = nil
        pdfPageNumber = nil
        canRetryFailure = false
        phase = .loading
        do {
#if DEBUG
            if shouldFailNextPayloadReadForRunningUITest {
                shouldFailNextPayloadReadForRunningUITest = false
                throw HistoryFailure.temporarilyUnavailable(.dedupIndexRebuild)
            }
#endif
            let outcome = try await Self.renderPayload(
                for: item, pdfPage: pdfPage, history: history, renderer: renderer,
                textConfiguration: textConfiguration,
                isCurrent: { [weak self] in
                    self?.requestGeneration == generation && self?.requestedItem == item
                }
            )
            try Task.checkCancellation()
            guard requestGeneration == generation,
                  requestedItem == item
            else { return }
            guard let outcome else {
                // The ID-based payload read raced a revision. Observation
                // retargets the current exact reference; this stale episode
                // must settle instead of retaining a permanent spinner.
                phase = .failed
                return
            }
            apply(outcome)
        } catch is CancellationError {
            // Cancellation is only a publication fence. It does not publish
            // a phase transition or claim that underlying History/native
            // work stopped; a superseding request owns the next phase.
            return
        } catch let failure as HistoryFailure {
            guard !Task.isCancelled,
                  requestGeneration == generation,
                  requestedItem == item
            else { return }
            raster = nil
            if case .temporarilyUnavailable = failure {
                canRetryFailure = true
            } else {
                canRetryFailure = false
            }
            phase = .failed
        } catch {
            guard !Task.isCancelled,
                  requestGeneration == generation,
                  requestedItem == item
            else { return }
            raster = nil
            canRetryFailure = false
            phase = .failed
        }
    }

    private func apply(_ outcome: PreviewOutcome) {
        raster = nil
        textSegments = []
        pdfPageCount = nil
        pdfPageNumber = nil
        canRetryFailure = false
        switch outcome {
        case .content(.raster(let artifact)):
            raster = artifact
            phase = .content(.image)
        case .content(.pdf(let artifact)):
            raster = artifact.raster
            pdfPageCount = artifact.pageCount
            pdfPageNumber = artifact.pageNumber
            phase = .content(.image)
        case .content(.text(let artifact)):
            textSegments = artifact.displaySegments
            phase = .content(.text(artifact.text, wasTruncated: artifact.wasTruncated))
        case .content(.reference(let artifact)):
            phase = .content(.reference(artifact))
        case .unavailable:
            phase = .unsupported
        case .failed(let failure):
            canRetryFailure = failure == .renderer
            phase = .failed
        }
    }

    func requestFilePreview() {
        guard canLoadFilePreview, case .content(.reference(let reference)) = phase else { return }
        fileLoadConfirmation = reference
    }

    func cancelFilePreviewConfirmation() { fileLoadConfirmation = nil }

    @discardableResult
    func confirmFilePreview() -> Task<Void, Never>? {
        guard !Task.isCancelled, let filePreviewSettings,
              let reference = fileLoadConfirmation, let item = requestedItem,
              phase == .content(.reference(reference)), reference.kind == .file else { return nil }
        fileLoadConfirmation = nil
        loadedFileReference = reference
        filePreviewFailure = nil
        requestedPDFPage = 1
        requestGeneration += 1
        let generation = requestGeneration
        phase = .loading
        canRetryFailure = false
        fileLoadTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let representation = try await filePreviewSettings.load(reference.address)
                try Task.checkCancellation()
                guard let self, self.requestGeneration == generation, self.requestedItem == item else { return }
                let outcome = await self.renderer.renderHistoryPane([
                    PreviewRepresentation(typeIdentifier: representation.typeIdentifier, bytes: representation.bytes)
                ], textConfiguration: self.textConfiguration)
                try Task.checkCancellation()
                guard self.requestGeneration == generation, self.requestedItem == item else { return }
                if case .content(.pdf(let pdf)) = outcome, pdf.pageCount > 1 {
                    self.loadedFilePDFSource = (
                        PreviewRepresentation(typeIdentifier: representation.typeIdentifier, bytes: representation.bytes),
                        pdf.pageCount
                    )
                }
                self.apply(outcome)
                // Retrying a file requires the same explicit confirmation;
                // the ordinary Retry control rereads History and is not used.
                self.canRetryFailure = false
                self.fileLoadTask = nil
            } catch {
                guard !Task.isCancelled, let self,
                      self.requestGeneration == generation, self.requestedItem == item else { return }
                self.filePreviewFailure = error as? FilePreviewFailure ?? .unavailable
                self.canRetryFailure = false
                self.phase = .failed
                self.fileLoadTask = nil
            }
        }
        return fileLoadTask
    }

    /// Navigation reuses the one confirmed immutable document. It performs
    /// no file reads and retains only the requested bounded page artifact.
    /// The same file task/generation retires both an initial read and a page
    /// render when Back, close, retarget, or purge removes this preview.
    @discardableResult
    func loadFilePDFPage(_ page: Int) -> Task<Void, Never>? {
        guard !Task.isCancelled, let item = requestedItem,
              loadedFileReference != nil, let source = loadedFilePDFSource,
              (1...source.pageCount).contains(page), page != requestedPDFPage else { return nil }
        fileLoadTask?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        requestedPDFPage = page
        raster = nil
        pdfPageNumber = nil
        pdfPageCount = nil
        phase = .loading
        canRetryFailure = false
        let renderer = self.renderer
        fileLoadTask = Task { [weak self] in
            let outcome = await renderer.renderHistoryPane([source.representation], pdfPage: page)
            guard !Task.isCancelled, let self, self.requestGeneration == generation,
                  self.requestedItem == item else { return }
            self.apply(outcome)
            switch outcome {
            case .content(.pdf(_)): break
            default: self.loadedFilePDFSource = nil
            }
            self.canRetryFailure = false
            self.fileLoadTask = nil
        }
        return fileLoadTask
    }

    func showFileReference() {
        guard let reference = loadedFileReference else { return }
        requestGeneration += 1
        retireFileLoad()
        requestedPDFPage = 1
        raster = nil
        pdfPageCount = nil
        pdfPageNumber = nil
        canRetryFailure = false
        phase = .content(.reference(reference))
    }

    /// A removal also retires an in-flight PDF page request. Pinned captured
    /// previews survive Clear Unpinned; file reads retain their existing
    /// conservative retirement behavior.
    func purgePreview(_ scope: HistorySurfacePurge.Scope, isPinned: Bool = false) {
        guard let requestedItem else { return }
        switch scope {
        case .all: clear()
        case .unpinned:
            if !isPinned {
                clear()
            } else if loadedFileReference != nil {
                // The pinned History reference survives. Retire its external
                // file read without losing the unchanged view task's target.
                showFileReference()
            } else {
                cancelFilePreviewConfirmation()
            }
        case .item(let id):
            if requestedItem.id == id { clear() }
        case .revision(let old, _):
            if requestedItem == old { clear() }
        }
    }

    private func retireFileLoad() {
        fileLoadTask?.cancel()
        fileLoadTask = nil
        loadedFilePDFSource = nil
        fileLoadConfirmation = nil
        loadedFileReference = nil
        filePreviewFailure = nil
    }

    /// Structured concurrency preserves cancellation and renderer TaskLocals.
    /// Metadata supplies source priority and byte limits before any payload
    /// read. Only a selected representation is fetched under the exact version;
    /// only the bounded artifact returns to MainActor (V2-09 §5).
    @concurrent
    private static func renderPayload(
        for item: HistoryItemReference,
        pdfPage: Int,
        history: any ClipboardHistory,
        renderer: ContentPreview,
        textConfiguration: PreviewTextConfiguration,
        isCurrent: @MainActor @Sendable () -> Bool
    ) async throws -> PreviewOutcome? {
        let details = try await history.details(for: item.id)
        try Task.checkCancellation()
        guard details.item == item else { return nil }
        guard await isCurrent() else { return nil }
        // Select formats within one constituent item at a time. Passing all
        // items together would combine sibling formats and duplicate exact
        // identifiers in the renderer's single-item source selection.
        let grouped = Dictionary(grouping: details.effective, by: \.pasteboardItemIndex)
        var outcome = PreviewOutcome.unavailable(.unsupported)
        for index in grouped.keys.sorted() {
            let sources = ContentPreview.prepareHistoryPane((grouped[index] ?? []).map {
                PreviewRepresentationMetadata(typeIdentifier: $0.typeIdentifier, byteCount: $0.byteCount)
            })
            for source in sources {
                try Task.checkCancellation()
                if let failure = source.preflightFailure {
                    outcome = failure
                    break
                }
                let representation = try await history.representation(HistoryRepresentationRequest(
                    item: item, basis: .effective, typeIdentifier: source.typeIdentifier,
                    pasteboardItemIndex: index
                ))
                try Task.checkCancellation()
                guard await isCurrent() else { return nil }
                outcome = await renderer.renderSelectedHistoryPane(source, representation: PreviewRepresentation(
                    typeIdentifier: representation.typeIdentifier, bytes: representation.bytes
                ), pdfPage: pdfPage, textConfiguration: textConfiguration)
                try Task.checkCancellation()
                guard await isCurrent() else { return nil }
                if case .content = outcome { return outcome }
                if !source.permitsFallback(after: outcome) { break }
            }
        }
        return outcome
    }
}

