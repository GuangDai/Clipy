/// ScriptedHistory.swift — the scripted `ClipboardHistory` doubles and shared
/// helpers for the PresentationUI suites (docs/01-architecture.md §4; docs/
/// roadmap/05-presentationui.md). The test target cannot import
/// HistoryStorage, so view-state and thumbnail semantics are driven through
/// the public seam exactly as SwiftUI previews do — but, per
/// docs/01-architecture.md §4, a scripted double is legitimate here because
/// these are VIEW-STATE tests (what `HistoryViewState`/`ThumbnailStore` do
/// with pages, cursors, and failures), never storage semantic tests.
///
/// The doubles are actors (implicitly `Sendable`, satisfying the
/// `ClipboardHistory: Sendable` refinement of docs/03a-instruction-set.md §3)
/// so they can both script responses and record the requests they received.
/// DTOs are built through their `package` initializers, reachable from this
/// SwiftPM test target.
import Foundation
import HistoryCore

// MARK: - ScriptedHistory (view-state double)

/// A scripted `ClipboardHistory` for `HistoryViewState` tests
/// (docs/roadmap/05-presentationui.md):
///
/// - `observe` records the request, registers the stream continuation as the
///   live one, and yields `observedFirstPage` immediately; later pages are
///   pushed by the test via `emitObservedPage(_:)` (observation is snapshot
///   replacement, docs/04-coherence.md §5 — the double never sends deltas).
/// - `browse` answers from a cursor-keyed script: a page, a typed failure such
///   as `.snapshotExpired`, or a deterministic non-cooperative suspension
///   released by the test (docs/03a-instruction-set.md §7; docs/
///   04-coherence.md §6).
/// - `perform` records every action and either throws `performFailure` or
///   returns `.unchanged`.
/// - `details`/`pastePayload` throw `.notFound`; `thumbnail` returns `nil`.
/// - `retentionConfiguration` returns the scripted configured-policy value
///   and records the request count (V2-07 §6.3's panel-open read).
actor ScriptedHistory: ClipboardHistory {

    /// One scripted browse outcome (docs/03a-instruction-set.md §7).
    enum BrowseOutcome {
        case page(HistoryPage)
        case failure(HistoryFailure)
        /// Returns only after the test calls `resumeBrowse(after:)`. The
        /// suspension deliberately ignores task cancellation, matching an
        /// adapter whose underlying operation cannot be cancelled.
        case paused(HistoryPage)
    }

    /// The page every new observation yields immediately; `nil` yields
    /// nothing (the stream stays live for `emitObservedPage`).
    private let observedFirstPage: HistoryPage?

    /// When false, only the first observation receives
    /// `observedFirstPage`; replacement observations stay live without a
    /// page until the test emits or fails them. This is the deterministic
    /// query-loading seam — no timing delay stands in for a missing page.
    private let repeatsObservedFirstPage: Bool

    /// Cursor-keyed one-shot browse script; a cursor without an entry answers
    /// an empty page.
    private let browseScript: [HistoryPageCursor: BrowseOutcome]

    /// Thrown by every `perform`; `nil` answers `.unchanged`.
    private var performFailure: HistoryFailure?

    /// The configured-policy value `retentionConfiguration` returns.
    private let scriptedRetentionConfiguration: HistoryRetentionConfiguration

    /// Recorded `observe` requests, in order.
    private(set) var observeRequests: [HistoryObservationRequest] = []

    /// Recorded `browse` requests, in order.
    private(set) var browseRequests: [HistoryBrowseRequest] = []

    /// Browse calls which returned from a pausable outcome. Tests use this
    /// acknowledgement before asserting on the consuming view-state task.
    private(set) var completedPausedBrowseCursors: [HistoryPageCursor] = []

    /// Recorded `perform` actions, in order.
    private(set) var performActions: [HistoryAction] = []

    /// How many `retentionConfiguration` reads have arrived.
    private(set) var retentionConfigurationRequestCount = 0

    /// The continuation of the most recently started observation stream.
    /// Registration happens synchronously inside `observe` (via
    /// `AsyncThrowingStream.makeStream`), so once a request is recorded its
    /// continuation is already live — a test polling `observeRequests` can
    /// emit safely. Superseded streams are simply never finished; yields to
    /// a cancelled iteration are dropped by the stream itself.
    private var liveContinuation:
        AsyncThrowingStream<HistoryPage, Error>.Continuation?

    /// Parked non-cooperative browse calls keyed by the requested cursor.
    private var pausedBrowses: [
        HistoryPageCursor: (
            continuation: CheckedContinuation<HistoryPage, Never>,
            page: HistoryPage
        )
    ] = [:]

    init(
        observedFirstPage: HistoryPage? = nil,
        repeatsObservedFirstPage: Bool = true,
        browseScript: [HistoryPageCursor: BrowseOutcome] = [:],
        performFailure: HistoryFailure? = nil,
        scriptedRetentionConfiguration: HistoryRetentionConfiguration = .newStoreDefaults
    ) {
        self.observedFirstPage = observedFirstPage
        self.repeatsObservedFirstPage = repeatsObservedFirstPage
        self.browseScript = browseScript
        self.performFailure = performFailure
        self.scriptedRetentionConfiguration = scriptedRetentionConfiguration
    }

    // MARK: Test control

    /// Pushes one observed page to the live stream — models a later
    /// authoritative snapshot (docs/04-coherence.md §5).
    func emitObservedPage(_ page: HistoryPage) {
        liveContinuation?.yield(page)
    }

    /// Fails the current observation deterministically.
    func failObservation(_ failure: HistoryFailure) {
        liveContinuation?.finish(throwing: failure)
        liveContinuation = nil
    }

    /// Finishes the live stream and clears it.
    func finishObservation() {
        liveContinuation?.finish()
        liveContinuation = nil
    }

    /// Changes the next mutation outcome without replacing the history
    /// boundary, allowing one test to drive failure → success → same failure.
    func setPerformFailure(_ failure: HistoryFailure?) {
        performFailure = failure
    }

    /// Whether the scripted browse for `cursor` has reached its deterministic
    /// suspension point.
    func isBrowsePaused(after cursor: HistoryPageCursor) -> Bool {
        pausedBrowses[cursor] != nil
    }

    /// Releases a parked browse with the page carried by its `.paused`
    /// outcome. Cancellation is intentionally not consulted.
    func resumeBrowse(after cursor: HistoryPageCursor) {
        guard let paused = pausedBrowses.removeValue(forKey: cursor) else {
            return
        }
        paused.continuation.resume(returning: paused.page)
    }

    // MARK: ClipboardHistory

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        performActions.append(action)
        if let performFailure {
            throw performFailure
        }
        return .unchanged
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        browseRequests.append(request)
        guard let cursor = request.after,
              let outcome = browseScript[cursor]
        else {
            return HistoryPage(
                position: ChangePosition(rawValue: 0),
                rows: [],
                next: nil
            )
        }
        switch outcome {
        case .page(let page):
            return page
        case .failure(let failure):
            throw failure
        case .paused(let scriptedPage):
            let page = await withCheckedContinuation { continuation in
                pausedBrowses[cursor] = (continuation, scriptedPage)
            }
            completedPausedBrowseCursors.append(cursor)
            return page
        }
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        observeRequests.append(request)
        let (stream, continuation) =
            AsyncThrowingStream<HistoryPage, Error>.makeStream()
        liveContinuation = continuation
        if let observedFirstPage,
           repeatsObservedFirstPage || observeRequests.count == 1 {
            continuation.yield(observedFirstPage)
        }
        return stream
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        throw HistoryFailure.notFound(id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        throw HistoryFailure.notFound(id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        nil
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        retentionConfigurationRequestCount += 1
        return scriptedRetentionConfiguration
    }
}

// MARK: - ThumbnailScriptHistory (thumbnail double)

/// A scripted `ClipboardHistory` for `ThumbnailStore` tests
/// (docs/01-architecture.md §5.7; docs/03b-instruction-set.md §9):
/// `thumbnail` answers a fixed encoded PNG per exact reference, `nil` for
/// unscripted references, or throws a scripted failure — and records every
/// request so prefetch idempotence and negative caching are observable.
actor ThumbnailScriptHistory: ClipboardHistory {

    /// Encoded PNG bytes per exact reference (docs/03b-instruction-set.md §9).
    private let pngByReference: [HistoryItemReference: Data]

    /// Typed failure per exact reference.
    private let failureByReference: [HistoryItemReference: HistoryFailure]

    /// Recorded thumbnail requests, in order.
    private(set) var requests: [(item: HistoryItemReference, pixels: PixelSize)] = []

    init(
        pngByReference: [HistoryItemReference: Data] = [:],
        failureByReference: [HistoryItemReference: HistoryFailure] = [:]
    ) {
        self.pngByReference = pngByReference
        self.failureByReference = failureByReference
    }

    /// How many thumbnail requests one exact reference has produced.
    func requestCount(for reference: HistoryItemReference) -> Int {
        requests.filter { $0.item == reference }.count
    }

    // MARK: ClipboardHistory

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        .unchanged
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        HistoryPage(position: ChangePosition(rawValue: 0), rows: [], next: nil)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        throw HistoryFailure.notFound(id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        throw HistoryFailure.notFound(id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        requests.append((item, pixels))
        if let failure = failureByReference[item] {
            throw failure
        }
        guard let encodedBytes = pngByReference[item] else {
            return nil
        }
        return ThumbnailPayload(
            item: item,
            pixels: pixels,
            format: .png,
            encodedBytes: encodedBytes
        )
    }

    /// Thumbnail suites never drive the configured-policy read; the double
    /// answers the new-store defaults (06 §2; `V2-02` §3.3 all-disabled).
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        .newStoreDefaults
    }
}

// MARK: - PausableDetailsHistory (preview fence double)

/// A scripted `ClipboardHistory` for `PreviewContentLoader` fence tests
/// (audit docs/reviews/2026-08-20-clipy-maccy-audit/
/// 02-spec-implementation.md §SPEC-IMPL-007;
/// 05-recommended-target-design.md §4.1 PREVIEW-FENCE-1): `details(for:)`
/// records the request, then SUSPENDS until the test resumes it with the
/// scripted `HistoryDetails` (or a typed failure) — so two in-flight detail
/// reads can be completed in REVERSE order deterministically, with no sleeps
/// on the deciding path. One in-flight read per item ID: the pane never
/// loads the same item twice concurrently, and a second read for an ID
/// already suspended would replace the first continuation (leaking it), so
/// tests keep one selection per ID.
actor PausableDetailsHistory: ClipboardHistory {

    /// Scripted detail answers by item ID.
    private var detailsByID: [HistoryItemID: HistoryDetails] = [:]

    /// Suspended detail reads by item ID.
    private var continuations: [HistoryItemID: CheckedContinuation<HistoryDetails, Error>] = [:]

    /// Recorded `details` request IDs, in order.
    private(set) var detailRequests: [HistoryItemID] = []

    /// Scripts the answer `details(for:)` completes with once resumed.
    func scriptDetails(_ details: HistoryDetails) {
        detailsByID[details.item.id] = details
    }

    /// Resumes the suspended read for `id` with the scripted answer, or with
    /// `failure` when one is given. No-op when no read is suspended — tests
    /// poll `detailRequests` before resuming, so a missing continuation
    /// surfaces as the poll's timeout failure, never as a silent pass.
    func resumeDetails(for id: HistoryItemID, throwing failure: HistoryFailure? = nil) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else if let details = detailsByID[id] {
            continuation.resume(returning: details)
        } else {
            continuation.resume(throwing: HistoryFailure.notFound(id))
        }
    }

    // MARK: ClipboardHistory

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        .unchanged
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        HistoryPage(position: ChangePosition(rawValue: 0), rows: [], next: nil)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        detailRequests.append(id)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
        }
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        throw HistoryFailure.notFound(id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        nil
    }

    /// Preview suites never drive the configured-policy read; the double
    /// answers the new-store defaults (06 §2; `V2-02` §3.3 all-disabled).
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        .newStoreDefaults
    }
}

// MARK: - PasteCallRecorder

/// Records the references handed to `HistoryViewState.onPaste`
/// (docs/01-architecture.md §5.6): the closure is synchronous and `@Sendable`,
/// so it hops into this actor via a `Task` and the test polls the result.
actor PasteCallRecorder {
    private(set) var received: [HistoryItemReference] = []

    func record(_ item: HistoryItemReference) {
        received.append(item)
    }
}

// MARK: - Shared fixtures

/// One canned row at a fixed reference (docs/03b-instruction-set.md §8).
/// Fixed UUID literals keep assertions readable; the force unwrap cannot fail
/// for a well-formed literal — a malformed one is a fixture-authoring bug
/// that must fail loudly, never silently produce a broken dataset.
func fixtureRow(
    id rawValue: String,
    title: String,
    pinned: Int? = nil
) -> HistoryRow {
    HistoryRow(
        item: HistoryItemReference(
            id: HistoryItemID(rawValue: UUID(uuidString: rawValue)!),
            contentVersion: ContentVersion(rawValue: 1)
        ),
        title: title,
        typeIdentifiers: ["public.utf8-plain-text"],
        lastCopiedAt: Date(timeIntervalSince1970: 1_787_000_000),
        copyCount: 1,
        lastSource: nil,
        pinnedPosition: pinned,
        search: nil
    )
}

/// One canned page over a named next-cursor token (docs/
/// 03b-instruction-set.md §8; cursor minting is package-only,
/// docs/03a-instruction-set.md §7).
func fixturePage(rows: [HistoryRow], next: String?) -> HistoryPage {
    HistoryPage(
        position: ChangePosition(rawValue: 1),
        rows: rows,
        next: next.map { HistoryPageCursor(payload: Data($0.utf8)) }
    )
}

/// A named pagination cursor.
func fixtureCursor(_ token: String) -> HistoryPageCursor {
    HistoryPageCursor(payload: Data(token.utf8))
}

/// A valid, fixed 1×1 RGBA PNG (70 bytes) — the encoded thumbnail bytes the
/// doubles return (docs/03b-instruction-set.md §9: History hands the UI
/// encoded, `Sendable` bytes, never `NSImage`/`CGImage`).
let fixturePNGBytes: [UInt8] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
    0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99,
    0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]

/// The canned PNG as `Data`.
var fixturePNGData: Data {
    Data(fixturePNGBytes)
}

// MARK: - Polling helper

/// Spins in short slices until `condition` holds or `timeout` elapses,
/// yielding the main actor between checks so `HistoryViewState` observation
/// tasks and `ThumbnailStore` fetch tasks can make progress. Returns whether
/// the condition was met. Tests poll only on stable (monotone) conditions —
/// a state that stays true once true — never on transient windows.
///
/// The default budget is 10 s, not because a correct run needs it (a quiet
/// machine satisfies these conditions in milliseconds) but because CI runs
/// the heavy real-scale suites in parallel with this target: under runner
/// saturation a 2 s wall-clock deadline can expire before the observation
/// task gets its first MainActor slot (CI run 32267167679). A generous
/// deadline costs nothing on the passing path — the poll returns the moment
/// the condition holds.
@MainActor
func pollUntil(
    timeout: Duration = .seconds(10),
    interval: Duration = .milliseconds(5),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

// MARK: - Configured-policy fixture

extension HistoryRetentionConfiguration {
    /// The new-store defaults: the Part VI default count (06 §2) and every
    /// V2-02 dimension disabled (`V2-02` §3.3) — the value a fresh store's
    /// `retentionConfiguration()` read returns.
    static var newStoreDefaults: HistoryRetentionConfiguration {
        HistoryRetentionConfiguration(
            maximumUnpinnedItems: HistoryLimits.standard.defaultMaximumUnpinnedItems,
            policies: HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil)
        )
    }
}
