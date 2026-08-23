/// AppComposition.swift — the composed application object: the sole place
/// that constructs the production `SwiftDataHistory`, the pasteboard
/// adapter and observer, and the panel view state, and the ONLY coordinator
/// of the History → pasteboard hand-off.
/// Owning spec: docs/01-architecture.md §2 (ClipyApp composition-root row),
/// §5.6 (paste orchestration), §8 (no second writer, no service locator);
/// caller example docs/03b-instruction-set.md §12; store startup
/// docs/05-authority-kernel.md §2/§13; roadmap docs/roadmap/06-clipyapp.md
/// (step 9b).
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import PresentationUI

// MARK: - Composition error (docs/roadmap/06-clipyapp.md acceptance)

/// The one failure vocabulary ClipyApp owns itself. Everything
/// storage-related stays `HistoryFailure` (03b §10); this error exists only
/// for the process-side second-open guard that keeps a second facade — and
/// with it writers outside the single `HistoryAuthority` — from ever
/// existing over one store file (01 §8; roadmap 06 acceptance).
enum ClipyCompositionError: Error, Equatable {
    /// `AppComposition.open` was asked to open a store URL this process has
    /// already opened.
    case storeAlreadyOpen(URL)
}

/// Content-free outcome for a copy request that did not complete. The app
/// owner can surface this without retaining clipboard bytes or exposing
/// AppKit values (REVIEW Card 7 / CLIP-5). AppDelegate presents it in the
/// panel while keeping every failed request from closing the panel.
enum ClipyPasteFailure: Error, Sendable, Equatable {
    /// Another request already owns the exclusive copy slot. v1 deliberately
    /// has no pending queue: repeated Return/double-click gestures must not
    /// schedule later pasteboard overwrites.
    case busy

    /// The current-by-ID History read failed before any pasteboard write.
    case history(HistoryFailure)

    /// The pasteboard refused a representation while staging, or refused the
    /// completed item after the board was cleared. The adapter does not
    /// promise a cross-process atomic transaction.
    case write(PasteboardWriteFailure)
}

/// App-owned capture failure categories. The exhaustive History mapping and
/// opaque unexpected fallback strip every identifier, version, UTI, and
/// other associated input before failure becomes long-lived UI state
/// (REVIEW Card 6).
enum ClipyCaptureFailure: Sendable, Equatable {
    case unsupportedClipboardShape
    case declaredContentUnavailable
    case invalidInput
    case stateConflict
    case capacityExceeded(CapacityKind)
    case temporarilyUnavailable(UnavailableReason)
    case persistence(PersistenceFailure)
    case unexpected

    init(historyFailure: HistoryFailure) {
        switch historyFailure {
        case .invalidInput:
            self = .invalidInput
        case .capacityExceeded(let kind):
            self = .capacityExceeded(kind)
        case .temporarilyUnavailable(let reason):
            self = .temporarilyUnavailable(reason)
        case .persistence(let failure):
            self = .persistence(failure)
        case .notFound,
             .staleContent,
             .invalidPinnedPlacement,
             .revisionNotFound,
             .snapshotExpired:
            self = .stateConflict
        }
    }
}

/// Content-free instrumentation for REVIEW Card 6's capture owner. Counts
/// describe the fixed capacity (zero-or-one active History commit plus
/// zero-or-one replaceable latest pending capture); no UTI or clipboard bytes
/// escape through this app-internal seam. Byte counts expose capacity only,
/// never payload. `lastFailure` retains the unresolved
/// sanitized rejection category that was not the expected privacy exclusion;
/// `failedCaptureCount` distinguishes later failures of the same typed value
/// without retaining the rejected capture.
struct ClipyCaptureHealth: Sendable, Equatable {
    let activeCommitCount: Int
    let activeCaptureBytes: Int
    let pendingCaptureCount: Int
    let pendingCaptureBytes: Int
    let replacedCaptureCount: Int
    let failedCaptureCount: Int
    let lastFailure: ClipyCaptureFailure?

    static let inactive = ClipyCaptureHealth(
        activeCommitCount: 0,
        activeCaptureBytes: 0,
        pendingCaptureCount: 0,
        pendingCaptureBytes: 0,
        replacedCaptureCount: 0,
        failedCaptureCount: 0,
        lastFailure: nil
    )
}

// MARK: - AppComposition (docs/01-architecture.md §2, §5.6, §8)

/// The assembled application object: the opened store, the pasteboard
/// adapter and its observer, and the panel's view state, wired together
/// once at launch.
///
/// Main-actor confined (01 §6: window behavior and framework-value writes
/// live on the main actor; History work hops off it inside the facade's
/// actors). Its `Sendable` conformance derives from that MainActor
/// isolation — the same sanctioned derivation `PasteboardAdapter` documents
/// (01 §8) — but pieces handed across isolation boundaries should still be
/// the already-`Sendable` values it exposes.
@MainActor
final class AppComposition {
    /// The sole `ClipboardHistory` of the process — the concrete production
    /// facade (Part V §2). Injected into `viewState` and used by the paste
    /// path; never duplicated (01 §8).
    let history: any ClipboardHistory

    /// The App Intents-only X.6 projection of the SAME production History
    /// graph. Production open creates this immediately after
    /// `SwiftDataHistory.open` returns; hosted compositions built from a
    /// scripted `ClipboardHistory` deliberately have no external facade.
    /// Keeping the value here prevents App Intents dependency resolution
    /// from opening a second store or constructing a second writer.
    let appIntentsHistoryFacade: ExternalHistoryFacade?

    /// The NSPasteboard ↔ HistoryCore translator (01 §5.1/§5.6).
    let adapter: PasteboardAdapter

    /// The changeCount-polled observation loop feeding captures into
    /// `history` (01 §5.1; roadmap 04).
    let observer: PasteboardObserver

    /// The panel's state holder over HistoryCore DTOs (01 §6).
    let viewState: HistoryViewState

    /// Invoked on the main actor after every SUCCESSFUL paste write —
    /// the composition root's panel-close hook (Maccy's paste-dismiss;
    /// the floating panel never activates the app, so the paste target
    /// keeps focus and the only dismissal needed is the panel's own).
    /// A refused write (`PasteboardWriteFailure`) never reaches this hook:
    /// the panel stays open so a failed system side effect is never presented
    /// as success (audit SPEC-IMPL-005; 01 §5.6).
    /// `nil` when no panel-close consumer is installed.
    var onPasteCompleted: (() -> Void)?

    /// Invoked for every copy request that does not complete. Success and
    /// failure hooks are mutually exclusive; a busy, History, staging/write,
    /// or unexpected failure always leaves the panel open. AppDelegate maps
    /// this hook to the panel's content-free failure banner.
    var onPasteFailed: ((ClipyPasteFailure) -> Void)?

    /// Main-actor push seam for Card 6 capture health. The app shell receives
    /// an immutable, content-free snapshot only when its actual capacity or
    /// failure state changes; it never polls the composition or observes the
    /// clipboard value that caused the transition.
    var onCaptureHealthChanged: (@MainActor (ClipyCaptureHealth) -> Void)? {
        didSet {
            let health = captureHealth
            lastPublishedCaptureHealth = health
            onCaptureHealthChanged?(health)
        }
    }

    /// Content-free Card 5A access-state push. Installing the sole app-shell
    /// consumer publishes the current authoritative state immediately; later
    /// callbacks occur only when the reducer's value changes.
    var onCaptureAccessStateChanged: (@MainActor (CaptureAccessState) -> Void)? {
        didSet {
            let state = captureAccessState
            lastPublishedCaptureAccessState = state
            onCaptureAccessStateChanged?(state)
        }
    }

    /// The entire v1 copy lane: one owned task means one active request and
    /// zero pending requests. The slot is installed synchronously before the
    /// task can reach its first `await`, so a second UI gesture is rejected as
    /// `.busy` instead of entering FIFO/latest-wins machinery (CLIP-5).
    private var pasteTask: Task<Void, Never>?

#if DEBUG
    /// App-internal deterministic results used by hosted composition tests
    /// (REVIEW Card 5D). They are sanitized typed outcomes, not adapter state,
    /// clipboard payloads, step closures, or a second pasteboard abstraction.
    /// Production construction cannot set either value, and both declarations
    /// are absent from Release.
    private var pasteWriteFailureForTesting: PasteboardWriteFailure?
    private var nextCaptureFailureForTesting: ClipyCaptureFailure?
    private var captureAccessBehaviorForTesting:
        (@MainActor () -> PasteboardAccessBehavior)?
#endif

    /// REVIEW Card 6 capture ownership. The active task is the sole caller of
    /// `history.perform(.capture)`; while it is suspended, one immutable
    /// latest capture may wait. A third observation replaces that pending
    /// value rather than allocating another task or retaining an unbounded
    /// byte queue.
    private var captureTask: Task<Void, Never>?
    private var activeCaptureBytes = 0
    private var pendingCapture: AdmittedCapture?
    private var replacedCaptureCount = 0
    private var failedCaptureCount = 0
    private var lastCaptureFailure: ClipyCaptureFailure?
    private var acceptsCaptures = false
    private var isStarted = false
    private var lastPublishedCaptureHealth = ClipyCaptureHealth.inactive
    private var captureAccessReducer: CaptureAccessReducer
    private var lastPublishedCaptureAccessState: CaptureAccessState
    private let captureByteLimit: Int

    /// One value admitted through the composition owner's memory boundary.
    /// The stored byte count was computed with checked arithmetic before the
    /// value could occupy either lane slot.
    private struct AdmittedCapture: Sendable {
        let capture: ClipboardCapture
        let byteCount: Int
        let failureCountAtAdmission: Int
    }

    /// App-internal, content-free trace of capture capacity and failure state.
    /// The computed shape cannot drift from the two owned slots.
    var captureHealth: ClipyCaptureHealth {
        ClipyCaptureHealth(
            activeCommitCount: captureTask == nil ? 0 : 1,
            activeCaptureBytes: activeCaptureBytes,
            pendingCaptureCount: pendingCapture == nil ? 0 : 1,
            pendingCaptureBytes: pendingCapture?.byteCount ?? 0,
            replacedCaptureCount: replacedCaptureCount,
            failedCaptureCount: failedCaptureCount,
            lastFailure: lastCaptureFailure
        )
    }

    var captureAccessState: CaptureAccessState {
        captureAccessReducer.state
    }

    /// Store URLs this process has opened. The process-side half of the
    /// no-second-writer rule (01 §8): `open(storeURL:)` consults and
    /// reserves here so a second facade over one store file is rejected
    /// with `ClipyCompositionError.storeAlreadyOpen` before any
    /// `ModelContainer` exists (roadmap 06 acceptance).
    private static var openedStoreURLs: Set<URL> = []

    /// The production store location:
    /// `~/Library/Application Support/Clipy/history.store` (roadmap 06).
    ///
    /// The user-domain Application Support search on macOS always resolves
    /// to `~/Library/Application Support`; if it ever came back empty the
    /// process must fail loudly at launch rather than invent a second
    /// location and split the store across two files (01 §8). House
    /// precedent for a cannot-fail unwrap: `HistoryLimits.standard`.
    static let defaultStoreURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("Clipy", isDirectory: true)
        .appendingPathComponent("history.store")

    /// Assembles one coherent app graph from the two true boundary values.
    /// View state and observer are always derived here, so tests cannot pair
    /// a History or pasteboard adapter with mismatched collaborators.
    private init(
        history: any ClipboardHistory,
        appIntentsHistoryFacade: ExternalHistoryFacade?,
        adapter: PasteboardAdapter,
        observerPollInterval: TimeInterval = 0.5,
        captureByteLimit: Int = HistoryLimits.standard.maximumCaptureBytes,
        initialCaptureAccessBehavior: PasteboardAccessBehavior? = nil
    ) {
        self.history = history
        self.appIntentsHistoryFacade = appIntentsHistoryFacade
        self.adapter = adapter
        observer = PasteboardObserver(
            adapter: adapter,
            pollInterval: observerPollInterval
        )
        viewState = HistoryViewState(history: history)
        let accessBehavior = initialCaptureAccessBehavior
            ?? adapter.captureAccessBehavior
        captureAccessReducer = CaptureAccessReducer(
            systemBehavior: accessBehavior
        )
        lastPublishedCaptureAccessState = captureAccessReducer.state
        self.captureByteLimit = captureByteLimit
    }

    /// Opens the persistent store (creating the store's parent directory
    /// first), wires capture observation and the paste hand-off, and
    /// rejects a second open over a URL this process already opened.
    ///
    /// Sequence (roadmap 06; Part V §13 for the storage half):
    ///
    /// 1. second-open guard: reserve `storeURL` BEFORE the first `await` —
    ///    MainActor confinement serializes the check-and-insert pair, so no
    ///    later resumption can slip a second facade past it (01 §8). A
    ///    failed open releases the reservation so a launch-time retry
    ///    remains possible;
    /// 2. create the store's parent directory
    ///    (`~/Library/Application Support/Clipy` for the default URL);
    /// 3. `SwiftDataHistory.open(configuration:)` with the persistent
    ///    medium and the Part VI default retention (200) — the facade
    ///    validates and runs the whole §13 startup itself;
    /// 4. construct adapter, view state, and observer, then `start()` the
    ///    capture loop and the paste hand-off.
    ///
    /// Directory-creation failures surface as
    /// `HistoryFailure.persistence(.openStore)`: preparing the store's
    /// location is part of opening it, and the storage boundary's own
    /// vocabulary already says exactly that (03b §10; 05 §16).
    static func open(storeURL: URL = defaultStoreURL) async throws -> AppComposition {
        guard !openedStoreURLs.contains(storeURL) else {
            throw ClipyCompositionError.storeAlreadyOpen(storeURL)
        }
        openedStoreURLs.insert(storeURL)
        do {
            try Task.checkCancellation()
            let composition = try await openReserved(storeURL: storeURL)
            try Task.checkCancellation()
            composition.start()
            return composition
        } catch {
            openedStoreURLs.remove(storeURL)
            throw error
        }
    }

    /// The awaited body of `open` under an already-reserved URL.
    private static func openReserved(storeURL: URL) async throws -> AppComposition {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }

        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL)
            )
        )
        let appIntentsHistoryFacade = history.makeAppIntentsHistoryFacade()
        let adapter = PasteboardAdapter()
        return AppComposition(
            history: history,
            appIntentsHistoryFacade: appIntentsHistoryFacade,
            adapter: adapter
        )
    }

    /// Wires the paste hand-off and starts capture observation. Called
    /// exactly once by `open(storeURL:)`; the composition is not ready for
    /// UI use until it returns.
    private func start() {
        // Paste hand-off (01 §5.6; 03b §12): `requestPaste(_:)` is
        // MainActor-isolated, matching PresentationUI's stored
        // `@MainActor @Sendable` callback. Admit directly into the one owned
        // slot at this module boundary.
        // There is no mailbox, pending queue, or nested task.
        viewState.onPaste = { [weak self] item in
            self?.requestPaste(item)
        }

        isStarted = true

        // Capture loop (01 §5.1; 03a §4; REVIEW Card 6): one COMPLETE capture
        // per distinct pasteboard changeCount is admitted to this owner's
        // fixed active+latest lane. Only the active slot owns a task; while
        // History is suspended, newer observations replace the one pending
        // value instead of growing an unbounded task/byte backlog.
        // A PARTIAL freeze — the item declared a representation whose bytes
        // were unavailable at a stable generation, or the start/end
        // `changeCount` fence observed a newer generation — is rejected HERE
        // with a content-free health episode: partial Canonical Content would
        // poison dedup/coalescing identity (audit SPEC-IMPL-005; 03a §4;
        // REVIEW Card 5B). A generation mismatch is a retry signal and does
        // not diagnose why bytes were unavailable. The
        // observer has already consumed the changeCount, so the next copy
        // re-freezes whole. Typed History rejections are EXPECTED and
        // surfaced in the content-free `captureHealth`; only concealed
        // content's `.invalidInput(.excludedFromHistory)` is ignored by
        // design (05 §6.1, whole-capture semantics; defense in depth). The
        // app's own paste writes round-trip through
        // this loop and coalesce via the lineage hint (WS4; 03b §9); they
        // must not be suppressed. The observer callback stays synchronous
        // and MainActor-owned, so slot
        // replacement is atomic with respect to later poll deliveries.
        reconcileCaptureObservation()
    }

    /// Stops app-owned side effects. Cancellation is advisory for History:
    /// capture drops its pending value and fences a non-cooperative active
    /// return from launching another commit; copy checks again after payload
    /// resolution and before touching the pasteboard. Neither lane may
    /// publish a late side effect after shutdown.
    func stop() {
        isStarted = false
        reconcileCaptureObservation()
        viewState.deactivate()
        viewState.onPaste = { _ in }
        pendingCapture = nil
        captureTask?.cancel()
        captureTask = nil
        activeCaptureBytes = 0
        publishCaptureHealthIfChanged()
        pasteTask?.cancel()
        pasteTask = nil
    }

    /// User-owned pause always wins over system changes and read failures.
    /// Resuming rechecks the current system value before deciding whether the
    /// observer may restart.
    func setCapturePaused(_ paused: Bool) {
        captureAccessReducer.setUserPaused(paused)
        if !paused {
            captureAccessReducer.updateSystemBehavior(
                currentCaptureAccessBehavior()
            )
        }
        publishCaptureAccessStateIfChanged()
        reconcileCaptureObservation()
    }

    /// Explicit recovery entry. It re-reads the system posture and never
    /// guesses prompt/TCC behavior or turns a nil payload into an access
    /// diagnosis. The signed clean-profile matrix owns those runtime facts.
    func retryCaptureAccess() {
        captureAccessReducer.retry(
            systemBehavior: currentCaptureAccessBehavior()
        )
        publishCaptureAccessStateIfChanged()
        reconcileCaptureObservation()
    }

#if DEBUG
    /// Hosted tests use the production graph builder with only the two system
    /// boundaries substituted, then drive the same started copy lane.
    static func makeForTesting(
        history: any ClipboardHistory,
        adapter: PasteboardAdapter,
        observerPollInterval: TimeInterval = 60,
        captureByteLimit: Int = HistoryLimits.standard.maximumCaptureBytes,
        pasteWriteFailure: PasteboardWriteFailure? = nil,
        initialCaptureFailure: ClipyCaptureFailure? = nil,
        initialCaptureAccessBehavior: PasteboardAccessBehavior? = nil,
        captureAccessBehaviorProvider:
            (@MainActor () -> PasteboardAccessBehavior)? = nil
    ) -> AppComposition {
        let composition = AppComposition(
            history: history,
            appIntentsHistoryFacade: nil,
            adapter: adapter,
            observerPollInterval: observerPollInterval,
            captureByteLimit: captureByteLimit,
            initialCaptureAccessBehavior: initialCaptureAccessBehavior
                ?? captureAccessBehaviorProvider?()
        )
        composition.pasteWriteFailureForTesting = pasteWriteFailure
        composition.nextCaptureFailureForTesting = initialCaptureFailure
        composition.captureAccessBehaviorForTesting =
            captureAccessBehaviorProvider
        if let captureAccessBehaviorProvider {
            composition.observer.setAccessBehaviorProviderForTesting(
                captureAccessBehaviorProvider
            )
        }
        composition.start()
        return composition
    }

    /// Deterministic Debug entry for the same admission path used by the
    /// observer. Tests supply already-frozen values so active/latest ordering
    /// needs no timer or pasteboard-content race.
    func submitCaptureForTesting(_ capture: ClipboardCapture) {
        admitCapture(capture)
    }
#endif

    /// Synchronously admits an already-frozen value. There is exactly one
    /// active operation and one replaceable pending capture; no observation
    /// creates an independent task (REVIEW Card 6).
    private func admitCapture(_ capture: ClipboardCapture) {
        guard isStarted, acceptsCaptures else { return }
        guard let admitted = admittedCapture(capture) else {
            recordCaptureFailure(.invalidInput)
            return
        }
        guard captureTask == nil else {
            if pendingCapture != nil {
                replacedCaptureCount += 1
            }
            pendingCapture = admitted
            publishCaptureHealthIfChanged()
            return
        }
        startCapture(admitted)
    }

    private func startCapture(_ admitted: AdmittedCapture) {
        precondition(captureTask == nil)
        let history = self.history
        activeCaptureBytes = admitted.byteCount
        captureTask = Task { [weak self] in
            let outcome = await Self.executeCapture(
                admitted.capture,
                history: history
            )
            guard !Task.isCancelled, let self else { return }
            self.captureDidFinish(
                outcome,
                failureCountAtAdmission: admitted.failureCountAtAdmission
            )
        }
        publishCaptureHealthIfChanged()
    }

    private enum CaptureExecutionOutcome: Sendable {
        case completed(HistoryReceipt)
        case cancelled
        case excluded
        case failed(ClipyCaptureFailure)
    }

    /// The one active History operation. Every typed failure is returned to
    /// the owner; there is deliberately no `try?` failure erasure.
    private nonisolated static func executeCapture(
        _ capture: ClipboardCapture,
        history: any ClipboardHistory
    ) async -> CaptureExecutionOutcome {
        do {
            let receipt = try await history.perform(.capture(capture))
            return .completed(receipt)
        } catch is CancellationError {
            return .cancelled
        } catch let failure as HistoryFailure {
            if failure == .invalidInput(.excludedFromHistory) {
                return .excluded
            }
            return .failed(ClipyCaptureFailure(historyFailure: failure))
        } catch {
            return .failed(.unexpected)
        }
    }

    /// Completes the active slot before starting the pending value. Since
    /// `perform` has returned, this is the lane's strict serialization point.
    private func captureDidFinish(
        _ outcome: CaptureExecutionOutcome,
        failureCountAtAdmission: Int
    ) {
        captureTask = nil
        activeCaptureBytes = 0
        switch outcome {
        case .completed(let receipt):
            viewState.acceptCaptureReceipt(receipt)
            if failureCountAtAdmission == failedCaptureCount {
                lastCaptureFailure = nil
            }
        case .cancelled:
            break
        case .excluded:
            // Privacy markers are an expected do-not-retain decision (05
            // §6.1), not degraded capture health.
            break
        case .failed(let failure):
            failedCaptureCount += 1
            lastCaptureFailure = failure
            if failure == .temporarilyUnavailable(.insufficientDiskSpace) {
                // A full volume is not made healthier by immediately
                // replaying bytes observed while the failed transaction was
                // active. Drop that value before publishing the episode; a
                // later pasteboard observation is the only v1 retry signal
                // (REVIEW Card 6B; 05 §16).
                pendingCapture = nil
            }
        }
        publishCaptureHealthIfChanged()

        guard acceptsCaptures, let next = pendingCapture else {
            pendingCapture = nil
            publishCaptureHealthIfChanged()
            return
        }
        pendingCapture = nil
        publishCaptureHealthIfChanged()
        startCapture(next)
    }

    /// Interprets the adapter's exhaustive freeze record at the app boundary.
    /// Structural and unavailable outcomes become content-free episodes, while
    /// concealed content stays the one intentional quiet decision. Only a
    /// complete freeze may enter the active/latest lane.
    private func receiveCaptureOutcome(_ outcome: CaptureOutcome) {
#if DEBUG
        if let failure = nextCaptureFailureForTesting {
            nextCaptureFailureForTesting = nil
            recordCaptureFailure(failure)
            return
        }
#endif
        switch outcome {
        case let .complete(complete):
            admitCapture(complete.capture)
        case .concealed:
            return
        case .unsupportedMultiItem:
            recordCaptureFailure(.unsupportedClipboardShape)
        case .changedDuringRead,
             .declaredUnavailable:
            recordCaptureFailure(.declaredContentUnavailable)
        }
    }

    /// Checked aggregate-byte admission for the two owner-held slots. Storage
    /// remains the authoritative full input validator; this direct check owns
    /// only the composition lane's memory bound (Part VI §2 / Card 6).
    private func admittedCapture(_ capture: ClipboardCapture) -> AdmittedCapture? {
        var byteCount = 0
        for representation in capture.representations {
            let (next, overflow) = byteCount.addingReportingOverflow(
                representation.bytes.count
            )
            guard !overflow, next <= captureByteLimit else { return nil }
            byteCount = next
        }
        return AdmittedCapture(
            capture: capture,
            byteCount: byteCount,
            failureCountAtAdmission: failedCaptureCount
        )
    }

    private func recordCaptureFailure(_ failure: ClipyCaptureFailure) {
        failedCaptureCount += 1
        lastCaptureFailure = failure
        publishCaptureHealthIfChanged()
    }

    /// Coalesces assignments that do not change the immutable snapshot while
    /// preserving every real active/pending/replacement/failure transition.
    private func publishCaptureHealthIfChanged() {
        let health = captureHealth
        guard health != lastPublishedCaptureHealth else { return }
        lastPublishedCaptureHealth = health
        onCaptureHealthChanged?(health)
    }

    /// Owns the only observer start/stop decision. `PasteboardObserver.start`
    /// is idempotent while running, so repeated allowed refreshes replace the
    /// same handler without re-freezing or installing another Timer.
    private func reconcileCaptureObservation() {
        let shouldObserve = isStarted
            && captureAccessState.permitsBackgroundPolling
        acceptsCaptures = shouldObserve
        if shouldObserve {
            observer.start(
                onAccessBehaviorChanged: { [weak self] behavior in
                    self?.receiveCaptureAccessBehavior(behavior)
                },
                handler: { [weak self] outcome in
                    self?.receiveCaptureOutcome(outcome)
                }
            )
        } else {
            observer.stop()
        }
    }

    private func publishCaptureAccessStateIfChanged() {
        let state = captureAccessState
        guard state != lastPublishedCaptureAccessState else { return }
        lastPublishedCaptureAccessState = state
        onCaptureAccessStateChanged?(state)
    }

    /// Every observer cycle reports the neutral AppKit value before touching
    /// items. A live revoke therefore updates presentation and synchronously
    /// stops the timer before the cycle can freeze clipboard content.
    private func receiveCaptureAccessBehavior(
        _ behavior: PasteboardAccessBehavior
    ) {
        captureAccessReducer.updateSystemBehavior(behavior)
        publishCaptureAccessStateIfChanged()
        if !captureAccessState.permitsBackgroundPolling {
            reconcileCaptureObservation()
        }
    }

    private func currentCaptureAccessBehavior() -> PasteboardAccessBehavior {
#if DEBUG
        if let captureAccessBehaviorForTesting {
            return captureAccessBehaviorForTesting()
        }
#endif
        return adapter.captureAccessBehavior
    }

    /// Paste orchestration — the ONLY History → pasteboard hand-off
    /// (01 §5.6; 03b §12; 04 §8): resolve the item's current Effective
    /// Content payload, write it to the general pasteboard (with the
    /// lineage hint that lets the next capture coalesce the round-trip,
    /// 03b §9), then run `onPasteCompleted` (which closes the floating
    /// panel — it never activated the app, so the user's target kept focus
    /// and remains ready for the user's manual Paste command). Everything
    /// happens outside any
    /// History transaction — a paste is a clipboard side effect, never
    /// durable History state (04 §8).
    ///
    /// `onPasteCompleted` runs only after a VERIFIED full write (01 §5.6;
    /// audit SPEC-IMPL-005): `PasteboardAdapter.write` throws
    /// `PasteboardWriteFailure` when staging rejects any representation/hint
    /// before clear, or when the system refuses the one completed item.
    /// Staging failure preserves the old pasteboard; a post-clear framework
    /// refusal has no rollback guarantee. In either case the hook is skipped
    /// and the panel stays OPEN. A payload-resolution failure (the item removed
    /// between selection and paste fails `.notFound`, 03b §10) still
    /// leaves the pasteboard untouched and the panel open; observation
    /// refreshes the rows. Auto-paste (Command-V) and plain-text paste
    /// remain out of scope (05-recommended-target-design.md product
    /// decisions).
    private func requestPaste(_ item: HistoryItemReference) {
        // Exclusive first-accepted policy (REVIEW CLIP-5/Card 7): the first
        // request reserves the slot before any suspension. There is no
        // pending request because a later pasteboard overwrite is not a
        // reversible operation and repeated UI activation should be busy.
        guard pasteTask == nil else {
            onPasteFailed?(.busy)
            return
        }

        let history = self.history
        let adapter = self.adapter
#if DEBUG
        let pasteWriteFailureForTesting = self.pasteWriteFailureForTesting
#else
        let pasteWriteFailureForTesting: PasteboardWriteFailure? = nil
#endif
        pasteTask = Task { [weak self] in
            let outcome = await Self.executePaste(
                item,
                history: history,
                adapter: adapter,
                pasteWriteFailureForTesting: pasteWriteFailureForTesting
            )
            guard !Task.isCancelled, let self else { return }

            // Release admission before publishing either hook so a user's
            // explicit retry from failure UI is immediately admissible.
            pasteTask = nil
            switch outcome {
            case .completed:
                onPasteCompleted?()
            case .failed(let failure):
                onPasteFailed?(failure)
            case .cancelled:
                break
            }
        }
    }

    private enum PasteExecutionOutcome {
        case completed
        case failed(ClipyPasteFailure)
        case cancelled
    }

    /// Runs one accepted request as one structured sequence: resolve the
    /// item's CURRENT Effective Content by ID, then perform the synchronous
    /// AppKit write. It never spawns work and never invokes UI hooks itself.
    /// `.completed` is the sole verified-success outcome.
    private static func executePaste(
        _ item: HistoryItemReference,
        history: any ClipboardHistory,
        adapter: PasteboardAdapter,
        pasteWriteFailureForTesting: PasteboardWriteFailure?
    ) async -> PasteExecutionOutcome {
        let payload: PastePayload
        do {
            payload = try await history.pastePayload(for: item.id)
        } catch is CancellationError {
            return .cancelled
        } catch let failure as HistoryFailure {
            return .failed(.history(failure))
        } catch {
            preconditionFailure(
                "ClipboardHistory.pastePayload violated its HistoryFailure contract"
            )
        }

        guard !Task.isCancelled else { return .cancelled }

        if let pasteWriteFailureForTesting {
            return .failed(.write(pasteWriteFailureForTesting))
        }

        do {
            try adapter.write(payload)
            return .completed
        } catch let failure as PasteboardWriteFailure {
            return .failed(.write(failure))
        } catch {
            preconditionFailure(
                "PasteboardAdapter.write violated its PasteboardWriteFailure contract"
            )
        }
    }
}
