/// ThumbnailStore.swift — panel-side thumbnail fetch and bounded,
/// reference-exact decoded-image retention (docs/01-architecture.md §5.7;
/// docs/04-coherence.md §9; roadmap 05).
///
/// History returns encoded, `Sendable` PNG bytes (docs/
/// 03b-instruction-set.md §9); this store hands them to
/// `DisplayImageDecoder` — PresentationUI's single, non-MainActor ImageIO
/// decode point (audit docs/reviews/2026-08-20-clipy-maccy-audit/
/// 01-standards.md §S-2 / 02-spec-implementation.md §SPEC-IMPL-002;
/// 05-recommended-target-design.md §4.1 rule 2) — and applies the decoded
/// `CGImage` only under the exact `HistoryItemReference` (item ID + Content
/// Version) that requested it, so a revised item never receives stale
/// pixels (04 §9's caller-side fence convention).
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
import CoreGraphics
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
        case hit(CGImage, decodedBytes: Int)
    }

    // MARK: - Injected state

    private let history: any ClipboardHistory
    private let pixels: PixelSize

    /// The off-MainActor decode hop (S-2/SPEC-IMPL-002); stateless, one per
    /// store — deliberately injected per instance, never a process-wide
    /// singleton (Part I §8's banned service-locator spelling).
    private let decoder = DisplayImageDecoder()

    // MARK: - Bounded retention (admission record in the file header)

    /// Decoded images and negative results keyed by exact reference.
    private var entries: [HistoryItemReference: Entry] = [:]

    /// The retained hits' summed decoded-byte cost — the byte half of the
    /// admission bound (misses contribute zero).
    private var retainedDecodedBytes = 0

    /// References with a fetch currently in flight, stamped by the surface
    /// purge generation. The stamp makes reset release the key immediately
    /// without letting a late old completion remove or fill a new flight for
    /// the same exact reference (deep review Card 9B).
    private var inFlight: [HistoryItemReference: Int] = [:]

    /// Monotone surface-owned purge generation. It is deliberately local to
    /// this cache rather than a global cache bus: every completion must match
    /// both this generation and the exact reference's current flight.
    private var generation = 0

    #if DEBUG
    /// Deterministic completion-boundary instrumentation for parked-history
    /// tests. Counts contain no clipboard content and compile out of Release.
    package private(set) var debugFetchCompletionCount = 0
    package private(set) var debugDiscardedFetchCompletionCount = 0
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
    /// memory-eviction observability hook for the smoke/measurement suites.
    public var cachedEntryCount: Int { entries.count }

    /// The retained decoded-byte total (misses count zero) — the byte half
    /// of the same observability hook.
    public var cachedDecodedBytes: Int { retainedDecodedBytes }

    /// The number of fetches currently in flight — the quiescence signal
    /// the smoke suites wait on before asserting retention state.
    public var inFlightCount: Int { inFlight.count }

    /// The frozen v1 ImageIO-decodable image type set, mirroring
    /// `HistoryAuthority.thumbnailImageTypeIdentifiers` in
    /// Sources/HistoryStorage/HistoryAuthority+DetailAndThumbnail.swift
    /// (docs/04-coherence.md §9: v1 freezes the concrete decodable UTIs).
    /// Keep the two sets in sync.
    private static let thumbnailableTypeIdentifiers: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.tiff",
        "public.heic",
        "public.heif",
        "com.compuserve.gif",
        "com.microsoft.bmp",
    ]

    // MARK: - Init

    public init(
        history: any ClipboardHistory,
        pixels: PixelSize = PixelSize(width: 72, height: 72),
        maximumEntries: Int = 500,
        maximumDecodedBytes: Int = 64 * 1_048_576
    ) {
        self.history = history
        self.pixels = pixels
        self.maximumEntries = maximumEntries
        self.maximumDecodedBytes = maximumDecodedBytes
    }

    // MARK: - Public surface

    /// The retained image for one exact reference — a pure read that never
    /// fetches; call `prefetch(_:)` first.
    public func image(for item: HistoryItemReference) -> CGImage? {
        guard let entry = entries[item], case .hit(let image, _) = entry else {
            return nil
        }
        return image
    }

    /// Starts one fetch for the exact reference if none is retained or in
    /// flight (idempotent). The encoded payload is decoded OFF the MainActor
    /// by `DisplayImageDecoder` and retained under the requesting key only:
    /// - a `nil` payload (no thumbnailable content) is recorded as a miss,
    ///   so the row's fallback icon stops re-asking;
    /// - a thrown failure is NOT retained — transient unavailability may
    ///   recover, so the reference stays eligible for a later prefetch.
    public func prefetch(_ item: HistoryItemReference) {
        guard entries[item] == nil, inFlight[item] == nil else { return }
        let requestGeneration = generation
        inFlight[item] = requestGeneration

        let history = self.history
        let pixels = self.pixels
        let decoder = self.decoder

        Task { [weak self] in
            do {
                let payload = try await history.thumbnail(for: item, pixels: pixels)
                // The decode hop leaves the MainActor; the decoded CGImage
                // crosses back as an immutable Sendable value (audit 02
                // §SPEC-IMPL-002's Apple-docs check). Nothing cancels these
                // unstructured tasks. A reset does not rely on cooperative
                // cancellation: it releases visible bookkeeping immediately,
                // and the captured generation rejects any late result.
                let image: CGImage?
                if let payload {
                    image = await decoder.thumbnailImage(fromPNG: payload.encodedBytes)
                } else {
                    image = nil
                }
                guard let self else { return }
                self.store(
                    item: item,
                    image: image,
                    requestGeneration: requestGeneration
                )
            } catch {
                // Not retained: see `prefetch(_:)`.
                guard let self else { return }
                self.finishWithoutEntry(
                    item: item,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    /// Privacy purge for this browsing surface. Retained pixels and negative
    /// entries disappear synchronously; advancing the generation invalidates
    /// every old flight, while clearing its visible bookkeeping permits a new
    /// request for the same exact reference immediately. A non-cooperative old
    /// history call may still return, but its completion cannot publish.
    public func reset() {
        generation += 1
        entries.removeAll()
        retainedDecodedBytes = 0
        inFlight.removeAll()
    }

    /// Cheap UTI heuristic gating prefetch: true when any of the row's type
    /// identifiers is in the frozen v1 ImageIO-decodable set. This is a
    /// prefetch filter only — History remains the fail-closed authority on
    /// what is thumbnailable (docs/04-coherence.md §9).
    public static func likelyThumbnailable(_ typeIdentifiers: [String]) -> Bool {
        typeIdentifiers.contains { thumbnailableTypeIdentifiers.contains($0) }
    }

    // MARK: - Retention bookkeeping (private, MainActor-only)

    /// The decoded-byte cost of one decoded image: the backing bitmap's
    /// `bytesPerRow × height` — an honest allocation size (row padding
    /// included), not the display point size.
    private static func decodedByteCost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    /// Records a completed fetch under its exact requesting key, resetting
    /// the whole store when EITHER admission bound is exceeded.
    /// Insert-then-evict: checking BEFORE insertion would let retention
    /// reach `maximumEntries + 1` (audit 2026-08-20 cache-ceiling
    /// off-by-one); checking after the insert keeps
    /// `cachedEntryCount <= maximumEntries` AND
    /// `cachedDecodedBytes <= maximumDecodedBytes` an observable invariant
    /// at every quiescent point.
    private func store(
        item: HistoryItemReference,
        image: CGImage?,
        requestGeneration: Int
    ) {
        guard acceptCompletion(item: item, requestGeneration: requestGeneration) else {
            return
        }
        // A same-key overwrite cannot happen (`prefetch` refuses to start
        // when an entry exists), but keep the byte total exact even so.
        if case .hit(_, let replacedCost) = entries[item] {
            retainedDecodedBytes -= replacedCost
        }
        if let image {
            let cost = Self.decodedByteCost(of: image)
            entries[item] = .hit(image, decodedBytes: cost)
            retainedDecodedBytes += cost
        } else {
            entries[item] = .miss
        }
        if entries.count > maximumEntries || retainedDecodedBytes > maximumDecodedBytes {
            evictRetainedEntries()
        }
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
    /// An old generation must not remove a newer same-reference flight.
    private func finishWithoutEntry(
        item: HistoryItemReference,
        requestGeneration: Int
    ) {
        _ = acceptCompletion(item: item, requestGeneration: requestGeneration)
    }

    /// The single completion fence shared by success, failure and
    /// cancellation paths. Returning true also consumes the current flight.
    private func acceptCompletion(
        item: HistoryItemReference,
        requestGeneration: Int
    ) -> Bool {
        #if DEBUG
        debugFetchCompletionCount += 1
        #endif
        guard
            generation == requestGeneration,
            inFlight[item] == requestGeneration
        else {
            #if DEBUG
            debugDiscardedFetchCompletionCount += 1
            #endif
            return false
        }
        inFlight.removeValue(forKey: item)
        return true
    }
}
