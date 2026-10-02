/// Settings projects one page from HistoryViewState's existing three-page
/// window (04 §6). Ordinals describe that query's order; this value retains
/// neither History content nor a second list of item identities.
struct HistoryWorkspacePaging: Equatable, Sendable {
    enum Direction: Equatable, Sendable { case previous, next }

    let pageLimit: Int
    private(set) var startOrdinal = 1
    private(set) var pendingTarget: Int?
    private var waitingForPreviousAtOrigin = false

    init(pageLimit: Int = 50) {
        precondition(pageLimit > 0)
        self.pageLimit = pageLimit
    }

    var pageNumber: Int { (startOrdinal - 1) / pageLimit + 1 }

    /// A seek can reach the true beginning through a short preceding page.
    /// Re-browsing from that beginning restores pageLimit-aligned boundaries;
    /// query refresh already does so while its first page is loading.
    static func shouldRestartAtKnownBoundary(wasKnown: Bool, isKnown: Bool,
                                            isLoadingFirstPage: Bool) -> Bool {
        !wasKnown && isKnown && !isLoadingFirstPage
    }

    func visibleRange(in loadedRange: ClosedRange<Int>?) -> ClosedRange<Int>? {
        guard let loadedRange else { return nil }
        let lower = max(startOrdinal, loadedRange.lowerBound)
        let upper = min(startOrdinal + pageLimit - 1, loadedRange.upperBound)
        return lower <= upper ? lower...upper : nil
    }

    /// These offsets index HistoryViewState.rows directly, including after the
    /// storage-backed window has retired its first or last page.
    func rowOffsets(in loadedRange: ClosedRange<Int>?) -> Range<Int> {
        guard let loadedRange, let visible = visibleRange(in: loadedRange) else { return 0..<0 }
        return (visible.lowerBound - loadedRange.lowerBound)..<(visible.upperBound - loadedRange.lowerBound + 1)
    }

    func canMove(_ direction: Direction, loadedRange: ClosedRange<Int>?,
                 hasPreviousPage: Bool, hasNextPage: Bool, hasKnownRowOffset: Bool = true) -> Bool {
        guard pendingTarget == nil, let loadedRange, visibleRange(in: loadedRange) != nil else { return false }
        if direction == .previous && startOrdinal == 1 && !hasKnownRowOffset { return hasPreviousPage }
        let target = targetOrdinal(for: direction)
        guard target >= 1 else { return false }
        if loadedRange.contains(target) { return true }
        switch direction {
        case .previous: return target < loadedRange.lowerBound && hasPreviousPage
        case .next: return target > loadedRange.upperBound && hasNextPage
        }
    }

    /// Cached navigation completes immediately. A returned direction asks the
    /// owner to call HistoryViewState.loadPreviousPage/loadNextPage once; the
    /// selected page stays visible until reconciliation admits the target.
    @discardableResult
    mutating func move(_ direction: Direction, loadedRange: ClosedRange<Int>?,
                       hasPreviousPage: Bool, hasNextPage: Bool, hasKnownRowOffset: Bool = true) -> Direction? {
        guard canMove(direction, loadedRange: loadedRange,
                      hasPreviousPage: hasPreviousPage, hasNextPage: hasNextPage,
                      hasKnownRowOffset: hasKnownRowOffset) else { return nil }
        if direction == .previous && startOrdinal == 1 && !hasKnownRowOffset {
            pendingTarget = 1
            waitingForPreviousAtOrigin = true
            return .previous
        }
        let target = targetOrdinal(for: direction)
        if loadedRange?.contains(target) == true {
            startOrdinal = target
            return nil
        }
        pendingTarget = target
        return direction
    }

    /// Call when the existing window or its loading state changes. A failed
    /// request leaves the selected page unchanged. Query/snapshot resets clear
    /// the old window and therefore select the new authoritative first page.
    mutating func reconcile(loadedRange: ClosedRange<Int>?, isLoadingPage: Bool) {
        guard let loadedRange else { reset(); return }
        // A restored reading position has local ordinals. Prepending there
        // replaces ordinal 1 with the newer page, so the unchanged range alone
        // cannot distinguish the old rows from a completed previous-page read.
        if waitingForPreviousAtOrigin {
            if !isLoadingPage {
                waitingForPreviousAtOrigin = false
                pendingTarget = nil
            }
            return
        }
        if let target = pendingTarget, loadedRange.contains(target) {
            startOrdinal = target
            pendingTarget = nil
            return
        }
        if !isLoadingPage { pendingTarget = nil }
        if visibleRange(in: loadedRange) == nil {
            startOrdinal = ((loadedRange.lowerBound - 1) / pageLimit) * pageLimit + 1
            pendingTarget = nil
        }
    }

    /// The owning surface also invokes this for explicit refresh/query intents,
    /// before HistoryViewState publishes the replacement window.
    mutating func reset() {
        startOrdinal = 1
        pendingTarget = nil
        waitingForPreviousAtOrigin = false
    }

    private func targetOrdinal(for direction: Direction) -> Int {
        switch direction {
        case .previous: startOrdinal - pageLimit
        case .next: startOrdinal + pageLimit
        }
    }
}
