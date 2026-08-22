/// §10 atomic transaction execution and its invariant guards.
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension HistoryAuthority {
    // MARK: Transaction execution (docs/05-authority-kernel.md §10)

    /// The one durable History Commit primitive (§10), shared by every
    /// stamped plan: fetch the singleton inside the closure, guard the
    /// expected previous position, apply every stamped mutation in order,
    /// revalidate the final pin order, append the plan's one HCR, fire the
    /// armed test injection if any, and write the singleton position last —
    /// all in one `ModelContext.transaction`.
    ///
    /// Rules (§10): no `await` in the closure or between fact load and
    /// closure completion; production lookups fetch rows by business ID
    /// (never `registeredModel(for:)`); delete fetches the actual row; every
    /// referenced row exists exactly once unless the stamped case is create;
    /// trusted fixture creates may use the equivalent complete-index absence
    /// proof validated by `executeStampedPlan` above;
    /// closure failure commits nothing — there is no receipt, index delta,
    /// or invalidation; closure success is the save boundary, with no
    /// trailing `save()`/`processPendingChanges()`/`rollback()`.
    ///
    /// - Throws: `.temporarilyUnavailable(.insufficientDiskSpace)` for a
    ///   Cocoa out-of-space/POSIX `ENOSPC` transaction failure; otherwise
    ///   `.persistence(.transaction)` for closure or framework failure (§16).
    internal func executeCommitTransaction(
        _ plan: StampedCommitPlan,
        expectedPreviousPosition: ChangePosition,
        in context: ModelContext,
        createExistenceProof: CreateExistenceProof
    ) throws {
        do {
            try context.transaction {
                let meta = try Self.fetchExactlyOnePositionRow(in: context)
                let positionChangedInjected = self.consumeTransactionFailureInjection(
                    .positionChanged
                )
                guard !positionChangedInjected,
                      meta.rawValue == expectedPreviousPosition.rawValue
                else {
                    throw StorageInvariant.positionChanged
                }
                // V2-02 §3.3 (roadmap R.3, perf discipline): when the plan
                // retires items, supply every `.delete` with its 1:1
                // projection row from ONE bounded scalar fetch — a per-item
                // predicate fetch during mass retirement degrades the
                // commit to a scan per delete (§9 bullet 5's
                // retentionMassEviction envelope). Nil when the plan
                // retires nothing.
                let bytesRowsByItem = try RetainedBytesStamping
                    .prefetchRowsForRetirements(
                        in: plan.mutations, context: context
                    )
                for mutation in plan.mutations {
                    try self.apply(
                        mutation,
                        in: context,
                        positionRow: meta,
                        createExistenceProof: createExistenceProof,
                        bytesRowsByItem: bytesRowsByItem
                    )
                }
                if plan.requiresFinalPinOrderValidation {
                    try self.validateFinalPinOrder(in: context)
                }
                // X-HCR.2 WS-J1-5 window (a): one-shot test failure after
                // item mutation/final-pin proof but before HCR staging.
                if self.consumeTransactionFailureInjection(.beforeHCRAppend) {
                    throw InjectedTransactionFailure.beforeHCRAppend
                }
                // DC-25/J.3: every non-empty stamped plan carries exactly one
                // HCR derived from the same explicit mutations. Stage it (and
                // any fixed-limit oldest-prefix trim) before the existing
                // failure injections and position-last write, so closure
                // failure rolls back item rows, HCR, config counters, and
                // Change Position together.
                try HCRStore.append(
                    plan.hcrAppend,
                    expectedPreviousPosition: expectedPreviousPosition,
                    in: context
                )
                // X-HCR.2 WS-J1-5 window (b): the existing WS13 one-shot
                // failure now sits after HCR staging and before the singleton
                // update. Disarmed (nil) in production.
                if self.consumeTransactionFailureInjection(.beforeSingletonUpdate) {
                    throw InjectedTransactionFailure.beforeSingletonUpdate
                }
                if self.consumeTransactionFailureInjection(.insufficientDiskSpace) {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: CocoaError.Code.fileWriteOutOfSpace.rawValue
                    )
                }
                // The singleton position is written last, inside the same
                // transaction (§10, D6).
                meta.rawValue = plan.position.rawValue
            }
        } catch {
            // §16: a `ModelContext.transaction` closure failure (including
            // the `StorageInvariant.positionChanged` guard) or any
            // framework-level failure to durably commit the transaction.
            // Only a platform domain/code proof of exhausted disk space gets
            // the narrower retryable failure.
            throw PersistenceErrorClassification.transactionFailure(for: error)
        }
    }

    /// Applies one stamped mutation to the transaction context.
    /// docs/05-authority-kernel.md §9 (rename table), §10 (executor rules)
    ///
    /// Every payload is already absolute — the Authority never infers hidden
    /// behavior from a case (docs/02-domain.md D18). Production and
    /// non-create fetches go through the bounded business-ID lookup (§5);
    /// the trusted fixture create case arrives with the complete-index proof
    /// checked by the shared commit tail. A missing referenced row, a
    /// duplicate create ID, or a revision base-version mismatch is
    /// `TransactionApplyRejection`, remapped to `.persistence(.transaction)`
    /// with every other closure failure (§16). Revision IDs are unique by
    /// construction (a freshly minted candidate ID appended to a validated
    /// unique-ID list) and re-verified at every decode (§4); the OCC check
    /// here is the interleaving guard (§9 `expectedCurrentVersion`).
    internal func apply(
        _ mutation: StampedMutation,
        in context: ModelContext,
        positionRow: LastChangePositionRow,
        createExistenceProof: CreateExistenceProof,
        bytesRowsByItem: [UUID: RetainedBytesRow]? = nil
    ) throws {
        switch mutation {
        case .create(let item):
            let duplicateCreateInjected = consumeTransactionFailureInjection(
                .duplicateCreateID
            )
            if case .durableLookup = createExistenceProof {
                let existingRow = try HistoryItemRowHydration.fetchRow(
                    businessID: item.id,
                    in: context
                )
                guard existingRow == nil else {
                    throw TransactionApplyRejection.duplicateCreateID(
                        itemID: item.id
                    )
                }
            }
            guard !duplicateCreateInjected else {
                throw TransactionApplyRejection.duplicateCreateID(itemID: item.id)
            }
            context.insert(Self.makeRow(for: item))
            // V2-02 §3.3b (roadmap R.3): the capture-insert projection stamp
            // — same `ModelContext.transaction` as the row insert above
            // ("durable derived value stamped in the same
            // `ModelContext.transaction` as the blob it summarizes").
            // Mandatory maintenance regardless of policies (§4.1: the
            // projection is maintained 1:1 even while every policy is
            // disabled); the capture COMPOSITION (R1/R2 planning) is R.4 and
            // is deliberately absent here.
            try RetainedBytesStamping.stampForInsert(
                for: item,
                limits: limits,
                in: context
            )

        case .updateOccurrence(let itemID, let occurrence):
            // Content Version and projections are preserved by absence from
            // the stamped payload (§9; docs/02-domain.md §13).
            let row = try requireRow(itemID, in: context)
            row.firstCopiedAt = occurrence.firstCopiedAt
            row.lastCopiedAt = occurrence.lastCopiedAt
            row.copyCount = occurrence.count
            row.firstSource = occurrence.firstSource
            row.lastSource = occurrence.lastSource

        case .setPinOrdinal(let itemID, let ordinal):
            let row = try requireRow(itemID, in: context)
            row.pinOrdinal = ordinal

        case .appendRevision(let update):
            let row = try requireRow(update.itemID, in: context)
            let versionMismatchInjected = consumeTransactionFailureInjection(
                .contentVersionMismatch
            )
            guard !versionMismatchInjected,
                  row.contentVersionRaw == update.expectedCurrentVersion.rawValue
            else {
                throw TransactionApplyRejection.contentVersionMismatch(
                    itemID: update.itemID
                )
            }
            // Revision state, Content Version, and effective projections are
            // written together (§10).
            row.contentVersionRaw = update.nextVersion.rawValue
            row.revisionStateBlob = update.revisionStateBlob
            row.projectionSchemaVersion = update.projection.schemaVersion
            row.title = update.projection.title
            row.searchBody = update.projection.searchBody
            row.effectiveTypeIdentifiersBlob = update.effectiveTypeIdentifiersBlob
            // V2-02 §3.3b/§6.3 (roadmap R.3): the revise restamp — the
            // revision scalars move to the post-append value stamped from
            // the same list the blob was encoded from; `canonicalBytes` is
            // untouched (Canonical Content never changes after insert, D2).
            try RetainedBytesStamping.restamp(
                itemID: update.itemID,
                revisionScalars: update.retainedRevisionScalars,
                in: context
            )

        case .delete(let itemID, _):
            // §10: delete fetches the actual row — no predicate delete over
            // pending state. v1 writes no tombstone (docs/02-domain.md D15).
            let row = try requireRow(itemID, in: context)
            context.delete(row)
            // V2-02 §3.3/§3.4 (roadmap R.3): the V2-extended `.delete`
            // stamping also removes the 1:1 `RetainedBytesRow` in the same
            // `ModelContext.transaction` — an explicit step, never a
            // `@Relationship` on the frozen v1 model. Applies to every
            // retirement reason (user removal, clear, retention). The row
            // comes from the transaction's one bounded prefetch when the
            // plan retires items (see `prefetchRowsForRetirements`).
            try RetainedBytesStamping.deleteRow(
                itemID: itemID, in: context, prefetched: bytesRowsByItem
            )

        case .setRetentionPolicy(let maximumUnpinnedItems):
            // The singleton owns the current v1 retention policy (§3.2);
            // the value was validated when the action entered (§2).
            positionRow.maximumUnpinnedItems = maximumUnpinnedItems

        case .pruneRevisions(let itemID, let revisionStateBlob, let revisionScalars):
            // V2-02 §5.3/§5.5 execution (roadmap R.3): rewrite the row's
            // `revisionStateBlob` with the pruned blob (fewer revisions,
            // same `activeRevisionID`, `formatVersion == 1`), preserving its
            // `contentVersionRaw` and projections (R3 alone advances no
            // ContentVersion; neither Effective Content nor its projection
            // changes, §5.2) — and restamp the 1:1 `RetainedBytesRow`
            // projection to the post-prune value in the same transaction
            // (§3.3b/§6.3). The stamped payload already carries the
            // recomputed scalars and the re-encoded blob, so the executor
            // performs no lineage decode. The revise+R3 plan (roadmap R.5)
            // never reaches this arm — its prune is folded into the
            // `.appendRevision` blob write at stamp-emission time (§6.3
            // compose-with-append, `RET-STAMP-1`) — so the producer of this
            // row is the R.6 `.setRetentionPolicies` sweep (`RET-STAMP-2`),
            // whose composer drops prunes for items the same commit retires
            // before the plan exists.
            let row = try requireRow(itemID, in: context)
            row.revisionStateBlob = revisionStateBlob
            try RetainedBytesStamping.restamp(
                itemID: itemID,
                revisionScalars: revisionScalars,
                in: context
            )

        case .setRetentionPolicies(let policies):
            // V2-02 §5.6 execution (roadmap R.6, policy sweep): fetch the
            // `RetentionExpansionConfigRow` singleton and write the normalized
            // policy fields — an enabled flag plus in-range value per lane, a
            // `nil` lane mapping to the disabled shape with its dormant value
            // zeroed and its R3 thresholds nil (the exact §3.1/§5.6
            // normalization the boundary already validated) — leaving
            // `configSchemaVersion` at 1 and preserving every item row,
            // `ContentVersion`, and projection (§5.6: "no item row is
            // touched"). The plan-level singleton position guard checked at
            // the top of this closure is the concurrency protection, exactly
            // as v1 `.setRetentionPolicy` (which likewise carries no position
            // field, §5.6).
            let configRow = try Self.fetchRetentionConfigRow(in: context)
            configRow.agePolicyEnabled = policies.age != nil
            configRow.ageMaxSeconds = policies.age?.maxAge ?? 0
            configRow.storagePolicyEnabled = policies.storage != nil
            configRow.storageMaxBytes = policies.storage?.maxTotalBytes ?? 0
            configRow.revisionPolicyEnabled = policies.revisions != nil
            configRow.revisionMaxCount = policies.revisions?.maxRevisionsPerItem
            configRow.revisionMaxBytes = policies.revisions?.maxRevisionBytesPerItem
        }
    }

    /// The single mapping from an encoded create payload to the SwiftData
    /// model. Both durable-lookup and trusted fixture creates use it, so the
    /// performance seam cannot drift into a second row representation.
    internal static func makeRow(for item: StoredNewItem) -> HistoryItemRow {
        HistoryItemRow(
            id: item.id.rawValue,
            contentVersionRaw: item.contentVersion.rawValue,
            canonicalBlob: item.canonicalBlob,
            revisionStateBlob: item.revisionStateBlob,
            canonicalSignatureBlob: item.canonicalSignatureBlob,
            projectionSchemaVersion: item.projection.schemaVersion,
            title: item.projection.title,
            searchBody: item.projection.searchBody,
            effectiveTypeIdentifiersBlob: item.effectiveTypeIdentifiersBlob,
            firstCopiedAt: item.occurrence.firstCopiedAt,
            lastCopiedAt: item.occurrence.lastCopiedAt,
            copyCount: item.occurrence.count,
            firstSource: item.occurrence.firstSource,
            lastSource: item.occurrence.lastSource,
            pinOrdinal: nil
        )
    }

    /// Fetches the unique row a non-create stamped mutation references, or
    /// throws `TransactionApplyRejection.missingRow` (§10). A duplicate
    /// business ID or a framework fetch failure surfaces from the hydration
    /// helper already typed and is remapped with every other closure failure
    /// (§16).
    internal func requireRow(
        _ itemID: HistoryItemID,
        in context: ModelContext
    ) throws -> HistoryItemRow {
        let row = try HistoryItemRowHydration.fetchRow(
            businessID: itemID,
            in: context
        )
        let missingRowInjected = consumeTransactionFailureInjection(.missingRow)
        guard !missingRowInjected, let row else {
            throw TransactionApplyRejection.missingRow(itemID: itemID)
        }
        return row
    }

    /// §10: revalidates the final pinned order inside the transaction
    /// closure — ordinals non-negative, unique, and exactly `0 ..< p` (D12)
    /// — before closure success. The fetch is scalar (`pinOrdinal` only) and
    /// bounded by the hard retained-item maximum (§7.3). It runs only for a
    /// plan that may affect the pinned lane, and uses the same verified
    /// optional-ordinal predicate as the recent pinned-lane fetch (§14.1).
    internal func validateFinalPinOrder(in context: ModelContext) throws {
        var descriptor = FetchDescriptor<HistoryItemRow>(
            predicate: #Predicate { $0.pinOrdinal != nil }
        )
        descriptor.propertiesToFetch = [\.pinOrdinal]
        descriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let rows: [HistoryItemRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw TransactionApplyRejection.finalPinOrderViolated
        }
        guard rows.count <= limits.hardMaximumRetainedItems else {
            throw TransactionApplyRejection.finalPinOrderViolated
        }
        var ordinals: [Int] = []
        ordinals.reserveCapacity(rows.count)
        for row in rows {
            guard let ordinal = row.pinOrdinal else { continue }
            guard ordinal >= 0 else {
                throw TransactionApplyRejection.finalPinOrderViolated
            }
            ordinals.append(ordinal)
        }
        if consumeTransactionFailureInjection(.finalPinOrderViolated) {
            // The seam changes only this operation-local scalar proof value;
            // it never manufactures or persists a corrupt `@Model` row.
            ordinals.append(Int.max)
        }
        guard PinnedOrderValidator.sourceOffsetsByOrdinal(
            in: ordinals,
            ordinal: { $0 }
        ) != nil else {
            throw TransactionApplyRejection.finalPinOrderViolated
        }
    }

}
