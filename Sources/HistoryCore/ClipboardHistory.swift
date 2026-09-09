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
/// `SQLiteHistory` is the production implementation. UI previews may use a
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

    /// Metadata for one retained item: title, Canonical/Effective representation
    /// descriptors, revision summaries, occurrence and pin position. This read
    /// opens no content payloads; it resolves the current item or fails typed.
    ///
    /// docs/03a-instruction-set.md §3; docs/03b-instruction-set.md §9;
    /// guarantee docs/03b-instruction-set.md §11 item 7.
    func details(
        for id: HistoryItemID
    ) async throws -> HistoryDetails

    /// Up to 32 application copy summaries for one item, read only when
    /// requested. An occurrence-count change expires the page so an offset
    /// cannot silently skip/repeat sources after recency reorders them.
    func copySources(
        for id: HistoryItemID, expectedCopyCount: UInt64, offset: Int
    ) async throws -> HistoryCopySourcePage

    /// Reads only the requested representation. The item must still exist at
    /// the supplied Content Version before any payload access. A stale request
    /// throws `.staleContent`; an absent representation throws
    /// `.invalidInput(.unsupportedRepresentationType(...))`. The returned type
    /// identifier retains its stored spelling. V2-09 §5.
    func representation(
        _ request: HistoryRepresentationRequest
    ) async throws -> HistoryRepresentation

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

    /// Current retained counts and logical content bytes from one coherent
    /// snapshot. Counts include pinned items; revision bytes include every
    /// retained revision. These are content totals, not physical disk usage.
    /// The read-after-commit guarantee applies as for other History reads.
    func usage() async throws -> HistoryUsage

    /// Creates a consistent backup in a new directory, containing
    /// `history.sqlite` and `history.sqlite-content`. The parent must exist;
    /// an existing destination is never overwritten. A failed or cancelled
    /// operation removes only the directory that operation created.
    /// The sole writer serializes the complete metadata/file copy so the
    /// receipt identifies exactly the exported snapshot.
    func backup(to directory: URL) async throws -> HistoryBackupReceipt

    /// The authoritative configured retention state: the v1 maximum-unpinned
    /// count plus the V2-02 age/storage/revision dimensions, exactly as
    /// persisted.
    ///
    /// This is the settings surface's panel-open read (docs/v2/V2-07-ux.md
    /// §6.3 — a one-shot read per §4.2.2): it returns the configured policy.
    /// The separate `usage()` read returns retained counts and content bytes.
    /// Configuration reads the same durable singletons the mutation paths write
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
