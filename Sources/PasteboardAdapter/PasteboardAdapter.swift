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
///
/// Failure vocabulary (audit SPEC-IMPL-005,
/// docs/reviews/2026-08-20-clipy-maccy-audit/02-spec-implementation.md):
/// the freeze distinguishes "nothing retainable" (nil) from "declared but
/// unavailable" (`CaptureOutcome.unavailableTypeIdentifiers` — Apple
/// documents a nil `data(forType:)` as the contents having changed or the
/// provider having timed out), and the write throws
/// `PasteboardWriteFailure` when the pasteboard refuses a representation
/// (a false `setData(_:forType:)` return — Apple: ownership changed), so
/// neither a partial freeze nor a partial write can masquerade as a
/// complete success.
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

    #if DEBUG
    /// Deterministic AppKit-failure injection seam for Debug tests — the audit's
    /// recommended direction (SPEC-IMPL-005: "a seam that deterministically
    /// injects each documented AppKit failure"). A type identifier listed
    /// here freezes as declared-but-unavailable: the `data(forType:)` == nil
    /// outcome Apple documents as the contents having changed or the
    /// provider having timed out. The declaration and every simulated branch
    /// are absent from Release. `public` only because the hosted Debug test
    /// target imports the adapter as a regular module, without `@testable`.
    public var simulatedUnavailableTypeIdentifiers: Set<String> = []

    /// The write half of the same seam: a type identifier listed here is
    /// treated as refused by `setData(_:forType:)` — the false return
    /// Apple documents as the pasteboard's ownership having changed.
    /// Absent from Release; never set outside Debug tests.
    public var simulatedRejectedWriteTypeIdentifiers: Set<String> = []
    #endif

    /// Creates an adapter over `pasteboard` (`.general` in production).
    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Freezes the current pasteboard contents into a raw capture
    /// (docs/03a-instruction-set.md §4; docs/01-architecture.md §5.1) —
    /// the convenience half of `captureOutcome(observedAt:)` that drops
    /// the partial-freeze record. Production capture flows through
    /// `PasteboardObserver`, which delivers the full outcome; direct
    /// callers that need only the frozen value keep this one.
    public func capture(observedAt: Date = Date()) -> ClipboardCapture? {
        captureOutcome(observedAt: observedAt)?.capture
    }

    /// Freezes the current pasteboard contents into a raw capture PLUS the
    /// record of what could not be frozen (docs/03a-instruction-set.md §4;
    /// docs/01-architecture.md §5.1; audit SPEC-IMPL-005).
    ///
    /// - Every retainable typed representation of the first pasteboard item
    ///   becomes one `CapturedRepresentation` (type identifier + bytes).
    ///   v1 freezes the first item — the general pasteboard's standard
    ///   shape; merging multiple items would synthesize duplicate type
    ///   identifiers, which HistoryStorage rejects.
    /// - A type the item DECLARES but whose `data(forType:)` comes back
    ///   nil is never silently dropped: Apple documents that outcome as
    ///   the contents having changed or the provider having timed out, so
    ///   the type identifier is recorded in
    ///   `CaptureOutcome.unavailableTypeIdentifiers` and the freeze is
    ///   partial — a caller must not treat it as the complete observation
    ///   (the composition root drops partial freezes at the seam rather
    ///   than admitting partial Canonical Content, 01 §5.1).
    /// - Types whose payload is present but EMPTY are skipped without a
    ///   record: an empty byte payload is never retainable.
    /// - The lineage-hint marker type is metadata, not content: its payload
    ///   is decoded into `origin.lineageHint` and excluded from the frozen
    ///   representations; an absent hint payload is an absent hint, never
    ///   an unavailability record.
    /// - The six exclusion markers (docs/05-authority-kernel.md §6.1) mark
    ///   the WHOLE capture `isConcealed` — the adapter never strips a
    ///   marker and submits its sibling plaintext as an ordinary capture;
    ///   storage then rejects the capture with
    ///   `.invalidInput(.excludedFromHistory)` before fingerprinting
    ///   (defense in depth).
    /// - `origin.sourceApplication` is the frontmost application's bundle
    ///   identifier (`NSWorkspace`); nil when unknown.
    /// - Returns nil when nothing retainable was observed (cleared
    ///   pasteboard, metadata-only item — including an item whose EVERY
    ///   declared representation is unavailable: no retainable bytes exist
    ///   to freeze, and the observer has already consumed the changeCount,
    ///   so the next copy re-freezes) so the caller never hands History an
    ///   empty capture it must reject as `.emptyCapture`.
    public func captureOutcome(observedAt: Date = Date()) -> CaptureOutcome? {
        guard let item = pasteboard.pasteboardItems?.first else { return nil }
        let typeIdentifiers = item.types.map { $0.rawValue }

        var representations: [CapturedRepresentation] = []
        representations.reserveCapacity(typeIdentifiers.count)
        var unavailableTypeIdentifiers: [String] = []
        var lineageHint: HistoryItemID?
        for typeIdentifier in typeIdentifiers {
            #if DEBUG
            // The Debug seam forces the documented declared-but-unavailable
            // outcome (SPEC-IMPL-005).
            let data = simulatedUnavailableTypeIdentifiers.contains(typeIdentifier)
                ? nil
                : item.data(forType: NSPasteboard.PasteboardType(typeIdentifier))
            #else
            let data = item.data(
                forType: NSPasteboard.PasteboardType(typeIdentifier)
            )
            #endif
            if typeIdentifier == PasteboardLineageHint.typeIdentifier {
                lineageHint = data.flatMap(PasteboardLineageHint.decode)
                continue
            }
            guard let data else {
                unavailableTypeIdentifiers.append(typeIdentifier)
                continue
            }
            guard !data.isEmpty else { continue }
            representations.append(
                CapturedRepresentation(typeIdentifier: typeIdentifier, bytes: data)
            )
        }
        guard !representations.isEmpty else { return nil }

        return CaptureOutcome(
            capture: ClipboardCapture(
                representations: representations,
                origin: CopyOriginObservation(
                    sourceApplication: NSWorkspace.shared.frontmostApplication?
                        .bundleIdentifier,
                    lineageHint: lineageHint
                ),
                observedAt: observedAt,
                isConcealed: PasteboardMarkers.marksConcealed(typeIdentifiers)
            ),
            unavailableTypeIdentifiers: unavailableTypeIdentifiers
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
    ///
    /// Failure is explicit, never silent (audit SPEC-IMPL-005; the 03b §12
    /// caller example already writes `try ... write(payload)`): every
    /// `setData(_:forType:)` Boolean is honored — a false return, which
    /// Apple documents as the pasteboard's ownership having changed, is
    /// collected into `PasteboardWriteFailure` and thrown AFTER every
    /// write was attempted, so the pasteboard holds as much of the payload
    /// as the system accepted and the failure names everything refused.
    /// `clearContents()` has no failure signal of its own; a failed clear
    /// surfaces through the subsequent write refusals. A thrown write may
    /// leave a PREFIX of the payload on the pasteboard — the caller (the
    /// composition root) must not present the paste as completed.
    public func write(_ payload: PastePayload) throws {
        pasteboard.clearContents()
        var rejectedTypeIdentifiers: [String] = []
        for representation in payload.representations {
            #if DEBUG
            // The Debug seam models the refusal faithfully: an injected
            // rejection skips the write entirely, exactly as a false
            // `setData` return leaves the type unwritten.
            let isSimulatedRejection = simulatedRejectedWriteTypeIdentifiers.contains(
                representation.typeIdentifier
            )
            #else
            let isSimulatedRejection = false
            #endif
            let accepted = !isSimulatedRejection && pasteboard.setData(
                representation.bytes,
                forType: NSPasteboard.PasteboardType(representation.typeIdentifier)
            )
            if !accepted {
                rejectedTypeIdentifiers.append(representation.typeIdentifier)
            }
        }
        #if DEBUG
        let isSimulatedHintRejection = simulatedRejectedWriteTypeIdentifiers.contains(
            PasteboardLineageHint.typeIdentifier
        )
        #else
        let isSimulatedHintRejection = false
        #endif
        let hintAccepted = !isSimulatedHintRejection && pasteboard.setData(
            PasteboardLineageHint.encode(payload.lineageHint),
            forType: NSPasteboard.PasteboardType(PasteboardLineageHint.typeIdentifier)
        )
        if !hintAccepted {
            rejectedTypeIdentifiers.append(PasteboardLineageHint.typeIdentifier)
        }
        guard rejectedTypeIdentifiers.isEmpty else {
            throw PasteboardWriteFailure.representationsRejected(
                typeIdentifiers: rejectedTypeIdentifiers
            )
        }
    }
}

// MARK: - Capture outcome + write failure (audit SPEC-IMPL-005)

/// The outcome of a capture freeze (03a §4): the frozen capture plus the
/// record of every type the pasteboard item DECLARED but whose bytes were
/// unavailable at freeze time — Apple documents a nil `data(forType:)` as
/// the contents having changed or the provider having timed out. The
/// record is what keeps a partial freeze distinguishable from a complete
/// one (SPEC-IMPL-005: partial Canonical Content must never enter History
/// posing as a complete observation).
public struct CaptureOutcome: Sendable, Equatable {
    /// The frozen capture (03a §4). Holds only the representations whose
    /// bytes were actually observed.
    public let capture: ClipboardCapture

    /// Every declared type identifier whose payload was unavailable at
    /// freeze time, in declaration order. Empty on a complete freeze.
    public let unavailableTypeIdentifiers: [String]

    /// Whether the freeze observed every declared representation — the
    /// only freeze a caller may treat as the complete observation.
    public var isComplete: Bool { unavailableTypeIdentifiers.isEmpty }

    /// Creates the outcome; the adapter is the only producer.
    public init(capture: ClipboardCapture, unavailableTypeIdentifiers: [String]) {
        self.capture = capture
        self.unavailableTypeIdentifiers = unavailableTypeIdentifiers
    }
}

/// The typed failure of a paste write (03b §9; 04 §8; audit SPEC-IMPL-005).
public enum PasteboardWriteFailure: Error, Sendable, Equatable {
    /// One or more `setData(_:forType:)` calls returned false — the
    /// outcome Apple documents as the pasteboard's ownership having
    /// changed mid-write. Carries every refused type identifier in write
    /// order: payload representations first, the lineage-hint marker type
    /// last. The pasteboard may hold a PREFIX of the payload.
    case representationsRejected(typeIdentifiers: [String])
}
