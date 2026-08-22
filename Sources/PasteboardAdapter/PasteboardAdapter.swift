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
/// unavailable" (`CaptureOutcome.declaredUnavailable`), and the write throws
/// `PasteboardWriteFailure` when an item refuses a staged representation or
/// the pasteboard refuses the completed item, so neither a partial freeze
/// nor a known incomplete write can masquerade as a complete success. A
/// multi-item clipboard is reported as an unsupported capture shape instead
/// of silently truncating it to the first item.
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
    /// Immutable, package-only AppKit-failure injection. None of this state is
    /// part of the shipped public adapter surface (REVIEW Card 5D). Keeping
    /// the three observed framework outcomes together also makes a configured
    /// adapter stable after construction instead of exposing mutable switches
    /// to callers.
    private let failureSimulation: PasteboardFailureSimulation

    /// Records each real payload accessor immediately before the adapter
    /// calls `NSPasteboardItem.data(forType:)`. Tests use this hook to prove
    /// privacy short-circuits without replacing AppKit or adding a second
    /// provider abstraction. Simulated-unavailable reads do not call the
    /// framework accessor and therefore do not notify this observer.
    package var payloadReadObserver: (@MainActor (String) -> Void)?

    /// Runs immediately after each real payload accessor. Adapter tests use
    /// this package-only boundary to replace a named private pasteboard
    /// between representation reads and prove the start/end `changeCount`
    /// fence. It is absent from Release and is not a provider abstraction.
    package var payloadReadCompletionHook: (@MainActor (String) -> Void)?
    #endif

    /// Creates an adapter over `pasteboard` (`.general` in production).
    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        #if DEBUG
        self.failureSimulation = PasteboardFailureSimulation()
        #endif
    }

    #if DEBUG
    /// Creates a Debug test adapter with fixed framework outcomes. Package
    /// rather than `public`: its owning SwiftPM tests can arrange the AppKit
    /// boundary while external clients cannot discover or configure it.
    package init(
        pasteboard: NSPasteboard,
        failureSimulation: PasteboardFailureSimulation
    ) {
        self.pasteboard = pasteboard
        self.failureSimulation = failureSimulation
    }
    #endif

    /// Freezes the current pasteboard contents into a raw capture
    /// (docs/03a-instruction-set.md §4; docs/01-architecture.md §5.1) —
    /// the convenience half of `captureOutcome(observedAt:)` that returns
    /// only a complete freeze. Production capture flows through
    /// `PasteboardObserver`, which delivers the full outcome; direct
    /// callers that need only the frozen value keep this one. Partial,
    /// concealed, and multi-item outcomes return nil here; callers needing
    /// the reason use `captureOutcome(observedAt:)`.
    public func capture(observedAt: Date = Date()) -> ClipboardCapture? {
        guard let outcome = captureOutcome(observedAt: observedAt) else {
            return nil
        }
        switch outcome {
        case let .complete(complete):
            return complete.capture
        case .declaredUnavailable,
             .concealed,
             .unsupportedMultiItem,
             .changedDuringRead:
            return nil
        }
    }

    /// Freezes the current pasteboard contents into a raw capture PLUS the
    /// record of what could not be frozen (docs/03a-instruction-set.md §4;
    /// docs/01-architecture.md §5.1; audit SPEC-IMPL-005).
    ///
    /// - Exactly one pasteboard item is supported by the current flat capture
    ///   model. A pasteboard containing multiple items returns an explicit
    ///   unsupported outcome before any payload accessor runs, with the
    ///   observed item count and zero representations. It is never flattened
    ///   and its first item is never presented as a complete observation.
    /// - Every retainable typed representation of the supported single item
    ///   becomes one `CapturedRepresentation` (type identifier + bytes).
    /// - A type the item DECLARES but whose `data(forType:)` comes back
    ///   nil is never silently dropped: the type identifier is recorded in
    ///   `CaptureOutcome.declaredUnavailable` and the freeze is partial — a
    ///   caller must not treat it as the complete observation or infer a
    ///   provider-specific cause
    ///   (the composition root drops partial freezes at the seam rather
    ///   than admitting partial Canonical Content, 01 §5.1).
    /// - Types whose payload is present but EMPTY are skipped without a
    ///   record: an empty byte payload is never retainable.
    /// - The lineage-hint marker type is metadata, not content: its payload
    ///   is decoded into `origin.lineageHint` and excluded from the frozen
    ///   representations; an absent hint payload is an absent hint, never
    ///   an unavailability record.
    /// - If the item's DECLARED types contain one of the six exclusion
    ///   markers (docs/05-authority-kernel.md §6.1), the adapter returns an
    ///   explicit concealed outcome before calling `data(forType:)` for any
    ///   type. The outcome carries no capture, so no caller can accidentally
    ///   submit sibling bytes that were intentionally not read.
    /// - `origin.sourceApplication` is the frontmost application's bundle
    ///   identifier (`NSWorkspace`); nil when unknown.
    /// - Returns nil only when the item declared no unavailable content and
    ///   nothing retainable was observed (cleared or metadata-only). If every
    ///   content representation is unavailable, an explicit empty partial
    ///   outcome reaches the owner so the consumed change is not silent.
    ///   Concealed and unsupported-shape outcomes are likewise intentionally
    ///   empty and cannot masquerade as admissible content.
    /// - The pasteboard `changeCount` is recorded before metadata access and
    ///   after the last payload read. A mismatch produces an explicit
    ///   changed-during-read outcome containing no representations. It is a
    ///   retry signal, not an unavailable-type diagnosis.
    public func captureOutcome(observedAt: Date = Date()) -> CaptureOutcome? {
        let startChangeCount = pasteboard.changeCount
        guard let items = pasteboard.pasteboardItems,
              let item = items.first else {
            let endChangeCount = pasteboard.changeCount
            guard startChangeCount == endChangeCount else {
                return changedDuringReadOutcome(
                    startChangeCount: startChangeCount,
                    endChangeCount: endChangeCount
                )
            }
            return nil
        }
        guard items.count == 1 else {
            let endChangeCount = pasteboard.changeCount
            guard startChangeCount == endChangeCount else {
                return changedDuringReadOutcome(
                    startChangeCount: startChangeCount,
                    endChangeCount: endChangeCount
                )
            }
            return .unsupportedMultiItem(.init(
                itemCount: items.count,
                changeCount: startChangeCount
            ))
        }
        let typeIdentifiers = item.types.map { $0.rawValue }
        if let marker = typeIdentifiers.first(where: {
            PasteboardMarkers.concealedTypeIdentifiers.contains($0)
        }) {
            let endChangeCount = pasteboard.changeCount
            guard startChangeCount == endChangeCount else {
                return changedDuringReadOutcome(
                    startChangeCount: startChangeCount,
                    endChangeCount: endChangeCount
                )
            }
            return .concealed(.init(
                markerTypeIdentifier: marker,
                changeCount: startChangeCount
            ))
        }

        var representations: [CapturedRepresentation] = []
        representations.reserveCapacity(typeIdentifiers.count)
        var unavailableTypeIdentifiers: [String] = []
        var lineageHint: HistoryItemID?
        for typeIdentifier in typeIdentifiers {
            #if DEBUG
            // The Debug seam forces the documented declared-but-unavailable
            // outcome (SPEC-IMPL-005).
            let data: Data?
            if failureSimulation.unavailableTypeIdentifiers.contains(typeIdentifier) {
                data = nil
            } else {
                payloadReadObserver?(typeIdentifier)
                data = item.data(
                    forType: NSPasteboard.PasteboardType(typeIdentifier)
                )
                payloadReadCompletionHook?(typeIdentifier)
            }
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
        let endChangeCount = pasteboard.changeCount
        guard startChangeCount == endChangeCount else {
            return changedDuringReadOutcome(
                startChangeCount: startChangeCount,
                endChangeCount: endChangeCount
            )
        }
        let capture = ClipboardCapture(
            representations: representations,
            origin: CopyOriginObservation(
                sourceApplication: NSWorkspace.shared.frontmostApplication?
                    .bundleIdentifier,
                lineageHint: lineageHint
            ),
            observedAt: observedAt,
            isConcealed: false
        )
        guard !representations.isEmpty else {
            guard !unavailableTypeIdentifiers.isEmpty else { return nil }
            return .declaredUnavailable(.init(
                partialCapture: capture,
                unavailableTypeIdentifiers: unavailableTypeIdentifiers,
                changeCount: startChangeCount
            ))
        }

        if unavailableTypeIdentifiers.isEmpty {
            return .complete(.init(
                capture: capture,
                changeCount: startChangeCount
            ))
        }
        return .declaredUnavailable(.init(
            partialCapture: capture,
            unavailableTypeIdentifiers: unavailableTypeIdentifiers,
            changeCount: startChangeCount
        ))
    }

    /// Builds the one content-free retry outcome for an ownership change
    /// observed by the freeze fence (REVIEW Card 5B). Bytes read before the
    /// mismatch are intentionally discarded rather than partially admitted.
    private func changedDuringReadOutcome(
        startChangeCount: Int,
        endChangeCount: Int
    ) -> CaptureOutcome {
        .changedDuringRead(.init(
            startChangeCount: startChangeCount,
            endChangeCount: endChangeCount
        ))
    }

    /// Writes the payload's Effective Content representations plus the
    /// lineage hint equal to the item ID (docs/03b-instruction-set.md §9;
    /// docs/04-coherence.md §8; docs/01-architecture.md §5.6).
    ///
    /// Every representation and the `com.clipy.lineageHint` metadata are
    /// first staged on one new, unbound `NSPasteboardItem`. Only a complete
    /// item reaches the system pasteboard: the adapter then clears the old
    /// contents and makes one `writeObjects([item])` attempt. The hint lets
    /// the next capture of this same paste coalesce into the item instead of
    /// inserting a duplicate (WS4 copy-coalescing through History; the
    /// end-to-end proof lives in HistoryStorage, not this target). The write
    /// is a framework side effect owned by the composition root's paste
    /// orchestration and is intentionally outside any History transaction
    /// (docs/04-coherence.md §8).
    ///
    /// Failure is explicit, never silent (audit SPEC-IMPL-005; the 03b §12
    /// caller example already writes `try ... write(payload)`). A staging
    /// rejection is reported before `clearContents()`, leaving the existing
    /// pasteboard and its `changeCount` untouched. A false `writeObjects`
    /// result is reported separately. One framework write attempt narrows
    /// the partial-write window; Apple does not document it as a cross-process
    /// atomic transaction, so this API makes no atomicity claim.
    public func write(_ payload: PastePayload) throws {
        let item = NSPasteboardItem()
        var rejectedTypeIdentifiers: [String] = []
        for representation in payload.representations {
            #if DEBUG
            // The Debug seam rejects staging without touching the observed
            // pasteboard, matching a false item-setter result.
            let isSimulatedRejection = failureSimulation.rejectedWriteTypeIdentifiers.contains(
                representation.typeIdentifier
            )
            #else
            let isSimulatedRejection = false
            #endif
            let accepted = !isSimulatedRejection && item.setData(
                representation.bytes,
                forType: NSPasteboard.PasteboardType(representation.typeIdentifier)
            )
            if !accepted {
                rejectedTypeIdentifiers.append(representation.typeIdentifier)
            }
        }
        #if DEBUG
        let isSimulatedHintRejection = failureSimulation.rejectedWriteTypeIdentifiers.contains(
            PasteboardLineageHint.typeIdentifier
        )
        #else
        let isSimulatedHintRejection = false
        #endif
        let hintAccepted = !isSimulatedHintRejection && item.setData(
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

        pasteboard.clearContents()
        #if DEBUG
        let itemAccepted = !failureSimulation.rejectCompletedItem
            && pasteboard.writeObjects([item])
        #else
        let itemAccepted = pasteboard.writeObjects([item])
        #endif
        guard itemAccepted else {
            throw PasteboardWriteFailure.itemRejected
        }
    }
}

#if DEBUG
/// Exact AppKit outcomes required by deterministic adapter tests. This type
/// and its initializer are package-only and absent from Release; they are not
/// a product capability or a general provider abstraction (REVIEW Card 5D).
package struct PasteboardFailureSimulation: Sendable {
    package let unavailableTypeIdentifiers: Set<String>
    package let rejectedWriteTypeIdentifiers: Set<String>
    package let rejectCompletedItem: Bool

    package init(
        unavailableTypeIdentifiers: Set<String> = [],
        rejectedWriteTypeIdentifiers: Set<String> = [],
        rejectCompletedItem: Bool = false
    ) {
        self.unavailableTypeIdentifiers = unavailableTypeIdentifiers
        self.rejectedWriteTypeIdentifiers = rejectedWriteTypeIdentifiers
        self.rejectCompletedItem = rejectCompletedItem
    }
}
#endif

// MARK: - Capture outcome + write failure (audit SPEC-IMPL-005)

/// The closed outcome of a capture freeze (03a §4; REVIEW Card 5B). Each
/// case carries only facts valid for that state, so callers cannot construct
/// or receive contradictory combinations such as a complete concealed
/// capture or an ownership-race result containing bytes. `nil` remains the
/// truly empty or metadata-only observation.
public enum CaptureOutcome: Sendable, Equatable {
    /// One stable pasteboard generation whose retainable representations were
    /// all observed. This is the only case callers may admit to History.
    case complete(Complete)

    /// One stable generation with at least one declared content type whose
    /// bytes were unavailable. `partialCapture` holds only bytes actually
    /// observed; the case records no provider-specific cause.
    case declaredUnavailable(DeclaredUnavailable)

    /// A declared privacy marker stopped the freeze before any payload read.
    case concealed(Concealed)

    /// The current flat capture model cannot preserve multiple item
    /// boundaries. No item payload was read.
    case unsupportedMultiItem(UnsupportedMultiItem)

    /// Ownership/content changed while the freeze was read. Bytes from the
    /// superseded generation are discarded; this content-free case asks the
    /// observer to retry without diagnosing unavailable content.
    case changedDuringRead(ChangedDuringRead)

    /// Facts of a stable, complete freeze. Only the adapter can create this
    /// payload, so a caller cannot relabel a concealed capture as complete.
    public struct Complete: Sendable, Equatable {
        public let capture: ClipboardCapture
        public let changeCount: Int

        fileprivate init(capture: ClipboardCapture, changeCount: Int) {
            self.capture = capture
            self.changeCount = changeCount
        }
    }

    /// Facts of a stable partial freeze. The adapter calls the private
    /// initializer only after observing a non-empty unavailable set.
    public struct DeclaredUnavailable: Sendable, Equatable {
        public let partialCapture: ClipboardCapture
        public let unavailableTypeIdentifiers: [String]
        public let changeCount: Int

        fileprivate init(
            partialCapture: ClipboardCapture,
            unavailableTypeIdentifiers: [String],
            changeCount: Int
        ) {
            self.partialCapture = partialCapture
            self.unavailableTypeIdentifiers = unavailableTypeIdentifiers
            self.changeCount = changeCount
        }
    }

    /// Facts observed before a privacy short-circuit. There is intentionally
    /// no capture or payload field.
    public struct Concealed: Sendable, Equatable {
        public let markerTypeIdentifier: String
        public let changeCount: Int

        fileprivate init(markerTypeIdentifier: String, changeCount: Int) {
            self.markerTypeIdentifier = markerTypeIdentifier
            self.changeCount = changeCount
        }
    }

    /// Facts of an unsupported multi-item clipboard. There is intentionally
    /// no capture or payload field.
    public struct UnsupportedMultiItem: Sendable, Equatable {
        public let itemCount: Int
        public let changeCount: Int

        fileprivate init(itemCount: Int, changeCount: Int) {
            self.itemCount = itemCount
            self.changeCount = changeCount
        }
    }

    /// The two generations around an unstable read. There is intentionally
    /// no capture, unavailable-type, or provider-reason field.
    public struct ChangedDuringRead: Sendable, Equatable {
        public let startChangeCount: Int
        public let endChangeCount: Int

        fileprivate init(startChangeCount: Int, endChangeCount: Int) {
            self.startChangeCount = startChangeCount
            self.endChangeCount = endChangeCount
        }
    }
}

/// The typed failure of a paste write (03b §9; 04 §8; audit SPEC-IMPL-005).
public enum PasteboardWriteFailure: Error, Sendable, Equatable {
    /// One or more setters rejected a representation while building the
    /// unbound item. Carries every refused type identifier in staging order:
    /// payload representations first, the lineage-hint marker type last.
    /// This failure occurs before the existing pasteboard is changed.
    case representationsRejected(typeIdentifiers: [String])

    /// The framework rejected the one completed item passed to
    /// `writeObjects`. This is a distinct post-clear failure; the framework
    /// does not promise rollback or cross-process atomicity.
    case itemRejected
}
