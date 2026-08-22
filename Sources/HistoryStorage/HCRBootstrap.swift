/// DC-25 X-HCR singleton bootstrap, retained-suffix validation, and startup
/// prefix compaction. No reconnect reader, cursor, cache, or repair lives here.
/// Owning spec: `V2-03` §0.3 and the M1 total open order.
import Foundation
import HistoryCore
import SwiftData

internal enum HCRBootstrap {
    internal static let configKey = "change-journal"
    internal static let configSchemaVersion: UInt16 = 1

    /// One-row probes used by earlier startup singleton classifiers. Any V4
    /// HCR fact proves that those earlier owners have already bootstrapped;
    /// their missing rows must therefore fail closed instead of being repaired.
    internal static func tablesAreEmpty(in context: ModelContext) throws -> Bool {
        var configDescriptor = FetchDescriptor<JournalConfigRow>()
        configDescriptor.fetchLimit = 1
        var recordDescriptor = FetchDescriptor<HistoryChangeRecordRow>()
        recordDescriptor.fetchLimit = 1
        do {
            let configs = try context.fetch(configDescriptor)
            let records = try context.fetch(recordDescriptor)
            return configs.isEmpty && records.isEmpty
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }

    internal static func ensureReady(
        in context: ModelContext,
        now: @autoclosure () -> Date,
        historyLimits: HistoryLimits = .standard,
        journalLimits: JournalLimits = .standard,
        compactionInjection: (() throws -> Void)? = nil
    ) throws {
        let position = try loadCurrentPosition(
            in: context,
            limits: historyLimits
        )
        let configs = try loadConfigs(in: context)
        switch configs.count {
        case 0:
            guard try historyChangeRowsAreEmpty(in: context) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            do {
                try context.transaction {
                    context.insert(JournalConfigRow(
                        key: configKey,
                        compactionFloorRaw: position,
                        journalBytes: 0,
                        configSchemaVersion: configSchemaVersion
                    ))
                }
            } catch {
                throw HistoryFailure.persistence(.openStore)
            }
        case 1:
            try validateAndCompact(
                config: configs[0],
                position: position,
                in: context,
                now: now(),
                limits: journalLimits,
                compactionInjection: compactionInjection
            )
        default:
            throw HistoryFailure.persistence(.invariantViolation)
        }
    }

    private static func validateAndCompact(
        config: JournalConfigRow,
        position: UInt64,
        in context: ModelContext,
        now: Date,
        limits: JournalLimits,
        compactionInjection: (() throws -> Void)?
    ) throws {
        let validated = try validate(
            config: config,
            position: position,
            in: context,
            limits: limits
        )
        let deleteCount = try prefixDeleteCount(
            rows: validated.rows,
            now: now,
            limits: limits
        )
        guard deleteCount > 0 else { return }

        let deletedRows = validated.rows.prefix(deleteCount)
        let newFloor = deletedRows[deletedRows.index(before: deletedRows.endIndex)]
            .sequence
        var deletedBytes: UInt64 = 0
        for row in deletedRows {
            guard let bytes = UInt64(exactly: row.affectedItemsBlob.count) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let (sum, overflow) = deletedBytes.addingReportingOverflow(bytes)
            guard !overflow else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            deletedBytes = sum
        }
        let (remainingBytes, underflow) = config.journalBytes
            .subtractingReportingOverflow(deletedBytes)
        guard !underflow else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        do {
            try context.transaction {
                for row in deletedRows {
                    context.delete(row)
                }
                try compactionInjection?()
                config.compactionFloorRaw = newFloor
                config.journalBytes = remainingBytes
            }
        } catch {
            throw HistoryFailure.persistence(.transaction)
        }

        _ = try validate(
            config: config,
            position: position,
            in: context,
            limits: limits
        )
    }

    private struct ValidatedSuffix {
        let rows: [HistoryChangeRecordRow]
        let logicalBytes: UInt64
    }

    private static func validate(
        config: JournalConfigRow,
        position: UInt64,
        in context: ModelContext,
        limits: JournalLimits
    ) throws -> ValidatedSuffix {
        guard config.key == configKey else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        guard config.configSchemaVersion == configSchemaVersion else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        guard config.compactionFloorRaw <= position else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        var descriptor = FetchDescriptor<HistoryChangeRecordRow>(
            sortBy: [SortDescriptor(\.sequence)]
        )
        // J3 keeps count/bytes strictly capped inside each append transaction;
        // cadence 50 only schedules the age scan. The extra row distinguishes
        // an impossible overflow without an unbounded startup fetch.
        let (fetchLimit, fetchLimitOverflow) = limits.maxJournalRecordCount
            .addingReportingOverflow(1)
        guard !fetchLimitOverflow else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        descriptor.fetchLimit = fetchLimit
        let rows: [HistoryChangeRecordRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        guard rows.count <= limits.maxJournalRecordCount else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        let expectedCount = position - config.compactionFloorRaw
        guard UInt64(rows.count) == expectedCount else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var expectedSequence = config.compactionFloorRaw
        var logicalBytes: UInt64 = 0
        for row in rows {
            let (successor, overflow) = expectedSequence.addingReportingOverflow(1)
            guard !overflow,
                  row.sequence == successor,
                  row.changePositionRaw == row.sequence else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            expectedSequence = successor
            guard let changeKind = HistoryChangeKindRawV1(
                rawValue: row.changeKindRaw
            ) else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            do {
                _ = try AffectedItemsBlobCodec.decode(
                    row.affectedItemsBlob,
                    for: changeKind,
                    limits: limits
                )
            } catch let rejection as AffectedItemsBlobRejection {
                throw rejection.historyFailure
            }
            guard row.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            guard let bytes = UInt64(exactly: row.affectedItemsBlob.count) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let (sum, byteOverflow) = logicalBytes.addingReportingOverflow(bytes)
            guard !byteOverflow else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            logicalBytes = sum
        }
        guard expectedSequence == position,
              logicalBytes == config.journalBytes,
              logicalBytes <= limits.maxJournalBytes else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return ValidatedSuffix(rows: rows, logicalBytes: logicalBytes)
    }

    private static func prefixDeleteCount(
        rows: [HistoryChangeRecordRow],
        now: Date,
        limits: JournalLimits
    ) throws -> Int {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var deleteCountForAge = 0
        for (offset, row) in rows.enumerated()
        where now.timeIntervalSince(row.createdAt) > limits.maxJournalAgeSeconds {
            deleteCountForAge = offset + 1
        }
        return deleteCountForAge
    }

    private static func loadCurrentPosition(
        in context: ModelContext,
        limits: HistoryLimits
    ) throws -> UInt64 {
        var descriptor = FetchDescriptor<LastChangePositionRow>()
        descriptor.fetchLimit = 2
        let rows: [LastChangePositionRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        guard rows.count == 1, rows[0].key == HistoryAuthority.positionSingletonKey else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return try HistoryAuthority.decodePositionRow(rows[0], limits: limits)
            .position.rawValue
    }

    private static func loadConfigs(
        in context: ModelContext
    ) throws -> [JournalConfigRow] {
        var descriptor = FetchDescriptor<JournalConfigRow>()
        descriptor.fetchLimit = 2
        do {
            return try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }

    private static func historyChangeRowsAreEmpty(
        in context: ModelContext
    ) throws -> Bool {
        var descriptor = FetchDescriptor<HistoryChangeRecordRow>()
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).isEmpty
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }

}
