/// PasteboardAdapter — NSPasteboard ↔ HistoryCore raw-value translation:
/// the capture freeze (docs/03a-instruction-set.md §4; docs/01-architecture.md
/// §5.1), the paste write (docs/03b-instruction-set.md §9; docs/04-coherence.md
/// §8; docs/01-architecture.md §5.6), and the source/lineage observation.
/// Owning roadmap: docs/roadmap/04-pasteboardadapter.md.
///
/// AppKit is confined to this target (docs/01-architecture.md §2/§8). The
/// adapter is deliberately dumb: it never constructs `CanonicalContent`,
/// never fingerprints, and never touches persistence — every
/// dedup/coalescing/OCC decision stays behind `ClipboardHistory`
/// (docs/01-architecture.md §3 "Must not own", roadmap 04 negative
/// acceptance).
///
/// Isolation: the whole translation surface is confined to the main actor.
/// `NSPasteboard` and `NSWorkspace` are AppKit values that are not
/// `Sendable`, so the adapter keeps them main-actor-isolated and only
/// immutable `Sendable` values (`ClipboardCapture`, `PastePayload`) cross
/// actor boundaries (docs/01-architecture.md §6 boundary rule). Main-actor
/// isolation also provides this struct's `Sendable` conformance without
/// ever claiming the stored `NSPasteboard` reference itself is Sendable —
/// the sanctioned alternative to the banned concurrency escape hatches
/// (docs/01-architecture.md §8).
import AppKit
import Foundation
import HistoryCore

/// NSPasteboard ↔ HistoryCore raw-value translation (01 §5.1/§5.6; 03a §4;
/// 03b §9/§12; 04 §8).
@MainActor
public struct PasteboardAdapter {
    /// The observed pasteboard. `.general` in production; tests inject a
    /// private `NSPasteboard(name:)` so they never read or mutate the
    /// user's clipboard.
    public let pasteboard: NSPasteboard

    /// Creates an adapter over `pasteboard` (`.general` in production).
    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Freezes the current pasteboard contents into a raw capture
    /// (docs/03a-instruction-set.md §4; docs/01-architecture.md §5.1).
    ///
    /// - Every retainable typed representation of the first pasteboard item
    ///   becomes one `CapturedRepresentation` (type identifier + bytes).
    ///   v1 freezes the first item — the general pasteboard's standard
    ///   shape; merging multiple items would synthesize duplicate type
    ///   identifiers, which HistoryStorage rejects. Types whose payload is
    ///   absent or empty are skipped: an empty byte payload is never
    ///   retainable.
    /// - The lineage-hint marker type is metadata, not content: its payload
    ///   is decoded into `origin.lineageHint` and excluded from the frozen
    ///   representations.
    /// - The six exclusion markers (docs/05-authority-kernel.md §6.1) mark
    ///   the WHOLE capture `isConcealed` — the adapter never strips a
    ///   marker and submits its sibling plaintext as an ordinary capture;
    ///   storage then rejects the capture with
    ///   `.invalidInput(.excludedFromHistory)` before fingerprinting
    ///   (defense in depth).
    /// - `origin.sourceApplication` is the frontmost application's bundle
    ///   identifier (`NSWorkspace`); nil when unknown.
    /// - Returns nil when nothing retainable was observed (cleared
    ///   pasteboard, metadata-only item) so the caller never hands History
    ///   an empty capture it must reject as `.emptyCapture`.
    public func capture(observedAt: Date = Date()) -> ClipboardCapture? {
        guard let item = pasteboard.pasteboardItems?.first else { return nil }
        let typeIdentifiers = item.types.map { $0.rawValue }

        var representations: [CapturedRepresentation] = []
        representations.reserveCapacity(typeIdentifiers.count)
        var lineageHint: HistoryItemID?
        for typeIdentifier in typeIdentifiers {
            let data = item.data(forType: NSPasteboard.PasteboardType(typeIdentifier))
            if typeIdentifier == PasteboardLineageHint.typeIdentifier {
                lineageHint = data.flatMap(PasteboardLineageHint.decode)
                continue
            }
            guard let data, !data.isEmpty else { continue }
            representations.append(
                CapturedRepresentation(typeIdentifier: typeIdentifier, bytes: data)
            )
        }
        guard !representations.isEmpty else { return nil }

        return ClipboardCapture(
            representations: representations,
            origin: CopyOriginObservation(
                sourceApplication: NSWorkspace.shared.frontmostApplication?
                    .bundleIdentifier,
                lineageHint: lineageHint
            ),
            observedAt: observedAt,
            isConcealed: PasteboardMarkers.marksConcealed(typeIdentifiers)
        )
    }

    /// Writes the payload's Effective Content representations plus the
    /// lineage hint equal to the item ID (docs/03b-instruction-set.md §9;
    /// docs/04-coherence.md §8; docs/01-architecture.md §5.6).
    ///
    /// The pasteboard is cleared first (`clearContents()`), then each
    /// representation is written under its type identifier, then the
    /// lineage hint is written under `com.clipy.lineageHint` so the next
    /// capture of this same paste coalesces into the item instead of
    /// inserting a duplicate (WS4 copy-coalescing through History; the
    /// end-to-end proof lives in HistoryStorage, not this target). The
    /// write is a framework side effect owned by the composition root's
    /// paste orchestration and is intentionally outside any History
    /// transaction (docs/04-coherence.md §8).
    public func write(_ payload: PastePayload) {
        pasteboard.clearContents()
        for representation in payload.representations {
            pasteboard.setData(
                representation.bytes,
                forType: NSPasteboard.PasteboardType(representation.typeIdentifier)
            )
        }
        pasteboard.setData(
            PasteboardLineageHint.encode(payload.lineageHint),
            forType: NSPasteboard.PasteboardType(PasteboardLineageHint.typeIdentifier)
        )
    }
}
