/// V2-09 §10: record-only measurements over real SQLite/blob stores. Each
/// sample contains whole-process kernel facts, not cache attribution.
import Darwin
import Foundation
import HistoryCore
import HistoryStorage

struct SQLiteScaleMemory: Codable, Sendable {
    let residentBytes: UInt64
    let peakResidentBytesSinceLaunch: UInt64
    let footprintBytes: UInt64

    static func read() throws -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { taskInfo in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), taskInfo, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw SQLiteScaleError.memoryUnavailable }
        return Self(
            residentBytes: UInt64(info.resident_size),
            peakResidentBytesSinceLaunch: UInt64(info.resident_size_peak),
            footprintBytes: info.phys_footprint
        )
    }
}

struct SQLiteScaleSample: Codable, Sendable {
    let phase: String
    let elapsedMilliseconds: Double
    let before: SQLiteScaleMemory
    let after: SQLiteScaleMemory?
    let returnedRows: Int?
    let processedFixtureRows: Int?
    /// Bytes explicitly returned by purpose-specific content reads. This is
    /// neither total process-owned memory nor retained logical store bytes.
    let returnedContentBytes: Int?
    let failure: String?
    let query: SQLiteScaleQuery?
    let searchWork: SQLiteScaleSearchWork?
    let recentWork: SQLiteScaleRecentWork?
    /// Full-scroll native work and raw page timings, without row identities
    /// or content. Nil for first-page, other phases and historical reports.
    let recentPages: [SQLiteScaleRecentPageSample]?
    /// Search-page repetition only: 0 is the saved warmup, 1...5 are timed
    /// samples. Nil in older reports and in non-search phases.
    let sampleIndex: Int?
    let isWarmup: Bool?
}

struct SQLiteScaleDisk: Codable, Sendable {
    let apparentBytes: Int64
    let allocatedBytes: Int64
    let regularFileCount: Int

    /// Streaming enumeration stays outside operation intervals. This reports
    /// observed filesystem allocation, not an APFS quota or exclusive blocks.
    static func read(root: URL) throws -> Self {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: nil
        ) else { throw SQLiteScaleError.diskUnavailable }
        var apparent: Int64 = 0
        var allocated: Int64 = 0
        var files = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize, let blocks = values.fileAllocatedSize else {
                throw SQLiteScaleError.diskUnavailable
            }
            apparent += Int64(size)
            allocated += Int64(blocks)
            files += 1
        }
        return Self(apparentBytes: apparent, allocatedBytes: allocated, regularFileCount: files)
    }
}

struct SQLiteScaleUsage: Codable, Sendable {
    let itemCount: Int
    let canonicalBytes: Int
    let revisionBytes: Int
    let position: UInt64

    init(_ usage: HistoryUsage) {
        itemCount = usage.itemCount
        canonicalBytes = usage.canonicalBytes
        revisionBytes = usage.revisionBytes
        position = usage.position.rawValue
    }
}

struct SQLiteScaleReport: Codable, Sendable {
    let mode: String
    let retainedRows: Int
    let bodyBytes: Int?
    let fixtureStatistics: SQLiteScaleFixtureStatistics
    let operatingSystem: String
    let physicalMemoryBytes: UInt64
    let machine: MachineMetadata
    let swiftVersion: String
    let samples: [SQLiteScaleSample]
    let logicalBefore: SQLiteScaleUsage?
    let logicalAfter: SQLiteScaleUsage?
    let diskAfter: SQLiteScaleDisk?
    let failure: String?
    let notes: [String]
}

func measureSQLiteScale<T>(
    phase: String,
    samples: inout [SQLiteScaleSample],
    query: SQLiteScaleQuery? = nil,
    sampleIndex: Int? = nil,
    isWarmup: Bool? = nil,
    operation: () async throws -> T,
    facts: (T) throws -> (rows: Int, contentBytes: Int) = { _ in (0, 0) },
    searchWork: (T) -> SQLiteScaleSearchWork? = { _ in nil },
    recentWork: (T) -> SQLiteScaleRecentWork? = { _ in nil },
    recentPages: (T) -> [SQLiteScaleRecentPageSample]? = { _ in nil },
    fixtureRows: (T) -> Int? = { _ in nil }
) async throws -> T {
    let before = try SQLiteScaleMemory.read()
    let clock = ContinuousClock()
    let start = clock.now
    var work: SQLiteScaleSearchWork?
    var recent: SQLiteScaleRecentWork?
    var pages: [SQLiteScaleRecentPageSample]?
    var completedOperationMilliseconds: Double?
    do {
        let result = try await operation()
        let elapsed = durationToMs(start.duration(to: clock.now))
        completedOperationMilliseconds = elapsed
        work = searchWork(result)
        recent = recentWork(result)
        pages = recentPages(result)
        let after = try SQLiteScaleMemory.read()
        let resultFacts = try facts(result)
        samples.append(SQLiteScaleSample(
            phase: phase, elapsedMilliseconds: elapsed,
            before: before, after: after,
            returnedRows: resultFacts.rows, processedFixtureRows: fixtureRows(result), returnedContentBytes: resultFacts.contentBytes,
            failure: nil, query: query, searchWork: work,
            recentWork: recent, recentPages: pages,
            sampleIndex: sampleIndex, isWarmup: isWarmup
        ))
        let repetition = sampleIndex.map { " sampleIndex=\($0) isWarmup=\(isWarmup == true)" } ?? ""
        print("sqlite-scale phase=\(phase)\(repetition) elapsedMs=\(elapsed) rss=\(after.residentBytes)")
        return result
    } catch {
        // Keep completed and failed timing evidence when a later workload
        // cannot finish. A failed phase carries no fabricated row/payload facts.
        let elapsed = completedOperationMilliseconds ?? durationToMs(start.duration(to: clock.now))
        samples.append(SQLiteScaleSample(
            phase: phase, elapsedMilliseconds: elapsed,
            before: before, after: try? SQLiteScaleMemory.read(),
            returnedRows: nil, processedFixtureRows: nil, returnedContentBytes: nil,
            failure: String(describing: error), query: query, searchWork: work,
            recentWork: recent, recentPages: pages,
            sampleIndex: sampleIndex, isWarmup: isWarmup
        ))
        let repetition = sampleIndex.map { " sampleIndex=\($0) isWarmup=\(isWarmup == true)" } ?? ""
        print("sqlite-scale phase=\(phase)\(repetition) failed=\(error)")
        throw error
    }
}

/// Request-local work returned by the same production scan, including partial
/// work when its deadline/failure terminates the request. SQL posting-list and
/// planner work are not represented by these Swift row counters.
struct SQLiteScaleSearchWork: Codable, Sendable {
    let rowsDecoded: Int
    let rowsEvaluated: Int
    let matchesFound: Int
    let batchCount: Int
    let stopReason: String

    init(_ metrics: SearchWorkMetrics) {
        rowsDecoded = metrics.rowsDecoded
        rowsEvaluated = metrics.rowsEvaluated
        matchesFound = metrics.matchesFound
        batchCount = metrics.batchCount
        stopReason = metrics.stopReason.rawValue
    }
}
