/// ThumbnailStore.swift — panel-side thumbnail fetch and bounded,
/// reference-exact decoded-image retention (docs/01-architecture.md §5.7;
/// docs/04-coherence.md §9; roadmap 05).
///
/// History returns encoded, `Sendable` PNG bytes (03b §9); this store retains
/// ContentPreview's eager, framework-neutral raster only under the exact
/// `HistoryItemReference` that requested it. HistoryStorage remains the
/// thumbnail source/version/single-flight owner; ContentPreview performs only
/// PNG display materialization and knows no item/reference/cache semantics.
///
/// ADMISSION RECORD (audit 01 §S-3 / 02 §SPEC-IMPL-001; 05 §4.1 rule 4):
/// the retained dictionary below is per-surface DISPLAY STATE, explicitly
/// NOT the deferred G1 shared completed-thumbnail cache (docs/
/// 00-overview.md's v1 cache exclusion; docs/06-cross-cutting.md §3 G1's
/// unmet evidence thresholds) and not the V2-04 C1 cache (docs/v2/
/// V2-roadmap.md). One store per browsing surface, keyed by exact
/// reference, released with its surface — and, as the audit's minimum for
/// an admitted UI-side store, bounded by DECODED BYTES as well as entry
/// count (`maximumDecodedBytes` / `maximumEntries`, whole-store reset when
/// either bound is crossed; the byte cost of a hit is its backing bitmap's
/// `bytesPerRow × height`, not its display points). 05 §4.1 rule 4's end
/// state — view state retaining only the currently visible images, with
/// identical in-flight decodes coalesced and zero cross-page completed
/// retention — additionally requires row-view ownership changes and the
/// G1 evidence/spec admission; that follow-up stays open, and this bounded
/// store is the recorded intermediate state, not a silently grown cache.
import ContentPreview
import Foundation
import HistoryCore
import SwiftUI

/// Thumbnail fetch + bounded reference-exact retention (docs/
/// 01-architecture.md §5.7; docs/04-coherence.md §9). One instance per
/// browsing surface; the panel owns it and the detail view owns its own
/// (larger-pixel) instance.
@MainActor @Observable
public final class ThumbnailStore {

    /// One retained entry: a decoded image WITH its decoded-byte cost, or a
    /// recorded negative result (fetched; nothing decodable at that exact
    /// reference — zero decoded bytes).
    private enum Entry {
        case miss
        case hit(PreviewRaster, decodedBytes: Int)
    }

    // MARK: - Injected state

    private let history: any ClipboardHistory
    private let pixels: PixelSize

    /// Concrete off-MainActor eager rasterizer. It owns no History or cache
    /// policy and is injected per surface, never process-global.
    private let renderer = ContentPreview()

    // MARK: - Bounded retention (admission record in the file header)

    /// Decoded images and negative results keyed by exact reference.
    private var entries: [HistoryItemReference: Entry] = [:]

    /// The retained hits' summed decoded-byte cost — the byte half of the
    /// admission bound (misses contribute zero).
    private var retainedDecodedBytes = 0

    /// References with a fetch currently in flight, stamped by a unique
    /// monotonic request token. Removing a target releases that key
    /// immediately without letting a late old completion remove or fill a
    /// newer flight for the same exact reference (deep review Card 9B).
    private var inFlight: [HistoryItemReference: Int] = [:]

    /// Monotone surface-owned purge generation. It is local observability for
    /// destructive invalidation, not a process-wide cache epoch.
    package private(set) var purgeGeneration = 0

    /// Monotone identity for individual flights. Unlike one global request
    /// epoch, exact eviction does not invalidate unrelated in-flight rows.
    private var nextRequestToken = 0

    #if DEBUG
    /// Deterministic completion-boundary instrumentation for parked-history
    /// tests. Counts contain no clipboard content and compile out of Release.
    package private(set) var debugFetchCompletionCount = 0
    package private(set) var debugDiscardedFetchCompletionCount = 0
    #endif

    #if DEBUG
    /// DEC-THUMB-CACHE G1 evidence sink (see `ThumbnailMeasurement` at the
    /// bottom of this file): nil in Release, in every ordinary DEBUG run,
    /// and in owner tests that do not inject one. Batch 39's owner-test
    /// package counter posture is unchanged — the sink adds no public
    /// surface and no capacity knob (REVIEW GOV-3; 05 §4.1 rule 4).
    private let measurement: ThumbnailMeasurement?
    #endif

    /// Entry-count half of the admission bound (default 500). Injectable so
    /// the memory-eviction smoke suites can drive the reset at a small
    /// scale instead of seeding 500+ thumbnails.
    private let maximumEntries: Int

    /// Decoded-byte half of the admission bound (default 64 MiB). At the
    /// default 72 px payload the ENTRY ceiling binds first (500 × ≈21 KB ≈
    /// 10 MiB of decoded bitmap); the byte ceiling is the backstop that
    /// keeps larger pixel sizes (the details view's 128 px store) or
    /// row-padded bitmaps from growing a surface without bound. Injectable
    /// for the same small-scale proof as `maximumEntries`.
    private let maximumDecodedBytes: Int

    /// The number of retained entries (hits AND recorded misses) — the
    /// memory-eviction observability hook for owner tests.
    package var cachedEntryCount: Int { entries.count }

    /// The retained decoded-byte total (misses count zero) — the byte half
    /// of the same observability hook.
    package var cachedDecodedBytes: Int { retainedDecodedBytes }

    /// The number of fetches currently in flight — the quiescence signal
    /// owner tests wait on before asserting retention state.
    package var inFlightCount: Int { inFlight.count }

    // MARK: - Init

    public convenience init(
        history: any ClipboardHistory,
        pixels: PixelSize = PixelSize(width: 72, height: 72)
    ) {
        #if DEBUG
        // A DEBUG running-app journey activates the per-surface evidence
        // sink through its own envelope key (the HistoryPreviewView
        // CLIPY_UI_TEST_PREVIEW_FAILURE precedent); every other DEBUG
        // context — including the details view's 128 px store, whose records
        // would still be distinguishable by `pixelsWidth/Height` — and all
        // Release builds construct a sink-free store.
        self.init(
            history: history,
            pixels: pixels,
            maximumEntries: 500,
            maximumDecodedBytes: 64 * 1_048_576,
            measurement: ThumbnailMeasurement.makeIfRequested()
        )
        #else
        self.init(
            history: history,
            pixels: pixels,
            maximumEntries: 500,
            maximumDecodedBytes: 64 * 1_048_576
        )
        #endif
    }

    /// Owner-test seam for exercising the two admitted retention bounds at a
    /// small scale. Product callers get one fixed policy through the public
    /// initializer; cache capacity is not an application configuration knob
    /// (REVIEW GOV-3; 05 §4.1 rule 4). Under DEBUG the same seam injects the
    /// measurement sink; the parameter compiles away entirely in Release, so
    /// existing call sites are untouched in both configurations.
    #if DEBUG
    package init(
        history: any ClipboardHistory,
        pixels: PixelSize = PixelSize(width: 72, height: 72),
        maximumEntries: Int,
        maximumDecodedBytes: Int,
        measurement: ThumbnailMeasurement? = nil
    ) {
        self.history = history
        self.pixels = pixels
        self.maximumEntries = maximumEntries
        self.maximumDecodedBytes = maximumDecodedBytes
        self.measurement = measurement
    }
    #else
    package init(
        history: any ClipboardHistory,
        pixels: PixelSize = PixelSize(width: 72, height: 72),
        maximumEntries: Int,
        maximumDecodedBytes: Int
    ) {
        self.history = history
        self.pixels = pixels
        self.maximumEntries = maximumEntries
        self.maximumDecodedBytes = maximumDecodedBytes
    }
    #endif

    // MARK: - Public surface

    /// Content-free public observation used by hosted product journeys.
    /// Pixel bytes stay internal to this module (`raster(for:)` below);
    /// callers outside SwiftPM see dimensions only.
    public func imagePixelSize(for item: HistoryItemReference) -> PixelSize? {
        guard let entry = entries[item], case .hit(let raster, _) = entry else {
            return nil
        }
        return PixelSize(width: raster.width, height: raster.height)
    }

    /// Internal render edge (GOV-3 tail: only this module's row and details
    /// views read retained pixels; hosted journeys and owner tests observe
    /// the content-free `imagePixelSize(for:)` above). The returned value is
    /// immutable Sendable pixels, never a framework object, and this pure
    /// read never fetches.
    internal func raster(for item: HistoryItemReference) -> PreviewRaster? {
        guard let entry = entries[item], case .hit(let raster, _) = entry else {
            return nil
        }
        return raster
    }

    /// Starts one fetch for the exact reference if none is retained or in
    /// flight (idempotent). The encoded payload is decoded OFF the MainActor
    /// by ContentPreview's display rasterizer and retained under the
    /// requesting key only:
    /// - a `nil` payload (no thumbnailable content) is recorded as a miss,
    ///   so the row's fallback icon stops re-asking;
    /// - `.thumbnailUnavailable` is the same stable miss for these immutable
    ///   bytes, so scrolling does not repeatedly decode a malformed image;
    /// - other failures are NOT retained — stale references, cancellation,
    ///   storage failures, and transient unavailability may recover.
    public func prefetch(_ item: HistoryItemReference) {
        guard entries[item] == nil, inFlight[item] == nil else {
            #if DEBUG
            // The duplicate-request signal of DEC-THUMB-CACHE G1's
            // "identical requests" numerator (docs/06-cross-cutting.md §3):
            // the row asked again while an answer was already retained
            // (`.rejectedRetained`) or a flight was still pending
            // (`.rejectedInFlight`).
            recordMeasurement(
                entries[item] != nil ? .rejectedRetained : .rejectedInFlight,
                item: item
            )
            #endif
            return
        }
        nextRequestToken += 1
        let requestToken = nextRequestToken
        inFlight[item] = requestToken
        #if DEBUG
        recordMeasurement(.started, item: item)
        #endif

        let history = self.history
        let pixels = self.pixels
        let renderer = self.renderer

        Task { [weak self] in
            #if DEBUG
            // Timing windows wrap ONLY the awaited segments; the sink's file
            // write happens after the windows close, so a slow append can
            // never pollute the measured wall clock.
            let fetchStart = ContinuousClock.Instant.now
            var fetchMs: Double?
            #endif
            do {
                let payload = try await history.thumbnail(for: item, pixels: pixels)
                #if DEBUG
                fetchMs = Self.elapsedMilliseconds(since: fetchStart)
                #endif
                // Deletion/reset can retire this request while History is
                // suspended. Discard its encoded bytes before allocating a
                // display raster; the final completion fence still covers a
                // purge that happens during the renderer's own suspension.
                guard self?.inFlight[item] == requestToken else {
                    if let self {
                        self.finishWithoutEntry(item: item, requestToken: requestToken)
                        #if DEBUG
                        self.recordMeasurement(
                            .completed, item: item, fetchMs: fetchMs, outcome: .discarded
                        )
                        #endif
                    }
                    return
                }
                // A reset does not rely on native cancellation: it releases
                // visible bookkeeping immediately and the request token
                // rejects any late eager-raster result.
                let raster: PreviewRaster?
                #if DEBUG
                var rasterMs: Double?
                #endif
                if let payload {
                    #if DEBUG
                    let rasterStart = ContinuousClock.Instant.now
                    #endif
                    let outcome = await renderer.rasterizePNGForDisplay(
                        payload.encodedBytes
                    )
                    #if DEBUG
                    rasterMs = Self.elapsedMilliseconds(since: rasterStart)
                    #endif
                    if case let .content(.raster(value)) = outcome {
                        raster = value
                    } else {
                        raster = nil
                    }
                } else {
                    raster = nil
                }
                guard let self else { return }
                #if DEBUG
                let boundary = self.store(
                    item: item,
                    raster: raster,
                    requestToken: requestToken
                )
                self.recordMeasurement(
                    .completed,
                    item: item,
                    fetchMs: fetchMs,
                    rasterMs: rasterMs,
                    raster: raster,
                    outcome: Self.measurementOutcome(
                        boundary: boundary,
                        raster: raster
                    )
                )
                #else
                self.store(
                    item: item,
                    raster: raster,
                    requestToken: requestToken
                )
                #endif
            } catch {
                #if DEBUG
                fetchMs = Self.elapsedMilliseconds(since: fetchStart)
                #endif
                guard let self else { return }
                let isStableMiss = (error as? HistoryFailure) == .thumbnailUnavailable
                #if DEBUG
                let boundary = isStableMiss
                    ? self.store(item: item, raster: nil, requestToken: requestToken)
                    : self.finishWithoutEntry(item: item, requestToken: requestToken)
                self.recordMeasurement(
                    .completed,
                    item: item,
                    fetchMs: fetchMs,
                    outcome: boundary == .discarded ? .discarded : (isStableMiss ? .miss : .failure)
                )
                #else
                if isStableMiss {
                    self.store(item: item, raster: nil, requestToken: requestToken)
                } else {
                    self.finishWithoutEntry(item: item, requestToken: requestToken)
                }
                #endif
            }
        }
    }

    /// Privacy purge for this browsing surface. Retained pixels and negative
    /// entries disappear synchronously; advancing the generation invalidates
    /// every old flight, while clearing its visible bookkeeping permits a new
    /// request for the same exact reference immediately. A non-cooperative old
    /// history call may still return, but its completion cannot publish.
    public func reset() {
        purgeGeneration += 1
        entries.removeAll()
        retainedDecodedBytes = 0
        inFlight.removeAll()
    }

    /// Receipt-confirmed precise invalidation used by the owning panel.
    /// Remove clears all retained/in-flight references for that item; Revise
    /// clears only the old exact reference; either Clear scope delegates to
    /// `reset()` because entries intentionally omit pin metadata.
    package func purge(_ scope: HistorySurfacePurge.Scope) {
        switch scope {
        case .all:
            reset()
        case .unpinned:
            // This cache deliberately stores only exact references, not pin
            // metadata. It is rebuildable derived state, so Clear Unpinned
            // resets it owner-locally rather than guessing membership.
            reset()
        case .item(let id):
            purgeGeneration += 1
            removeEntries { $0.id == id }
            inFlight = inFlight.filter { $0.key.id != id }
        case .revision(let item, _):
            purgeGeneration += 1
            removeEntries { $0 == item }
            inFlight.removeValue(forKey: item)
        }
    }

    /// Cheap UTI heuristic gating prefetch: true when any of the row's type
    /// identifiers is in the frozen v1 ImageIO-decodable set. This is a
    /// prefetch filter only — History remains the fail-closed authority on
    /// what is thumbnailable (docs/04-coherence.md §9).
    public static func likelyThumbnailable(_ typeIdentifiers: [String]) -> Bool {
        typeIdentifiers.contains { thumbnailableTypeIdentifiers.contains($0) }
    }

    /// Thumbnail request eligibility remains local pending
    /// DEC-THUMBNAIL-REQUEST-OWNER. This frozen set mirrors Storage's current
    /// semantic manifest; ContentPreview sees only a selected PNG payload.
    private static let thumbnailableTypeIdentifiers: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.tiff",
        "public.heic",
        "public.heif",
        "com.compuserve.gif",
        "com.microsoft.bmp",
    ]

    // MARK: - Retention bookkeeping (private, MainActor-only)

    /// The decoded-byte cost of one decoded image: the backing bitmap's
    /// `bytesPerRow × height` — an honest allocation size (row padding
    /// included), not the display point size.
    private static func decodedByteCost(of raster: PreviewRaster) -> Int {
        raster.pixels.count
    }

    /// What the completion fence did with one flight's result. Consumed only
    /// by the DEBUG measurement sink's outcome classification;
    /// `@discardableResult` keeps the Release call sites in `prefetch(_:)`
    /// identical to their pre-sink form.
    private enum FlightBoundary: Equatable {
        /// The fence accepted the flight and consumed its bookkeeping.
        case accepted
        /// A late or old-generation flight was rejected by its request token
        /// (deep review Card 9B).
        case discarded
    }

    #if DEBUG
    /// Emits one content-free event through the injected sink: reference
    /// identity, requested pixel size, measured segment durations, and the
    /// completion outcome kind — never clipboard bytes or titles.
    private func recordMeasurement(
        _ event: ThumbnailMeasurement.Event,
        item: HistoryItemReference,
        fetchMs: Double? = nil,
        rasterMs: Double? = nil,
        raster: PreviewRaster? = nil,
        outcome: ThumbnailMeasurement.Outcome? = nil
    ) {
        guard let measurement else { return }
        var record = ThumbnailMeasurement.Record(
            event: event,
            refID: item.id.rawValue.uuidString,
            contentVersion: item.contentVersion.rawValue,
            pixelsWidth: pixels.width,
            pixelsHeight: pixels.height
        )
        record.fetchMs = fetchMs
        record.rasterMs = rasterMs
        record.rasterWidth = raster.map(\.width)
        record.rasterHeight = raster.map(\.height)
        record.outcome = outcome
        measurement.record(&record)
    }

    /// Milliseconds on the continuous clock between `start` and now — the
    /// elapsed-ms half of the sink's monotone timestamp.
    private static func elapsedMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        // `Instant.duration(to:)` — the earlier instant is the receiver
        // (the repo's `SearchWorker+Exact.swift` precedent).
        let components = start
            .duration(to: ContinuousClock.Instant.now)
            .components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// Maps a fetch-flight completion to the sink's outcome kind: `.miss`
    /// mirrors this store's negative entry (a nil payload OR an undecodable
    /// payload are both negative-cached), `.discarded` is the Card 9B fence.
    private static func measurementOutcome(
        boundary: FlightBoundary,
        raster: PreviewRaster?
    ) -> ThumbnailMeasurement.Outcome {
        switch boundary {
        case .discarded:
            return .discarded
        case .accepted:
            return raster != nil ? .hit : .miss
        }
    }
    #endif

    /// Records a completed fetch under its exact requesting key, resetting
    /// the whole store when EITHER admission bound is exceeded.
    /// Insert-then-evict: checking BEFORE insertion would let retention
    /// reach `maximumEntries + 1` (audit 2026-08-20 cache-ceiling
    /// off-by-one); checking after the insert keeps
    /// `cachedEntryCount <= maximumEntries` AND
    /// `cachedDecodedBytes <= maximumDecodedBytes` an observable invariant
    /// at every quiescent point.
    @discardableResult
    private func store(
        item: HistoryItemReference,
        raster: PreviewRaster?,
        requestToken: Int
    ) -> FlightBoundary {
        guard acceptCompletion(item: item, requestToken: requestToken) else {
            return .discarded
        }
        // A same-key overwrite cannot happen (`prefetch` refuses to start
        // when an entry exists), but keep the byte total exact even so.
        if case .hit(_, let replacedCost) = entries[item] {
            retainedDecodedBytes -= replacedCost
        }
        if let raster {
            let cost = Self.decodedByteCost(of: raster)
            entries[item] = .hit(raster, decodedBytes: cost)
            retainedDecodedBytes += cost
        } else {
            entries[item] = .miss
        }
        if entries.count > maximumEntries || retainedDecodedBytes > maximumDecodedBytes {
            evictRetainedEntries()
        }
        return .accepted
    }

    /// Capacity eviction only drops rebuildable completed entries. It must
    /// not advance the privacy-purge generation or invalidate unrelated
    /// visible-row flights: those rows have already issued their `.task`
    /// request and would otherwise remain permanent fallbacks.
    private func evictRetainedEntries() {
        entries.removeAll()
        retainedDecodedBytes = 0
    }

    /// Finishes a thrown/cancelled request without negative-retaining it.
    /// An old request token must not remove a newer same-reference flight.
    @discardableResult
    private func finishWithoutEntry(
        item: HistoryItemReference,
        requestToken: Int
    ) -> FlightBoundary {
        acceptCompletion(item: item, requestToken: requestToken)
            ? .accepted
            : .discarded
    }

    /// The single completion fence shared by success, failure and
    /// cancellation paths. Returning true also consumes the current flight.
    private func acceptCompletion(
        item: HistoryItemReference,
        requestToken: Int
    ) -> Bool {
        #if DEBUG
        debugFetchCompletionCount += 1
        #endif
        guard
            inFlight[item] == requestToken
        else {
            #if DEBUG
            debugDiscardedFetchCompletionCount += 1
            #endif
            return false
        }
        inFlight.removeValue(forKey: item)
        return true
    }

    /// Removes matching retained entries while keeping the decoded-byte
    /// ledger exact. Flights are handled separately because they retain no
    /// decoded pixels.
    private func removeEntries(
        where shouldRemove: (HistoryItemReference) -> Bool
    ) {
        let removedKeys = entries.keys.filter(shouldRemove)
        for key in removedKeys {
            if case .hit(_, let cost) = entries.removeValue(forKey: key) {
                retainedDecodedBytes -= cost
            }
        }
    }
}

#if DEBUG
/// DEC-THUMB-CACHE G1 evidence sink (docs/06-cross-cutting.md §3 G1;
/// docs/reviews/2026-08-22-clipy-maccy-deep-review/
/// 05-evidence-and-open-questions.md §6 "Completed thumbnail cache" row and
/// §5.5's reporting floors; 11 §4.7). Batch 39 contracted the store's
/// counters to owner-test package scope; this sink keeps exactly that
/// posture — package-only, DEBUG-only, never a product knob — while making
/// the same facts observable from a real scrolling panel, which the
/// owner-test counters cannot cross the process boundary to reach.
///
/// Content-free: reference identity, requested pixel size, segment
/// durations, and outcome kind. Appends one JSON line per event to the
/// exact absolute path named by `CLIPY_UI_TEST_THUMB_MEASUREMENT_PATH` when
/// the running-app journey envelope (`CLIPY_RUNNING_UI_TEST`) is active;
/// compiles out of Release entirely.
///
/// NOT a ratchet: nothing here evaluates a threshold or fails anything —
/// G1's dual-threshold adjudication stays with docs/06 §3 G1 and
/// docs/v2/V2-07. The two segments are reported exactly as measured:
/// `fetchMs` wraps the awaited `history.thumbnail` call, and `rasterMs`
/// wraps the awaited `rasterizePNGForDisplay`, whose single native decode
/// slot means the raster segment includes queueing behind an earlier
/// decode — recorded honestly, never corrected here.
@MainActor
package final class ThumbnailMeasurement {

    /// One sink event: a flight started, a duplicate request was refused
    /// because an answer was retained or a flight was pending, or a flight
    /// reached its completion boundary.
    package enum Event: String, Codable, Sendable {
        case started
        case rejectedRetained
        case rejectedInFlight
        case completed
    }

    /// What the completion boundary did with the flight's result. `.miss`
    /// mirrors the store's negative entry (nil/undecodable payload or typed
    /// `.thumbnailUnavailable`); `.discarded` is the request-token fence rejecting a
    /// late old-generation result.
    package enum Outcome: String, Codable, Sendable {
        case hit
        case miss
        case failure
        case discarded
    }

    /// One JSONL line. `seq` and `monotonicMs` are sink-assigned; the
    /// segment fields are present only where they were measured.
    package struct Record: Codable, Sendable, Equatable {
        package var seq = 0
        /// Milliseconds on the continuous clock since sink creation —
        /// monotone ordering evidence, not a wall-clock timestamp.
        package var monotonicMs: Int64 = 0
        package var event: Event
        /// HistoryItemID raw UUID string — content-free reference identity.
        package var refID: String
        package var contentVersion: UInt64
        package var pixelsWidth: Int
        package var pixelsHeight: Int
        /// Awaited `history.thumbnail(for:pixels:)` wall clock.
        package var fetchMs: Double?
        /// Awaited `rasterizePNGForDisplay` wall clock (includes the single
        /// decode slot's queueing).
        package var rasterMs: Double?
        /// Display-side sampling of the produced raster's dimensions (the
        /// `imagePixelSize(for:)` precedent — dimensions only, no pixels).
        package var rasterWidth: Int?
        package var rasterHeight: Int?
        package var outcome: Outcome?
    }

    private let fileURL: URL
    private let clock = ContinuousClock()
    private let start = ContinuousClock.Instant.now
    private let encoder: JSONEncoder
    private var handle: FileHandle?
    private var nextSeq = 0

    /// Owner-test seam: a sink pointed at one explicit file. Nothing is
    /// touched on disk until the first `record`.
    package init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        // Stable field order keeps the journey's JSONL diff-friendly.
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    /// Activates the sink only under the DEBUG running-app journey envelope
    /// and only for an absolute path — the same two gates ClipyApp's
    /// `RunningUITestConfiguration` applies to the store path. The key is
    /// PresentationUI-local and self-read (the HistoryPreviewView
    /// `CLIPY_UI_TEST_PREVIEW_FAILURE` precedent); the launch envelope
    /// deliberately ignores unknown extra environment keys.
    package static func makeIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ThumbnailMeasurement? {
        guard environment["CLIPY_RUNNING_UI_TEST"] == "1",
              let path = environment["CLIPY_UI_TEST_THUMB_MEASUREMENT_PATH"],
              path.hasPrefix("/")
        else { return nil }
        return ThumbnailMeasurement(
            fileURL: URL(fileURLWithPath: path).standardizedFileURL
        )
    }

    /// Assigns `seq`/`monotonicMs` and appends exactly one JSON line. File
    /// failures are observed-and-dropped (`try?`, the AppDelegate
    /// store-reveal marker precedent): measurement must never take down a
    /// running app, and a lost record surfaces as the journey's own
    /// sampling-integrity assertion rather than as a crash here. Internal
    /// (GOV-3 tail): the owning store is the only writer; owner tests drive
    /// recording through the store and read the JSONL back.
    internal func record(_ record: inout Record) {
        nextSeq += 1
        record.seq = nextSeq
        record.monotonicMs = elapsedMilliseconds
        guard let line = try? encoder.encode(record) else { return }
        append(line + Data([0x0A]))
    }

    private var elapsedMilliseconds: Int64 {
        // Same `duration(to:)` receiver rule as the static helper above.
        let components = start.duration(to: clock.now).components
        return Int64(components.seconds) * 1_000
            + Int64(components.attoseconds / 1_000_000_000_000_000)
    }

    private func append(_ data: Data) {
        if handle == nil {
            // Create-on-first-use: the journey's measurement path lives in
            // a directory the test process created before launch.
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try? Data().write(to: fileURL)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
        }
        guard let handle else { return }
        // Unbuffered appends: the journey test polls this file while the
        // app runs, so every completed line is visible without a flush.
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
    }
}
#endif
