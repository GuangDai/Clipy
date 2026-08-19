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
import Foundation
import HistoryCore
import SwiftUI

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

    /// The latest typed failure to surface in the panel banner; `nil` when
    /// healthy. Cleared when an observed page arrives.
    public private(set) var failure: HistoryFailure?

    /// The live search field text. Edits restart observation after a 250 ms
    /// debounce; empty/whitespace text means kind `.recent`.
    public var searchText: String = "" {
        didSet { scheduleSearchRestart() }
    }

    /// The search evaluation mode (docs/03a-instruction-set.md §7). A change
    /// restarts observation immediately.
    public var searchMode: SearchMode = .fuzzy {
        didSet { restartObservation() }
    }

    /// Composition-root paste hand-off (docs/01-architecture.md §5.6): the
    /// view state never touches the pasteboard; it hands the reference to the
    /// app, which resolves the payload and writes it. Default no-op so
    /// previews need no wiring.
    public var onPaste: @Sendable (HistoryItemReference) -> Void = { _ in }

    // MARK: - Pagination/observation bookkeeping (private)

    /// The observe loop task; cancelled and replaced on every restart.
    private var observationTask: Task<Void, Never>?

    /// The pending 250 ms search-debounce task.
    private var debounceTask: Task<Void, Never>?

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

    /// Rows-epoch counter. Bumped on every observation restart AND on every
    /// applied observed page, so a one-shot pagination result captured against
    /// superseded rows is discarded instead of appending to replaced rows.
    private var observationGeneration = 0

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

    /// Whether the search field holds a query (non-empty after whitespace
    /// trimming) — drives the "N results" caption and empty-state choice.
    public var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The current query shape: `.recent` when the trimmed text is empty,
    /// else a search in the current mode. The trimmed text is passed so a
    /// whitespace-only field never reaches storage as an empty search term.
    private var currentKind: HistoryBrowseKind {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .recent }
        return .search(text: trimmed, mode: searchMode)
    }

    // MARK: - Lifecycle

    /// Starts the observe loop for the current query. Idempotent: an existing
    /// loop is cancelled first, so re-activation after `deactivate()` (or a
    /// redundant `.task` restart) is safe.
    public func activate() {
        restartObservation()
    }

    /// Cancels the observe loop and any pending debounce; safe to call again
    /// or to follow with `activate()`.
    public func deactivate() {
        debounceTask?.cancel()
        debounceTask = nil
        observationTask?.cancel()
        observationTask = nil
    }

    /// Explicit re-observe on user action (V2-07 §4: re-browse after retry) —
    /// immediate, no debounce.
    public func refresh() {
        restartObservation()
    }

    /// Appends one one-shot browse page after the last displayed row
    /// (docs/03a-instruction-set.md §7). On `.snapshotExpired` — the cursor
    /// predates the retained window or its query shape changed — the appended
    /// rows are dropped and pagination resumes from the observed first page's
    /// cursor (docs/04-coherence.md §6).
    public func loadNextPage() {
        guard !isLoadingPage, let cursor = nextPageCursor else { return }
        isLoadingPage = true

        // Snapshot the request shape at call time: MainActor is free during
        // the await, and the cursor must travel with the kind it was minted
        // under or storage will (correctly) fail it as `.snapshotExpired`.
        let kind = currentKind
        let limit = pageLimit
        let generation = observationGeneration
        let history = self.history

        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingPage = false }
            do {
                let page = try await history.browse(
                    HistoryBrowseRequest(kind: kind, limit: limit, after: cursor)
                )
                guard !Task.isCancelled,
                      self.observationGeneration == generation
                else { return }
                self.rows.append(contentsOf: page.rows)
                self.nextPageCursor = page.next
            } catch let failure as HistoryFailure {
                guard !Task.isCancelled,
                      self.observationGeneration == generation
                else { return }
                if case .snapshotExpired = failure {
                    // docs/04-coherence.md §6 recovery: fall back to the
                    // observed first page and continue from its cursor.
                    self.rows = self.observedRows
                    self.nextPageCursor = self.observedCursor
                }
                self.failure = failure
            } catch {
                // browse throws typed HistoryFailure at the storage boundary
                // (docs/03a-instruction-set.md §3); an untyped error has no
                // panel vocabulary and is swallowed.
            }
        }
    }

    // MARK: - Interactions (docs/03a-instruction-set.md §5; 03b §12)

    /// Hands a paste request to the composition root (docs/
    /// 01-architecture.md §5.6); the view state never touches NSPasteboard.
    public func requestPaste(_ item: HistoryItemReference) {
        onPaste(item)
    }

    /// Pins or reorders; typed failures land in `failure`.
    public func pin(_ id: HistoryItemID, at placement: PinnedPlacement = .first) {
        perform(.placePinned(id, at: placement))
    }

    /// Unpins; typed failures land in `failure`.
    public func unpin(_ id: HistoryItemID) {
        perform(.unpin(id))
    }

    /// Removes one item; typed failures land in `failure`.
    public func remove(_ id: HistoryItemID) {
        perform(.remove(id))
    }

    /// Removes a whole class of items; typed failures land in `failure`.
    public func clear(_ scope: ClearScope) {
        perform(.clear(scope))
    }

    // MARK: - Thin async passthroughs (callers own presentation)

    /// Full detail for one item (docs/03b-instruction-set.md §9).
    public func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await history.details(for: id)
    }

    /// Appends an immutable content revision (docs/03a-instruction-set.md §5).
    public func revise(_ request: RevisionRequest) async throws -> HistoryReceipt {
        try await history.perform(.revise(request))
    }

    /// Applies the v1 count-dimension retention cap.
    public func applyMaximumUnpinnedItems(_ count: Int) async throws -> HistoryReceipt {
        try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: count))
    }

    /// Applies the V2-02 age/storage/revision policy dimensions
    /// (docs/v2/V2-02-retention.md §3.1).
    public func applyRetentionPolicies(
        _ policies: HistoryRetentionPolicies
    ) async throws -> HistoryReceipt {
        try await history.perform(.setRetentionPolicies(policies))
    }

    // MARK: - Observation plumbing (private)

    /// Cancels any current loop and debounce, then observes the current query.
    /// Pagination state is reset because its cursor belongs to the superseded
    /// query shape; the displayed rows are kept as the recovery baseline
    /// until the new stream's first page replaces them.
    private func restartObservation() {
        debounceTask?.cancel()
        debounceTask = nil
        observationTask?.cancel()
        observationGeneration += 1
        nextPageCursor = nil
        observedCursor = nil
        observedRows = rows

        let kind = currentKind
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
                self?.failure = failure
            }
        }
    }

    /// Applies one observed page as a full replacement (docs/
    /// 04-coherence.md §5) and records its own cursor as both the live and
    /// the recovery resume point. The generation bump discards any in-flight
    /// one-shot append whose rows were captured before this replacement.
    private func applyObservedPage(_ page: HistoryPage) {
        observationGeneration += 1
        rows = page.rows
        observedRows = page.rows
        nextPageCursor = page.next
        observedCursor = page.next
        failure = nil
    }

    /// Debounces search-field edits into one observation restart.
    private func scheduleSearchRestart() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.searchDebounceInterval)
            } catch {
                // Cancelled: a newer edit owns the restart.
                return
            }
            self?.restartObservation()
        }
    }

    /// Forwards one mutating History Action; a typed failure is stored into
    /// `failure` rather than thrown — the observation loop refreshes rows
    /// after every commit, so no manual row surgery follows a mutation.
    private func perform(_ action: HistoryAction) {
        let history = self.history
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await history.perform(action)
            } catch let failure as HistoryFailure {
                self.failure = failure
            } catch {
                // perform throws typed HistoryFailure at the storage
                // boundary (docs/03a-instruction-set.md §3).
            }
        }
    }
}
