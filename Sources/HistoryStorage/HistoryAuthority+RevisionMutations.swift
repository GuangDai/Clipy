/// SQL revision preparation, OCC commit, and count-retention mutations.
/// Canonical/current bytes and requested revert bytes are loaded on demand;
/// all other revisions remain summaries (05 §6.2/§9; V2-09 §4/§6).
import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    internal func revisionPreparationInputs(
        _ request: RevisionRequest
    ) async throws -> (
        snapshot: RevisionPreparationSnapshot,
        retentionPolicies: HistoryRetentionPolicies?
    ) {
        let revertedRevisionID: RevisionID?
        if case .revert(.revision(let id)) = request.intent {
            revertedRevisionID = id
        } else {
            revertedRevisionID = nil
        }
        return try revisionPreparationInputs(
            itemID: request.itemID,
            expected: request.expected,
            revertedRevisionID: revertedRevisionID,
            in: database
        )
    }

    private func revisionPreparationInputs(
        itemID: HistoryItemID,
        expected: ContentVersion,
        revertedRevisionID: RevisionID? = nil,
        in database: SQLiteDatabase
    ) throws -> (
        snapshot: RevisionPreparationSnapshot,
        retentionPolicies: HistoryRetentionPolicies?
    ) {
        guard let metadata = try HistoryItemRowHydration.metadata(
            itemID: itemID, in: database, limits: limits
        ) else {
            throw HistoryFailure.notFound(itemID)
        }
        // Reject stale requests before opening any immutable content file.
        guard expected == metadata.contentVersion else {
            throw HistoryFailure.staleContent(
                expected: expected,
                current: metadata.contentVersion
            )
        }
        let facts = try MutationFactLoaders.loadRevisionFacts(
            itemID: itemID, in: database, blobStore: blobStore, limits: limits
        )
        let revertedContent: EffectiveContent?
        if let revertedRevisionID,
           facts.revisions.contains(where: { $0.id == revertedRevisionID }) {
            if revertedRevisionID == facts.activeRevisionID {
                revertedContent = facts.current
            } else {
                revertedContent = try HistoryItemRowHydration.content(
                    id: revertedRevisionID.rawValue, itemID: itemID,
                    in: database, blobStore: blobStore, limits: limits
                ).content
            }
        } else {
            revertedContent = nil
        }

        return (
            snapshot: RevisionPreparationSnapshot(
                canonical: facts.canonical,
                current: facts.current,
                revisions: facts.revisions,
                activeRevisionID: facts.activeRevisionID,
                contentVersion: facts.contentVersion,
                revertedContent: revertedContent
            ),
            retentionPolicies: try RetentionConfigLoading.loadReviseLanePolicies(
                in: database
            )
        )
    }

    internal func localAutomationRevisionPreparationInputs(
        itemID: HistoryItemID,
        expected: ContentVersion,
        representations: [HistoryRepresentation],
        write: ExternalWriteCommitContext
    ) throws -> (
        request: RevisionRequest,
        snapshot: RevisionPreparationSnapshot,
        retentionPolicies: HistoryRetentionPolicies?
    ) {
        let config = try Self.loadGatewayConfig(in: database)
        switch try Self.targetedExternalAuthorizationDecision(
            write.descriptor, connection: write.connection,
            expectedConnectionKind: .localAutomation, config: config, in: database
        ) {
        case .authorized: break
        case .unknownConnection, .inadmissibleConnection:
            throw ExternalWriteGateRejection.unknownConnection(
                requestedCapability: .reviseContent, connectionID: write.connection
            )
        case .denied(let failure):
            throw ExternalWriteGateRejection.denied(failure)
        }
        guard !representations.isEmpty,
              representations.count <= limits.maximumRepresentationsPerCaptureOrRevision else {
            throw HistoryFailure.invalidInput(.incoherentRevisionDraft)
        }
        let inputs = try revisionPreparationInputs(itemID: itemID, expected: expected, in: database)
        // A complete Effective replacement supplies hidden Canonical types
        // as internal hide decisions without disclosing them to the client.
        let canonicalTypes = Set(inputs.snapshot.canonical.representations.map(\.content.key))
        var bytesByType: [ContentRepresentationKey: Data] = [:]
        for representation in representations {
            let key = ContentRepresentationKey(pasteboardItemIndex: representation.pasteboardItemIndex, typeIdentifier: representation.typeIdentifier)
            guard canonicalTypes.contains(key),
                  !representation.bytes.isEmpty,
                  bytesByType.updateValue(representation.bytes, forKey: key) == nil else {
                throw HistoryFailure.invalidInput(.incoherentRevisionDraft)
            }
        }
        let decisions = inputs.snapshot.canonical.representations.map { canonical in
            let type = canonical.content.typeIdentifier
            return RevisionDecision(
                typeIdentifier: type,
                action: bytesByType[canonical.content.key].map { RevisionDecisionAction.replace(bytes: $0) } ?? .hide,
                pasteboardItemIndex: canonical.content.pasteboardItemIndex
            )
        }
        return (
            RevisionRequest(itemID: itemID, expected: expected, intent: .replace(RevisionDraft(decisions: decisions))),
            inputs.snapshot,
            inputs.retentionPolicies
        )
    }

    internal func revisionPreparationSnapshot(
        _ request: RevisionRequest
    ) async throws -> RevisionPreparationSnapshot {
        try await revisionPreparationInputs(request).snapshot
    }

    internal func commitRevision(
        _ request: RevisionRequest,
        _ bundle: PreparedRevisionBundle,
        externalWrite: ExternalWriteCommitContext? = nil
    ) async throws -> HistoryReceipt {
        await suspendIfRequested(.revisionCommitEntry)

        let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        let facts = try MutationFactLoaders.loadRevisionFacts(
            itemID: request.itemID,
            in: database,
            blobStore: blobStore,
            limits: limits,
            expectedVersion: request.expected
        )

        let planningResult: PlanningResult
        do {
            planningResult = try planRevision(
                request: request,
                prepared: bundle.domain,
                facts: facts
            )
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let v1Plan) = planningResult else {
            if let externalWrite {
                try commitExternalWriteNoOpAudit(externalWrite, in: database)
            }
            return .unchanged
        }

        let mutationPlan = try composeRetentionExpansionForRevision(
            v1Plan,
            bundle: bundle,
            facts: facts,
            in: database
        )

        let stamped: StampedCommitPlan
        do {
            let committedAt = storageClock.now()
            let internalPlan = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .revision(
                    currentVersion: facts.contentVersion,
                    existingRevisions: facts.revisions,
                    projection: bundle.projection,
                    effectiveMatchesCanonical: bundle.effectiveMatchesCanonical
                ),
                createdAt: committedAt
            )
            stamped = try externalWrite.map {
                try Self.attachExternalWriteAudit(to: internalPlan, write: $0, committedAt: committedAt)
            } ?? internalPlan
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: database
        )
    }

    internal func commitRetentionPolicy(
        _ maximumUnpinnedItems: Int?
    ) async throws -> HistoryReceipt {
        guard maximumUnpinnedItems.map(limits.userMaximumUnpinnedRange.contains) ?? true else {
            throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
        }

        let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
        let (currentPosition, currentPolicy) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // V2-09 §4: the aggregate determines the complete victim count.
        // Fetch only that ordered prefix; retained survivors stay in SQLite.
        let state = try database.prepare("""
            SELECT retainedItemCount, pinnedItemCount
            FROM history_state WHERE key = ?
            """, bindings: [.text(Self.positionSingletonKey)])
        defer { state.finalize() }
        guard try state.step() else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let retainedCount = try HistoryItemRowHydration.integer(state, 0)
        let pinnedCount = try HistoryItemRowHydration.integer(state, 1)
        guard retainedCount >= 0,
              pinnedCount >= 0, pinnedCount <= retainedCount else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let victimCount = maximumUnpinnedItems.map { max(0, retainedCount - pinnedCount - $0) } ?? 0
        state.finalize()
        let prefix = try RetentionConfigLoading.retirementPrefix(
            in: database,
            policies: HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil),
            now: storageClock.now(), protectedItemID: nil,
            projectedTotalBytes: RetentionConfigLoading.totalRetainedBytes(in: database),
            minimumRetiredItems: victimCount
        )
        let planningResult = planRetention(
            currentPolicy: currentPolicy,
            policy: RetentionPolicy(maximumUnpinnedItems: maximumUnpinnedItems),
            retirementPrefix: prefix
        )

        guard case .commit(let mutationPlan) = planningResult else {
            return .unchanged
        }

        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none,
                createdAt: storageClock.now()
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: database
        )
    }
}
