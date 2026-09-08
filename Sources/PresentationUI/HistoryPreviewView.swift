/// HistoryPreviewView.swift — the preview column shown beside the history
/// list (Maccy's `PreviewItemView` replicated onto HistoryCore DTOs): the
/// selected item's Effective Content rendered large — image representations
/// rendered OFF the MainActor into bounded ContentPreview values —
/// plus a compact metadata bar.
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
import SwiftUI

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
/// MainActor load frame. Unselected payloads remain in storage.
@MainActor @Observable
package final class PreviewContentLoader {

    /// What the preview column renders for the requested item. Raster pixels
    /// stay in the framework-neutral `raster` value below.
    package enum AppliedContent: Equatable {
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
    package enum Phase: Equatable {
        case loading
        case content(AppliedContent)
        case failed
        case unsupported
    }

    /// The current phase — always fenced to `requestedItem`.
    package private(set) var phase: Phase = .unsupported

    /// Whether the current failed episode admits the real Retry control.
    /// History's public taxonomy grants that only to
    /// `.temporarilyUnavailable`; stable/invalid failures and deterministic
    /// malformed/resource rejections must not loop the same exact request.
    /// ContentPreview's `.renderer` case denotes failure to create the native
    /// platform rendering resources and remains retryable (03b §10;
    /// review Card 9D).
    package private(set) var canRetryFailure = false

    /// The exact reference the loader is serving — set synchronously at the
    /// head of every `load(item:)`; late completions compare against it.
    package private(set) var requestedItem: HistoryItemReference?

    /// A confirmation never performs I/O. Only confirmFilePreview starts the
    /// app-owned read, and every retarget/clear retires both steps.
    package private(set) var fileLoadConfirmation: PreviewReference?
    package private(set) var loadedFileReference: PreviewReference?
    package private(set) var filePreviewFailure: FilePreviewFailure?
    private let filePreviewSettings: FilePreviewSettings?
    private var fileLoadTask: Task<Void, Never>?

    package var canLoadFilePreview: Bool {
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
    package private(set) var raster: PreviewRaster?

    /// PDF uses the same bitmap surface, but its page count must not be
    /// mistaken for an image source's frame count. Other formats keep nil.
    package private(set) var pdfPageCount: Int?
    package private(set) var pdfPageNumber: Int?
    package private(set) var requestedPDFPage = 1

    /// The applied image's pixel dimensions — the package-observable proof
    /// of a decode without exposing the image itself.
    package var appliedImageSize: CGSize? {
        raster.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Literal semantic dimensions for Card 15C. The value comes from the
    /// bounded eager artifact, never by retaining or introspecting a
    /// `CGImage`/`NSImage` accessibility object.
    package var appliedImageAccessibilityLabel: String? {
        imageAccessibilityLabel(locale: .current)
    }

    package func imageAccessibilityLabel(locale: Locale) -> String? {
        guard let raster else { return nil }
        if let pdfPageCount, let pdfPageNumber {
            return PreviewCopy.pdfPageAccessibilityLabel(pageNumber: pdfPageNumber, pageCount: pdfPageCount, locale: locale)
        }
        return PreviewCopy.imageDimensions(width: raster.width, height: raster.height, locale: locale)
    }

    package func appliedRasterNotice(locale: Locale = .current) -> String? {
        guard phase == .content(.image), let raster else { return nil }
        if let pdfPageCount, let pdfPageNumber {
            return PreviewCopy.pdfPageDisclosure(pageNumber: pdfPageNumber, pageCount: pdfPageCount, locale: locale)
        }
        return raster.sourceImageCount > 1 ? PreviewCopy.multiImageDisclosure() : nil
    }

    private let history: any ClipboardHistory

    private let renderer = ContentPreview()

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

    package init(history: any ClipboardHistory, filePreviewSettings: FilePreviewSettings? = nil) {
        self.history = history
        self.filePreviewSettings = filePreviewSettings
    }

    #if DEBUG
    /// Content-free renderer accounting for deterministic lifecycle proofs.
    /// The concrete renderer remains private and Release exposes no hook.
    package func rendererDebugSnapshot() async -> ContentPreviewDebugSnapshot {
        await renderer.debugSnapshot()
    }
    #endif

    /// Starts a fresh episode for the same exact reference. The loader owns
    /// the generation/reference transition, so the view never reconstructs
    /// a request from an ID after a retryable failure (review Card 9D).
    package func retry() async {
        guard phase == .failed,
              canRetryFailure,
              let requestedItem
        else { return }
        await load(item: requestedItem, pdfPage: requestedPDFPage)
    }

    /// View disappearance releases applied content immediately, including
    /// when SwiftUI retains this state for a later appearance. In-flight
    /// reads/renders cannot publish after the pane or Quick Look closes
    /// (PREVIEW-FENCE-1).
    package func clear() {
        retireFileLoad()
        requestGeneration += 1
        requestedItem = nil
        requestedPDFPage = 1
        raster = nil
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
    package func load(item: HistoryItemReference?, pdfPage: Int = 1) async {
        guard !Task.isCancelled else { return }
        guard let item else {
            clear()
            return
        }
        retireFileLoad()
        requestGeneration += 1
        let generation = requestGeneration
        requestedItem = item
        requestedPDFPage = pdfPage
        raster = nil
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

    package func requestFilePreview() {
        guard canLoadFilePreview, case .content(.reference(let reference)) = phase else { return }
        fileLoadConfirmation = reference
    }

    package func cancelFilePreviewConfirmation() { fileLoadConfirmation = nil }

    @discardableResult
    package func confirmFilePreview() -> Task<Void, Never>? {
        guard !Task.isCancelled, let filePreviewSettings,
              let reference = fileLoadConfirmation, let item = requestedItem,
              phase == .content(.reference(reference)), reference.kind == .file else { return nil }
        fileLoadConfirmation = nil
        loadedFileReference = reference
        filePreviewFailure = nil
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
                ])
                try Task.checkCancellation()
                guard self.requestGeneration == generation, self.requestedItem == item else { return }
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

    package func showFileReference() {
        guard let reference = loadedFileReference else { return }
        requestGeneration += 1
        retireFileLoad()
        raster = nil
        pdfPageCount = nil
        pdfPageNumber = nil
        canRetryFailure = false
        phase = .content(.reference(reference))
    }

    /// A removal also retires an in-flight PDF page request. Pinned captured
    /// previews survive Clear Unpinned; file reads retain their existing
    /// conservative retirement behavior.
    package func purgePreview(_ scope: HistorySurfacePurge.Scope, isPinned: Bool = false) {
        guard let requestedItem else { return }
        switch scope {
        case .all: clear()
        case .unpinned:
            if !isPinned || loadedFileReference != nil || fileLoadConfirmation != nil { clear() }
        case .item(let id):
            if requestedItem.id == id { clear() }
        case .revision(let old, _):
            if requestedItem == old { clear() }
        }
    }

    private func retireFileLoad() {
        fileLoadTask?.cancel()
        fileLoadTask = nil
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
        isCurrent: @MainActor @Sendable () -> Bool
    ) async throws -> PreviewOutcome? {
        let details = try await history.details(for: item.id)
        try Task.checkCancellation()
        guard details.item == item else { return nil }
        guard await isCurrent() else { return nil }
        let sources = ContentPreview.prepareHistoryPane(details.effective.map {
            PreviewRepresentationMetadata(typeIdentifier: $0.typeIdentifier, byteCount: $0.byteCount)
        })
        var outcome = PreviewOutcome.unavailable(.unsupported)
        for source in sources {
            try Task.checkCancellation()
            if let failure = source.preflightFailure { return failure }
            let representation = try await history.representation(HistoryRepresentationRequest(
                item: item, basis: .effective, typeIdentifier: source.typeIdentifier
            ))
            try Task.checkCancellation()
            guard await isCurrent() else { return nil }
            outcome = await renderer.renderSelectedHistoryPane(source, representation: PreviewRepresentation(
                typeIdentifier: representation.typeIdentifier, bytes: representation.bytes
            ), pdfPage: pdfPage)
            try Task.checkCancellation()
            guard await isCurrent() else { return nil }
            if !source.permitsFallback(after: outcome) { return outcome }
        }
        return outcome
    }
}

/// Footer facts are the current visible row's values, independent of content
/// loading. Missing rows (including page-window/query gaps) hide the footer;
/// another version never supplies metadata for the requested exact reference.
package struct PreviewFooterMetadata: Equatable, Sendable {
    package let lastSource: String?
    package let count: UInt64
    package let lastCopiedAt: Date

    package init?(item: HistoryItemReference?, row: HistoryRow?) {
        guard let item, let row, row.item == item else { return nil }
        lastSource = row.lastSource
        count = row.copyCount
        lastCopiedAt = row.lastCopiedAt
    }
}

/// The preview column: a loading indicator while the item's content loads,
/// the resolved content, and a metadata bar (source, copy count, last
/// copied time — Maccy's preview footer replicated without AppKit app
/// icons, which PresentationUI's confinement forbids).
struct HistoryPreviewView: View {
    private let viewState: HistoryViewState
    private let previewState: PreviewPaneState
    private let selectionSource: SelectionSource

    @State private var loader: PreviewContentLoader
    @State private var retryGeneration = 0
    @State private var fileConfirmationPresented = false
    @State private var pdfPageSelection: PDFPageSelection?

    /// Page selection belongs to this exact content version, including when
    /// the observed target changes before SwiftUI invokes onChange.
    private struct PDFPageSelection {
        let item: HistoryItemReference
        let number: Int
    }

    private var requestedPDFPage: Int {
        pdfPageSelection?.item == targetItem ? (pdfPageSelection?.number ?? 1) : 1
    }
    @Environment(\.locale) private var locale

    /// Retargets and retries share SwiftUI's view-owned task, so either a
    /// new reference or disappearance cancels the active load (Card 9D).
    private struct LoadRequest: Equatable {
        let item: HistoryItemReference?
        let retryGeneration: Int
        let pdfPage: Int
    }

    /// Standalone entry point: PreviewPaneState owns the exact target.
    init(viewState: HistoryViewState, previewState: PreviewPaneState) {
        self.viewState = viewState
        self.previewState = previewState
        selectionSource = .paneState
        _loader = State(
            initialValue: PreviewContentLoader(
                history: viewState.history, filePreviewSettings: viewState.filePreviewSettings
            )
        )
    }

    /// The composed panel supplies the reference derived directly from its
    /// latest rows, closing the observation→preview gap before dwell state
    /// finishes retargeting the visible pane (review Card 9A).
    package init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        selection: PreviewSelectionResolution
    ) {
        self.viewState = viewState
        self.previewState = previewState
        selectionSource = .observedRows(selection)
        _loader = State(
            initialValue: PreviewContentLoader(
                history: viewState.history, filePreviewSettings: viewState.filePreviewSettings
            )
        )
    }

    /// The quick-look overlay pins its exact reference at trigger time and
    /// owns dismissal itself, so its target is independent of the preview
    /// pane's dwell/visibility state. Content still flows through the same
    /// fenced loader, typed failure taxonomy, and `clipy.preview.*`
    /// identifiers as the side pane (SPEC-IMPL-007 / PREVIEW-FENCE-1).
    package init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        item: HistoryItemReference
    ) {
        self.viewState = viewState
        self.previewState = previewState
        selectionSource = .exactItem(item)
        _loader = State(
            initialValue: PreviewContentLoader(
                history: viewState.history, filePreviewSettings: viewState.filePreviewSettings
            )
        )
    }

    private enum SelectionSource {
        case paneState
        case observedRows(PreviewSelectionResolution)
        case exactItem(HistoryItemReference)
    }

    private var targetItem: HistoryItemReference? {
        switch selectionSource {
        case .paneState:
            previewState.previewedItem
        case .observedRows(let selection):
            selection.previewTarget(previewedItem: previewState.previewedItem)
        case .exactItem(let item):
            item
        }
    }

    private var observedRow: HistoryRow? {
        guard let targetItem else { return nil }
        return viewState.rows.first { $0.item == targetItem }
    }

    var body: some View {
        VStack(spacing: 0) {
            if loader.requestedItem == targetItem, let file = loader.loadedFileReference {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: file.filePath ?? file.address)
                        .font(.caption)
                        .lineLimit(2)
                    Text(PreviewCopy.text("Showing the file’s current contents. Copying still copies the original file reference."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("clipy.preview.file.disclosure")
                    Button(PreviewCopy.text("Back to File Reference")) { loader.showFileReference() }
                        .accessibilityIdentifier("clipy.preview.file.back")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                Divider()
            }
            previewBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            metadataBar
                .padding(.horizontal, PanelTheme.spacingMedium)
                .padding(.vertical, PanelTheme.spacingSmall)
        }
        // One load per exact reference, explicit page choice, or retry; the loader's fence
        // discards a late result, so a superseded selection never renders
        // another item's content (SPEC-IMPL-007 / PREVIEW-FENCE-1).
        .task(id: LoadRequest(item: targetItem, retryGeneration: retryGeneration, pdfPage: requestedPDFPage)) {
            await loader.load(item: targetItem, pdfPage: requestedPDFPage)
        }
        .onChange(of: targetItem) { _, target in
            fileConfirmationPresented = false
            pdfPageSelection = nil
            if loader.requestedItem != target { loader.clear() }
        }
        .onChange(of: viewState.surfacePurge) { _, purge in
            guard let purge else { return }
            loader.purgePreview(purge.scope, isPinned: observedRow?.pinnedPosition != nil)
            if loader.fileLoadConfirmation == nil { fileConfirmationPresented = false }
        }
        .onDisappear {
            pdfPageSelection = nil
            fileConfirmationPresented = false
            loader.clear()
        }
        .alert(PreviewCopy.text("Load File Contents?"), isPresented: $fileConfirmationPresented) {
            Button(PreviewCopy.text("Load File")) {
                guard loader.requestedItem == targetItem else { return }
                loader.confirmFilePreview()
            }
            .accessibilityIdentifier("clipy.preview.file.confirm")
            Button(PreviewCopy.text("Cancel"), role: .cancel) {
                loader.cancelFilePreviewConfirmation()
            }
        } message: {
            Text(PreviewCopy.text("Clipy will read this local file once to show a preview. Its current contents are not added to clipboard history. No website will be opened.")
                + "\n\n" + (loader.fileLoadConfirmation?.filePath ?? ""))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.preview.root")
    }

    /// One explicit page choice starts one view-owned request. Clearing here
    /// immediately retires the old raster and any superseded publication;
    /// the task ID handles cancellation of the preceding load.
    private func selectPDFPage(_ page: Int) {
        guard let item = targetItem, loader.requestedItem == item,
              loader.loadedFileReference == nil,
              let count = loader.pdfPageCount, (1...count).contains(page),
              page != loader.pdfPageNumber else { return }
        pdfPageSelection = PDFPageSelection(item: item, number: page)
        loader.clear()
    }

    private func pdfNavigation(page: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Button {
                selectPDFPage(page - 1)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(page <= 1)
            .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            .help(PreviewCopy.text("Previous PDF Page"))
            .accessibilityLabel(PreviewCopy.text("Previous PDF Page"))
            .accessibilityIdentifier("clipy.preview.pdf.previous")

            Text(PreviewCopy.pdfPageCaption(pageNumber: page, pageCount: count, locale: locale))
                .font(.caption)
                .monospacedDigit()
                .accessibilityIdentifier("clipy.preview.pdf.page")

            Button {
                selectPDFPage(page + 1)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(page >= count)
            .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            .help(PreviewCopy.text("Next PDF Page"))
            .accessibilityLabel(PreviewCopy.text("Next PDF Page"))
            .accessibilityIdentifier("clipy.preview.pdf.next")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var previewBody: some View {
        if targetItem == nil {
            unavailableBody
        } else if loader.requestedItem != targetItem || loader.requestedPDFPage != requestedPDFPage {
            ProgressView()
                .accessibilityLabel(PreviewCopy.text("Loading preview"))
        } else {
            switch loader.phase {
            case .loading:
                ProgressView()
                    .accessibilityLabel(PreviewCopy.text("Loading preview"))
            case .content(.image):
                if let raster = loader.raster,
                   let accessibilityLabel =
                    loader.imageAccessibilityLabel(locale: locale),
                   let image = PreviewRasterDisplay.image(
                       raster,
                       scale: 1,
                       label: Text(accessibilityLabel)
                   ) {
                    VStack(spacing: 0) {
                        image
                            .resizable()
                            .scaledToFit()
                            // Fill the available area while keeping the
                            // bounded raster aspect-fit and centered.
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(8)
                            .accessibilityIdentifier("clipy.preview.image")
                        if loader.loadedFileReference == nil,
                           let page = loader.pdfPageNumber,
                           let count = loader.pdfPageCount {
                            pdfNavigation(page: page, count: count)
                        }
                        if let notice = loader.appliedRasterNotice(locale: locale) {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .accessibilityIdentifier(loader.pdfPageCount == nil
                                    ? "clipy.preview.multi-image-notice"
                                    : "clipy.preview.pdf-page-notice")
                        }
                    }
                } else {
                    failedBody
                }
            case .content(.text(let text, let wasTruncated)):
                VStack(spacing: 0) {
                    ScrollView(.vertical) {
                        Text(verbatim: text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .accessibilityIdentifier("clipy.preview.text")
                    }
                    // The body scrolls independently; the disclosure stays
                    // visible and never becomes part of selectable content.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if wasTruncated {
                        Text(PreviewCopy.text(
                            "Preview truncated. Copying the item keeps its complete content."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .accessibilityIdentifier("clipy.preview.truncation-notice")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .content(.reference(let reference)):
                ReferencePreviewView(
                    reference: reference,
                    requestFileLoad: loader.canLoadFilePreview ? {
                        loader.requestFilePreview()
                        fileConfirmationPresented = loader.fileLoadConfirmation != nil
                    } : nil
                )
            case .failed:
                failedBody
            case .unsupported:
                unavailableBody
            }
        }
    }

    private var unavailableBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(PreviewCopy.text("No Preview"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.preview.unsupported")
        }
    }

    /// Retry is offered only when the failed episode's typed outcome admits
    /// replay. Stable unsupported, malformed, resource, invalid, and stale
    /// outcomes therefore never present this control (review Card 9D).
    private var failedBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(loader.filePreviewFailure.map(PreviewCopy.fileFailure) ?? PreviewCopy.text("Preview Unavailable"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.preview.failed")
            if loader.canRetryFailure {
                Button(PreviewCopy.text("Retry")) {
                    if loader.phase == .failed, loader.canRetryFailure {
                        retryGeneration += 1
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityIdentifier("clipy.preview.retry")
            }
        }
    }

    // MARK: - Metadata bar

    @ViewBuilder
    private var metadataBar: some View {
        HStack(spacing: 6) {
            if let occurrence = PreviewFooterMetadata(item: targetItem, row: observedRow) {
                if let source = occurrence.lastSource {
                    Text(source)
                        .lineLimit(1)
                }
                Text(PreviewCopy.copyCount(occurrence.count, locale: locale))
                Spacer(minLength: 4)
                Text(occurrence.lastCopiedAt, style: .date)
                Text(occurrence.lastCopiedAt, style: .time)
            } else {
                Spacer()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
