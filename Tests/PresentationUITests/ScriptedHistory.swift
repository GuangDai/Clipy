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
/// - `browse` answers from a cursor-keyed script: a page, or a typed failure
///   such as `.snapshotExpired` (docs/03a-instruction-set.md §7; docs/
///   04-coherence.md §6).
/// - `perform` records every action and either throws `performFailure` or
///   returns `.unchanged`.
/// - `details`/`pastePayload` throw `.notFound`; `thumbnail` returns `nil`.
actor ScriptedHistory: ClipboardHistory {

    /// One scripted browse outcome (docs/03a-instruction-set.md §7).
    enum BrowseOutcome {
        case page(HistoryPage)
        case failure(HistoryFailure)
    }

    /// The page every new observation yields immediately; `nil` yields
    /// nothing (the stream stays live for `emitObservedPage`).
    private let observedFirstPage: HistoryPage?

    /// Cursor-keyed one-shot browse script; a cursor without an entry answers
    /// an empty page.
    private let browseScript: [HistoryPageCursor: BrowseOutcome]

    /// Thrown by every `perform`; `nil` answers `.unchanged`.
    private let performFailure: HistoryFailure?

    /// Recorded `observe` requests, in order.
    private(set) var observeRequests: [HistoryObservationRequest] = []

    /// Recorded `browse` requests, in order.
    private(set) var browseRequests: [HistoryBrowseRequest] = []

    /// Recorded `perform` actions, in order.
    private(set) var performActions: [HistoryAction] = []

    /// The continuation of the most recently started observation stream.
    /// Registration happens synchronously inside `observe` (via
    /// `AsyncThrowingStream.makeStream`), so once a request is recorded its
    /// continuation is already live — a test polling `observeRequests` can
    /// emit safely. Superseded streams are simply never finished; yields to
    /// a cancelled iteration are dropped by the stream itself.
    private var liveContinuation:
        AsyncThrowingStream<HistoryPage, Error>.Continuation?

    init(
        observedFirstPage: HistoryPage? = nil,
        browseScript: [HistoryPageCursor: BrowseOutcome] = [:],
        performFailure: HistoryFailure? = nil
    ) {
        self.observedFirstPage = observedFirstPage
        self.browseScript = browseScript
        self.performFailure = performFailure
    }

    // MARK: Test control

    /// Pushes one observed page to the live stream — models a later
    /// authoritative snapshot (docs/04-coherence.md §5).
    func emitObservedPage(_ page: HistoryPage) {
        liveContinuation?.yield(page)
    }

    /// Finishes the live stream and clears it.
    func finishObservation() {
        liveContinuation?.finish()
        liveContinuation = nil
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
        }
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        observeRequests.append(request)
        let (stream, continuation) =
            AsyncThrowingStream<HistoryPage, Error>.makeStream { _ in }
        liveContinuation = continuation
        if let observedFirstPage {
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
@MainActor
func pollUntil(
    timeout: Duration = .seconds(2),
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
