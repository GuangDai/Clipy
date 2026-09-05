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
/// PREVIEW-FENCE-1): owns the async details read, renderer invocation, and
/// exact-reference fence. ContentPreview owns the off-MainActor bounded
/// decode itself.
///
/// Fence law: a load captures its `HistoryItemReference` at start; after
/// EVERY await it re-checks cancellation AND that its reference is still
/// the requested one. The details answer itself must also carry that same
/// reference: `details(for:)` reads by ID, so a concurrent revision that
/// advanced the Content Version is invisible to the request — the
/// `details.item == item` half pins the version (04 §9's caller-side fence
/// convention). A late or superseded result is DISCARDED without touching
/// any published state (the newer load owns the phase and applied content).
/// Starting a new exact reference invalidates the previous publication
/// before the first suspension, so old sensitive content is not retained as
/// a loading placeholder.
///
/// Retention: only the REQUESTED item's applied content lives here — a
/// bounded decoded image or a capped text body. The full Effective Content
/// bytes are a transient local of `load(item:)`, never stored (closing
/// SPEC-IMPL-007's "retains the full selected image bytes in view state").
/// Bounding those bytes BEFORE they reach the MainActor needs the 05 §3.1
/// `preview(for:pixels:)` storage seam — an owned follow-up outside this
/// file set.
@MainActor @Observable
package final class PreviewContentLoader {

    /// What the preview column renders for the requested item. Raster pixels
    /// stay in the framework-neutral `raster` value below.
    package enum AppliedContent: Equatable {
        /// Body text, capped by ContentPreview's history-pane profile.
        case text(String)
        /// A bounded decoded image is published on `image`.
        case image
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

    /// The metadata-bar facts for the applied item (03b §9).
    package private(set) var occurrence: CopyOccurrenceSummary?

    /// The exact reference the loader is serving — set synchronously at the
    /// head of every `load(item:)`; late completions compare against it.
    package private(set) var requestedItem: HistoryItemReference?

    /// Distinguishes overlapping load episodes even when they request the
    /// same exact reference. Reference equality alone cannot tell an older
    /// retry from the current request (review Card 9A).
    private var requestGeneration = 0

    /// Eager bounded pixels; no ImageIO/CoreGraphics object is retained in
    /// observable state or crosses the renderer actor seam.
    package private(set) var raster: PreviewRaster?

    /// The applied image's pixel dimensions — the package-observable proof
    /// of a decode without exposing the image itself.
    package var appliedImageSize: CGSize? {
        raster.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Literal semantic dimensions for Card 15C. The value comes from the
    /// bounded eager artifact, never by retaining or introspecting a
    /// `CGImage`/`NSImage` accessibility object.
    package var appliedImageAccessibilityLabel: String? {
        guard let raster else { return nil }
        return "Image preview, \(raster.width) by \(raster.height) pixels"
    }

    private let history: any ClipboardHistory

    private let renderer = ContentPreview()

#if DEBUG
    /// Running-app acceptance can make only this loader's first details read
    /// transiently unavailable. The one-shot is instance-local: Retry still
    /// replays the same exact reference through the production History read
    /// and ContentPreview renderer, while Release has no failure switch
    /// (review Card 9D / Card 15 runtime acceptance).
    private var shouldFailNextDetailsReadForRunningUITest =
        ProcessInfo.processInfo.environment["CLIPY_RUNNING_UI_TEST"] == "1"
            && ProcessInfo.processInfo.environment[
                "CLIPY_UI_TEST_PREVIEW_FAILURE"
            ] == "transient-details-once"
#endif

    package init(history: any ClipboardHistory) {
        self.history = history
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
        await load(item: requestedItem)
    }

    /// View disappearance releases applied content immediately, including
    /// when SwiftUI retains this state for a later appearance. In-flight
    /// reads/renders cannot publish after the pane or Quick Look closes
    /// (PREVIEW-FENCE-1).
    package func clear() {
        requestGeneration += 1
        requestedItem = nil
        raster = nil
        occurrence = nil
        canRetryFailure = false
        phase = .unsupported
    }

    /// Loads the preview content for `item` (`nil` clears the pane's
    /// content state). Driven by the view's reference/retry-keyed task: a
    /// retarget cancels the previous load's task, and the fence covers the
    /// case where cancellation arrives late or the awaited work does not
    /// throw on cancellation.
    package func load(item: HistoryItemReference?) async {
        guard !Task.isCancelled else { return }
        guard let item else {
            clear()
            return
        }
        requestGeneration += 1
        let generation = requestGeneration
        requestedItem = item
        raster = nil
        occurrence = nil
        canRetryFailure = false
        phase = .loading
        do {
            let details = try await readDetails(for: item.id)
            try Task.checkCancellation()
            guard requestGeneration == generation,
                  requestedItem == item
            else { return }
            guard details.item == item else {
                // The ID-based detail read raced a revision. Observation
                // retargets the current exact reference; this stale episode
                // must settle instead of retaining a permanent spinner.
                phase = .failed
                return
            }
            let outcome = await renderer.renderHistoryPane(
                details.effective.map {
                    PreviewRepresentation(
                        typeIdentifier: $0.typeIdentifier,
                        bytes: $0.bytes
                    )
                }
            )
            try Task.checkCancellation()
            guard requestGeneration == generation,
                  requestedItem == item
            else { return }
            switch outcome {
            case .content(.raster(let artifact)):
                raster = artifact
                canRetryFailure = false
                phase = .content(.image)
                occurrence = details.occurrence
            case .content(.text(let artifact)):
                raster = nil
                canRetryFailure = false
                phase = .content(.text(artifact.text))
                occurrence = details.occurrence
            case .unavailable:
                raster = nil
                canRetryFailure = false
                phase = .unsupported
                occurrence = details.occurrence
            case .failed(let failure):
                raster = nil
                canRetryFailure = failure == .renderer
                phase = .failed
                occurrence = nil
            }
        } catch is CancellationError {
            // Cancellation is only a publication fence. It does not publish
            // a phase transition or claim that underlying History/native
            // work stopped; a superseding request owns the next phase.
            return
        } catch let failure as HistoryFailure {
            // History keeps its own typed taxonomy. Only its explicit
            // temporary-unavailability case admits replay of this exact
            // request; invalid/stale/persistence failures remain terminal.
            guard !Task.isCancelled,
                  requestGeneration == generation,
                  requestedItem == item
            else { return }
            raster = nil
            occurrence = nil
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
            occurrence = nil
            canRetryFailure = false
            phase = .failed
        }
    }

    /// The DEBUG branch substitutes one outcome at the loader's details-call
    /// boundary. A successful retry still has to traverse the real History
    /// read, ContentPreview renderer, and view publication before content is
    /// observable; the first substituted episode does not claim History I/O.
    private func readDetails(for id: HistoryItemID) async throws -> HistoryDetails {
#if DEBUG
        if shouldFailNextDetailsReadForRunningUITest {
            shouldFailNextDetailsReadForRunningUITest = false
            throw HistoryFailure.temporarilyUnavailable(.dedupIndexRebuild)
        }
#endif
        return try await history.details(for: id)
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

    /// Retargets and retries share SwiftUI's view-owned task, so either a
    /// new reference or disappearance cancels the active load (Card 9D).
    private struct LoadRequest: Equatable {
        let item: HistoryItemReference?
        let retryGeneration: Int
    }

    /// Standalone entry point: PreviewPaneState owns the exact target.
    init(viewState: HistoryViewState, previewState: PreviewPaneState) {
        self.viewState = viewState
        self.previewState = previewState
        selectionSource = .paneState
        _loader = State(
            initialValue: PreviewContentLoader(history: viewState.history)
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
            initialValue: PreviewContentLoader(history: viewState.history)
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
            initialValue: PreviewContentLoader(history: viewState.history)
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

    var body: some View {
        VStack(spacing: 0) {
            previewBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            metadataBar
                .padding(.horizontal, PanelTheme.spacingMedium)
                .padding(.vertical, PanelTheme.spacingSmall)
        }
        // One load per exact observed reference or explicit retry; the loader's fence
        // discards a late result, so a superseded selection never renders
        // another item's content (SPEC-IMPL-007 / PREVIEW-FENCE-1).
        .task(id: LoadRequest(item: targetItem, retryGeneration: retryGeneration)) {
            await loader.load(item: targetItem)
        }
        .onDisappear {
            loader.clear()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.preview.root")
    }

    // MARK: - Content

    @ViewBuilder
    private var previewBody: some View {
        if targetItem == nil {
            unavailableBody
        } else if loader.requestedItem != targetItem {
            ProgressView()
                .accessibilityLabel("Loading preview")
        } else {
            switch loader.phase {
            case .loading:
                ProgressView()
                    .accessibilityLabel("Loading preview")
            case .content(.image):
                if let raster = loader.raster,
                   let accessibilityLabel =
                    loader.appliedImageAccessibilityLabel,
                   let image = PreviewRasterDisplay.image(
                       raster,
                       scale: 1,
                       label: Text(accessibilityLabel)
                   ) {
                    image
                        .resizable()
                        .scaledToFit()
                        // Fill the (window-sized) content area so a taller
                        // panel shows a proportionally larger preview; the
                        // image itself stays aspect-fit and centered.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                        .accessibilityIdentifier("clipy.preview.image")
                } else {
                    failedBody
                }
            case .content(.text(let text)):
                ScrollView(.vertical) {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .accessibilityIdentifier("clipy.preview.text")
                }
                // The column is window-sized; the scroll view fills it so a
                // taller panel reveals more of the body per page.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("No Preview")
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
            Text("Preview Unavailable")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.preview.failed")
            if loader.canRetryFailure {
                Button("Retry") {
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
            if loader.requestedItem == targetItem,
               let occurrence = loader.occurrence {
                if let source = occurrence.lastSource {
                    Text(source)
                        .lineLimit(1)
                }
                Text("Copied \(occurrence.count)×")
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
