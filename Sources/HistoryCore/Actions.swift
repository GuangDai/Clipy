/// Actions.swift — the closed History Action set and revision input values.
/// Owning spec: docs/03a-instruction-set.md §5 (Part III — Caller Interface A).
/// Foundation-only; value semantics; complete for v1 — adding an action is an
/// owned source change across Core, Domain, Storage, and tests (03a §1).
import Foundation

/// The complete, closed set of mutations a caller can request via
/// `ClipboardHistory.perform(_:)`.
///
/// Owning spec: docs/03a-instruction-set.md §5.
///
/// The set is deliberately closed for v1: no generic command protocol, no
/// default cases — every required switch stays compiler-visible.
public enum HistoryAction: Sendable {
    /// Ingests a raw pasteboard observation (03a §4). `HistoryStorage`
    /// validates and prepares it; the capture carries no trusted Domain state.
    case capture(ClipboardCapture)

    /// First pin or reorder of a pinned item. Never accepts a numeric slot;
    /// a placement that produces the existing order is a no-op.
    case placePinned(HistoryItemID, at: PinnedPlacement)

    /// Unpins an item. Unpinning an unpinned item is a no-op.
    case unpin(HistoryItemID)

    /// Removes one retained item entirely.
    case remove(HistoryItemID)

    /// Removes a whole class of retained items (see `ClearScope`).
    case clear(ClearScope)

    /// Requests a new Effective Content state for one item (see
    /// `RevisionRequest`). Callers do not mint the new Revision ID or
    /// timestamp.
    case revise(RevisionRequest)

    /// Sets the retention cap on unpinned items.
    case setRetentionPolicy(maximumUnpinnedItems: Int)
}

/// A pinned-order placement for `HistoryAction.placePinned`.
///
/// Owning spec: docs/03a-instruction-set.md §5.
public enum PinnedPlacement: Sendable, Hashable {
    /// Front of the pinned lane.
    case first

    /// Back of the pinned lane.
    case last

    /// Directly before the given anchor, which must name a different retained
    /// pinned item.
    case before(HistoryItemID)
}

/// Which retained items `HistoryAction.clear` removes.
///
/// Owning spec: docs/03a-instruction-set.md §5.
public enum ClearScope: Sendable, Hashable {
    /// All unpinned items; pinned items are retained.
    case unpinned

    /// Everything, including pinned items.
    case all
}

/// A revision request: one item, one expected base version, one intent.
///
/// Owning spec: docs/03a-instruction-set.md §5.
///
/// `expected` is the optimistic-concurrency token: the Content Version the
/// caller based its edit on. Callers do not mint the new Revision ID or
/// timestamp.
public struct RevisionRequest: Sendable {
    public let itemID: HistoryItemID
    public let expected: ContentVersion
    public let intent: RevisionIntent

    public init(
        itemID: HistoryItemID,
        expected: ContentVersion,
        intent: RevisionIntent
    ) {
        self.itemID = itemID
        self.expected = expected
        self.intent = intent
    }
}

/// What a revision does: author a new draft, or revert to an existing state.
///
/// Owning spec: docs/03a-instruction-set.md §5.
public enum RevisionIntent: Sendable {
    /// Authors a new revision from explicit per-type decisions.
    case replace(RevisionDraft)

    /// Reverts Effective Content to the canonical state or a prior revision.
    case revert(to: RevisionTarget)
}

/// The state a `.revert` intent targets.
///
/// Owning spec: docs/03a-instruction-set.md §5.
public enum RevisionTarget: Sendable, Hashable {
    /// The item's Canonical Content.
    case canonical

    /// A prior retained revision.
    case revision(RevisionID)
}

/// A replace draft: one explicit decision for every Canonical type and no
/// decision for a foreign type.
///
/// Owning spec: docs/03a-instruction-set.md §5.
///
/// The proposed Effective Content must remain non-empty — a draft that hides
/// every Canonical type is rejected as `invalidInput(.incoherentRevisionDraft)`.
public struct RevisionDraft: Sendable, Hashable {
    public let decisions: [RevisionDecision]

    public init(decisions: [RevisionDecision]) {
        self.decisions = decisions
    }
}

/// One per-representation-type decision inside a `RevisionDraft`.
///
/// Owning spec: docs/03a-instruction-set.md §5.
public struct RevisionDecision: Sendable, Hashable {
    public let typeIdentifier: String
    public let action: RevisionDecisionAction

    public init(
        typeIdentifier: String,
        action: RevisionDecisionAction
    ) {
        self.typeIdentifier = typeIdentifier
        self.action = action
    }
}

/// How one Canonical representation type flows into the proposed Effective
/// Content (resolution performed by `RevisionPreparationActor`, Part V §6.2).
///
/// Owning spec: docs/03a-instruction-set.md §5.
public enum RevisionDecisionAction: Sendable, Hashable {
    /// Carries the Canonical representation's bytes into Effective unchanged.
    case inheritCanonical

    /// Omits the representation from Effective Content entirely. The
    /// Canonical representation is retained for lineage and general-lane
    /// dedup; hiding never changes Canonical Content or its signature. Hidden
    /// types do not appear in `HistoryDetails.effective` or `PastePayload`;
    /// a later revision's `.inheritCanonical` or `.replace` restores them.
    case hide

    /// Substitutes the supplied bytes for that type in Effective.
    case replace(bytes: Data)
}
