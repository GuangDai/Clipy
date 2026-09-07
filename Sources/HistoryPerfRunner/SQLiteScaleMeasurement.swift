/// V2-09 §10: record-only measurements over real SQLite/blob stores. Each
/// sample contains whole-process kernel facts, not cache attribution.
import Darwin
import Foundation
import HistoryCore

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
    let rowsVisited: Int?
    /// Bytes explicitly returned by purpose-specific content reads. This is
    /// neither total process-owned memory nor retained logical store bytes.
    let returnedContentBytes: Int?
    let failure: String?
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
    let bodyBytes: Int
    let operatingSystem: String
    let physicalMemoryBytes: UInt64
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
    operation: () async throws -> T,
    facts: (T) -> (rows: Int, contentBytes: Int) = { _ in (0, 0) }
) async throws -> T {
    let before = try SQLiteScaleMemory.read()
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let result = try await operation()
        let elapsed = durationToMs(start.duration(to: clock.now))
        let after = try SQLiteScaleMemory.read()
        let resultFacts = facts(result)
        samples.append(SQLiteScaleSample(
            phase: phase, elapsedMilliseconds: elapsed,
            before: before, after: after,
            rowsVisited: resultFacts.rows, returnedContentBytes: resultFacts.contentBytes,
            failure: nil
        ))
        print("sqlite-scale phase=\(phase) elapsedMs=\(elapsed) rss=\(after.residentBytes)")
        return result
    } catch {
        // Keep completed and failed timing evidence when a later workload
        // cannot finish. A failed phase carries no fabricated row/payload facts.
        let elapsed = durationToMs(start.duration(to: clock.now))
        samples.append(SQLiteScaleSample(
            phase: phase, elapsedMilliseconds: elapsed,
            before: before, after: try? SQLiteScaleMemory.read(),
            rowsVisited: nil, returnedContentBytes: nil,
            failure: String(describing: error)
        ))
        print("sqlite-scale phase=\(phase) failed=\(error)")
        throw error
    }
}
