/// HistoryViewState.swift — the panel's single observable view-state holder
/// over HistoryCore DTOs (docs/architecture.md; docs/interface.md). It never sees SwiftData, Domain state, or
/// fingerprints — only the public DTO seam.
///
/// Observation is snapshot replacement, not deltas (docs/storage.md):
/// every incoming `HistoryPage` REPLACES `rows`. The held page is ordinary
/// caller state, not a cache tier (docs/storage.md). Additional
/// pages are one-shot `browse` requests (docs/architecture.md) in a
/// three-page window. Cursor expiration restarts the current observation
/// from page one (docs/storage.md).
import ClipboardFormats
import ContentPreview
import Foundation
import HistoryCore
import SwiftUI

/// One receipt-confirmed invalidation for state owned by a single panel
/// surface (deep review Card 9B). This narrow public UI coordination value is
/// visible to the ClipyApp composition boundary, which only forwards the
/// opaque value (GOV-3 contraction; 01 §8 module boundary): the scope
/// vocabulary and the payload members below are package, so only
/// PresentationUI constructs or inspects one. It is not a second History
/// event stream: authoritative rows still arrive exclusively through
/// `observe`; the signal only drops derived presentation state which must
/// not survive a destructive/effective-content commit.
struct HistorySurfacePurge: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case all
        case unpinned
        case item(HistoryItemID)
        case revision(
            old: HistoryItemReference,
            new: HistoryItemReference
        )
    }

    let generation: Int
    let scope: Scope

    init(generation: Int, scope: Scope) {
        self.generation = generation
        self.scope = scope
    }
}

/// View state over HistoryCore DTOs — the ONLY state holder for the browsing
/// panel (docs/architecture.md; roadmap 05).
///
/// Mutation methods (`pin`, `unpin`, `remove`, `clear`) do not throw: they
/// forward the `HistoryAction` to `perform` and store any typed
/// `HistoryFailure` into `failure` (docs/architecture.md), where
/// the observation loop that committed the mutation also refreshes `rows`.
/// The detail/revise/retention methods are thin `async throws` passthroughs
/// because their callers (details pane, settings) own retry presentation.
@MainActor @Observable
final class HistoryViewState {

    // MARK: - Injected state

    /// The public History seam (docs/architecture.md). Production
    /// passes `SQLiteHistory`; SwiftUI previews pass the scripted
    /// `PreviewClipboardHistory`.
    let history: any ClipboardHistory
    let externalOpener: HistoryExternalOpener
    /// One native raster slot for this browsing session, shared by floating
    /// and Quick Look loaders. Retargeting cannot create a new decoder pool.
    let previewRenderer = ContentPreview()

    /// App-owned preferences for explicit file preview reads.
    var filePreviewSettings: FilePreviewSettings?

    /// Rows per browse/observation page. Default 50 — inside the Part VI
    /// page/observation row-limit range 1…500 (docs/testing.md).
    let pageLimit: Int

    // MARK: - Observed panel state

    /// At most three consecutive browse pages. Older/Newer navigation drops
    /// the opposite page's DTOs; observation replaces the window (04 §5/§6).
    private(set) var rows: [HistoryRow] = []

    /// One bounded previous window keeps the list visible while a replacement
    /// query runs. These DTOs never participate in selection, copy, drag or
    /// mutation: those operations continue to resolve only `rows`.
    private var retainedRows: [HistoryRow] = []
    private var retainedRowRange: ClosedRange<Int>?

    var rowsForPresentation: [HistoryRow] {
        isLoadingFirstPage ? retainedRows : displayedRows
    }

    var rowRangeForPresentation: ClosedRange<Int>? {
        isLoadingFirstPage ? retainedRowRange : loadedRowRange
    }

    /// True while a one-shot `browse` pagination request is in flight.
    /// Package (GOV-3): the pagination footer and owner tests read it;
    /// ClipyApp observes loading only through the first-page seam below.
    private(set) var isLoadingPage = false

    /// True after a browse intent has invalidated its prior rows and before
    /// the replacement observation produces its first authoritative page (or
    /// typed failure). This is intentionally separate from pagination: no
    /// prior-query row remains executable during this phase.
    private(set) var isLoadingFirstPage = false {
        didSet {
            if !isLoadingFirstPage {
                retainedRows = []
                retainedRowRange = nil
            }
        }
    }

    /// The latest typed failure to surface in the panel banner; `nil` when
    /// its owning operation has recovered.
    private(set) var failure: HistoryFailure?

    /// Latest receipt-confirmed presentation purge. The generation makes two
    /// identical mutations separately observable by SwiftUI and fences late
    /// local completions without introducing a process-wide cache bus.
    private(set) var surfacePurge: HistorySurfacePurge?

    /// Monotonic identity of a published failure. Unlike `HistoryFailure`
    /// equality, this distinguishes two occurrences of the same typed value
    /// so dismissing one banner cannot suppress a later recurrence (Card 8H).
    private(set) var failureEpisode = 0

    /// Whether the visible failure belongs to query activity that
    /// `refresh()` can actually retry. Mutation failures require repeating
    /// their original user action; presenting Refresh as mutation Retry would
    /// be a no-op with misleading copy (Card 8H).
    var canRetryFailureByRefreshing: Bool {
        switch failureSource {
        case .observation, .pagination:
            return true
        case .mutation, nil:
            return false
        }
    }

    /// The raw search-field draft. Edits coalesce within a 20 ms window
    /// before observation restarts; only the empty string means `.recent`.
    /// Exact and regexp whitespace is syntax and is never rewritten by
    /// presentation state.
    var searchText: String = "" {
        didSet {
            // Swift String equality merges canonically equivalent spellings,
            // but exact/regexp searches can distinguish their literal scalars.
            // Such an edit must retire the old results and highlight ranges.
            guard !searchText.utf8.elementsEqual(oldValue.utf8) else { return }
            validateSearchExpression()
            advanceSearchQueryGeneration()
            scheduleSearchRestart()
        }
    }

    /// The search evaluation mode (docs/architecture.md). A change
    /// restarts observation immediately.
    var searchMode: SearchMode = .exact {
        didSet {
            guard searchMode != oldValue else { return }
            validateSearchExpression()
            advanceSearchQueryGeneration()
            replaceObservationImmediately()
        }
    }

    var sortOrder: HistorySortOrder = .newestFirst {
        didSet {
            guard sortOrder != oldValue else { return }
            advanceSearchQueryGeneration()
            replaceObservationImmediately()
        }
    }

    /// Draft expression diagnostics belong beside the input, before any
    /// storage request. The original query remains editable byte-for-byte.
    private(set) var expressionValidationError: HistorySearchExpressionError?
    private(set) var unresolvedSearchSources: [String] = []
    private(set) var isSourceSearchTooBroad = false
    private(set) var sourceResolutionError: HistorySearchExpressionError?
    private var parsedSearchExpression: HistorySearchExpression?
    private var compiledSearchQuery: HistorySearchQueryCompilation?
    private var resolvedSearchExpression: HistorySearchExpression?
    private var resolvedSourceApplicationIDs: [String]?
    private let searchSourceResolver: SourceApplicationSearchResolver

    private func validateSearchExpression() {
        expressionValidationError = nil
        parsedSearchExpression = nil
        compiledSearchQuery = nil
        guard !searchText.isEmpty else { return }
        // Large literal fuzzy drafts keep their existing 64-character
        // execution view. Discovering a dollar elsewhere in that draft runs
        // in the asynchronous preparation below, outside MainActor.
        let limit = HistoryLimits.standard.maximumSearchTermUTF8Bytes
        guard searchText.utf8.prefix(limit + 1).count <= limit else { return }
        do {
            let compiled = try HistorySearchQueryCompiler.compile(searchText, mode: searchMode)
            compiledSearchQuery = compiled
            parsedSearchExpression = compiled.expression
        } catch {
            expressionValidationError = error
        }
    }

    var hasWrappedSearchConditions: Bool { parsedSearchExpression != nil }

    var fuzzyQueryExceedsLimit: Bool {
        guard searchMode == .fuzzy || searchMode == .expression,
              let text = compiledSearchQuery?.literalText else { return false }
        let limit = HistoryLimits.standard.maximumFuzzyQueryCharacters
        return text.prefix(limit + 1).count > limit
    }

    /// The status row and the native content-height calculation use the
    /// same visibility, including rejected closed conditions with no AST.
    var isSearchStatusVisible: Bool {
        hasActiveFilters || hasWrappedSearchConditions
            || HistorySearchCopy.issue(for: self) != nil
    }

    var sourceCompletionPosition: ChangePosition? {
        if let observedPosition, let latestReceiptPosition { return max(observedPosition, latestReceiptPosition) }
        return observedPosition ?? latestReceiptPosition
    }

    func sourceApplicationsForCompletion() async -> [SourceApplicationSearchResolver.Application] {
        await searchSourceResolver.prepare()
        return searchSourceResolver.applications
    }

    func searchSourceApplications() async -> [SourceApplicationSearchResolver.Application] {
        await searchSourceResolver.prepare(refresh: true)
        return searchSourceResolver.applications
    }

    /// Composition-root paste hand-off (docs/architecture.md): the
    /// view state never touches the pasteboard; it hands the reference to the
    /// app, which resolves the payload and writes it. Default no-op so
    /// previews need no wiring.
    /// Latest automatic-workflow failure, published by the app's capture-side
    /// owner so notification denial and processing errors are visible in Settings.
    var automaticWorkflowFailure: BuiltInAutomationFailure?

    var onPaste: @MainActor @Sendable (HistoryItemReference) -> Void = { _ in }

    /// Explicit Details Save As handoff. The immutable representation comes
    /// from the displayed Canonical/Effective snapshot; the app owns the
    /// destination picker and file write (V2-07 §4.1.1).
    var onExportRepresentation:
        @MainActor @Sendable (HistoryRepresentation) async -> Result<Void, RepresentationExportFailure> = {
            _ in .failure(.unavailable)
        }

    /// App-shell accessibility handoff for one user-initiated remove whose
    /// committed receipt has already published its exact surface purge.
    /// External/background mutations use their own ingress and never invoke
    /// this callback, avoiding unsolicited or duplicate announcements.
    var onCommittedUserRemoval:
        @MainActor @Sendable (HistorySurfacePurge) -> Void = { _ in }

    /// The two browsing surfaces share committed invalidations, while each
    /// keeps its own query, selection and page window. Receiving a peer purge
    /// never republishes it, so the composition connects them directly.
    var onCommittedSurfacePurge:
        @MainActor @Sendable (HistorySurfacePurge, ChangePosition?) -> Void = { _, _ in }
    var onCommittedRetention: @MainActor @Sendable (ChangePosition, Bool) -> Void = { _, _ in }

    /// Content-free accessibility handoff for one settled search intent.
    /// Only the current query generation's first authoritative observation
    /// page invokes this callback with the filtered visible count.
    /// Debounce drafts, stale completions,
    /// replacement snapshots, and pagination never do (REVIEW UI-16/Card
    /// 15D). `hasNextPage` keeps the app shell from presenting this bounded
    /// first-page count as an exact total.
    var onSettledSearchResultCount:
        @MainActor @Sendable (_ count: Int, _ hasNextPage: Bool) -> Void = {
            _, _ in
        }

    // MARK: - Pagination/observation bookkeeping (private)

    /// The observe loop task; cancelled and replaced on every restart.
    private var observationTask: Task<Void, Never>?
    private var activationHasRequestedRestore = false

    /// The pending frame-sized search-coalescing task.
    private var debounceTask: Task<Void, Never>?

    /// The one-shot page request owned by the current browsing lifecycle.
    private var paginationTask: Task<Void, Never>?

    /// Monotonic ownership token for pagination completion. Cancellation is
    /// advisory; the token prevents a non-cooperative stale request from
    /// mutating rows or a newer request's loading state.
    private var paginationRequestToken = 0

    /// Direction is encoded by History, never interpreted here. Only the
    /// three loaded pages retain navigation metadata (04 §6).
    private struct LoadedPage {
        let rowCount: Int
        let previous: HistoryPageCursor?
        let next: HistoryPageCursor?

        init(_ page: HistoryPage) {
            rowCount = page.rows.count
            previous = page.previous
            next = page.next
        }
    }
    private var loadedPages: [LoadedPage] = []
    private var rowsBeforeWindow = 0
    private var visibleRowIDs: Set<HistoryItemID> = []

    /// Seeking by item identity does not enumerate preceding rows to invent
    /// an absolute ordinal. The loaded range is local until Newer reaches
    /// the query's actual first page.
    private(set) var hasKnownRowOffset = true
    private(set) var restoredReadingItemID: HistoryItemID?

    enum ReadingPositionLoss: Equatable {
        case saved, live
    }

    private(set) var readingPositionLoss: ReadingPositionLoss?
    var didLoseReadingPosition: Bool { readingPositionLoss != nil }

    private enum FirstPageAnchor {
        case automatic
        case restoring(HistoryItemID)
        case preserving(HistoryItemID?)

        var itemID: HistoryItemID? {
            switch self {
            case .automatic: nil
            case .restoring(let id): id
            case .preserving(let id): id
            }
        }

        var restoresBookmark: Bool {
            if case .restoring = self { return true }
            return false
        }
    }

    private var firstPageAnchor = FirstPageAnchor.automatic

    var isPreservingReadingPosition: Bool {
        if case .preserving = firstPageAnchor { return true }
        return false
    }

    /// Remember a visible row, rather than a selection left behind by a
    /// mouse scroll. Only this opaque ID is handed to browsing preferences.
    var readingItemID: HistoryItemID? {
        let displayed = displayedRows
        return displayed.first(where: { visibleRowIDs.contains($0.item.id) })?.item.id
            ?? displayed.first?.item.id
    }

    private var readingAnchorBeyondFirstPage: HistoryItemID? {
        guard let first = loadedPages.first, let anchor = readingItemID else { return nil }
        if first.previous != nil || rowsBeforeWindow > 0 { return anchor }
        return rows.prefix(first.rowCount).contains { $0.item.id == anchor } ? nil : anchor
    }

    /// Workspace pagination reports its rendered page without triggering the
    /// floating panel's viewport-driven prefetch policy.
    func recordReadingPosition(visibleRowIDs ids: [HistoryItemID]) {
        visibleRowIDs = Set(ids)
    }

    /// Workspace row geometry changes one membership in O(1). These IDs
    /// have no visual consumer, so scrolling need not invalidate the workspace
    /// or rebuild its page slice. The closed/loading lifecycle owns an empty set.
    func recordReadingPosition(for itemID: HistoryItemID, isVisible: Bool) {
        guard hasAuthoritativeFirstPage, !isLoadingFirstPage else { return }
        if isVisible {
            visibleRowIDs.insert(itemID)
        } else {
            visibleRowIDs.remove(itemID)
        }
    }

    var hasPreviousPage: Bool { loadedPages.first?.previous != nil }
    var loadedPageCount: Int { loadedPages.count }
    var hasUnalignedLeadingPage: Bool {
        hasKnownRowOffset && loadedPages.count > 1 && (loadedPages.first?.rowCount ?? pageLimit) < pageLimit
    }
    /// Remains true when Newer returns to the first three pages: dropping
    /// the tail still needs visible-selection reconciliation and Latest.
    private(set) var hasWindowedPages = false
    var traversedRowCount: Int { rowsBeforeWindow + rows.count }
    var loadedRowRange: ClosedRange<Int>? {
        rows.isEmpty ? nil : (rowsBeforeWindow + 1)...traversedRowCount
    }

    /// Counts belong to the complete filtered query, including rows already
    /// traversed before this bounded window.
    var displayedCount: Int { traversedRowCount }
    var displayedCountIsLowerBound: Bool {
        !hasKnownRowOffset || hasNextPage || (observedPosition == nil && !rows.isEmpty)
    }

    /// Position of the latest authoritative first page. A receipt may return
    /// after an equal or newer observation; that page must not be erased,
    /// though the receipt still publishes its derived-state purge.
    private var observedPosition: ChangePosition?

    /// A receipt proves this history instance has committed at least this
    /// position. Buffered observations/one-shot reads may predate its delivery.
    /// Query changes and panel closure do not erase that already-known fact.
    private var latestReceiptPosition: ChangePosition?
    /// The minimum position that can safely expose executable rows after a
    /// deletion or content revision. Ordinary captures permit an older coherent
    /// first page while the observer catches up to continuing writes.
    private var latestInvalidatingReceiptPosition: ChangePosition?
    private(set) var retentionChangePosition: ChangePosition?
    private(set) var revisionPrunePosition: ChangePosition?

    /// Rows-epoch counter. Bumped on every observation restart AND on every
    /// applied observed page, so a one-shot pagination result captured against
    /// superseded rows is discarded instead of appending to replaced rows.
    private var observationGeneration = 0

    /// Monotonic identity of the raw-query/mode intent. Same-query refreshes,
    /// observation replacement pages, lifecycle restarts, and pagination do
    /// not advance it, so they cannot reannounce one already-settled search
    /// generation (review UI-4/UI-16).
    private var searchQueryGeneration = 0

    /// The one active search intent still eligible for a result-count
    /// announcement. Applying its first authoritative page consumes the
    /// value before invoking the callback, so an identical later snapshot
    /// cannot announce again.
    private var pendingSearchAnnouncementGeneration: Int?

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
    /// History: the real `SQLiteHistory` remains this state's sole facade,
    /// and both mutations still reach its sole `HistoryAuthority` writer. The
    /// first editor revision is preceded by one distinct real revision; the
    /// next details read then returns one typed transient failure before all
    /// later reads resume normally.
    private var injectCompetingEditorRevisionForTesting = false
    private var failNextEditorDetailsReadForTesting = false
#endif

    /// Merge same-turn edits without retaining a quarter-second idle delay.
    /// Cancellation and authoritative publication still
    /// belong to the existing query generation, not to this duration.
    private static let searchDebounceInterval: Duration = .milliseconds(20)

    // MARK: - Init

    init(
        history: any ClipboardHistory, pageLimit: Int = 50,
        searchSourceResolver: SourceApplicationSearchResolver = SourceApplicationSearchResolver()
    ) {
        self.history = history
        self.externalOpener = HistoryExternalOpener(history: history)
        self.pageLimit = pageLimit
        self.searchSourceResolver = searchSourceResolver
    }

    // MARK: - Derived panel state

    /// Rows in the pinned lane (`pinnedPosition != nil`; docs/interface.md — the position is 0-based, display adds one).
    var pinnedRows: [HistoryRow] {
        rows.filter { $0.pinnedPosition != nil }
    }

    /// Rows in the recency lane.
    var unpinnedRows: [HistoryRow] {
        rows.filter { $0.pinnedPosition == nil }
    }

    /// Each filter is part of the History query: changing it immediately
    /// retires the previous page/cursors and observes matching retained rows.
    var typeFilter: HistoryTypeFilter = .all {
        didSet {
            guard typeFilter != oldValue else { return }
            advanceSearchQueryGeneration(wasFiltering: oldValue != .all)
            replaceObservationImmediately()
        }
    }

    var showsPinnedOnly = false {
        didSet {
            guard showsPinnedOnly != oldValue else { return }
            advanceSearchQueryGeneration(wasFiltering: oldValue)
            replaceObservationImmediately()
        }
    }

    var searchFilters = HistorySearchFilters() {
        didSet {
            guard searchFilters != oldValue else { return }
            advanceSearchQueryGeneration(wasFiltering: oldValue.isActive)
            replaceObservationImmediately()
        }
    }

    private var searchDateBounds: (after: Date?, before: Date?) = (nil, nil)
    private(set) var hasInvalidDateFilter = false

    func refreshDateFiltersIfNeeded(now: Date = Date(), calendar: Calendar = .current) {
        guard searchFilters.dateRange != .anyTime, observationTask != nil || hasInvalidDateFilter else { return }
        let bounds = searchFilters.dateBounds(now: now, calendar: calendar)
        guard bounds != searchDateBounds else { return }
        let anchor = (isLoadingFirstPage || hasInvalidDateFilter) && firstPageAnchor.itemID != nil
            ? firstPageAnchor : .preserving(readingItemID)
        beginFirstPageLoad(dateBounds: bounds, anchor: anchor)
        startObservation()
    }

    var hasActiveFilters: Bool {
        typeFilter != .all || showsPinnedOnly || searchFilters.isActive
    }

    func clearFilters() {
        typeFilter = .all
        showsPinnedOnly = false
        if searchFilters.isActive { searchFilters = HistorySearchFilters() }
    }

    private var historyFilter: HistoryFilter {
        HistoryFilter(
            type: typeFilter.contentType, pinnedOnly: showsPinnedOnly,
            sourceApplicationIDs: resolvedSourceApplicationIDs,
            copiedAfter: searchDateBounds.after, copiedBefore: searchDateBounds.before
        )
    }

    /// The pinned lane of the current filtered query.
    var displayedPinnedRows: [HistoryRow] {
        rows.filter { $0.pinnedPosition != nil && isDisplayed($0) }
    }

    /// The recency lane of the current query; empty while
    /// `showsPinnedOnly` is set.
    var displayedUnpinnedRows: [HistoryRow] {
        guard !showsPinnedOnly else { return [] }
        return rows.filter { $0.pinnedPosition == nil && isDisplayed($0) }
    }

    /// The list's visible order after its type and pinned-only filters.
    /// AppKit's Return handler reads this same order synchronously, so an
    /// old selection cannot paste a hidden row while SwiftUI is still
    /// reconciling the filter change (01 §5.6; review Card 14A).
    var displayedRows: [HistoryRow] {
        guard sortOrder == .automatic else { return rows.filter { isDisplayed($0) } }
        // Keep the UI's stable pinned/recency lanes even while supplied rows
        // are interleaved. HistoryListView reuses this snapshot for a render.
        var displayed: [HistoryRow] = []
        displayed.reserveCapacity(rows.count)
        for row in rows where row.pinnedPosition != nil && isDisplayed(row) {
            displayed.append(row)
        }
        if !showsPinnedOnly {
            for row in rows where row.pinnedPosition == nil && isDisplayed(row) {
                displayed.append(row)
            }
        }
        return displayed
    }

    /// Keyboard actions resolve the current row without allocating the
    /// complete displayed array. Query invalidation still retires it in the
    /// same MainActor turn, before SwiftUI reconciles its old selection.
    func displayedRow(for id: HistoryItemID) -> HistoryRow? {
        rows.first { $0.item.id == id && isDisplayed($0) }
    }

    /// Details may remain open after its item moves off the current page or
    /// falls outside the query. Reuse the browse snapshot when it has the
    /// row, otherwise seek it directly without reading revisions or payloads.
    func detailRow(for id: HistoryItemID, atLeast position: ChangePosition) async throws -> HistoryRow {
        if let observedPosition, observedPosition >= position,
           let row = rows.first(where: { $0.item.id == id }) {
            return row
        }
        let page = try await history.browse(.init(kind: .recent, limit: 1, startAround: id))
        guard page.position >= position else {
            throw HistoryFailure.snapshotExpired(current: page.position)
        }
        guard let row = page.rows.first else {
            throw HistoryFailure.notFound(id)
        }
        guard row.item.id == id else { throw HistoryFailure.persistence(.invariantViolation) }
        return row
    }

    private func isDisplayed(_ row: HistoryRow) -> Bool {
        (!showsPinnedOnly || row.pinnedPosition != nil) && typeFilter.admits(row)
    }

    /// Whether a further one-shot page exists after the displayed rows.
    var hasNextPage: Bool {
        loadedPages.last?.next != nil
    }

    /// Actual viewport visibility drives continuation, not LazyVStack's
    /// speculative onAppear. A full window may advance only once the page
    /// being retired has left the viewport (04 §6; V2-09 bounded UI DTOs).
    func prefetchPagesIfNeeded(visibleRowIDs ids: [HistoryItemID]) {
        guard hasAuthoritativeFirstPage, !isLoadingFirstPage else { return }
        recordReadingPosition(visibleRowIDs: ids)
        guard !isLoadingPage, !ids.isEmpty else { return }
        let displayed = displayedRows
        let olderLead = min(5, max(1, (loadedPages.last?.rowCount ?? pageLimit) / 5))
        if let cursor = loadedPages.last?.next,
           displayed.suffix(olderLead).contains(where: { visibleRowIDs.contains($0.item.id) }),
           canRetirePageOutsideViewport(prepending: false) {
            loadPage(cursor: cursor, prepending: false, preservingViewport: true)
            return
        }
        let newerLead = min(5, max(1, (loadedPages.first?.rowCount ?? pageLimit) / 5))
        if let cursor = loadedPages.first?.previous,
           displayed.prefix(newerLead).contains(where: { visibleRowIDs.contains($0.item.id) }),
           canRetirePageOutsideViewport(prepending: true) {
            loadPage(cursor: cursor, prepending: true, preservingViewport: true)
        }
    }

    private func canRetirePageOutsideViewport(prepending: Bool) -> Bool {
        guard loadedPages.count == 3 else { return true }
        let retiringRows = prepending
            ? rows.suffix(loadedPages.last?.rowCount ?? 0)
            : rows.prefix(loadedPages.first?.rowCount ?? 0)
        return !retiringRows.contains { visibleRowIDs.contains($0.item.id) }
    }

    /// Whether the current browse generation has published its authoritative
    /// first page. Query restart clears this fact before clearing/replacing
    /// rows; a load failure leaves it false, while an authoritative empty page
    /// sets it true through its ChangePosition (review Card 8A/8C).
    private(set) var hasAuthoritativeFirstPage = false

    /// Whether the search field holds a query. Only a truly empty raw draft
    /// is `.recent`; whitespace can be meaningful exact/regexp syntax.
    var isSearchActive: Bool {
        !searchText.isEmpty
    }

    var isFuzzyTextSearch: Bool {
        if case .search(_, .fuzzy) = admittedKind { return true }
        return false
    }

    /// The query uses the full compiled text. When a fuzzy draft exceeds its
    /// matcher limit, preparation keeps the draft editable without issuing a query.
    private var admittedKind: HistoryBrowseKind {
        guard !searchText.isEmpty else { return .recent }
        let literalText = compiledSearchQuery?.literalText ?? searchText
        guard !literalText.isEmpty else { return .recent }
        switch searchMode {
        case .exact, .regexp:
            return .search(text: literalText, mode: searchMode)
        case .fuzzy, .expression:
            // Old saved mode values follow the current wrapped syntax too;
            // they never re-enable interpretation of bare source:/type: text.
            return .search(text: literalText, mode: .fuzzy)
        }
    }

    private var admittedCondition: HistorySearchExpression? { resolvedSearchExpression ?? parsedSearchExpression }

    // MARK: - Lifecycle

    /// Starts the observe loop for the current query. Idempotent: an existing
    /// loop already owns the active panel episode, so duplicate AppKit and
    /// SwiftUI lifecycle notifications do not register a second observer.
    /// Re-activation after `deactivate()` starts a fresh loop.
    func activate(restoring itemID: HistoryItemID? = nil) {
        if observationTask != nil {
            // Query properties may already have started observation before
            // this surface appears. Its first explicit restore still owns
            // activation; repeated lifecycle notifications remain idempotent.
            guard itemID != nil, !activationHasRequestedRestore else { return }
        }
        activationHasRequestedRestore = itemID != nil
        beginFirstPageLoad(anchor: itemID.map(FirstPageAnchor.restoring) ?? .automatic)
        startObservation()
    }

    /// Cancels browsing and releases this closed surface's rows/cursors.
    /// Query, mode and filters survive; activate obtains a fresh first page.
    func deactivate() {
        activationHasRequestedRestore = false
        debounceTask?.cancel()
        debounceTask = nil
        observationTask?.cancel()
        observationTask = nil
        invalidatePagination()
        observationGeneration += 1
        hasAuthoritativeFirstPage = false
        observedPosition = nil
        rows = []
        resetPageWindow()
        firstPageAnchor = .automatic
        hasInvalidDateFilter = false
        isLoadingFirstPage = false
    }

    /// Explicit re-observe on user action (V2-07 §4: re-browse after retry) —
    /// immediate, no debounce.
    func refresh() {
        replaceObservationImmediately()
    }

    /// Clears the raw query as one immediate intent. The TextField's ordinary
    /// edits remain debounced, while its explicit Clear control invalidates
    /// the old generation and starts `.recent` without a stale-results window.
    /// Package (GOV-3): the Clear control lives in this module's search
    /// header; composition-root search restarts go through `searchText`.
    func clearSearch() {
        guard !searchText.isEmpty else { return }
        searchText = ""
        debounceTask?.cancel()
        debounceTask = nil
        startObservation()
    }

    func resetSearchForOpening() {
        clearFilters()
        clearSearch()
    }

    /// Appends the next older page, retiring the newest page when the window
    /// is full. Expiration restarts the same query at page one (04 §6).
    func loadNextPage() {
        guard !isLoadingPage, let cursor = loadedPages.last?.next else { return }
        loadPage(cursor: cursor, prepending: false)
    }

    /// Read adjacent newer rows using the first loaded page's opaque cursor.
    func loadPreviousPage() {
        guard !isLoadingPage, let cursor = loadedPages.first?.previous else { return }
        loadPage(cursor: cursor, prepending: true)
    }

    func returnToLatest() {
        replaceObservationImmediately()
    }

    private func loadPage(
        cursor: HistoryPageCursor,
        prepending: Bool,
        preservingViewport: Bool = false
    ) {
        paginationRequestToken += 1
        let requestToken = paginationRequestToken
        isLoadingPage = true

        // Snapshot the request shape at call time: MainActor is free during
        // the await, and the cursor must travel with the kind it was minted
        // under or storage will (correctly) fail it as `.snapshotExpired`.
        let kind = admittedKind
        let filter = historyFilter
        let condition = admittedCondition
        let order = sortOrder
        let limit = pageLimit
        let generation = observationGeneration
        let history = self.history

        paginationTask = Task { [weak self] in
            do {
                let page = try await history.browse(
                    HistoryBrowseRequest(kind: kind, limit: limit, cursor: cursor, filter: filter, sortOrder: order,
                                         conditionExpression: condition)
                )
                guard let self,
                      self.paginationRequestToken == requestToken,
                      self.observationGeneration == generation
                else { return }
                guard self.latestReceiptPosition.map({ page.position >= $0 }) ?? true else {
                    // Keep the window and reading anchor until observation
                    // can seek it in the new snapshot.
                    self.finishPagination(requestToken)
                    return
                }
                // Never combine pages from different snapshots, even if
                // an adapter returns a page before observation catches up.
                guard page.position == self.observedPosition else {
                    self.replaceObservationImmediately()
                    return
                }
                // A user can reverse direction while the read is in flight.
                // Discard this prefetch if it would now evict a visible row;
                // its cursor stays available when the user reaches that edge.
                guard !preservingViewport || self.canRetirePageOutsideViewport(prepending: prepending) else {
                    self.finishPagination(requestToken)
                    return
                }
                if prepending {
                    self.rowsBeforeWindow = max(0, self.rowsBeforeWindow - page.rows.count)
                    if page.previous == nil {
                        self.rowsBeforeWindow = 0
                        self.hasKnownRowOffset = true
                    }
                    if self.loadedPages.count == 3 {
                        self.hasWindowedPages = true
                        // The final older page can be shorter than limit.
                        self.rows.removeLast(self.loadedPages.removeLast().rowCount)
                    }
                    self.loadedPages.insert(LoadedPage(page), at: 0)
                    self.rows.insert(contentsOf: page.rows, at: 0)
                } else {
                    if self.loadedPages.count == 3 {
                        self.hasWindowedPages = true
                        let removedCount = self.loadedPages.removeFirst().rowCount
                        self.rows.removeFirst(removedCount)
                        self.rowsBeforeWindow += removedCount
                    }
                    self.loadedPages.append(LoadedPage(page))
                    self.rows.append(contentsOf: page.rows)
                }
                self.clearFailure(from: .pagination)
                self.finishPagination(requestToken)
            } catch let failure as HistoryFailure {
                guard let self,
                      self.paginationRequestToken == requestToken,
                      self.observationGeneration == generation
                else { return }
                if case .snapshotExpired = failure {
                    let anchor = self.readingAnchorBeyondFirstPage
                    self.beginFirstPageLoad(anchor: .preserving(anchor))
                    self.startObservation()
                    return
                }
                self.publishFailure(failure, from: .pagination)
                self.finishPagination(requestToken)
            } catch {
                // browse throws typed HistoryFailure at the storage boundary
                // (docs/architecture.md); an untyped error has no
                // panel vocabulary and is swallowed.
                self?.finishPagination(requestToken)
            }
        }
    }

    // MARK: - Interactions (docs/architecture.md; 03b §12)

    /// Hands a paste request to the composition root (docs/testing.md); the view state never touches NSPasteboard.
    func requestPaste(_ item: HistoryItemReference) {
        onPaste(item)
    }

    /// List-owned paste requests are accepted only while the exact row is
    /// still in the filtered authoritative display. This closes the render
    /// gap after a filter hides a row or a query intent clears `rows`, while
    /// the old row closure or selection may still be reachable.
    func requestPasteFromDisplayedRow(_ item: HistoryItemReference) {
        guard rows.contains(where: { $0.item == item && isDisplayed($0) }) else { return }
        onPaste(item)
    }

    // MARK: - Drag-out (01 §5.6; 03b §9)

    /// One drag gesture freezes current Effective Content before AppKit starts
    /// its native multi-item session (03b §9; V2-09 §11). Only an exact displayed
    /// row can begin this read. The returned immutable payload owns every item
    /// and format for the session, independent of later revisions or panel close.
    func dragPayload(for reference: HistoryItemReference) async throws -> PastePayload? {
        try Task.checkCancellation()
        guard rows.contains(where: { $0.item == reference && isDisplayed($0) }) else { return nil }
        let payload = try await history.pastePayload(for: reference.id)
        try Task.checkCancellation()
        // The ID read can return a revision committed after mouse-down. A
        // closed, filtered or revised row no longer owns this pending drag;
        // only a successfully returned payload may outlive its source row.
        guard payload.item == reference,
              rows.contains(where: { $0.item == reference && isDisplayed($0) })
        else { return nil }
        return payload
    }

    /// Pins or reorders; typed failures land in `failure`.
    func pin(_ id: HistoryItemID, at placement: PinnedPlacement = .first) {
        perform(.placePinned(id, at: placement))
    }

    /// Awaitable Pin seam for a details action whose readback must follow the
    /// mutation receipt rather than race the fire-and-forget task.
    func pinAwaitingReceipt(
        _ id: HistoryItemID,
        at placement: PinnedPlacement = .first
    ) async throws -> HistoryReceipt {
        try await performAwaitingReceipt(.placePinned(id, at: placement))
    }

    /// Unpins; typed failures land in `failure`.
    func unpin(_ id: HistoryItemID) {
        perform(.unpin(id))
    }

    /// Awaitable Unpin seam paired with `pinAwaitingReceipt` for details.
    func unpinAwaitingReceipt(
        _ id: HistoryItemID
    ) async throws -> HistoryReceipt {
        try await performAwaitingReceipt(.unpin(id))
    }

    /// Removes one item; typed failures land in `failure`.
    func remove(_ id: HistoryItemID) {
        perform(.remove(id))
    }

    /// Awaitable Remove seam for a user intent that must sequence its next
    /// read/transition after the real receipt (review UI-2/Card 9B).
    func removeAwaitingReceipt(
        _ id: HistoryItemID
    ) async throws -> HistoryReceipt {
        try await performAwaitingReceipt(.remove(id))
    }

    /// Removes a whole class of items; typed failures land in `failure`.
    func clear(_ scope: ClearScope) {
        perform(.clear(scope))
    }

    /// Awaitable Clear seam used by the panel confirmation. Receipt-driven
    /// purge publication remains inside this view state.
    func clearAwaitingReceipt(
        _ scope: ClearScope
    ) async throws -> HistoryReceipt {
        try await performAwaitingReceipt(.clear(scope))
    }

    // MARK: - Thin async passthroughs (callers own presentation)

    /// Full detail for one item (docs/architecture.md).
    func details(for id: HistoryItemID) async throws -> HistoryDetails {
#if DEBUG
        if failNextEditorDetailsReadForTesting {
            failNextEditorDetailsReadForTesting = false
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
#endif
        return try await history.details(for: id)
    }

    /// Appends an immutable content revision (docs/architecture.md).
    func revise(_ request: RevisionRequest) async throws -> HistoryReceipt {
        try await performRevision(request, beforePurge: nil)
    }

    /// A details-owned edit or revert must hand its receipt-minted exact
    /// reference to the Details owner before publishing the corresponding purge.
    /// That ordering prevents the old-reference surface from being retired in
    /// the same MainActor turn, while every other revise caller keeps the
    /// ordinary purge behavior above.
    func reviseKeepingDetails(
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
    func configureEditorStaleJourneyForRunningUITest() {
        injectCompetingEditorRevisionForTesting = true
        failNextEditorDetailsReadForTesting = false
    }

    static func competingEditorRevisionForRunningUITest(
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
                ),
                pasteboardItemIndex: decision.pasteboardItemIndex
            )
        }
        return RevisionRequest(
            itemID: request.itemID,
            expected: request.expected,
            intent: .replace(RevisionDraft(decisions: decisions))
        )
    }
#endif

    /// Applies the optional count limit; nil turns off count-based removal.
    func applyMaximumUnpinnedItems(_ count: Int?) async throws -> HistoryReceipt {
        let action = HistoryAction.setRetentionPolicy(maximumUnpinnedItems: count)
        let receipt = try await history.perform(action)
        publishSurfacePurge(for: action, receipt: receipt)
        return receipt
    }

    /// Applies the V2-02 age/storage/revision policy dimensions
    /// (docs/storage.md).
    func applyRetentionPolicies(
        _ policies: HistoryRetentionPolicies
    ) async throws -> HistoryReceipt {
        let action = HistoryAction.setRetentionPolicies(policies)
        let receipt = try await history.perform(action)
        publishSurfacePurge(for: action, receipt: receipt)
        return receipt
    }

    /// A capture can retire other records. Its receipt supplies the ordering
    /// fence, while the observation and exact reads establish the victims.
    func acceptCaptureReceipt(_ receipt: HistoryReceipt) {
        guard case .committed(let commit) = receipt else { return }
        recordCommittedPosition(commit.position)
        publishRetentionChange(for: commit)
    }

    func acceptPeerRetention(at position: ChangePosition, prunedRevisions: Bool) {
        if prunedRevisions, revisionPrunePosition.map({ position > $0 }) ?? true {
            revisionPrunePosition = position
        }
        guard retentionChangePosition.map({ position > $0 }) ?? true else { return }
        recordCommittedPosition(position)
        // Retention does not identify any specific row. Continue publishing
        // coherent pages while exact preview and copy reads verify their targets.
        retentionChangePosition = position
    }

    /// Composition-root removal handoff. The app-owned ingress calls this
    /// after the real Gateway has committed a positive remove and before
    /// replying; pin/unpin/no-op/failure never enter this seam (Card 9B).
    func acceptCommittedExternalRemoval(
        _ itemID: HistoryItemID, position: ChangePosition
    ) -> HistorySurfacePurge {
        let purge = publishCommittedSurfacePurge(.item(itemID), position: position)
        onCommittedSurfacePurge(purge, position)
        return purge
    }

    /// The automation ingress forwards the real revision commit and its
    /// request's old reference before replying. Use the same commit-position
    /// rule as a local edit: a late callback never removes already-new rows.
    func acceptCommittedExternalRevision(
        from old: HistoryItemReference,
        commit: HistoryCommit
    ) -> HistorySurfacePurge? {
        guard case .revised(let new) = commit.outcome else { return nil }
        publishRetentionChange(for: commit)
        let purge = publishCommittedSurfacePurge(.revision(old: old, new: new), position: commit.position)
        onCommittedSurfacePurge(purge, commit.position)
        return purge
    }

    /// Applies a receipt-confirmed change from the other local surface.
    /// A newer authoritative snapshot still wins over a late receipt.
    @discardableResult
    func acceptPeerSurfacePurge(
        _ purge: HistorySurfacePurge, position: ChangePosition?
    ) -> HistorySurfacePurge {
        let received: HistorySurfacePurge
        if let position {
            received = publishCommittedSurfacePurge(purge.scope, position: position)
        } else {
            applyReceiptConfirmedRowPurge(purge.scope)
            received = HistorySurfacePurge(
                generation: (surfacePurge?.generation ?? 0) + 1, scope: purge.scope
            )
            surfacePurge = received
        }
        if purge.scope == .unpinned, observationTask != nil {
            replaceObservationImmediately()
        }
        return received
    }

    /// The authoritative configured retention state (docs/interface.md
    /// §5.2/§6.3) — the settings tabs' panel-open read, so every control
    /// opens at its persisted value instead of a neutral prefill (audit
    /// SPEC-IMPL-003). Configured policy only; no usage readout exists on
    /// the public surface (V2-07 §2.2 OPEN-2).
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
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
    private func beginFirstPageLoad(
        dateBounds: (after: Date?, before: Date?)? = nil, anchor: FirstPageAnchor = .automatic
    ) {
        debounceTask?.cancel()
        debounceTask = nil
        observationTask?.cancel()
        observationTask = nil
        invalidatePagination()
        observationGeneration += 1
        if hasAuthoritativeFirstPage {
            retainedRows = rows
            retainedRowRange = loadedRowRange
        }
        // Retire the old generation's authority before publishing its empty
        // loading placeholder. Selection reconciliation must never observe
        // `rows == []` while this still describes the prior settled page.
        hasAuthoritativeFirstPage = false
        observedPosition = nil
        rows = []
        resetPageWindow()
        clearQueryFailure()
        resolvedSearchExpression = nil
        resolvedSourceApplicationIDs = nil
        unresolvedSearchSources = []
        isSourceSearchTooBroad = false
        restoredReadingItemID = nil
        readingPositionLoss = nil
        firstPageAnchor = anchor
        sourceResolutionError = nil
        // Relative days refresh with each query, and stay fixed while paging.
        searchDateBounds = dateBounds ?? searchFilters.dateBounds(now: Date(), calendar: .current)
        hasInvalidDateFilter = searchFilters.dateRange == .custom
            && (searchDateBounds.after == nil || searchDateBounds.before == nil)
        isLoadingFirstPage = expressionValidationError == nil && !fuzzyQueryExceedsLimit && !hasInvalidDateFilter
    }

    /// Starts observation for the already-invalidated current intent.
    private func startObservation() {
        guard expressionValidationError == nil, !fuzzyQueryExceedsLimit, !hasInvalidDateFilter else {
            isLoadingFirstPage = false
            return
        }
        let limit = pageLimit
        let history = self.history
        let queryGeneration = searchQueryGeneration
        let order = sortOrder
        let initialAnchor = firstPageAnchor

        observationTask = Task { [weak self] in
            guard !Task.isCancelled,
                  await self?.prepareSearchConditions() == true, !Task.isCancelled,
                  let kind = self?.admittedKind, let filter = self?.historyFilter else { return }
            let request = HistoryObservationRequest(
                kind: kind, limit: limit, filter: filter, sortOrder: order,
                conditionExpression: self?.admittedCondition
            )
            let stream = await history.observe(request)
            do {
                var initialTarget = initialAnchor.itemID
                var restoredPosition: ChangePosition?
                for try await page in stream {
                    // A superseded loop must not apply pages over its
                    // replacement; cancellation flips before the first
                    // resume of a stale loop.
                    guard !Task.isCancelled else { return }
                    // The seek may read a newer snapshot than the first
                    // buffered observation. Never let that older first page
                    // replace the just-restored reading position.
                    if let restoredPosition, page.position <= restoredPosition { continue }
                    guard self?.allowsObservedPosition(page.position) == true else { continue }
                    if var target = initialTarget ?? self?.readingAnchorBeyondFirstPage {
                        let isInitialSeek = initialTarget != nil
                        let isRestoringBookmark = isInitialSeek && initialAnchor.restoresBookmark
                        for attempt in 0..<2 {
                            let restoredPage: HistoryPage
                            if isInitialSeek, !isRestoringBookmark, page.rows.contains(where: { $0.item.id == target }) {
                                restoredPage = page
                            } else {
                                restoredPage = try await Self.browseReadingAnchor(
                                    target, request: request, history: history,
                                    firstPage: page, isRestoringBookmark: isRestoringBookmark
                                )
                            }
                            guard !Task.isCancelled, let self else { return }
                            let currentAnchor = isInitialSeek ? target : self.readingAnchorBeyondFirstPage
                            if let currentAnchor, currentAnchor != target, attempt == 0 {
                                target = currentAnchor
                                continue
                            }
                            // If the user moves again, keep the last anchor when the
                            // completed seek contains it. Otherwise admit the
                            // observed first page without waiting for another write.
                            let restoredAnchor = currentAnchor.flatMap { id in
                                restoredPage.rows.first { $0.item.id == id }?.item.id
                            }
                            let useRestoredPage = restoredPage.position >= page.position
                                && self.allowsObservedPosition(restoredPage.position)
                                && (restoredAnchor != nil || isRestoringBookmark)
                            let replacement = useRestoredPage ? restoredPage : page
                            guard self.allowsObservedPosition(replacement.position) else { break }
                            let retainedAnchor = currentAnchor.flatMap { id in
                                replacement.rows.first { $0.item.id == id }?.item.id
                            }
                            self.applyObservedPage(replacement, forSearchGeneration: queryGeneration)
                            if let retainedAnchor {
                                self.visibleRowIDs = [retainedAnchor]
                            }
                            if isRestoringBookmark {
                                self.readingPositionLoss = retainedAnchor == nil ? .saved : nil
                                self.restoredReadingItemID = retainedAnchor
                            } else if !isInitialSeek {
                                self.readingPositionLoss = currentAnchor != nil && retainedAnchor == nil ? .live : nil
                            }
                            initialTarget = nil
                            restoredPosition = replacement.position
                            break
                        }
                        continue
                    }
                    self?.applyObservedPage(
                        page,
                        forSearchGeneration: queryGeneration
                    )
                }
            } catch {
                // The frozen Part III stream failure is untyped
                // (docs/architecture.md): implementations still
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

    private static func browseReadingAnchor(
        _ target: HistoryItemID, request: HistoryObservationRequest, history: any ClipboardHistory,
        firstPage: HistoryPage, isRestoringBookmark: Bool
    ) async throws -> HistoryPage {
        do {
            return try await history.browse(HistoryBrowseRequest(
                kind: request.kind, limit: request.limit, filter: request.filter, sortOrder: request.sortOrder,
                startAround: target, conditionExpression: request.conditionExpression
            ))
        } catch HistoryFailure.notFound(_) where isRestoringBookmark {
            return try await history.browse(HistoryBrowseRequest(
                kind: request.kind, limit: request.limit, filter: request.filter, sortOrder: request.sortOrder,
                conditionExpression: request.conditionExpression
            ))
        } catch where !isRestoringBookmark {
            // Background continuity may fall back to the already-read page
            // without terminating observation if the seek fails.
            return firstPage
        }
    }

    /// Resolve real application names once for a query generation. Subsequent
    /// cursor requests reuse its exact IDs and expression, including while
    /// application metadata changes or new History pages arrive.
    private func prepareSearchConditions() async -> Bool {
        if compiledSearchQuery == nil, !searchText.isEmpty {
            let text = searchText
            let mode = searchMode
            let compiling = Task.detached {
                try Task.checkCancellation()
                let result = try HistorySearchQueryCompiler.compile(text, mode: mode)
                try Task.checkCancellation()
                return result
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await compiling.value
                } onCancel: { compiling.cancel() }
                guard !Task.isCancelled else { return false }
                compiledSearchQuery = result
                parsedSearchExpression = result.expression
            } catch let error as HistorySearchExpressionError {
                guard !Task.isCancelled else { return false }
                expressionValidationError = error
                isLoadingFirstPage = false
                return false
            } catch {
                return false
            }
        }
        guard !fuzzyQueryExceedsLimit else {
            isLoadingFirstPage = false
            return false
        }
        let expression = parsedSearchExpression
        let filters = searchFilters
        if !(expression?.applicationTerms.isEmpty ?? true)
            || (filters.source != nil && filters.sourceMatch == .applicationName) {
            await searchSourceResolver.prepare()
            guard !Task.isCancelled else { return false }
        }
        var unresolved: [String] = []
        if let source = filters.source {
            if filters.sourceMatch == .bundleIdentifier {
                resolvedSourceApplicationIDs = [source]
            } else {
                let ids = searchSourceResolver.identifiers(matching: source)
                resolvedSourceApplicationIDs = ids
                if ids.isEmpty { unresolved.append(source) }
            }
        }
        if let expression, !expression.applicationTerms.isEmpty {
            do {
                let resolution = try searchSourceResolver.resolve(expression)
                resolvedSearchExpression = resolution.expression
                unresolved.append(contentsOf: resolution.unresolvedNames)
            } catch {
                sourceResolutionError = error
            }
        }
        if let ids = resolvedSourceApplicationIDs,
           ids.count > 64 || ids.reduce(0, { $0 + $1.utf8.count }) > 4_096
            || ids.contains(where: { $0.utf8.count > 1_024 }) {
            isSourceSearchTooBroad = true
        }
        unresolvedSearchSources = Array(Set(unresolved)).sorted()
        let hasUnresolvedSourceFilter = resolvedSourceApplicationIDs?.isEmpty == true
        guard !hasUnresolvedSourceFilter, !isSourceSearchTooBroad, sourceResolutionError == nil else {
            isLoadingFirstPage = false
            return false
        }
        return true
    }

    /// Applies one observed page as a full replacement (docs/testing.md) and resets the bounded navigation window.
    /// The generation bump discards any in-flight
    /// one-shot append whose rows were captured before this replacement.
    private func applyObservedPage(
        _ page: HistoryPage,
        forSearchGeneration queryGeneration: Int
    ) {
        guard allowsObservedPosition(page.position) else { return }
        invalidatePagination()
        observationGeneration += 1
        rows = page.rows
        loadedPages = [LoadedPage(page)]
        hasWindowedPages = page.previous != nil
        rowsBeforeWindow = 0
        hasKnownRowOffset = page.previous == nil
        observedPosition = page.position
        hasAuthoritativeFirstPage = true
        clearQueryFailure()
        firstPageAnchor = .automatic
        isLoadingFirstPage = false
        if pendingSearchAnnouncementGeneration == queryGeneration {
            pendingSearchAnnouncementGeneration = nil
            onSettledSearchResultCount(displayedRows.count, page.previous != nil || page.next != nil)
        }
    }

    /// Advances only the user's admitted query/mode generation. Generic
    /// observation restarts intentionally do not re-arm an announcement for
    /// an identical settled search (REVIEW Card 15D).
    private func advanceSearchQueryGeneration(wasFiltering: Bool = false) {
        searchQueryGeneration += 1
        pendingSearchAnnouncementGeneration = isSearchActive || hasActiveFilters || wasFiltering
            ? searchQueryGeneration
            : nil
    }

    private func resetPageWindow() {
        loadedPages = []
        hasWindowedPages = false
        rowsBeforeWindow = 0
        visibleRowIDs = []
        hasKnownRowOffset = true
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
            // Sleep may have completed before its MainActor continuation
            // resumes. A newer input can still cancel it in that interval.
            guard !Task.isCancelled else { return }
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
        recordCommittedPosition(commit.position)
        publishRetentionChange(for: commit)

        let scope: HistorySurfacePurge.Scope?
        switch (action, commit.outcome) {
        case (.clear(.all), .cleared(let count)) where count > 0:
            scope = .all
        case (.clear(.unpinned), .cleared(let count)) where count > 0:
            scope = .unpinned
        case (.remove(let id), .removed(let count)) where count > 0:
            scope = .item(id)
        case (.revise(let request), .revised(let newReference)):
            scope = .revision(old: HistoryItemReference(id: request.itemID, contentVersion: request.expected),
                              new: newReference)
        default:
            scope = nil
        }

        guard let scope else { return }
        let purge = publishCommittedSurfacePurge(scope, position: commit.position)
        onCommittedSurfacePurge(purge, commit.position)
        if case (.remove, .removed(let count)) = (action, commit.outcome),
           count > 0 {
            onCommittedUserRemoval(purge)
        }
        if scope == .unpinned, observationTask != nil {
            // Pin state in the held page may trail a just-committed Unpin.
            // Clear every executable row and restart this exact query; only
            // the post-receipt authoritative snapshot may repopulate it.
            // A late receipt or a Settings-only mutation must not reopen a
            // closed browsing surface. An active search debounce already owns
            // its replacement when no observation task currently exists.
            replaceObservationImmediately()
        }
    }

    private func publishCommittedSurfacePurge(
        _ scope: HistorySurfacePurge.Scope,
        position: ChangePosition
    ) -> HistorySurfacePurge {
        recordCommittedPosition(position)
        recordInvalidatingPosition(position)
        let hasObservedCommit = observedPosition.map {
            $0 >= position
        } ?? false
        if scope != .unpinned, !hasObservedCommit {
            applyReceiptConfirmedRowPurge(scope)
        }
        let generation = (surfacePurge?.generation ?? 0) + 1
        let purge = HistorySurfacePurge(
            generation: generation,
            scope: scope
        )
        purgeRetainedRows(scope)
        surfacePurge = purge
        return purge
    }

    private func publishRetentionChange(for commit: HistoryCommit) {
        guard commit.hasDestructiveRetentionEffects else { return }
        let prunedRevisions: Bool
        if case .retentionPoliciesSet(_, let pruned) = commit.outcome {
            prunedRevisions = pruned > 0
        } else {
            prunedRevisions = false
        }
        acceptPeerRetention(at: commit.position, prunedRevisions: prunedRevisions)
        onCommittedRetention(commit.position, prunedRevisions)
    }

    private func recordCommittedPosition(_ position: ChangePosition) {
        guard latestReceiptPosition.map({ position > $0 }) ?? true else { return }
        latestReceiptPosition = position
    }

    private func recordInvalidatingPosition(_ position: ChangePosition) {
        guard latestInvalidatingReceiptPosition.map({ position > $0 }) ?? true else { return }
        latestInvalidatingReceiptPosition = position
    }

    private func allowsObservedPosition(_ position: ChangePosition) -> Bool {
        (observedPosition.map { position > $0 } ?? true)
            && (latestInvalidatingReceiptPosition.map { position >= $0 } ?? true)
    }

    /// Retires executable list state for precise destructive scopes. Clear
    /// Unpinned instead uses the full observation restart above because held
    /// pin metadata cannot classify its members authoritatively.
    private func applyReceiptConfirmedRowPurge(
        _ scope: HistorySurfacePurge.Scope
    ) {
        purgeRetainedRows(scope)
        switch scope {
        case .item(let id) where !rows.contains(where: { $0.item.id == id }): return
        case .revision(let old, _) where !rows.contains(where: { $0.item == old }): return
        default: break
        }
        invalidatePagination()
        observationGeneration += 1
        resetPageWindow()
        // Until observation supplies a replacement, the surviving rows are
        // only a partial display and cannot establish an exact total count.
        observedPosition = nil

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
    }

    private func purgeRetainedRows(_ scope: HistorySurfacePurge.Scope) {
        // A destructive change invalidates the retained display too. Its old
        // pin facts cannot classify Clear Unpinned after a concurrent Unpin.
        switch scope {
        case .all, .unpinned:
            retainedRows = []
        case .item(let id):
            retainedRows.removeAll { $0.item.id == id }
        case .revision(let old, _):
            retainedRows.removeAll { $0.item == old }
        }
        retainedRowRange = retainedRows.isEmpty ? nil : retainedRowRange.map {
            $0.lowerBound...($0.lowerBound + retainedRows.count - 1)
        }
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
