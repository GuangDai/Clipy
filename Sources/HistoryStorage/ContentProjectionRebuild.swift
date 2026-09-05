/// Projection recipes v1/v2 → v3 startup rebuild.
/// Owning spec: docs/05-authority-kernel.md §13 (startup order), §15
/// (recipe v3 and the projection-only rebuild boundary).
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

/// A local failure used only by the deterministic transaction-interruption
/// proof. Production startup always passes the default `false` value.
private struct InjectedProjectionRebuildInterruption: Error {}

internal enum ContentProjectionRebuild {
    private struct Replacement {
        let rowIndex: Int
        let projection: ContentProjection
        let identifiersBlob: Data
    }

    /// Rebuilds every legacy projection row before the facade is published.
    ///
    /// The complete row set is bounded before any write. Only tags 1–3
    /// are understood: v3 rows are left untouched, while each v1/v2 row is
    /// derived again from validated Canonical/revision bytes. All legacy scalar
    /// replacements share one transaction, so a later invalid source or a
    /// transaction interruption publishes none of them. Source rejection
    /// preserves its codec mapping; transaction failure maps uniformly to
    /// `.persistence(.transaction)` (§16). This changes no
    /// lineage bytes, Content Version, Change Position, or signature state.
    ///
    /// `failAfterFirstMutation` is the smallest deterministic test seam for
    /// proving transaction rollback. Public startup never enables it.
    internal static func rebuildIfNeeded(
        in context: ModelContext,
        limits: HistoryLimits,
        failAfterFirstMutation: Bool = false
    ) throws {
        var descriptor = FetchDescriptor<HistoryItemRow>()
        descriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let rows: [HistoryItemRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        guard rows.count <= limits.hardMaximumRetainedItems else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        for row in rows {
            switch row.projectionSchemaVersion {
            case ContentProjector.legacySchemaVersion, 2:
                continue
            case ContentProjector.schemaVersion:
                continue
            default:
                try mapCodecFailure {
                    try ContentProjector.validateStoredSchemaVersion(
                        row.projectionSchemaVersion
                    )
                }
            }
        }

        // Compute every replacement before the transaction. Invalid source
        // bytes therefore retain their codec failure and no row has yet been
        // mutated; the transaction closure below is a mechanical stamp only.
        var replacements: [Replacement] = []
        replacements.reserveCapacity(rows.count)
        for (rowIndex, row) in rows.enumerated() where
            row.projectionSchemaVersion != ContentProjector.schemaVersion
        {
            let canonical = try mapCodecFailure {
                try CanonicalBlobCodec.decode(
                    row.canonicalBlob,
                    limits: limits
                )
            }
            let lineage = try mapCodecFailure {
                try RevisionStateBlobCodec.decode(
                    row.revisionStateBlob,
                    canonical: canonical,
                    limits: limits
                )
            }
            let effective: EffectiveContent
            if let activeRevisionID = lineage.activeRevisionID {
                guard let active = lineage.revisions.first(where: {
                    $0.id == activeRevisionID
                }) else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                effective = active.content
            } else {
                effective = EffectiveContent(
                    representations: canonical.representations.map(\.content)
                )
            }

            let projection = ContentProjector.project(
                effective,
                limits: limits
            )
            let identifiersBlob = try mapCodecFailure {
                try EffectiveTypeIdentifiersBlobCodec.encode(
                    projection.effectiveTypeIdentifiers
                )
            }
            replacements.append(Replacement(
                rowIndex: rowIndex,
                projection: projection,
                identifiersBlob: identifiersBlob
            ))
        }
        guard !replacements.isEmpty else { return }

        do {
            try context.transaction {
                for (mutationIndex, replacement) in replacements.enumerated() {
                    let row = rows[replacement.rowIndex]
                    row.title = replacement.projection.title
                    row.searchBody = replacement.projection.searchBody
                    row.effectiveTypeIdentifiersBlob = replacement.identifiersBlob
                    row.projectionSchemaVersion = replacement.projection.schemaVersion

                    if failAfterFirstMutation, mutationIndex == 0 {
                        throw InjectedProjectionRebuildInterruption()
                    }
                }
            }
        } catch {
            throw HistoryFailure.persistence(.transaction)
        }
    }
}
