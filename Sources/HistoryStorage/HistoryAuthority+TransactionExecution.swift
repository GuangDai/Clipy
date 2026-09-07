import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    /// V2-09 §6: files are published before their references, and History,
    /// Gateway audit, accounting and position commit in one SQLite transaction.
    /// Rollback never deletes old payload files. Post-commit cleanup consults
    /// the actual remaining references before unlinking any immutable file.
    internal func executeCommitTransaction(
        _ plan: StampedCommitPlan,
        expectedPreviousPosition: ChangePosition,
        in database: SQLiteDatabase
    ) throws {
        var publishedNewFiles = false
        var committed = false
        defer {
            if publishedNewFiles && !committed { requestBlobCleanup() }
        }
        do {
            let published = try publishHistoryContent(for: plan) { publishedNewFiles = true }
            try database.writeTransaction {
                let auditConfig = try validateHistoryCommit(
                    expectedPreviousPosition: expectedPreviousPosition,
                    auditAppend: plan.auditAppend, in: database
                )
                for (index, mutation) in plan.mutations.enumerated() {
                    try apply(mutation, published: published[index], in: database)
                }
                if plan.requiresFinalPinOrderValidation {
                    try validateFinalPinOrder(in: database)
                }
                try finishHistoryCommit(
                    position: plan.position, hcrAppend: plan.hcrAppend,
                    expectedPreviousPosition: expectedPreviousPosition,
                    auditAppend: plan.auditAppend, auditConfig: auditConfig, in: database
                )
            }
            committed = true
        } catch let rejection as ExternalWriteGateRejection {
            throw rejection
        } catch let failure as ExternalFailure {
            throw failure
        } catch {
            throw PersistenceErrorClassification.transactionFailure(for: error)
        }
    }

    /// Called inside the real transaction before its first History mutation.
    /// Streaming sweeps and ordinary stamped actions share this position and
    /// live external authorization check; neither opens a nested transaction.
    internal func validateHistoryCommit(
        expectedPreviousPosition: ChangePosition,
        auditAppend: OperationRecordPayload? = nil,
        in database: SQLiteDatabase
    ) throws -> GatewayConfigRow? {
        let meta = try Self.fetchExactlyOnePositionRow(in: database)
        guard !consumeTransactionFailureInjection(.positionChanged),
              meta.rawValue == expectedPreviousPosition.rawValue else {
            throw StorageInvariant.positionChanged
        }
        guard let auditAppend else { return nil }
        guard let connection = auditAppend.connectionID,
              let capability = auditAppend.capability else {
            throw ExternalWriteGateRejection.incoherentPlan
        }
        let connectionKind: ConnectionEnrollKind
        switch capability {
        case .manage:
            connectionKind = .appIntents
        case .organize, .deleteItem, .reviseContent:
            connectionKind = .localAutomation
        case .browse, .readContent, .browsePreview, .readEffectiveContent:
            throw ExternalWriteGateRejection.incoherentPlan
        }
        let config = try Self.loadGatewayConfig(in: database)
        let descriptor = ExternalOperationDescriptor(
            capability: capability, operationKind: auditAppend.operationKind,
            requestSummary: auditAppend.requestSummary
        )
        switch try Self.targetedExternalAuthorizationDecision(
            descriptor, connection: connection, expectedConnectionKind: connectionKind,
            config: config, in: database
        ) {
        case .authorized:
            return config
        case .unknownConnection:
            throw ExternalWriteGateRejection.unknownConnection(
                requestedCapability: capability, connectionID: connection
            )
        case .inadmissibleConnection:
            throw ExternalWriteGateRejection.inadmissibleConnection(
                requestedCapability: capability, connectionID: connection
            )
        case .denied(let failure):
            throw ExternalWriteGateRejection.denied(failure)
        }
    }

    /// The one HCR/audit/position tail inside an already-open SQL transaction.
    /// No observation or immutable-file cleanup happens before COMMIT returns.
    internal func finishHistoryCommit(
        position: ChangePosition,
        hcrAppend: HistoryChangeRecordPayload,
        expectedPreviousPosition: ChangePosition,
        auditAppend: OperationRecordPayload? = nil,
        auditConfig: GatewayConfigRow? = nil,
        in database: SQLiteDatabase
    ) throws {
        if consumeTransactionFailureInjection(.beforeHCRAppend) {
            throw InjectedTransactionFailure.beforeHCRAppend
        }
        try HCRStore.append(
            hcrAppend, expectedPreviousPosition: expectedPreviousPosition, in: database
        )
        if let auditAppend, let auditConfig {
            _ = try GatewayAuditStore.append(auditAppend, config: auditConfig, in: database)
        }
        if consumeTransactionFailureInjection(.beforeSingletonUpdate) {
            throw InjectedTransactionFailure.beforeSingletonUpdate
        }
#if DEBUG
        TransactionKillDebugInstrumentation.terminateIfArmed(.beforePositionWrite)
#endif
        if consumeTransactionFailureInjection(.insufficientDiskSpace) {
            throw HistoryFailure.temporarilyUnavailable(.insufficientDiskSpace)
        }
        try database.execute(
            "UPDATE history_state SET changePosition = ? WHERE key = ?",
            bindings: [.blob(sqliteUInt64(position.rawValue)), .text(Self.positionSingletonKey)]
        )
#if DEBUG
        TransactionKillDebugInstrumentation.terminateIfArmed(.beforeCommit)
#endif
    }
    internal func apply(
        _ mutation: StampedMutation, published: PublishedHistoryContent?, in database: SQLiteDatabase
    ) throws {
        switch mutation {
        case .create(let item):
            guard !consumeTransactionFailureInjection(.duplicateCreateID) else {
                throw TransactionApplyRejection.duplicateCreateID(itemID: item.id)
            }
            guard let published else { throw HistoryFailure.persistence(.invariantViolation) }
            let contentID = published.id
            let canonicalBytes = published.byteCount
            try database.execute("""
                INSERT INTO history_items
                    (id, contentVersion, currentContentID, titleUTF8, searchBodyUTF8,
                     effectiveTypeIdentifiersBlob, firstCopiedAt, lastCopiedAt, copyCount,
                     firstSource, lastSource, pinOrdinal, canonicalBytes, revisionCount, revisionBytes,
                     effectiveMatchesCanonical)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, 0, 0, 1)
                """, bindings: [
                    .text(item.id.rawValue.uuidString), .blob(sqliteUInt64(item.contentVersion.rawValue)),
                    .text(contentID.uuidString), .blob(Data(item.projection.title.utf8)),
                    .blob(Data(item.projection.searchBody.utf8)),
                    .blob(try EffectiveTypeIdentifiersBlobCodec.encode(item.projection.effectiveTypeIdentifiers)),
                    .real(item.occurrence.firstCopiedAt.timeIntervalSinceReferenceDate),
                    .real(item.occurrence.lastCopiedAt.timeIntervalSinceReferenceDate),
                    .blob(sqliteUInt64(item.occurrence.count)),
                    item.occurrence.firstSource.map(SQLiteValue.text) ?? .null,
                    item.occurrence.lastSource.map(SQLiteValue.text) ?? .null,
                    .integer(Int64(canonicalBytes)),
                ])
            try insertContent(
                published, itemID: item.id, ordinal: 0,
                createdAt: item.occurrence.firstCopiedAt, title: item.projection.title,
                in: database
            )
            try database.execute("""
                UPDATE history_state SET retainedItemCount = retainedItemCount + 1,
                    canonicalBytes = canonicalBytes + ? WHERE key = ?
                """, bindings: [.integer(Int64(canonicalBytes)), .text(Self.positionSingletonKey)])

        case .updateOccurrence(let itemID, let occurrence):
            _ = try requireMutationRow(itemID, in: database)
            try database.execute("""
                UPDATE history_items SET firstCopiedAt = ?, lastCopiedAt = ?, copyCount = ?,
                    firstSource = ?, lastSource = ? WHERE id = ?
                """, bindings: [
                    .real(occurrence.firstCopiedAt.timeIntervalSinceReferenceDate),
                    .real(occurrence.lastCopiedAt.timeIntervalSinceReferenceDate),
                    .blob(sqliteUInt64(occurrence.count)),
                    occurrence.firstSource.map(SQLiteValue.text) ?? .null,
                    occurrence.lastSource.map(SQLiteValue.text) ?? .null,
                    .text(itemID.rawValue.uuidString),
                ])

        case .relocatePin(let relocation):
            try applyPinRelocation(relocation, in: database)

        case .appendRevision(let update):
            guard let published else { throw HistoryFailure.persistence(.invariantViolation) }
            let old = try requireMutationRow(update.itemID, in: database)
            guard !consumeTransactionFailureInjection(.contentVersionMismatch),
                  old.version == update.expectedCurrentVersion.rawValue else {
                throw TransactionApplyRejection.contentVersionMismatch(itemID: update.itemID)
            }
            let ordinalQuery = try database.prepare(
                "SELECT COALESCE(MAX(revisionOrdinal), 0) FROM contents WHERE itemID = ?",
                bindings: [.text(update.itemID.rawValue.uuidString)]
            )
            defer { ordinalQuery.finalize() }
            guard try ordinalQuery.step() else { throw HistoryFailure.persistence(.invariantViolation) }
            let previousOrdinal = try ordinalQuery.integer(at: 0)
            guard previousOrdinal < Int64.max else { throw HistoryFailure.persistence(.invariantViolation) }
            try insertContent(
                published, itemID: update.itemID, ordinal: previousOrdinal + 1,
                createdAt: update.revision.createdAt, title: update.projection.title,
                in: database
            )
            try database.execute("""
                UPDATE history_items SET currentContentID = ?, contentVersion = ?, titleUTF8 = ?,
                    searchBodyUTF8 = ?, effectiveTypeIdentifiersBlob = ?, effectiveMatchesCanonical = ? WHERE id = ?
                """, bindings: [
                    .text(update.revision.id.rawValue.uuidString), .blob(sqliteUInt64(update.nextVersion.rawValue)),
                    .blob(Data(update.projection.title.utf8)), .blob(Data(update.projection.searchBody.utf8)),
                    .blob(try EffectiveTypeIdentifiersBlobCodec.encode(update.projection.effectiveTypeIdentifiers)),
                    .integer(update.effectiveMatchesCanonical ? 1 : 0),
                    .text(update.itemID.rawValue.uuidString),
                ])
            try deleteRevisions(update.removedRevisionIDs, itemID: update.itemID, in: database)
            try updateRevisionAccounting(
                itemID: update.itemID, oldBytes: old.revisionBytes,
                new: update.retainedRevisionScalars, in: database
            )

        case .delete(let itemID, _):
            let old = try requireMutationRow(itemID, in: database)
            // FK cascades delete content/representation references, never files.
            try database.execute("DELETE FROM history_items WHERE id = ?", bindings: [.text(itemID.rawValue.uuidString)])
            try database.execute("""
                UPDATE history_state SET retainedItemCount = retainedItemCount - 1,
                    pinnedItemCount = pinnedItemCount - ?, canonicalBytes = canonicalBytes - ?,
                    revisionBytes = revisionBytes - ? WHERE key = ?
                """, bindings: [
                    .integer(old.pinOrdinal == nil ? 0 : 1), .integer(Int64(old.canonicalBytes)),
                    .integer(Int64(old.revisionBytes)), .text(Self.positionSingletonKey),
                ])

        case .bulkClear(let scope, let affectedCount):
            let predicate = scope == .all ? "" : " WHERE pinOrdinal IS NULL"
            let totals = try database.prepare("""
                SELECT count(*), count(pinOrdinal), COALESCE(sum(canonicalBytes), 0),
                       COALESCE(sum(revisionBytes), 0)
                FROM history_items\(predicate)
                """)
            defer { totals.finalize() }
            guard try totals.step(), try totals.integer(at: 0) == Int64(affectedCount) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let pinned = try totals.integer(at: 1)
            let canonical = try totals.integer(at: 2)
            let revisions = try totals.integer(at: 3)
            totals.finalize()
            try database.execute("DELETE FROM history_items" + predicate)
            guard try database.changedRowCount == Int64(affectedCount) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            try subtractRetiredAccounting(
                count: affectedCount, pinned: pinned, canonical: canonical, revisions: revisions,
                in: database
            )

        case .retirePrefix(let prefix):
            try database.execute("""
                DELETE FROM history_items WHERE pinOrdinal IS NULL AND id != ?
                  AND (lastCopiedAt < ? OR (lastCopiedAt = ? AND id <= ?))
                """, bindings: [
                    .text(prefix.excludedItemID?.rawValue.uuidString ?? ""),
                    .real(prefix.through.lastCopiedAt.timeIntervalSinceReferenceDate),
                    .real(prefix.through.lastCopiedAt.timeIntervalSinceReferenceDate),
                    .text(prefix.through.itemID.rawValue.uuidString),
                ])
            guard try database.changedRowCount == Int64(prefix.itemCount) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            try subtractRetiredAccounting(
                count: prefix.itemCount, pinned: 0, canonical: Int64(prefix.canonicalBytes),
                revisions: Int64(prefix.revisionBytes), in: database
            )

        case .setRetentionPolicy(let maximum):
            try database.execute(
                "UPDATE history_state SET maximumUnpinnedItems = ? WHERE key = ?",
                bindings: [.integer(Int64(maximum)), .text(Self.positionSingletonKey)]
            )

        case .pruneRevisions(let itemID, let removedRevisionIDs, let scalars):
            let old = try requireMutationRow(itemID, in: database)
            try deleteRevisions(removedRevisionIDs, itemID: itemID, in: database)
            try updateRevisionAccounting(itemID: itemID, oldBytes: old.revisionBytes, new: scalars, in: database)

        case .setRetentionPolicies(let policies):
            try database.execute("""
                UPDATE retention_policies SET ageMaxSeconds = ?, storageMaxBytes = ?,
                    revisionMaxCount = ?, revisionMaxBytes = ? WHERE key = 'retention-expansion'
                """, bindings: [
                    policies.age.map { .real($0.maxAge) } ?? .null,
                    policies.storage.map { .integer(Int64($0.maxTotalBytes)) } ?? .null,
                    policies.revisions?.maxRevisionsPerItem.map { .integer(Int64($0)) } ?? .null,
                    policies.revisions?.maxRevisionBytesPerItem.map { .integer(Int64($0)) } ?? .null,
                ])
            guard try database.changedRowCount == 1 else { throw HistoryFailure.persistence(.invariantViolation) }
        }
    }

    private func subtractRetiredAccounting(
        count: Int, pinned: Int64, canonical: Int64, revisions: Int64,
        in database: SQLiteDatabase
    ) throws {
        try database.execute("""
            UPDATE history_state SET retainedItemCount = retainedItemCount - ?,
                pinnedItemCount = pinnedItemCount - ?, canonicalBytes = canonicalBytes - ?,
                revisionBytes = revisionBytes - ? WHERE key = ?
            """, bindings: [
                .integer(Int64(count)), .integer(pinned), .integer(canonical),
                .integer(revisions), .text(Self.positionSingletonKey),
            ])
    }

    /// SQL writes consume only published locators and small inline values.
    /// File reads, writes and fsync have completed before this transaction.
    private func insertContent(
        _ published: PublishedHistoryContent,
        itemID: HistoryItemID, ordinal: Int64, createdAt: Date, title: String,
        in database: SQLiteDatabase
    ) throws {
        try database.execute("""
            INSERT INTO contents
                (id, itemID, revisionOrdinal, createdAt, titleUTF8, contentByteCount, representationCount)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                .text(published.id.uuidString), .text(itemID.rawValue.uuidString), .integer(ordinal),
                .real(createdAt.timeIntervalSinceReferenceDate), .blob(Data(title.utf8)),
                .integer(Int64(published.byteCount)), .integer(Int64(published.representations.count)),
            ])
        for (index, representation) in published.representations.enumerated() {
            try database.execute("""
                INSERT INTO representations
                    (contentID, ordinal, exactType, typeKey, byteCount, fingerprint, inlineBytes, blobID)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, bindings: [
                    .text(published.id.uuidString), .integer(Int64(index)), .text(representation.exactType),
                    .text(representation.typeKey), .integer(Int64(representation.byteCount)),
                    representation.fingerprint.map { .blob(sqliteUInt64($0)) } ?? .null,
                    representation.inline, representation.blobID,
                ])
        }
    }

    private func deleteRevisions(
        _ ids: [RevisionID], itemID: HistoryItemID, in database: SQLiteDatabase
    ) throws {
        for id in ids {
            try database.execute("""
                DELETE FROM contents WHERE id = ? AND itemID = ? AND revisionOrdinal > 0
                    AND id != (SELECT currentContentID FROM history_items WHERE id = ?)
                """, bindings: [
                    .text(id.rawValue.uuidString), .text(itemID.rawValue.uuidString),
                    .text(itemID.rawValue.uuidString),
                ])
            guard try database.changedRowCount == 1 else { throw HistoryFailure.persistence(.invariantViolation) }
        }
    }

    private func updateRevisionAccounting(
        itemID: HistoryItemID, oldBytes: Int, new: RetainedRevisionScalars, in database: SQLiteDatabase
    ) throws {
        try database.execute(
            "UPDATE history_items SET revisionCount = ?, revisionBytes = ? WHERE id = ?",
            bindings: [.integer(Int64(new.count)), .integer(Int64(new.bytes)), .text(itemID.rawValue.uuidString)]
        )
        try database.execute(
            "UPDATE history_state SET revisionBytes = revisionBytes + ? WHERE key = ?",
            bindings: [.integer(Int64(new.bytes - oldBytes)), .text(Self.positionSingletonKey)]
        )
    }

    internal func requireMutationRow(
        _ itemID: HistoryItemID, in database: SQLiteDatabase
    ) throws -> (version: UInt64, canonicalBytes: Int, revisionBytes: Int, pinOrdinal: Int?) {
        let statement = try database.prepare("""
            SELECT contentVersion, canonicalBytes, revisionBytes, pinOrdinal
            FROM history_items WHERE id = ?
            """, bindings: [.text(itemID.rawValue.uuidString)])
        defer { statement.finalize() }
        guard !consumeTransactionFailureInjection(.missingRow), try statement.step() else {
            throw TransactionApplyRejection.missingRow(itemID: itemID)
        }
        let canonical = try statement.integer(at: 1)
        let revisions = try statement.integer(at: 2)
        let ordinal = try statement.isNull(at: 3) ? nil : statement.integer(at: 3)
        guard canonical >= 0, revisions >= 0,
              ordinal.map({ $0 >= 0 && $0 < Int64(limits.hardMaximumRetainedItems) }) ?? true else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        return (
            try sqliteUInt64(statement.blob(at: 0)), Int(canonical), Int(revisions),
            ordinal.map(Int.init)
        )
    }

    internal func validateFinalPinOrder(in database: SQLiteDatabase) throws {
        do {
            _ = try PinnedOrderSQL.validatedCount(in: database, limits: limits)
        } catch HistoryFailure.persistence(.invariantViolation) {
            throw TransactionApplyRejection.finalPinOrderViolated
        }
        if consumeTransactionFailureInjection(.finalPinOrderViolated) {
            throw TransactionApplyRejection.finalPinOrderViolated
        }
    }
}
