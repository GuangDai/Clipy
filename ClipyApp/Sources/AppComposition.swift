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

    /// The entire v1 copy lane: one owned task means one active request and
    /// zero pending requests. The slot is installed synchronously before the
    /// task can reach its first `await`, so a second UI gesture is rejected as
    /// `.busy` instead of entering FIFO/latest-wins machinery (CLIP-5).
    private var pasteTask: Task<Void, Never>?

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
        adapter: PasteboardAdapter,
        observerPollInterval: TimeInterval = 0.5
    ) {
        self.history = history
        self.adapter = adapter
        observer = PasteboardObserver(
            adapter: adapter,
            pollInterval: observerPollInterval
        )
        viewState = HistoryViewState(history: history)
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
            let composition = try await openReserved(storeURL: storeURL)
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
        let adapter = PasteboardAdapter()
        return AppComposition(
            history: history,
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

        // Capture loop (01 §5.1; 03a §4): one COMPLETE capture per distinct
        // pasteboard changeCount becomes one `.capture` action; each runs
        // in its own task so a large capture never stalls the poll handler.
        // A PARTIAL freeze — the item declared a representation whose bytes
        // were unavailable at freeze time (contents changed or provider
        // timed out, per Apple's `data(forType:)` documentation) — is
        // dropped HERE, at the seam: partial Canonical Content would poison
        // dedup/coalescing identity (audit SPEC-IMPL-005; 03a §4). The
        // observer has already consumed the changeCount, so the next copy
        // re-freezes whole. Typed History rejections are EXPECTED and
        // swallowed silently — concealed content fails
        // `.invalidInput(.excludedFromHistory)` by design (05 §6.1,
        // whole-capture semantics; defense in depth) — with no logging and
        // no error surface. The app's own paste writes round-trip through
        // this loop and coalesce via the lineage hint (WS4; 03b §9); they
        // must not be suppressed. The local Sendable binding keeps the
        // escaping handler free of any self capture.
        let history = self.history
        observer.start { outcome in
            guard outcome.isComplete else { return }
            let capture = outcome.capture
            Task { try? await history.perform(.capture(capture)) }
        }
    }

    /// Stops app-owned side effects. Cancellation is advisory for History,
    /// so the copy task checks it again after payload resolution and before
    /// touching the pasteboard; a late non-cooperative read cannot write or
    /// publish callbacks after shutdown.
    func stop() {
        observer.stop()
        viewState.deactivate()
        viewState.onPaste = { _ in }
        pasteTask?.cancel()
        pasteTask = nil
    }

#if DEBUG
    /// Hosted tests use the production graph builder with only the two system
    /// boundaries substituted, then drive the same started copy lane.
    static func makeForTesting(
        history: any ClipboardHistory,
        adapter: PasteboardAdapter,
        observerPollInterval: TimeInterval = 60
    ) -> AppComposition {
        let composition = AppComposition(
            history: history,
            adapter: adapter,
            observerPollInterval: observerPollInterval
        )
        composition.start()
        return composition
    }
#endif

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
        pasteTask = Task { [weak self] in
            let outcome = await Self.executePaste(
                item,
                history: history,
                adapter: adapter
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
        adapter: PasteboardAdapter
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
