/// Item detail/paste reads (§14), thumbnail source (§14.5), and read-path helpers.
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

/// Content-free accounting for one current-layout thumbnail source read.
///
/// `returnedRepresentationBytes` is the one selected image value handed to
/// the decode lane. `aggregateHydratedBytes` is the encoded Canonical plus
/// revision-state aggregate the monolithic row layout made the Authority
/// access while selecting that value. The latter is not RSS, copied bytes, or
/// physical I/O, and the two counters must not be substituted for each other.
/// REVIEW `PLAY-TIER-2A-THUMB`; tiered-storage DESIGN-TIER-2A.
internal struct ThumbnailSourceHydrationReceipt: Sendable {
    internal let returnedRepresentationBytes: Int
    internal let aggregateHydratedBytes: Int
}

/// Existing thumbnail-purpose source shape: exactly one selected immutable
/// representation plus content-free current-layout accounting. This is local
/// to HistoryStorage's already-shipped thumbnail lane; it is not a general
/// content reader or a claim of representation-shaped physical storage.
internal struct ThumbnailSourceSelection: Sendable {
    internal let bytes: Data
    internal let receipt: ThumbnailSourceHydrationReceipt
}

extension HistoryAuthority {
    internal func details(for id: HistoryItemID) async throws -> HistoryDetails {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try details(for: id, in: context)
    }

    /// Synchronous V1 detail projection for an Authority caller that already
    /// owns the operation-local context. X.6 uses it after the live grant gate
    /// and before the audit append in that same non-suspending interval.
    internal func details(
        for id: HistoryItemID,
        in context: ModelContext
    ) throws -> HistoryDetails {
        try detailsAndTitle(for: id, in: context).details
    }

    /// X.7's external detail projection. The durable Effective title and the
    /// complete V1 lineage DTO are read from one fetched row in one gated
    /// Authority interval; no follow-up History query can observe a different
    /// content version.
    internal func externalDetails(
        for id: HistoryItemID,
        in context: ModelContext
    ) throws -> ExternalHistoryDetails {
        let projection = try detailsAndTitle(for: id, in: context)
        return ExternalHistoryDetails(
            details: projection.details,
            title: projection.title
        )
    }

    private func detailsAndTitle(
        for id: HistoryItemID,
        in context: ModelContext
    ) throws -> (details: HistoryDetails, title: String) {

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context or fetched row is live. ──

        guard let row = try HistoryItemRowHydration.fetchRow(
            businessID: id,
            in: context
        ) else {
            throw HistoryFailure.notFound(id)
        }
        let item = try HistoryItemRowHydration.hydrate(row, limits: limits)

        // Derive current Effective Content (docs/02-domain.md §2.6).
        let effective: EffectiveContent
        do {
            effective = try effectiveContent(of: item)
        } catch is DomainRejection {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // Map Canonical representations.
        let canonicalRepresentations = item.canonical.representations.map {
            representation in
            HistoryRepresentation(
                typeIdentifier: representation.content.typeIdentifier,
                bytes: representation.content.bytes
            )
        }
        // Map Effective representations.
        let effectiveRepresentations = effective.representations.map {
            representation in
            HistoryRepresentation(
                typeIdentifier: representation.typeIdentifier,
                bytes: representation.bytes
            )
        }
        // Map every stored revision.
        let revisionSummaries = item.revisions.map { revision -> RevisionSummary in
            let revisionTypeIdentifiers = revision.content.representations.map(
                \.typeIdentifier
            )
            let byteCount = revision.content.representations.reduce(0) {
                $0 + $1.bytes.count
            }
            let isActive = revision.id == item.activeRevisionID
            // The fetched row already carries the validated projection of
            // this exact Effective Content (05 §14.3/§15). Reuse it for the
            // active summary instead of decoding its text again on read.
            // Inactive revisions still need their own title projection.
            let revisionTitle = isActive
                ? row.title
                : ContentProjector.projectTitle(revision.content, limits: limits)
            return RevisionSummary(
                id: revision.id,
                createdAt: revision.createdAt,
                isActive: isActive,
                title: revisionTitle,
                typeIdentifiers: revisionTypeIdentifiers,
                byteCount: byteCount
            )
        }
        let occurrence = CopyOccurrenceSummary(
            firstCopiedAt: item.occurrence.firstCopiedAt,
            lastCopiedAt: item.occurrence.lastCopiedAt,
            count: item.occurrence.count,
            firstSource: item.occurrence.firstSource,
            lastSource: item.occurrence.lastSource
        )
        return (
            HistoryDetails(
                item: HistoryItemReference(
                    id: item.id,
                    contentVersion: item.contentVersion
                ),
                canonical: canonicalRepresentations,
                effective: effectiveRepresentations,
                revisions: revisionSummaries,
                occurrence: occurrence,
                pinnedPosition: item.pinOrdinal?.rawValue
            ),
            row.title
        )
    }

    /// Paste payload (docs/05-authority-kernel.md §14.3; docs/04-coherence.md
    /// §8): fetches exactly one row, decodes/validates its full lineage, and
    /// maps current Effective Content plus the current reference and lineage
    /// hint.
    ///
    /// One non-suspending read interval: no WS12 seam — paste is a one-shot
    /// caller query, not an observe-loop step.
    ///
    /// - Throws: `.notFound(id)` when the target is not retained; the codec
    ///   decode mappings (`.persistence(.corruptStoredValue)`, §4/§16);
    ///   `.temporarilyUnavailable(.factProof)` for a framework fetch failure;
    ///   `.persistence(.invariantViolation)` for corrupt lineage
    ///   (`effectiveContent` → `DomainRejection.corruptLineage`).
    internal func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try pastePayload(for: id, in: context)
    }

    /// Synchronous V1 paste projection for a caller-owned Authority context.
    internal func pastePayload(
        for id: HistoryItemID,
        in context: ModelContext
    ) throws -> PastePayload {

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context or fetched row is live. ──

        guard let row = try HistoryItemRowHydration.fetchRow(
            businessID: id,
            in: context
        ) else {
            throw HistoryFailure.notFound(id)
        }
        let item = try HistoryItemRowHydration.hydrate(row, limits: limits)

        let effective: EffectiveContent
        do {
            effective = try effectiveContent(of: item)
        } catch is DomainRejection {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        let representations = effective.representations.map { representation in
            HistoryRepresentation(
                typeIdentifier: representation.typeIdentifier,
                bytes: representation.bytes
            )
        }
        return PastePayload(
            item: HistoryItemReference(
                id: item.id,
                contentVersion: item.contentVersion
            ),
            representations: representations,
            lineageHint: item.id
        )
    }

    // MARK: - Thumbnail source (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9)

    // ThumbnailService.swift owns the off-Authority decode (§9 step 6). This
    // method — the Authority side of the thumbnail
    // single-flight — is the WS15 version fence (docs/06-cross-cutting.md §8).

    /// The frozen v1 set of ImageIO-decodable image type identifiers whose
    /// bytes are eligible as thumbnail source input. docs/04-coherence.md §9
    /// ("supported image representation") — the spec does not enumerate the
    /// set; v1 freezes the concrete decodable UTIs (not the abstract
    /// `public.image`, even though CGImageSource sniffs bytes) so the source
    /// representation is a pure, deterministic function of the content with no
    /// framework conformance lookup. Identifiers are Apple's declared UTType
    /// identifiers verbatim (BMP is `com.microsoft.bmp`; the nonstandard
    /// `public.bmp` matches nothing a real pasteboard declares).
    internal static let thumbnailImageTypeIdentifiers: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.tiff",
        "public.heic",
        "public.heif",
        "com.compuserve.gif",
        "com.microsoft.bmp",
    ]

    /// Existing-flight admission performs only the per-caller checks whose
    /// result may have changed since the creator loaded its source: bounded
    /// dimensions, target existence, and current Content Version. The scalar
    /// projection deliberately excludes content blobs, so C identical callers
    /// perform one complete source hydration plus at most C-1 small fences.
    ///
    /// The creator's full `thumbnailSource` task remains the fail-closed owner
    /// of every lineage/projection/codec check. Join validation failure does
    /// not mutate or cancel that task.
    internal func validateThumbnailFlightJoin(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws {
        try validateThumbnailDimensions(pixels)

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let uuid = item.id.rawValue
        var descriptor = FetchDescriptor<HistoryItemRow>(
            predicate: #Predicate { row in row.id == uuid }
        )
        descriptor.propertiesToFetch = [\.id, \.contentVersionRaw]
        descriptor.fetchLimit = 2
        let rows: [HistoryItemRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
        guard rows.count <= 1 else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        guard let row = rows.first else {
            throw HistoryFailure.notFound(item.id)
        }

        // Bind the immutable scalar before entering the failure-mapping
        // closure; no @Model value crosses a closure or actor boundary.
        let contentVersionRaw = row.contentVersionRaw
        let current = try mapCodecFailure {
            try RevisionStateBlobCodec.decodeContentVersion(contentVersionRaw)
        }
        guard current == item.contentVersion else {
            throw HistoryFailure.staleContent(
                expected: item.contentVersion,
                current: current
            )
        }
    }

    /// Thumbnail source (docs/05-authority-kernel.md §14.5; docs/04-coherence.md
    /// §9): verifies the requested Content Version and returns immutable source
    /// image selection — `nil` when the item has no supported image
    /// representation — inside one non-suspending Authority interval. The
    /// selection carries only that image value plus content-free byte
    /// accounting; the current storage layout still hydrates the complete
    /// Canonical/revision encoded aggregates to choose it.
    ///
    /// The §9 creator flow, steps 2–4 (the Authority's full-load part):
    /// 2. Validate both `pixels` axes before any context, fetch and fully
    ///    hydrate exactly one row, then require
    ///    `hydrated.contentVersion == item.contentVersion` — the version fence.
    /// 3. Derive current Effective Content (§9 step 3) — the same pure
    ///    derivation as `details(for:)` and `pastePayload(for:)`.
    /// 4. Select the first representation (in the Effective Content's
    ///    normalized type order) whose type identifier is in the frozen v1
    ///    image set, and return its immutable `bytes` (§9 step 3→4). No match
    ///    → `nil` (§9 step 4) through the already-installed flight.
    ///
    /// "Steps 2–3 run inside one non-suspending `HistoryAuthority` interval,
    /// so no commit can interleave between the version check (step 2) and the
    /// Effective-Content derivation (step 3)" (docs/04-coherence.md §9). The
    /// version fence is therefore about the off-Authority decode (step 6): if
    /// the item changes during decode, the result is still correctly tagged
    /// with the verified old reference. "A request whose reference was already
    /// stale before step 2 fails there with `.staleContent`; current bytes are
    /// never returned under an old key" (docs/04-coherence.md §9).
    ///
    /// - Throws: `.invalidInput(.invalidPixelSize)` when either `pixels` axis
    ///   is outside `limits.thumbnailDimensionRange` (§16); `.notFound(id)`
    ///   when the target is not retained; `.staleContent(expected:current:)`
    ///   when the item's Content Version already differs from the reference's
    ///   OCC token (§16 OCC mapping); the codec decode mappings
    ///   (`.persistence(.corruptStoredValue)`, §4/§16);
    ///   `.temporarilyUnavailable(.factProof)` for a framework fetch failure
    ///   (§16); `.persistence(.invariantViolation)` for corrupt lineage
    ///   (`effectiveContent` → `DomainRejection.corruptLineage`, mirrored from
    ///   `details(for:)`).
    internal func thumbnailSource(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailSourceSelection? {
        // §9 step 2: validate both dimensions before any context — the fixed
        // Part VI thumbnail-dimension interval (docs/06-cross-cutting.md §2).
        try validateThumbnailDimensions(pixels)

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5; §9 steps 2–3): no `await` past
        //    this line while the context or fetched row is live. No commit can
        //    interleave between the version check and Effective-Content
        //    derivation (docs/04-coherence.md §9). ──

        // §9 step 2: fetch and fully hydrate exactly the target item.
        guard let row = try HistoryItemRowHydration.fetchRow(
            businessID: item.id,
            in: context
        ) else {
            throw HistoryFailure.notFound(item.id)
        }
        // PLAY-TIER-2A-THUMB: the current row layout exposes Canonical and
        // revision content as two encoded aggregate values. Record both exact
        // encoded byte counts before full hydration; this counter deliberately
        // does not pretend to measure SwiftData physical reads, copies, or RSS.
        let (aggregateHydratedBytes, aggregateOverflow) = row.canonicalBlob.count
            .addingReportingOverflow(row.revisionStateBlob.count)
        guard !aggregateOverflow else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        let hydrated = try HistoryItemRowHydration.hydrate(row, limits: limits)

        // §9 step 2: the version fence — a reference already stale before this
        // point fails here; current bytes are never returned under an old key.
        guard hydrated.contentVersion == item.contentVersion else {
            throw HistoryFailure.staleContent(
                expected: item.contentVersion,
                current: hydrated.contentVersion
            )
        }

        // §9 step 3: derive current Effective Content — the same pure
        // derivation as `details(for:)`. A lineage inconsistency maps to
        // `.persistence(.invariantViolation)` (mirrors `details(for:)`'s
        // `catch is DomainRejection` → invariant-violation mapping).
        let effective: EffectiveContent
        do {
            effective = try effectiveContent(of: hydrated)
        } catch is DomainRejection {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // §9 steps 3–4: select the first representation (in the Effective
        // Content's normalized type order) whose type identifier is in the
        // frozen v1 image set. No match → `nil` through the creator's shared
        // source-to-decode task.
        for representation in effective.representations {
            if Self.thumbnailImageTypeIdentifiers.contains(
                representation.typeIdentifier
            ) {
                return ThumbnailSourceSelection(
                    bytes: representation.bytes,
                    receipt: ThumbnailSourceHydrationReceipt(
                        returnedRepresentationBytes: representation.bytes.count,
                        aggregateHydratedBytes: aggregateHydratedBytes
                    )
                )
            }
        }
        return nil
    }

    /// One owner for the Part VI thumbnail dimension envelope. Both the
    /// creator's full source load and an existing-flight caller's scalar join
    /// fence reject invalid dimensions before creating a `ModelContext`.
    internal func validateThumbnailDimensions(_ pixels: PixelSize) throws {
        guard limits.thumbnailDimensionRange.contains(pixels.width),
              limits.thumbnailDimensionRange.contains(pixels.height)
        else {
            throw HistoryFailure.invalidInput(.invalidPixelSize)
        }
    }

    // MARK: - Read-path helpers (docs/05-authority-kernel.md §14; docs/04-coherence.md §6)

    /// Reads the current ChangePosition in a fresh operation-local context
    /// with no suspension — used to supply the `current:` argument of a
    /// `.snapshotExpired` failure raised before the main read interval.
    /// docs/04-coherence.md §6; docs/05-authority-kernel.md §16
    internal func readPositionInLocalContext() throws -> ChangePosition {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )
        return currentPosition
    }

    /// Decodes and validates the cursor's format version, process marker, and
    /// query shape (§6 steps 1–2). The position check (§6 step 3) is deferred
    /// to the caller's non-suspending interval. docs/04-coherence.md §6
    ///
    /// - Throws: `PageCursorRejection` for any decode or marker failure, or a
    ///   shape mismatch (§16). The caller catches this and supplies the
    ///   current position for the `.snapshotExpired(current:)` mapping.
    internal static func decodeCursor(
        _ cursor: HistoryPageCursor,
        request: HistoryBrowseRequest,
        processMarker: UUID
    ) throws -> ResolvedPageCursor {
        let resolved = try PageCursorCodec.decode(cursor, processMarker: processMarker)
        guard resolved.queryShape.matches(request) else {
            throw PageCursorRejection.malformedCursor
        }
        return resolved
    }

    /// Default total-order comparison for scalar browse/search rows: pinned
    /// rows first by `pinOrdinal` ascending, then unpinned by `lastCopiedAt`
    /// descending and History Item ID bytes ascending (03b §8; 04 §7).
    internal static func defaultOrderIsOrdered(
        _ lhs: SearchCorpusRow,
        _ rhs: SearchCorpusRow
    ) -> Bool {
        switch (lhs.pinOrdinal, rhs.pinOrdinal) {
        case (let l?, let r?):
            // Both pinned: pinOrdinal ascending.
            return l < r
        case (_?, nil):
            // Pinned before unpinned.
            return true
        case (nil, _?):
            // Unpinned after pinned.
            return false
        case (nil, nil):
            // Both unpinned: lastCopiedAt DESC, id ASC.
            if lhs.lastCopiedAt != rhs.lastCopiedAt {
                return lhs.lastCopiedAt > rhs.lastCopiedAt
            }
            return lhs.id < rhs.id
        }
    }
}
