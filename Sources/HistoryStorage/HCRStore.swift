/// DC-25/J.3 same-transaction History Change Record append owner.
///
/// This type owns only the inline append and its fixed prefix-retention
/// accounting. It exposes no reader, cursor, cache, rebase, public protocol,
/// or second transaction boundary.
import Foundation
import HistoryCore
import SwiftData

internal enum HCRStore {
    /// Pure structural decision for whether append-time retention needs HCR
    /// rows at all. Tests lock this value instead of instrumenting SwiftData:
    /// `.none` returns before a descriptor exists, count-only pressure reads
    /// exactly its oldest prefix, and age/byte pressure needs the full bounded
    /// suffix.
    internal enum PrefixReadScope: Sendable, Equatable {
        case none
        case oldestPrefix(count: Int)
        case fullSuffix
    }

    internal static func prefixReadScope(
        minimumDeleteCount: Int,
        bytesAfterAppend: UInt64,
        scansAge: Bool,
        maxJournalBytes: UInt64
    ) -> PrefixReadScope {
        if scansAge || bytesAfterAppend > maxJournalBytes {
            return .fullSuffix
        }
        if minimumDeleteCount > 0 {
            return .oldestPrefix(count: minimumDeleteCount)
        }
        return .none
    }

    /// Stages exactly one HCR plus any required oldest-prefix trim inside the
    /// caller's existing History Commit transaction. The singleton position
    /// is still the previous value here and remains written last by the shared
    /// commit kernel.
    internal static func append(
        _ payload: HistoryChangeRecordPayload,
        expectedPreviousPosition: ChangePosition,
        in context: ModelContext,
        limits: JournalLimits = .standard
    ) throws {
        guard payload.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let (expectedSequence, sequenceOverflow) = expectedPreviousPosition
            .rawValue.addingReportingOverflow(1)
        guard !sequenceOverflow,
              payload.sequence == expectedSequence,
              payload.changePositionRaw == expectedSequence else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        let config = try loadConfig(in: context)
        guard config.key == HCRBootstrap.configKey,
              config.configSchemaVersion == HCRBootstrap.configSchemaVersion,
              config.compactionFloorRaw <= expectedPreviousPosition.rawValue,
              config.journalBytes <= limits.maxJournalBytes else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        let blob: Data
        do {
            blob = try AffectedItemsBlobCodec.encode(
                payload.affectedItemIDs,
                for: payload.changeKind,
                limits: limits
            )
        } catch let rejection as AffectedItemsBlobRejection {
            throw rejection.historyFailure
        }
        guard let blobBytes = UInt64(exactly: blob.count) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let (untrimmedBytes, byteOverflow) = config.journalBytes
            .addingReportingOverflow(blobBytes)
        guard !byteOverflow else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        let existingCountRaw = expectedPreviousPosition.rawValue
            - config.compactionFloorRaw
        guard let existingCount = Int(exactly: existingCountRaw),
              existingCount <= limits.maxJournalRecordCount,
              (existingCount == 0) == (config.journalBytes == 0) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let (untrimmedCount, countOverflow) = existingCount
            .addingReportingOverflow(1)
        guard !countOverflow else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        let mustTrimCount = max(
            0,
            untrimmedCount - limits.maxJournalRecordCount
        )
        guard let cadence = UInt64(exactly: limits.compactionCadenceCommits)
        else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let scansAge = payload.sequence % cadence == 0
        let trim = try prefixTrim(
            existingCount: existingCount,
            minimumDeleteCount: mustTrimCount,
            bytesAfterAppend: untrimmedBytes,
            scansAge: scansAge,
            now: payload.createdAt,
            config: config,
            in: context,
            limits: limits
        )

        for row in trim.rows {
            context.delete(row)
        }
        if let newFloor = trim.rows.last?.sequence {
            config.compactionFloorRaw = newFloor
        }
        let (retainedBytes, byteUnderflow) = untrimmedBytes
            .subtractingReportingOverflow(trim.deletedBytes)
        guard !byteUnderflow,
              retainedBytes <= limits.maxJournalBytes else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        config.journalBytes = retainedBytes
        context.insert(HistoryChangeRecordRow(
            sequence: payload.sequence,
            changePositionRaw: payload.changePositionRaw,
            changeKindRaw: payload.changeKind.rawValue,
            affectedItemsBlob: blob,
            createdAt: payload.createdAt
        ))
    }
}

private extension HCRStore {
    struct PrefixTrim {
        let rows: [HistoryChangeRecordRow]
        let deletedBytes: UInt64
    }

    static func loadConfig(in context: ModelContext) throws -> JournalConfigRow {
        var descriptor = FetchDescriptor<JournalConfigRow>()
        descriptor.fetchLimit = 2
        let rows: [JournalConfigRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.transaction)
        }
        guard rows.count == 1, let row = rows.first else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return row
    }

    static func prefixTrim(
        existingCount: Int,
        minimumDeleteCount: Int,
        bytesAfterAppend: UInt64,
        scansAge: Bool,
        now: Date,
        config: JournalConfigRow,
        in context: ModelContext,
        limits: JournalLimits
    ) throws -> PrefixTrim {
        let readScope = HCRStore.prefixReadScope(
            minimumDeleteCount: minimumDeleteCount,
            bytesAfterAppend: bytesAfterAppend,
            scansAge: scansAge,
            maxJournalBytes: limits.maxJournalBytes
        )
        let fetchLimit: Int
        let expectedFetchedCount: Int
        switch readScope {
        case .none:
            return PrefixTrim(rows: [], deletedBytes: 0)
        case .oldestPrefix(let count):
            fetchLimit = count
            expectedFetchedCount = count
        case .fullSuffix:
            let (fullFetchLimit, fetchLimitOverflow) = limits.maxJournalRecordCount
                .addingReportingOverflow(1)
            guard !fetchLimitOverflow else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            fetchLimit = fullFetchLimit
            expectedFetchedCount = existingCount
        }
        var descriptor = FetchDescriptor<HistoryChangeRecordRow>(
            sortBy: [SortDescriptor(\.sequence)]
        )
        descriptor.fetchLimit = fetchLimit
        let rows: [HistoryChangeRecordRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.transaction)
        }
        guard rows.count == expectedFetchedCount else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        var expectedSequence = config.compactionFloorRaw
        var deleteCountForAge = 0
        for (offset, row) in rows.enumerated() {
            let (successor, overflow) = expectedSequence.addingReportingOverflow(1)
            guard !overflow,
                  row.sequence == successor,
                  row.changePositionRaw == row.sequence else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            expectedSequence = successor
            guard row.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            if scansAge,
               now.timeIntervalSince(row.createdAt) > limits.maxJournalAgeSeconds {
                deleteCountForAge = offset + 1
            }
        }

        let requiredDeleteCount = max(
            minimumDeleteCount,
            deleteCountForAge
        )
        var deleteCount = 0
        var deletedBytes: UInt64 = 0
        for row in rows {
            let (bytesRemaining, byteUnderflow) = bytesAfterAppend
                .subtractingReportingOverflow(deletedBytes)
            guard !byteUnderflow else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let bytePressure = bytesRemaining > limits.maxJournalBytes
            guard deleteCount < requiredDeleteCount || bytePressure else {
                break
            }
            guard let rowBytes = UInt64(exactly: row.affectedItemsBlob.count)
            else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let (sum, byteOverflow) = deletedBytes
                .addingReportingOverflow(rowBytes)
            guard !byteOverflow, sum <= config.journalBytes else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            deletedBytes = sum
            deleteCount += 1
        }

        let (retainedBytes, retainedByteUnderflow) = bytesAfterAppend
            .subtractingReportingOverflow(deletedBytes)
        let (countAfterAppend, countOverflow) = existingCount
            .addingReportingOverflow(1)
        let (retainedCount, countUnderflow) = countAfterAppend
            .subtractingReportingOverflow(deleteCount)
        guard !retainedByteUnderflow,
              !countOverflow,
              !countUnderflow,
              deleteCount >= requiredDeleteCount,
              retainedBytes <= limits.maxJournalBytes,
              retainedCount <= limits.maxJournalRecordCount else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return PrefixTrim(
            rows: Array(rows.prefix(deleteCount)),
            deletedBytes: deletedBytes
        )
    }
}
