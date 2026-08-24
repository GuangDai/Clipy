/// HistoryViewState.swift — the panel's single observable view-state holder
/// over HistoryCore DTOs (docs/01-architecture.md §6; docs/roadmap/
/// 05-presentationui.md). It never sees SwiftData, Domain state, or
/// fingerprints — only the public DTO seam.
///
/// Observation is snapshot replacement, not deltas (docs/04-coherence.md §5):
/// every incoming `HistoryPage` REPLACES `rows`. The held page is ordinary
/// caller state, not a cache tier (docs/04-coherence.md §11). Additional
/// pages are one-shot `browse` requests (docs/03a-instruction-set.md §7) whose
/// `.snapshotExpired` failure is recovered by resuming from the observed
/// first page's cursor (docs/04-coherence.md §6).
import ClipboardFormats
import Foundation
import HistoryCore
import SwiftUI

/// One receipt-confirmed invalidation for state owned by a single panel
/// surface (deep review Card 9B). This narrow public UI coordination value is
/// visible to the ClipyApp composition boundary, while only PresentationUI
/// can construct one. It is not a second History event stream: authoritative
/// rows still arrive exclusively through `observe`; the signal only drops
/// derived presentation state which must not survive a destructive/effective-
/// content commit.
public struct HistorySurfacePurge: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case all
        case unpinned
        case item(HistoryItemID)
        case revision(
            old: HistoryItemReference,
            new: HistoryItemReference
        )
    }

    public let generation: Int
    public let scope: Scope

    package init(generation: Int, scope: Scope) {
        self.generation = generation
        self.scope = scope
    }
}

/// View state over HistoryCore DTOs — the ONLY state holder for the browsing
/// panel (docs/01-architecture.md §6; roadmap 05).
///
/// Mutation methods (`pin`, `unpin`, `remove`, `clear`) do not throw: they
/// forward the `HistoryAction` to `perform` and store any typed
/// `HistoryFailure` into `failure` (docs/03b-instruction-set.md §10), where
/// the observation loop that committed the mutation also refreshes `rows`.
/// The detail/revise/retention methods are thin `async throws` passthroughs
/// because their callers (details pane, settings) own retry presentation.
@MainActor @Observable
public final class HistoryViewState {

    // MARK: - Injected state

    /// The public History seam (docs/03a-instruction-set.md §3). Production
    /// passes `SwiftDataHistory`; SwiftUI previews pass the scripted
    /// `PreviewClipboardHistory`.
    public let history: any ClipboardHistory

    /// Rows per browse/observation page. Default 50 — inside the Part VI
    /// page/observation row-limit range 1…500 (docs/06-cross-cutting.md §2).
    public let pageLimit: Int

    // MARK: - Observed panel state

    /// The full display rows: the latest observed first page plus any
    /// one-shot appended pages. Replaced wholesale by each observed page
    /// (docs/04-coherence.md §5).
    public private(set) var rows: [HistoryRow] = []

    /// True while a one-shot `browse` pagination request is in flight.
    public private(set) var isLoadingPage = false

    /// True after a browse intent has invalidated its prior rows and before
    /// the replacement observation produces its first authoritative page (or
    /// typed failure). This is intentionally separate from pagination: no
    /// prior-query row remains executable during this phase.
    public private(set) var isLoadingFirstPage = false

    /// The latest typed failure to surface in the panel banner; `nil` when
    /// its owning operation has recovered.
    public private(set) var failure: HistoryFailure?

    /// Latest receipt-confirmed presentation purge. The generation makes two
    /// identical mutations separately observable by SwiftUI and fences late
    /// local completions without introducing a process-wide cache bus.
    package private(set) var surfacePurge: HistorySurfacePurge?

    /// Monotonic identity of a published failure. Unlike `HistoryFailure`
    /// equality, this distinguishes two occurrences of the same typed value
    /// so dismissing one banner cannot suppress a later recurrence (Card 8H).
    package private(set) var failureEpisode = 0

    /// Whether the visible failure belongs to query activity that
    /// `refresh()` can actually retry. Mutation failures require repeating
    /// their original user action; presenting Refresh as mutation Retry would
    /// be a no-op with misleading copy (Card 8H).
    package var canRetryFailureByRefreshing: Bool {
        switch failureSource {
        case .observation, .pagination:
            return true
        case .mutation, nil:
            return false
        }
    }

    /// The raw search-field draft. Edits restart observation after a 250 ms
    /// debounce; only the empty string means `.recent`. Exact and regexp
    /// whitespace is syntax and is never rewritten by presentation state.
    public var searchText: String = "" {
        didSet { scheduleSearchRestart() }
    }

    /// The search evaluation mode (docs/03a-instruction-set.md §7). A change
    /// restarts observation immediately.
    public var searchMode: SearchMode = .fuzzy {
        didSet { replaceObservationImmediately() }
    }

    /// Composition-root paste hand-off (docs/01-architecture.md §5.6): the
    /// view state never touches the pasteboard; it hands the reference to the
    /// app, which resolves the payload and writes it. Default no-op so
    /// previews need no wiring.
    public var onPaste: @MainActor @Sendable (HistoryItemReference) -> Void = { _ in }

    /// App-shell accessibility handoff for one user-initiated remove whose
    /// committed receipt has already published its exact surface purge.
    /// External/background mutations use their own ingress and never invoke
    /// this callback, avoiding unsolicited or duplicate announcements.
    public var onCommittedUserRemoval:
        @MainActor @Sendable (HistorySurfacePurge) -> Void = { _ in }

    // MARK: - Pagination/observation bookkeeping (private)

    /// The observe loop task; cancelled and replaced on every restart.
    private var observationTask: Task<Void, Never>?

    /// The pending 250 ms search-debounce task.
    private var debounceTask: Task<Void, Never>?

    /// The one-shot page request owned by the current browsing lifecycle.
    private var paginationTask: Task<Void, Never>?

    /// Monotonic ownership token for pagination completion. Cancellation is
    /// advisory; the token prevents a non-cooperative stale request from
    /// mutating rows or a newer request's loading state.
    private var paginationRequestToken = 0

    /// Cursor to the page after the last displayed page; `nil` when the
    /// display holds the final page.
    private var nextPageCursor: HistoryPageCursor?

    /// The rows of the latest OBSERVED first page — the resume point a
    /// `.snapshotExpired` pagination failure falls back to (docs/
    /// 04-coherence.md §6).
    private var observedRows: [HistoryRow] = []

    /// The observed first page's own `next` cursor; the recovery resume
    /// cursor for `.snapshotExpired` pagination.
    private var observedCursor: HistoryPageCursor?

    /// Position of the latest authoritative first page. A receipt may return
    /// after an equal or newer observation; that page must not be erased,
    /// though the receipt still publishes its derived-state purge.
    private var observedPosition: ChangePosition?

    /// Rows-epoch counter. Bumped on every observation restart AND on every
    /// applied observed page, so a one-shot pagination result captured against
    /// superseded rows is discarded instead of appending to replaced rows.
    private var observationGeneration = 0

    /// The operation family that owns the visible failure. Observation and
    /// pagination recover through query activity; mutation failures remain
    /// visible until a later mutation succeeds.
    private enum FailureSource: Equatable {
        case mutation
        case observation
        case pagination
    }

    private var failureSource: FailureSource?

#if DEBUG
    /// One narrow running-app Card 3B ordering seam. It never substitutes
    /// History: the real `SwiftDataHistory` remains this state's sole facade,
    /// and both mutations still reach its sole `HistoryAuthority` writer. The
    /// first editor revision is preceded by one distinct real revision; the
    /// next details read then returns one typed transient failure before all
    /// later reads resume normally.
    private var injectCompetingEditorRevisionForTesting = false
    private var failNextEditorDetailsReadForTesting = false
#endif

    /// Search-edit debounce (V2-07 §4 feel: no per-keystroke re-observe).
    private static let searchDebounceInterval: Duration = .milliseconds(250)

    // MARK: - Init

    public init(history: any ClipboardHistory, pageLimit: Int = 50) {
        self.history = history
        self.pageLimit = pageLimit
    }

    // MARK: - Derived panel state

    /// Rows in the pinned lane (`pinnedPosition != nil`; docs/
    /// 03b-instruction-set.md §8 — the position is 0-based, display adds one).
    public var pinnedRows: [HistoryRow] {
        rows.filter { $0.pinnedPosition != nil }
    }

    /// Rows in the recency lane.
    public var unpinnedRows: [HistoryRow] {
        rows.filter { $0.pinnedPosition == nil }
    }

    /// Whether a further one-shot page exists after the displayed rows.
    public var hasNextPage: Bool {
        nextPageCursor != nil
    }

    /// Whether the current browse generation has published its authoritative
    /// first page. Query restart clears this fact before clearing/replacing
    /// rows; a load failure leaves it false, while an authoritative empty page
    /// sets it true through its ChangePosition (review Card 8A/8C).
    package private(set) var hasAuthoritativeFirstPage = false

    /// Whether the search field holds a query. Only a truly empty raw draft
    /// is `.recent`; whitespace can be meaningful exact/regexp syntax.
    public var isSearchActive: Bool {
        !searchText.isEmpty
    }

    /// The admitted query shape derived atomically from raw draft + mode.
    /// Exact/regexp preserve the draft byte-for-byte. Fuzzy admission is a
    /// bounded view of that draft, leaving the raw value intact for a later
    /// mode switch (03b §8; 06 §2).
    private var admittedKind: HistoryBrowseKind {
        guard !searchText.isEmpty else { return .recent }
        switch searchMode {
        case .exact, .regexp:
            return .search(text: searchText, mode: searchMode)
        case .fuzzy:
            let limit = HistoryLimits.standard.maximumFuzzyQueryCharacters
            return .search(text: String(searchText.prefix(limit)), mode: .fuzzy)
        }
    }

    // MARK: - Lifecycle

    /// Starts the observe loop for the current query. Idempotent: an existing
    /// loop already owns the active panel episode, so duplicate AppKit and
    /// SwiftUI lifecycle notifications do not register a second observer.
    /// Re-activation after `deactivate()` starts a fresh loop.
    public func activate() {
        guard observationTask == nil else { return }
        replaceObservationImmediately()
    }

    /// Cancels the observe loop and any pending debounce; safe to call again
    /// or to follow with `activate()`.
    public func deactivate() {
        debounceTask?.cancel()
        debounceTask = nil
        observationTask?.cancel()
        observationTask = nil
        invalidatePagination()
        isLoadingFirstPage = false
    }

    /// Explicit re-observe on user action (V2-07 §4: re-browse after retry) —
    /// immediate, no debounce.
    public func refresh() {
        replaceObservationImmediately()
    }

    /// Clears the raw query as one immediate intent. The TextField's ordinary
    /// edits remain debounced, while its explicit Clear control invalidates
    /// the old generation and starts `.recent` without a stale-results window.
    public func clearSearch() {
        guard !searchText.isEmpty else { return }
        searchText = ""
        debounceTask?.cancel()
        debounceTask = nil
        startObservation()
    }

    /// Appends one one-shot browse page after the last displayed row
    /// (docs/03a-instruction-set.md §7). On `.snapshotExpired` — the cursor
    /// predates the retained window or its query shape changed — the appended
    /// rows are dropped and pagination resumes from the observed first page's
    /// cursor (docs/04-coherence.md §6).
    public func loadNextPage() {
        guard !isLoadingPage, let cursor = nextPageCursor else { return }
        paginationRequestToken += 1
        let requestToken = paginationRequestToken
        isLoadingPage = true

        // Snapshot the request shape at call time: MainActor is free during
        // the await, and the cursor must travel with the kind it was minted
        // under or storage will (correctly) fail it as `.snapshotExpired`.
        let kind = admittedKind
        let limit = pageLimit
        let generation = observationGeneration
        let history = self.history

        paginationTask = Task { [weak self] in
            do {
                let page = try await history.browse(
                    HistoryBrowseRequest(kind: kind, limit: limit, after: cursor)
                )
                guard let self,
                      self.paginationRequestToken == requestToken,
                      self.observationGeneration == generation
                else { return }
                self.rows.append(contentsOf: page.rows)
                self.nextPageCursor = page.next
                self.clearFailure(from: .pagination)
                self.finishPagination(requestToken)
            } catch let failure as HistoryFailure {
                guard let self,
                      self.paginationRequestToken == requestToken,
                      self.observationGeneration == generation
                else { return }
                if case .snapshotExpired = failure {
                    // docs/04-coherence.md §6 recovery: fall back to the
                    // observed first page and continue from its cursor.
                    self.rows = self.observedRows
                    self.nextPageCursor = self.observedCursor
                }
                self.publishFailure(failure, from: .pagination)
                self.finishPagination(requestToken)
            } catch {
                // browse throws typed HistoryFailure at the storage boundary
                // (docs/03a-instruction-set.md §3); an untyped error has no
                // panel vocabulary and is swallowed.
                self?.finishPagination(requestToken)
            }
        }
    }

    // MARK: - Interactions (docs/03a-instruction-set.md §5; 03b §12)

    /// Hands a paste request to the composition root (docs/
    /// 01-architecture.md §5.6); the view state never touches NSPasteboard.
    public func requestPaste(_ item: HistoryItemReference) {
        onPaste(item)
    }

    /// List-owned paste requests are accepted only while the exact row is
    /// still in the authoritative display. This closes the short render gap
    /// in which a stale row closure could otherwise fire after query intent
    /// has synchronously cleared `rows`.
    package func requestPasteFromDisplayedRow(_ item: HistoryItemReference) {
        guard rows.contains(where: { $0.item == item }) else { return }
        onPaste(item)
    }

    /// Pins or reorders; typed failures land in `failure`.
    public func pin(_ id: HistoryItemID, at placement: PinnedPlacement = .first) {
        perform(.placePinned(id, at: placement))
    }

    /// Awaitable Pin seam for a details action whose readback must follow the
    /// mutation receipt rather than race the fire-and-forget task.
    package func pinAwaitingReceipt(
        _ id: HistoryItemID,
        at placement: PinnedPlacement = .first
    ) async throws -> HistoryReceipt {
        try await performAwaitingReceipt(.placePinned(id, at: placement))
    }

    /// Unpins; typed failures land in `failure`.
    public func unpin(_ id: HistoryItemID) {
        perform(.unpin(id))
    }

    /// Awaitable Unpin seam paired with `pinAwaitingReceipt` for details.
    package func unpinAwaitingReceipt(
        _ id: HistoryItemID
    ) async throws -> HistoryReceipt {
        try await performAwaitingReceipt(.unpin(id))
    }

    /// Removes one item; typed failures land in `failure`.
    public func remove(_ id: HistoryItemID) {
        perform(.remove(id))
    }

    /// Awaitable Remove seam for a user intent that must sequence its next
    /// read/transition after the real receipt (review UI-2/Card 9B).
    package func removeAwaitingReceipt(
        _ id: HistoryItemID
    ) async throws -> HistoryReceipt {
        try await performAwaitingReceipt(.remove(id))
    }

    /// Removes a whole class of items; typed failures land in `failure`.
    public func clear(_ scope: ClearScope) {
        perform(.clear(scope))
    }

    /// Awaitable Clear seam used by the panel confirmation. Receipt-driven
    /// purge publication remains inside this view state.
    package func clearAwaitingReceipt(
        _ scope: ClearScope
    ) async throws -> HistoryReceipt {
        try await performAwaitingReceipt(.clear(scope))
    }

    // MARK: - Thin async passthroughs (callers own presentation)

    /// Full detail for one item (docs/03b-instruction-set.md §9).
    public func details(for id: HistoryItemID) async throws -> HistoryDetails {
#if DEBUG
        if failNextEditorDetailsReadForTesting {
            failNextEditorDetailsReadForTesting = false
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
#endif
        try await history.details(for: id)
    }

    /// Appends an immutable content revision (docs/03a-instruction-set.md §5).
    public func revise(_ request: RevisionRequest) async throws -> HistoryReceipt {
        try await performRevision(request, beforePurge: nil)
    }

    /// The embedded editor must hand its receipt-minted exact reference to
    /// the Details owner before this state publishes the corresponding purge.
    /// That ordering prevents the old-reference surface from being retired in
    /// the same MainActor turn, while every other revise caller keeps the
    /// ordinary purge behavior above.
    package func reviseFromEditor(
        _ request: RevisionRequest,
        onCommittedReference:
            @escaping @MainActor (HistoryItemReference) -> Void
    ) async throws -> HistoryReceipt {
        try await performRevision(
            request,
            beforePurge: onCommittedReference
        )
    }

    private func performRevision(
        _ request: RevisionRequest,
        beforePurge:
            (@MainActor (HistoryItemReference) -> Void)?
    ) async throws -> HistoryReceipt {
#if DEBUG
        if injectCompetingEditorRevisionForTesting,
           let competing = Self.competingEditorRevisionForRunningUITest(
               for: request
           ) {
            injectCompetingEditorRevisionForTesting = false
            _ = try await history.perform(.revise(competing))
            failNextEditorDetailsReadForTesting = true
        }
#endif
        let action = HistoryAction.revise(request)
        let receipt = try await history.perform(action)
        if case .committed(let commit) = receipt,
           case .revised(let reference) = commit.outcome {
            beforePurge?(reference)
        }
        publishSurfacePurge(for: action, receipt: receipt)
        return receipt
    }

#if DEBUG
    /// ClipyApp's exact running-UI launch configuration arms only the next
    /// editable-text revision. No scripted `ClipboardHistory`, fake receipt,
    /// or alternate storage path is installed.
    public func configureEditorStaleJourneyForRunningUITest() {
        injectCompetingEditorRevisionForTesting = true
        failNextEditorDetailsReadForTesting = false
    }

    package static func competingEditorRevisionForRunningUITest(
        for request: RevisionRequest
    ) -> RevisionRequest? {
        guard case .replace(let draft) = request.intent,
              draft.decisions.contains(where: {
                  $0.typeIdentifier
                      == ClipboardFormatIdentifier.utf8PlainText.rawValue
              })
        else { return nil }

        let decisions = draft.decisions.map { decision in
            guard decision.typeIdentifier
                == ClipboardFormatIdentifier.utf8PlainText.rawValue else {
                return decision
            }
            return RevisionDecision(
                typeIdentifier: decision.typeIdentifier,
                action: .replace(
                    bytes: Data("clipy-editor-competing-revision".utf8)
                )
            )
        }
        return RevisionRequest(
            itemID: request.itemID,
            expected: request.expected,
            intent: .replace(RevisionDraft(decisions: decisions))
        )
    }
#endif

    /// Applies the v1 count-dimension retention cap.
    public func applyMaximumUnpinnedItems(_ count: Int) async throws -> HistoryReceipt {
        let action = HistoryAction.setRetentionPolicy(maximumUnpinnedItems: count)
        let receipt = try await history.perform(action)
        publishSurfacePurge(for: action, receipt: receipt)
        return receipt
    }

    /// Applies the V2-02 age/storage/revision policy dimensions
    /// (docs/v2/V2-02-retention.md §3.1).
    public func applyRetentionPolicies(
        _ policies: HistoryRetentionPolicies
    ) async throws -> HistoryReceipt {
        let action = HistoryAction.setRetentionPolicies(policies)
        let receipt = try await history.perform(action)
        publishSurfacePurge(for: action, receipt: receipt)
        return receipt
    }

    /// Composition-root receipt handoff for clipboard captures. Capture has
    /// no panel-owned action method, but its same-commit retention victims
    /// must retire derived surface state before observation catches up.
    public func acceptCaptureReceipt(_ receipt: HistoryReceipt) {
        publishDestructiveRetentionPurge(receipt)
    }

    /// Composition-root handoff for the current external mutation set's only
    /// content-destructive case. The app-owned ingress calls this after the
    /// real Gateway has committed a positive remove and before the App Intent
    /// returns; pin/unpin/no-op/failure never enter this seam (Card 9B).
    public func acceptCommittedExternalRemoval(
        _ itemID: HistoryItemID
    ) -> HistorySurfacePurge {
        publishExactItemPurge(itemID)
    }

    /// The authoritative configured retention state (docs/v2/V2-07-ux.md
    /// §5.2/§6.3) — the settings tabs' panel-open read, so every control
    /// opens at its persisted value instead of a neutral prefill (audit
    /// SPEC-IMPL-003). Configured policy only; no usage readout exists on
    /// the public surface (V2-07 §2.2 OPEN-2).
    public func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await history.retentionConfiguration()
    }

    // MARK: - Observation plumbing (private)

    /// Invalidates one browse intent and immediately starts its replacement
    /// observation. The invalidation itself is shared with debounced edits so
    /// one intent bumps ownership exactly once.
    private func replaceObservationImmediately() {
        beginFirstPageLoad()
        startObservation()
    }

    /// Synchronously retires all state owned by the previous browse intent.
    /// This is the single invalidation path for immediate and debounced
    /// replacement, not a general loading-state reducer.
    private func beginFirstPageLoad() {
        debounceTask?.cancel()
        debounceTask = nil
        observationTask?.cancel()
        observationTask = nil
        invalidatePagination()
        observationGeneration += 1
        // Retire the old generation's authority before publishing its empty
        // loading placeholder. Selection reconciliation must never observe
        // `rows == []` while this still describes the prior settled page.
        hasAuthoritativeFirstPage = false
        observedPosition = nil
        rows = []
        nextPageCursor = nil
        observedCursor = nil
        observedRows = []
        clearQueryFailure()
        isLoadingFirstPage = true
    }

    /// Starts observation for the already-invalidated current intent.
    private func startObservation() {
        let kind = admittedKind
        let limit = pageLimit
        let history = self.history

        observationTask = Task { [weak self] in
            let stream = await history.observe(
                HistoryObservationRequest(kind: kind, limit: limit)
            )
            do {
                for try await page in stream {
                    // A superseded loop must not apply pages over its
                    // replacement; cancellation flips before the first
                    // resume of a stale loop.
                    guard !Task.isCancelled else { return }
                    self?.applyObservedPage(page)
                }
            } catch {
                // The frozen Part III stream failure is untyped
                // (docs/03a-instruction-set.md §3): implementations still
                // throw HistoryFailure, so cast to recover the typed
                // vocabulary. Cancellation is not a panel failure.
                guard !Task.isCancelled,
                      let failure = error as? HistoryFailure
                else { return }
                self?.publishFailure(failure, from: .observation)
                self?.isLoadingFirstPage = false
            }
        }
    }

    /// Applies one observed page as a full replacement (docs/
    /// 04-coherence.md §5) and records its own cursor as both the live and
    /// the recovery resume point. The generation bump discards any in-flight
    /// one-shot append whose rows were captured before this replacement.
    private func applyObservedPage(_ page: HistoryPage) {
        invalidatePagination()
        observationGeneration += 1
        rows = page.rows
        observedRows = page.rows
        nextPageCursor = page.next
        observedCursor = page.next
        observedPosition = page.position
        hasAuthoritativeFirstPage = true
        clearQueryFailure()
        isLoadingFirstPage = false
    }

    /// Cancels and invalidates pagination synchronously. The request may
    /// still return, but only the current token may publish or finish loading.
    private func invalidatePagination() {
        paginationTask?.cancel()
        paginationTask = nil
        paginationRequestToken += 1
        isLoadingPage = false
    }

    /// Clears loading only when `token` still owns the current request.
    private func finishPagination(_ token: Int) {
        guard paginationRequestToken == token else { return }
        paginationTask = nil
        isLoadingPage = false
    }

    /// Debounces search-field edits into one observation restart.
    private func scheduleSearchRestart() {
        beginFirstPageLoad()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.searchDebounceInterval)
            } catch {
                // Cancelled: a newer edit owns the restart.
                return
            }
            self?.debounceTask = nil
            self?.startObservation()
        }
    }

    /// Forwards one mutating History Action; a typed failure is stored into
    /// `failure` rather than thrown. Receipt-confirmed destructive mutations
    /// retire affected rows synchronously; observation remains the only path
    /// which can repopulate authoritative rows.
    private func perform(_ action: HistoryAction) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.performAwaitingReceipt(action)
            } catch {
                // The awaitable helper already published a typed failure.
                // Untyped failures have no panel vocabulary (03a §3).
            }
        }
    }

    /// The shared receipt boundary for fire-and-forget list actions and
    /// explicitly sequenced details/panel actions.
    private func performAwaitingReceipt(
        _ action: HistoryAction
    ) async throws -> HistoryReceipt {
        do {
            let receipt = try await history.perform(action)
            publishSurfacePurge(for: action, receipt: receipt)
            clearFailure(from: .mutation)
            return receipt
        } catch let failure as HistoryFailure {
            publishFailure(failure, from: .mutation)
            throw failure
        }
    }

    /// Converts only a matching, effective commit into local purge work.
    /// `.unchanged`, zero-count outcomes, metadata mutations, and failures do
    /// not discard presentation state (03a §6; review Card 9B).
    private func publishSurfacePurge(
        for action: HistoryAction,
        receipt: HistoryReceipt
    ) {
        guard case .committed(let commit) = receipt else { return }

        let scope: HistorySurfacePurge.Scope?
        if commit.hasDestructiveRetentionEffects {
            scope = .all
        } else {
            switch (action, commit.outcome) {
            case (.clear(.all), .cleared(let count)) where count > 0:
                scope = .all
            case (.clear(.unpinned), .cleared(let count)) where count > 0:
                scope = .unpinned
            case (.remove(let id), .removed(let count)) where count > 0:
                scope = .item(id)
            case (.revise(let request), .revised(let newReference)):
                scope = .revision(
                    old: HistoryItemReference(
                        id: request.itemID,
                        contentVersion: request.expected
                    ),
                    new: newReference
                )
            default:
                scope = nil
            }
        }

        guard let scope else { return }
        let hasObservedCommit = observedPosition.map {
            $0 >= commit.position
        } ?? false
        if scope != .unpinned, !hasObservedCommit {
            applyReceiptConfirmedRowPurge(scope)
        }
        let generation = (surfacePurge?.generation ?? 0) + 1
        let purge = HistorySurfacePurge(
            generation: generation,
            scope: scope
        )
        surfacePurge = purge
        if case (.remove, .removed(let count)) = (action, commit.outcome),
           count > 0 {
            onCommittedUserRemoval(purge)
        }
        if scope == .unpinned {
            // Pin state in the held page may trail a just-committed Unpin.
            // Clear every executable row and restart this exact query; only
            // the post-receipt authoritative snapshot may repopulate it.
            replaceObservationImmediately()
        }
    }

    /// Capture receipts have no local action-to-outcome scope. Only the
    /// authoritative retention-effect bit can invalidate their surfaces.
    private func publishDestructiveRetentionPurge(_ receipt: HistoryReceipt) {
        guard case .committed(let commit) = receipt,
              commit.hasDestructiveRetentionEffects else { return }
        let hasObservedCommit = observedPosition.map {
            $0 >= commit.position
        } ?? false
        if !hasObservedCommit {
            applyReceiptConfirmedRowPurge(.all)
        }
        let generation = (surfacePurge?.generation ?? 0) + 1
        surfacePurge = HistorySurfacePurge(generation: generation, scope: .all)
    }

    private func publishExactItemPurge(
        _ itemID: HistoryItemID
    ) -> HistorySurfacePurge {
        let scope = HistorySurfacePurge.Scope.item(itemID)
        applyReceiptConfirmedRowPurge(scope)
        let generation = (surfacePurge?.generation ?? 0) + 1
        let purge = HistorySurfacePurge(
            generation: generation,
            scope: scope
        )
        surfacePurge = purge
        return purge
    }

    /// Retires executable list state for precise destructive scopes. Clear
    /// Unpinned instead uses the full observation restart above because held
    /// pin metadata cannot classify its members authoritatively.
    private func applyReceiptConfirmedRowPurge(
        _ scope: HistorySurfacePurge.Scope
    ) {
        invalidatePagination()
        observationGeneration += 1
        nextPageCursor = nil
        observedCursor = nil

        switch scope {
        case .all:
            rows = []
        case .unpinned:
            // Handled by the full observation restart in
            // `publishSurfacePurge`.
            break
        case .item(let id):
            rows.removeAll { $0.item.id == id }
        case .revision(let old, _):
            rows.removeAll { $0.item == old }
        }
        observedRows = rows
    }

    /// Publishes one concrete failure occurrence. Equality is deliberately
    /// irrelevant: a repeated typed value after recovery is a new episode.
    private func publishFailure(
        _ failure: HistoryFailure,
        from source: FailureSource
    ) {
        self.failure = failure
        failureSource = source
        failureEpisode += 1
    }

    /// Clears a failure only when the successful operation belongs to the
    /// same family; unrelated healthy activity must not hide it.
    private func clearFailure(from source: FailureSource) {
        guard failureSource == source else { return }
        failure = nil
        failureSource = nil
    }

    /// A fresh query intent or authoritative page retires query-owned
    /// observation/pagination failures, while leaving mutation feedback
    /// visible until the next explicit mutation succeeds.
    private func clearQueryFailure() {
        switch failureSource {
        case .observation, .pagination:
            failure = nil
            failureSource = nil
        case .mutation, nil:
            break
        }
    }
}
