/// Floating and Quick Look preview presentation over one exact-reference
/// loader. Decoding and lossless text segmentation belong to ContentPreview;
/// the view owns visible layout and user controls (01 §6 / 06 §5).
import ContentPreview
import CoreGraphics
import Foundation
import HistoryCore
import SwiftUI

/// Footer facts are the current visible row's values, independent of content
/// loading. Missing rows (including page-window/query gaps) hide the footer;
/// another version never supplies metadata for the requested exact reference.
struct PreviewFooterMetadata: Equatable, Sendable {
    let lastSource: String?
    let count: UInt64
    let lastCopiedAt: Date

    init?(item: HistoryItemReference?, row: HistoryRow?) {
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

    private let sourceIcons: SourceIconStore?
    private var maximumHeight: CGFloat? = nil
    @State private var contentWidth: CGFloat = PanelGeometry.floatingPreviewWidth
    @State private var metadataHeight: CGFloat = 0
    @State private var fileHeaderHeight: CGFloat = 0
    @State private var imageFooterHeight: CGFloat = 0
    @State private var textNoticeHeight: CGFloat = 0
    @State private var loader: PreviewContentLoader
    @State private var retryGeneration = 0
    @State private var fileConfirmationPresented = false
    @State private var pdfPageSelection: PDFPageSelection?
    @State private var pinRequest: PinRequest?
    @State private var pinFailure: (item: HistoryItemReference, message: String)?
    @AppStorage(PreviewTextSettings.maximumCharactersKey)
    private var maximumTextCharacters = PreviewTextSettings.defaultMaximumCharacters
    @AppStorage(PreviewTextSettings.isLengthLimitedKey)
    private var isTextLengthLimited = true

    /// Page selection belongs to this exact content version, including when
    /// the observed target changes before SwiftUI invokes onChange.
    private struct PDFPageSelection {
        let item: HistoryItemReference
        let number: Int
    }

    private struct PinRequest: Equatable {
        let item: HistoryItemReference
        let isPinned: Bool
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
        let maximumTextCharacters: Int
        let isTextLengthLimited: Bool
    }

    /// Standalone entry point: PreviewPaneState owns the exact target.
    init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        sourceIcons: SourceIconStore? = nil,
        maximumHeight: CGFloat? = nil,
        preparedLoader: PreviewContentLoader? = nil
    ) {
        self.viewState = viewState
        self.previewState = previewState
        self.sourceIcons = sourceIcons
        self.maximumHeight = maximumHeight
        selectionSource = .paneState
        _loader = State(
            initialValue: preparedLoader ?? PreviewContentLoader(
                history: viewState.history, filePreviewSettings: viewState.filePreviewSettings,
                renderer: viewState.previewRenderer
            )
        )
    }

    /// The composed panel supplies the reference derived directly from its
    /// latest rows, closing the observation→preview gap before dwell state
    /// finishes retargeting the visible pane (review Card 9A).
    init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        selection: PreviewSelectionResolution,
        sourceIcons: SourceIconStore? = nil
    ) {
        self.viewState = viewState
        self.previewState = previewState
        self.sourceIcons = sourceIcons
        selectionSource = .observedRows(selection)
        _loader = State(
            initialValue: PreviewContentLoader(
                history: viewState.history, filePreviewSettings: viewState.filePreviewSettings,
                renderer: viewState.previewRenderer
            )
        )
    }

    /// The quick-look overlay pins its exact reference at trigger time and
    /// owns dismissal itself, so its target is independent of the preview
    /// pane's dwell/visibility state. Content still flows through the same
    /// fenced loader, typed failure taxonomy, and `clipy.preview.*`
    /// identifiers as the side pane (SPEC-IMPL-007 / PREVIEW-FENCE-1).
    init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        item: HistoryItemReference,
        sourceIcons: SourceIconStore? = nil
    ) {
        self.viewState = viewState
        self.previewState = previewState
        self.sourceIcons = sourceIcons
        selectionSource = .exactItem(item)
        _loader = State(
            initialValue: PreviewContentLoader(
                history: viewState.history, filePreviewSettings: viewState.filePreviewSettings,
                renderer: viewState.previewRenderer
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

    private var bodyMaximumHeight: CGFloat? {
        maximumHeight.map { max(0, $0 - metadataHeight - fileHeaderHeight) }
    }

    private var flexibleHeight: CGFloat? { maximumHeight == nil ? .infinity : nil }

    var body: some View {
        VStack(spacing: 0) {
            if loader.requestedItem == targetItem, let file = loader.loadedFileReference {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button { loader.showFileReference() } label: {
                            Image(systemName: "chevron.backward")
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(PreviewCopy.text("Back to File Reference"))
                        .help(PreviewCopy.text("Back to File Reference"))
                        .accessibilityIdentifier("clipy.preview.file.back")
                        Text(verbatim: file.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? file.address)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.filePath ?? file.address)
                    }
                    Text(PreviewCopy.text("Showing the file contents loaded for this preview. Copying still copies the original file reference."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(PreviewCopy.text("Showing the file contents loaded for this preview. Copying still copies the original file reference."))
                        .accessibilityIdentifier("clipy.preview.file.disclosure")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height + 1 } action: {
                    fileHeaderHeight = $0
                }
                .onDisappear { fileHeaderHeight = 0 }
                Divider()
            }
            previewBody
                .frame(maxWidth: .infinity, maxHeight: flexibleHeight)
                .layoutPriority(1)
            if PreviewFooterMetadata(item: targetItem, row: observedRow) != nil {
                VStack(spacing: 0) {
                    Divider().opacity(0.5)
                    metadataBar
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    if let pinFailure, pinFailure.item == targetItem {
                        HStack(alignment: .top, spacing: 8) {
                            Label(pinFailure.message, systemImage: "exclamationmark.triangle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("clipy.preview.pin.failure")
                            Button { self.pinFailure = nil } label: {
                                Image(systemName: "xmark")
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(PanelActionsCopy.text(
                                "Dismiss", bundle: PanelActionsCopy.bundle(for: locale)
                            ))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { metadataHeight = $0 }
                .onDisappear { metadataHeight = 0 }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        // One load per exact reference, explicit page choice, or retry; the loader's fence
        // discards a late result, so a superseded selection never renders
        // another item's content (SPEC-IMPL-007 / PREVIEW-FENCE-1).
        .task(id: LoadRequest(item: targetItem, retryGeneration: retryGeneration, pdfPage: requestedPDFPage,
                              maximumTextCharacters: maximumTextCharacters, isTextLengthLimited: isTextLengthLimited)) {
            await loader.loadForDisplay(item: targetItem, pdfPage: requestedPDFPage,
                textConfiguration: PreviewTextSettings.configuration(
                    maximumCharacters: maximumTextCharacters, isLengthLimited: isTextLengthLimited),
                isRetry: retryGeneration > 0)
        }
        .task(id: pinRequest) {
            guard let request = pinRequest, !Task.isCancelled else { return }
            await performPin(request)
        }
        .onChange(of: targetItem) { _, target in
            previewState.isInformationPresented = false
            fileConfirmationPresented = false
            pdfPageSelection = nil
            pinRequest = nil
            pinFailure = nil
            if loader.requestedItem != target { loader.clear() }
        }
        .onChange(of: viewState.surfacePurge) { _, purge in
            guard let purge else { return }
            previewState.isInformationPresented = false
            loader.purgePreview(purge.scope, isPinned: observedRow?.pinnedPosition != nil)
            if loader.fileLoadConfirmation == nil { fileConfirmationPresented = false }
        }
        // The floating pane is never key, so its Retry button's ⌘R
        // shortcut cannot fire there; the main panel republishes the chord
        // through the pane state, applied exactly like the button.
        .onChange(of: previewState.previewRetryRequestGeneration) { _, _ in
            if loader.phase == .failed, loader.canRetryFailure {
                retryGeneration += 1
            }
        }
        // The same republish covers the PDF pager's ⌥⌘←/→ chords; the
        // request is applied exactly like the pager buttons, so
        // `selectPDFPage`'s own bounds/file guards keep an out-of-range
        // step inert.
        .onChange(of: previewState.previewPagerRequestGeneration) { _, _ in
            guard let page = loader.pdfPageNumber,
                  loader.pdfPageCount != nil
            else { return }
            switch previewState.previewPagerRequestDirection {
            case .previous:
                selectPDFPage(page - 1)
            case .next:
                selectPDFPage(page + 1)
            }
        }
        .onDisappear {
            previewState.isInformationPresented = false
            pdfPageSelection = nil
            fileConfirmationPresented = false
            pinRequest = nil
            pinFailure = nil
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

    /// Captured documents use the view-owned History task; confirmed local
    /// files reuse their immutable source under the loader's file task.
    /// Both retire the old raster before starting one requested page.
    private func selectPDFPage(_ page: Int) {
        guard let item = targetItem, loader.requestedItem == item,
              let count = loader.pdfPageCount, (1...count).contains(page),
              page != loader.pdfPageNumber else { return }
        if loader.loadedFileReference != nil {
            loader.loadFilePDFPage(page)
            return
        }
        pdfPageSelection = PDFPageSelection(item: item, number: page)
        loader.clear()
    }

    private func pdfNavigation(page: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                selectPDFPage(page - 1)
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .disabled(page <= 1)
            .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            .help(PreviewCopy.text("Previous PDF Page"))
            .accessibilityLabel(PreviewCopy.text("Previous PDF Page"))
            .accessibilityIdentifier("clipy.preview.pdf.previous")

            // Keep the full phrase when it fits; a narrow Quick Look uses
            // the same localized numbers without squeezing the hit targets.
            ViewThatFits(in: .horizontal) {
                Text(PreviewCopy.pdfPageCaption(pageNumber: page, pageCount: count, locale: locale))
                    .fixedSize()
                Text(verbatim: LocalizedCountPresentation.number(page, locale: locale)
                    + " / " + LocalizedCountPresentation.number(count, locale: locale))
                    .fixedSize()
            }
            .font(.caption)
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PreviewCopy.pdfPageCaption(pageNumber: page, pageCount: count, locale: locale))
            .accessibilityIdentifier("clipy.preview.pdf.page")

            Button {
                selectPDFPage(page + 1)
            } label: {
                Image(systemName: "chevron.forward")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .disabled(page >= count)
            .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            .help(PreviewCopy.text("Next PDF Page"))
            .accessibilityLabel(PreviewCopy.text("Next PDF Page"))
            .accessibilityIdentifier("clipy.preview.pdf.next")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 4)
    }

    // MARK: - Content

    @ViewBuilder
    private var previewBody: some View {
        if targetItem == nil {
            unavailableBody
        } else if loader.requestedItem != targetItem
            || (loader.loadedFileReference == nil && loader.requestedPDFPage != requestedPDFPage) {
            loadingBody
        } else {
            switch loader.phase {
            case .loading:
                loadingBody
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
                            // Keep a small image at its natural size and let
                            // larger artifacts shrink into the available pane.
                            .frame(maxWidth: CGFloat(raster.width), maxHeight: CGFloat(raster.height))
                            .frame(height: bodyMaximumHeight.map {
                                min(
                                    CGFloat(raster.height),
                                    max(0, contentWidth - 24) * CGFloat(raster.height) / CGFloat(raster.width),
                                    max(0, $0 - imageFooterHeight - 24)
                                )
                            })
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: flexibleHeight)
                            .accessibilityIdentifier("clipy.preview.image")
                        VStack(spacing: 0) {
                            if let page = loader.pdfPageNumber, let count = loader.pdfPageCount {
                                pdfNavigation(page: page, count: count)
                            }
                            if let notice = loader.appliedRasterNotice(locale: locale) {
                                Text(notice)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .help(notice)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .accessibilityIdentifier(loader.pdfPageCount == nil
                                    ? "clipy.preview.multi-image-notice"
                                    : "clipy.preview.pdf-page-notice")
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { imageFooterHeight = $0 }
                    }
                } else {
                    failedBody
                }
            case .content(.text(_, let wasTruncated)):
                VStack(spacing: 0) {
                    PreviewTextBody(segments: loader.textSegments,
                        maximumHeight: bodyMaximumHeight.map { max(0, $0 - textNoticeHeight) })
                    .id(targetItem)
                    // The body scrolls independently; the disclosure stays
                    // visible and never becomes part of selectable content.
                    .frame(maxWidth: .infinity, maxHeight: flexibleHeight)
                    if wasTruncated {
                        Text(PreviewCopy.text(
                            "Preview truncated. Copying the item keeps its complete content."
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.06))
                        .accessibilityIdentifier("clipy.preview.truncation-notice")
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textNoticeHeight = $0 }
                        .onDisappear { textNoticeHeight = 0 }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: flexibleHeight)
            case .content(.reference(let reference)):
                ReferencePreviewView(
                    reference: reference,
                    requestFileLoad: loader.canLoadFilePreview ? {
                        loader.requestFilePreview()
                        fileConfirmationPresented = loader.fileLoadConfirmation != nil
                    } : nil,
                    maximumHeight: bodyMaximumHeight
                )
            case .failed:
                failedBody
            case .unsupported:
                unavailableBody
            }
        }
    }

    private var loadingBody: some View {
        ProgressView()
            .controlSize(.small)
            .padding(16)
            .accessibilityLabel(PreviewCopy.text("Loading preview"))
    }

    private var unavailableBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.body)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(PreviewCopy.text("No Preview"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.preview.unsupported")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// Retry is offered only when the failed episode's typed outcome admits
    /// replay. Stable unsupported, malformed, resource, invalid, and stale
    /// outcomes therefore never present this control (review Card 9D).
    private var failedBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.body)
                .foregroundStyle(.tertiary)
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
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: - Metadata bar

    /// One footer intent waits for its receipt (03b §10). Cancelling this
    /// view's task only retires its feedback; an admitted write may still
    /// commit. A retargeted preview never accepts that task's late result.
    private func performPin(_ request: PinRequest) async {
        do {
            if request.isPinned {
                _ = try await viewState.unpinAwaitingReceipt(request.item.id)
            } else {
                _ = try await viewState.pinAwaitingReceipt(request.item.id)
            }
        } catch {
            guard !Task.isCancelled, pinRequest == request else { return }
            if let failure = error as? HistoryFailure {
                pinFailure = (request.item, FailurePresentation.message(
                    for: failure, bundle: PanelActionsCopy.bundle(for: locale)
                ))
            } else if !(error is CancellationError) {
                pinFailure = (request.item, PanelActionsCopy.text(
                    "Clipy couldn't update this item.", bundle: PanelActionsCopy.bundle(for: locale)
                ))
            }
        }
        guard !Task.isCancelled, pinRequest == request else { return }
        pinRequest = nil
    }

    @ViewBuilder
    private var metadataBar: some View {
        if let occurrence = PreviewFooterMetadata(item: targetItem, row: observedRow) {
            HStack(spacing: 8) {
                SourceApplicationLabel(application: occurrence.lastSource, store: sourceIcons)
                    .foregroundStyle(.secondary)
                if occurrence.count > 1 {
                    // Copy count remains available in Information. Give the
                    // source and actions room before this secondary detail;
                    // resizing never replaces the source's icon-load owner.
                    ViewThatFits(in: .horizontal) {
                        Text(PreviewCopy.copyCount(occurrence.count, locale: locale))
                            .fixedSize()
                            .foregroundStyle(.secondary)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .layoutPriority(-1)
                }
                Spacer(minLength: 4)
                    .layoutPriority(-2)
                if let row = observedRow {
                    Button {
                        // Resolve the live row on activation so repeated
                        // shortcuts never reuse a rendered pin state.
                        guard pinRequest == nil, let current = observedRow else { return }
                        pinFailure = nil
                        pinRequest = PinRequest(item: current.item, isPinned: current.pinnedPosition != nil)
                    } label: {
                        Group {
                            if pinRequest?.item == row.item {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: row.pinnedPosition == nil ? "pin" : "pin.fill")
                                    .font(.system(size: 12))
                            }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                    }
                    .disabled(pinRequest != nil)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.mini)
                    .foregroundStyle(row.pinnedPosition == nil ? Color.secondary : Color.accentColor)
                    // The floating pane is never key; Quick Look shares this
                    // button in the key window while the list is disabled.
                    .keyboardShortcut("p", modifiers: .command)
                    .help(PanelActionsCopy.text(row.pinnedPosition == nil ? "Pin" : "Unpin") + "  ⌘P")
                    .accessibilityLabel(PanelActionsCopy.text(row.pinnedPosition == nil ? "Pin" : "Unpin"))
                    .accessibilityIdentifier("clipy.preview.pin")
                    .fixedSize()
                    .layoutPriority(1)
                }
                Button { previewState.isInformationPresented.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.mini)
                .help(PreviewPresentationCopy.text("Preview Information"))
                .accessibilityLabel(PreviewPresentationCopy.text("Preview Information"))
                .accessibilityIdentifier("clipy.preview.information")
                .fixedSize()
                .layoutPriority(1)
                .popover(isPresented: Binding(
                    get: { previewState.isInformationPresented },
                    set: { previewState.isInformationPresented = $0 }
                ), arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let row = observedRow {
                            PreviewMetadataView(history: viewState.history, row: row, sourceIcons: sourceIcons)
                                .id(row.item)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("clipy.preview.information.content")
                    .padding(16)
                    .frame(idealWidth: 240, maxWidth: 360, alignment: .leading)
                }
                if let row = observedRow {
                    Button { viewState.requestPasteFromDisplayedRow(row.item) } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.mini)
                    .help(PanelActionsCopy.text("Copy to Clipboard") + "  ↵")
                    .accessibilityLabel(PanelActionsCopy.text("Copy to Clipboard"))
                    .accessibilityIdentifier("clipy.preview.copy")
                    .fixedSize()
                    .layoutPriority(1)
                }
            }
            .font(.caption2)
        }
    }
}
