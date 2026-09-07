import Foundation
import HistoryCore
import HistoryDomain

internal enum StorageInvariant: Error {
    case positionChanged
}

internal enum TransactionApplyRejection: Error {
    case missingRow(itemID: HistoryItemID)
    case duplicateCreateID(itemID: HistoryItemID)
    case contentVersionMismatch(itemID: HistoryItemID)
    case finalPinOrderViolated
}

internal struct CaptureCandidateIDCollision: Error, Sendable {
    internal let itemID: HistoryItemID
}

/// Suspension is permitted only outside an isolated History transaction.
internal enum AuthoritySuspensionPoint: String, Sendable {
    case captureCommitEntry = "HistoryAuthority.commitCapture.entry"
    case revisionCommitEntry = "HistoryAuthority.commitRevision.entry"
    case readEntry = "HistoryAuthority.read.entry"
    case positionRecheckEntry = "HistoryAuthority.currentPosition.entry"
    case gatewayAuditCompactionEntry = "HistoryAuthority.compactExternalAudit.entry"
    case blobCleanupBatchEntry = "HistoryAuthority.blobCleanup.batch"
}

/// Existing one-shot probes now exercise actual SQLite transaction rollback.
internal enum InjectedTransactionFailure: Error, Sendable, Equatable {
    case beforeHCRAppend
    case beforeSingletonUpdate
    case positionChanged
    case missingRow
    case duplicateCreateID
    case contentVersionMismatch
    case finalPinOrderViolated
    case insufficientDiskSpace
    case beforeGatewayAuditCompaction
}

/// V2-09: the only durable writer. Database and file handles stay isolated in
/// this actor; callers receive immutable values. Startup reads configuration,
/// not full-store signature/ID collections, payloads or search corpora.
internal actor HistoryAuthority {
    internal let storeLocation: HistoryStoreLocation
    internal let database: SQLiteDatabase
    internal let blobStore: ImmutableBlobStore
    internal let limits: HistoryLimits
    internal let storageClock: any StorageClock
    internal let gatewayConnectionIDSource: @Sendable () -> UUID
    internal let volumeAvailableCapacityReader: @Sendable () -> Int64?
    internal var volumeAvailableCapacityOverride: Int64?
    internal var invalidationPublisher = HistoryInvalidationPublisher()
    internal let processMarker = UUID()
    internal var suspensionHandler: (@Sendable (AuthoritySuspensionPoint) async -> Void)?
    internal var injectedTransactionFailure: InjectedTransactionFailure?
    internal var blobCleanupTask: Task<Void, Never>?
    internal var blobCleanupNeedsAnotherPass = false

#if DEBUG
    internal var searchDebugProbe = SearchDebugProbe.environmentConfigured()
    internal var storageLifecycleDebugProbe = StorageLifecycleDebugProbe.environmentConfigured()

    internal func setSearchDebugProbe(_ probe: SearchDebugProbe) {
        searchDebugProbe = probe
    }

    internal func setStorageLifecycleDebugProbe(_ probe: StorageLifecycleDebugProbe) {
        storageLifecycleDebugProbe = probe
    }
#endif

    internal static let positionSingletonKey = "retained-history"
    internal var cursorProcessMarker: UUID { processMarker }

    deinit {
        blobCleanupTask?.cancel()
    }

    internal init(
        storeLocation: HistoryStoreLocation,
        limits: HistoryLimits = .standard,
        storageClock: any StorageClock = SystemStorageClock(),
        gatewayConnectionIDSource: @escaping @Sendable () -> UUID = { UUID() },
        volumeAvailableCapacityReader: @escaping @Sendable () -> Int64? = { nil }
    ) throws {
        self.storeLocation = storeLocation
        self.limits = limits
        self.storageClock = storageClock
        self.gatewayConnectionIDSource = gatewayConnectionIDSource
        self.volumeAvailableCapacityReader = volumeAvailableCapacityReader
        database = try SQLiteDatabase(url: storeLocation.databaseURL)
        blobStore = try ImmutableBlobStore(root: storeLocation.rootURL)
    }

    @discardableResult
    internal func performStartup(initialMaximumUnpinnedItems: Int) async throws -> ExternalConnectionID {
        guard limits.userMaximumUnpinnedRange.contains(initialMaximumUnpinnedItems) else {
            throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
        }
        do {
            return try database.writeTransaction {
                try SQLiteHistorySchema.create(in: database)
                try Self.ensurePositionSingleton(
                    in: database,
                    initialMaximumUnpinnedItems: initialMaximumUnpinnedItems,
                    limits: limits
                )
                try Self.ensureRetentionExpansionConfig(in: database)
                let identity = try ensureGatewayBootstrap(in: database)
                try HCRBootstrap.ensureReady(in: database, now: storageClock.now())
                return identity
            }
        } catch let failure as HistoryFailure {
            throw failure
        } catch let failure as SQLiteFailure {
            if case .temporarilyUnavailable = failure.historyFailure {
                throw failure.historyFailure
            }
            throw HistoryFailure.persistence(.openStore)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }

    /// Missing state is fresh only when no durable business facts survive.
    /// EXISTS stops at its first row; no table is materialized (V2-09 §4).
    internal static func ensurePositionSingleton(
        in database: SQLiteDatabase,
        initialMaximumUnpinnedItems: Int,
        limits: HistoryLimits
    ) throws {
        let existing = try database.prepare("SELECT key FROM history_state LIMIT 2")
        defer { existing.finalize() }
        if try existing.step() {
            guard try existing.text(at: 0) == positionSingletonKey,
                  try !existing.step() else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            _ = try decodePositionRow(fetchExactlyOnePositionRow(in: database), limits: limits)
            return
        }
        let occupied = try database.prepare("""
            SELECT EXISTS(SELECT 1 FROM history_items)
                OR EXISTS(SELECT 1 FROM contents)
                OR EXISTS(SELECT 1 FROM representations)
                OR EXISTS(SELECT 1 FROM retention_policies)
                OR EXISTS(SELECT 1 FROM connections)
                OR EXISTS(SELECT 1 FROM grants)
                OR EXISTS(SELECT 1 FROM operation_records)
                OR EXISTS(SELECT 1 FROM gateway_config)
                OR EXISTS(SELECT 1 FROM history_change_records)
                OR EXISTS(SELECT 1 FROM journal_config)
            """)
        defer { occupied.finalize() }
        guard try occupied.step(), try occupied.integer(at: 0) == 0 else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        try database.execute("""
            INSERT INTO history_state
                (key, changePosition, maximumUnpinnedItems,
                 retainedItemCount, pinnedItemCount, canonicalBytes, revisionBytes)
            VALUES (?, ?, ?, 0, 0, 0, 0)
            """, bindings: [
                .text(positionSingletonKey), .blob(sqliteUInt64(0)),
                .integer(Int64(initialMaximumUnpinnedItems)),
            ])
    }
}
