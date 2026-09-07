/// DC-25 X-HCR singleton bootstrap, retained-suffix validation, and startup
/// prefix compaction. No reconnect reader, cursor, cache, or repair lives here.
/// Owning spec: `V2-03` §0.3 and the M1 total open order.
import Foundation
import HistoryCore

internal enum HCRBootstrap {
    internal static let configKey = "change-journal"
    internal static let configSchemaVersion: UInt16 = 1

    /// One-row probes used by earlier startup singleton classifiers. Any
    /// HCR fact proves that those earlier owners have already bootstrapped;
    /// their missing rows must therefore fail closed instead of being repaired.
    internal static func tablesAreEmpty(in database: SQLiteDatabase) throws -> Bool {
        do {
            let statement = try database.prepare("""
                SELECT 1 FROM journal_config
                UNION ALL SELECT 1 FROM history_change_records LIMIT 1
                """)
            defer { statement.finalize() }
            return try !statement.step()
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }

    /// Runs inside the Authority's startup write transaction, so bootstrap,
    /// prefix deletion, and coverage-floor accounting roll back together.
    internal static func ensureReady(
        in database: SQLiteDatabase,
        now: @autoclosure () -> Date,
        journalLimits: JournalLimits = .standard,
        compactionInjection: (() throws -> Void)? = nil
    ) throws {
        let position = try loadCurrentPosition(in: database)
        let configs: [JournalConfigRow]
        do {
            configs = try loadConfigs(in: database)
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        switch configs.count {
        case 0:
            // Only a never-used, empty History may create the singleton.
            // Clearing retained items does not erase committed history or
            // permit reconstruction of a missing journal coverage floor.
            guard position == 0, try historyRowsAreEmpty(in: database) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            do {
                try database.execute("""
                    INSERT INTO journal_config
                        (key, compactionFloorRaw, journalBytes, configSchemaVersion)
                    VALUES (?, ?, ?, ?)
                    """, bindings: [
                        .text(configKey), .blob(sqliteUInt64(0)),
                        .blob(sqliteUInt64(0)), .integer(Int64(configSchemaVersion))
                    ])
            } catch {
                throw HistoryFailure.persistence(.openStore)
            }
        case 1:
            try validateAndCompact(
                config: configs[0],
                position: position,
                in: database,
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
        in database: SQLiteDatabase,
        now: Date,
        limits: JournalLimits,
        compactionInjection: (() throws -> Void)?
    ) throws {
        let validated = try validate(
            config: config,
            position: position,
            in: database,
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
            try database.execute(
                "DELETE FROM history_change_records WHERE sequence <= ?",
                bindings: [.blob(sqliteUInt64(newFloor))]
            )
            try compactionInjection?()
            try database.execute("""
                UPDATE journal_config SET compactionFloorRaw = ?, journalBytes = ?
                WHERE key = ?
                """, bindings: [
                    .blob(sqliteUInt64(newFloor)), .blob(sqliteUInt64(remainingBytes)),
                    .text(config.key)
                ])
        } catch {
            throw HistoryFailure.persistence(.transaction)
        }

        _ = try validate(
            config: JournalConfigRow(
                key: config.key,
                compactionFloorRaw: newFloor,
                journalBytes: remainingBytes,
                configSchemaVersion: config.configSchemaVersion
            ),
            position: position,
            in: database,
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
        in database: SQLiteDatabase,
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

        // J3 keeps count/bytes strictly capped inside each append transaction;
        // cadence 50 only schedules the age scan. The extra row distinguishes
        // an impossible overflow without an unbounded startup fetch.
        let (fetchLimit, fetchLimitOverflow) = limits.maxJournalRecordCount
            .addingReportingOverflow(1)
        guard !fetchLimitOverflow else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let rows: [HistoryChangeRecordRow]
        do {
            rows = try loadRecords(in: database, limit: fetchLimit)
        } catch let failure as HistoryFailure {
            throw failure
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
        in database: SQLiteDatabase
    ) throws -> UInt64 {
        var positions: [(key: String, rawValue: UInt64)] = []
        do {
            let statement = try database.prepare(
                "SELECT key, changePosition FROM history_state LIMIT 2"
            )
            defer { statement.finalize() }
            while try statement.step() {
                positions.append((
                    key: try statement.text(at: 0),
                    rawValue: try sqliteUInt64(statement.blob(at: 1))
                ))
            }
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        guard positions.count == 1,
              positions[0].key == HistoryAuthority.positionSingletonKey else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return positions[0].rawValue
    }

    internal static func loadConfigs(
        in database: SQLiteDatabase
    ) throws -> [JournalConfigRow] {
        let statement = try database.prepare("""
            SELECT key, compactionFloorRaw, journalBytes, configSchemaVersion
            FROM journal_config LIMIT 2
            """)
        defer { statement.finalize() }
        var rows: [JournalConfigRow] = []
        while try statement.step() {
            guard let version = UInt16(exactly: try statement.integer(at: 3)) else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            rows.append(JournalConfigRow(
                key: try statement.text(at: 0),
                compactionFloorRaw: try sqliteUInt64(statement.blob(at: 1)),
                journalBytes: try sqliteUInt64(statement.blob(at: 2)),
                configSchemaVersion: version
            ))
        }
        return rows
    }

    internal static func loadRecords(
        in database: SQLiteDatabase,
        limit: Int
    ) throws -> [HistoryChangeRecordRow] {
        let statement = try database.prepare("""
            SELECT sequence, changePositionRaw, changeKindRaw, affectedItemsBlob, createdAt
            FROM history_change_records ORDER BY sequence LIMIT ?
            """, bindings: [.integer(Int64(limit))])
        defer { statement.finalize() }
        var rows: [HistoryChangeRecordRow] = []
        while try statement.step() {
            guard let kind = Int16(exactly: try statement.integer(at: 2)) else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            rows.append(HistoryChangeRecordRow(
                sequence: try sqliteUInt64(statement.blob(at: 0)),
                changePositionRaw: try sqliteUInt64(statement.blob(at: 1)),
                changeKindRaw: kind,
                affectedItemsBlob: try statement.blob(at: 3),
                createdAt: Date(timeIntervalSinceReferenceDate: try statement.real(at: 4))
            ))
        }
        return rows
    }

    private static func historyRowsAreEmpty(
        in database: SQLiteDatabase
    ) throws -> Bool {
        do {
            let statement = try database.prepare("""
                SELECT 1 FROM history_change_records
                UNION ALL SELECT 1 FROM history_items LIMIT 1
                """)
            defer { statement.finalize() }
            return try !statement.step()
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }

}
