/// ThumbnailStore.swift — panel-side thumbnail fetch, decode, and
/// reference-exact cache (docs/01-architecture.md §5.7; docs/04-coherence.md
/// §9; roadmap 05).
///
/// History returns encoded, `Sendable` PNG bytes (docs/
/// 03b-instruction-set.md §9); this store decodes them with ImageIO into a
/// `CGImage` on the MainActor — PresentationUI never imports AppKit, and a
/// `CGImage` never crosses an actor boundary (docs/01-architecture.md §6).
/// The cache key is the full `HistoryItemReference` (item ID + Content
/// Version), so a revised item never receives stale pixels: a result is
/// applied only under the exact key that requested it.
import CoreGraphics
import Foundation
import HistoryCore
import ImageIO
import SwiftUI

/// Thumbnail fetch + reference-exact cache (docs/01-architecture.md §5.7;
/// docs/04-coherence.md §9). One instance per browsing surface; the panel
/// owns it and the detail view shares it via the view state's `history`.
@MainActor @Observable
public final class ThumbnailStore {

    /// One cache entry: a decoded image, or a recorded negative result
    /// (fetched; nothing decodable at that exact reference).
    private enum Entry {
        case miss
        case hit(CGImage)
    }

    // MARK: - Injected state

    private let history: any ClipboardHistory
    private let pixels: PixelSize

    // MARK: - Cache

    /// Decoded images and negative results keyed by exact reference.
    private var entries: [HistoryItemReference: Entry] = [:]

    /// References with a fetch currently in flight — makes `prefetch`
    /// idempotent per reference without caching its outcome.
    private var inFlight: Set<HistoryItemReference> = []

    /// Whole-cache ceiling (500): exceeded → the entire cache resets. A
    /// per-key eviction policy is deliberately out of scope for v1; the
    /// completed-thumbnail cache is deferred G1 work (docs/
    /// 04-coherence.md §9 step 7; docs/06-cross-cutting.md §3).
    private static let maximumEntryCount = 500

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
        "public.bmp",
    ]

    // MARK: - Init

    public init(
        history: any ClipboardHistory,
        pixels: PixelSize = PixelSize(width: 72, height: 72)
    ) {
        self.history = history
        self.pixels = pixels
    }

    // MARK: - Public surface

    /// The cached image for one exact reference — a pure read that never
    /// fetches; call `prefetch(_:)` first.
    public func image(for item: HistoryItemReference) -> CGImage? {
        guard let entry = entries[item], case .hit(let image) = entry else {
            return nil
        }
        return image
    }

    /// Starts one fetch for the exact reference if none is cached or in
    /// flight (idempotent). The encoded payload is decoded on the MainActor
    /// and cached under the requesting key only:
    /// - a `nil` payload (no thumbnailable content) is negative-cached, so
    ///   the row's fallback icon stops re-asking;
    /// - a thrown failure is NOT cached — transient unavailability may
    ///   recover, so the reference stays eligible for a later prefetch.
    public func prefetch(_ item: HistoryItemReference) {
        guard entries[item] == nil, !inFlight.contains(item) else { return }
        inFlight.insert(item)

        let history = self.history
        let pixels = self.pixels

        Task { [weak self] in
            do {
                let payload = try await history.thumbnail(for: item, pixels: pixels)
                // Nothing cancels these unstructured tasks, but even if one
                // were, recording (or dropping) the exact key is the correct
                // completion either way — an in-flight entry must never be
                // stranded.
                guard let self else { return }
                self.store(
                    item: item,
                    image: payload.flatMap { Self.decodePNG($0.encodedBytes) }
                )
            } catch {
                // Not negative-cached: see `prefetch(_:).
                guard let self else { return }
                self.inFlight.remove(item)
            }
        }
    }

    /// Clears the whole cache. In-flight fetches still land afterwards under
    /// their exact reference; the in-flight set itself is not cleared, so
    /// resetting mid-fetch cannot start duplicate flights.
    public func reset() {
        entries.removeAll()
    }

    /// Cheap UTI heuristic gating prefetch: true when any of the row's type
    /// identifiers is in the frozen v1 ImageIO-decodable set. This is a
    /// prefetch filter only — History remains the fail-closed authority on
    /// what is thumbnailable (docs/04-coherence.md §9).
    public static func likelyThumbnailable(_ typeIdentifiers: [String]) -> Bool {
        typeIdentifiers.contains { thumbnailableTypeIdentifiers.contains($0) }
    }

    // MARK: - Decode (private, MainActor-only)

    /// Records a completed fetch under its exact requesting key, resetting
    /// the whole cache first when the entry ceiling is exceeded.
    private func store(item: HistoryItemReference, image: CGImage?) {
        inFlight.remove(item)
        if entries.count > Self.maximumEntryCount {
            entries.removeAll()
        }
        entries[item] = image.map(Entry.hit) ?? .miss
    }

    /// Decodes encoded PNG thumbnail bytes (docs/03b-instruction-set.md §9)
    /// into a `CGImage`. A decode failure returns `nil` — it is recorded as
    /// a cache miss, not surfaced as a panel failure.
    private static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
