/// ClipboardHistory.swift — the public History interface: the single protocol
/// every caller (UI, paste coordination, previews) talks to.
/// Owning spec: docs/03a-instruction-set.md §3 (Part III — Caller Interface A);
/// interface guarantees: docs/03b-instruction-set.md §11.
/// Foundation-only; no persistence, Domain aggregate, fingerprint, framework
/// object, or service locator (03a §1).
import Foundation

/// The complete public interface between callers and retained History.
///
/// Owning spec: docs/03a-instruction-set.md §3.
///
/// `SwiftDataHistory` is the production implementation. UI previews may use a
/// scripted implementation, which must itself conform to `Sendable` (because
/// `ClipboardHistory: Sendable`) and must not be used as a substitute for
/// storage semantic tests.
///
/// Interface guarantees (docs/03b-instruction-set.md §11): a `.committed`
/// receipt from `perform` returns only after the durable transaction, and a
/// later call begun after that receipt observes at least its `ChangePosition`;
/// `observe` emits complete replacement pages, not deltas; read APIs resolve
/// current item/version semantics or fail typed — they never label new bytes
/// with an old Content Version.
public protocol ClipboardHistory: Sendable {
    /// Performs one mutating History Action.
    ///
    /// Returns `.unchanged` for no-op actions (no durable mutation, no
    /// position, no invalidation); a `.committed` receipt returns only after
    /// the durable transaction, mandatory index update, and internal
    /// invalidation publication. Failures return no receipt — they throw a
    /// typed `HistoryFailure`.
    ///
    /// docs/03a-instruction-set.md §3; guarantees docs/03b-instruction-set.md
    /// §11 items 1–3.
    func perform(_ action: HistoryAction) async throws -> HistoryReceipt

    /// One-shot browse: recent rows or a search, optionally continuing after
    /// a cursor from an earlier page.
    ///
    /// The returned page identifies the durable snapshot position its values
    /// were captured from. A cursor from an older position — or one whose
    /// query shape no longer matches — fails explicitly as
    /// `.snapshotExpired(current:)` rather than silently skipping or
    /// repeating items.
    ///
    /// docs/03a-instruction-set.md §3, §7; guarantees
    /// docs/03b-instruction-set.md §11 items 4 and 6.
    func browse(
        _ request: HistoryBrowseRequest
    ) async throws -> HistoryPage

    /// Observes the current first page for one query, emitting complete
    /// replacement pages (not deltas) as retained History changes.
    ///
    /// Observation intentionally has no cursor: additional pages are one-shot
    /// `browse` requests. The v1 surface deliberately uses an untyped stream
    /// failure because that is the frozen Part III contract; implementations
    /// still throw `HistoryFailure`, so callers that need its cases must cast
    /// the received `Error` to `HistoryFailure`.
    ///
    /// docs/03a-instruction-set.md §3, §7; guarantee
    /// docs/03b-instruction-set.md §11 item 5.
    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error>

    /// Full detail for one retained item: Canonical and Effective Content,
    /// revision summaries, occurrence summary, and pin position.
    ///
    /// Detail is the only general UI query that returns content lineage
    /// bytes. It resolves the requested current item or throws a typed
    /// not-found failure.
    ///
    /// docs/03a-instruction-set.md §3; docs/03b-instruction-set.md §9;
    /// guarantee docs/03b-instruction-set.md §11 item 7.
    func details(
        for id: HistoryItemID
    ) async throws -> HistoryDetails

    /// The paste payload for one retained item: current Effective Content
    /// only, plus the item's lineage hint.
    ///
    /// docs/03a-instruction-set.md §3; docs/03b-instruction-set.md §9;
    /// guarantee docs/03b-instruction-set.md §11 item 7.
    func pastePayload(
        for id: HistoryItemID
    ) async throws -> PastePayload

    /// An encoded thumbnail for one item at one Effective Content state,
    /// sized to `pixels`; `nil` when no supported image representation exists.
    /// A selected image that cannot be decoded throws `.thumbnailUnavailable`;
    /// its raw bytes remain readable and pasteable.
    ///
    /// Returns encoded, Sendable bytes rather than `NSImage`/`CGImage`. A
    /// stale `item` reference fails typed rather than returning current bytes
    /// under the old Content Version.
    ///
    /// docs/03a-instruction-set.md §3; docs/03b-instruction-set.md §9;
    /// guarantee docs/03b-instruction-set.md §11 item 7.
    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload?

    /// The authoritative configured retention state: the v1 maximum-unpinned
    /// count plus the V2-02 age/storage/revision dimensions, exactly as
    /// persisted.
    ///
    /// This is the settings surface's panel-open read (docs/v2/V2-07-ux.md
    /// §6.3 — a one-shot read per §4.2.2): it returns the CONFIGURED policy,
    /// never a live current-retained-bytes usage value, which the public
    /// surface deliberately does not expose (V2-07 §2.2 OPEN-2; `V2-02`
    /// §8.1). It reads the same durable singletons the mutation paths write
    /// (docs/05-authority-kernel.md §3.2; `V2-02` §3.3), so the value read
    /// here is the value a later `.setRetentionPolicy` /
    /// `.setRetentionPolicies` compares against, and the §11 read-after-
    /// commit guarantee applies unchanged. Extension-by-addition to the read
    /// surface — the same posture as the `V2-00` §8(h) enum-case additions.
    /// Ordinary callers are unaffected, but adding a protocol requirement is
    /// an intentionally owned Swift source break for conformers; every
    /// repository conformer is kept exhaustive and no default implementation
    /// may fabricate configured values. Failures are typed `HistoryFailure`s
    /// exactly as the other reads (a corrupted singleton fails closed as
    /// `.persistence(...)`, never as a default value).
    ///
    /// docs/v2/V2-02-retention.md §8.1/§12;
    /// docs/v2/V2-07-ux.md §5.2; audit: docs/reviews/
    /// 2026-08-20-clipy-maccy-audit/02-spec-implementation.md SPEC-IMPL-003.
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration
}
