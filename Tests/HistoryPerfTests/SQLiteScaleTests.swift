import Foundation
import Testing
@testable import HistoryPerfRunner

struct SQLiteScaleTests {
    @Test func argumentsAcceptDocumentedScalesWithoutWideningPayloadBounds() throws {
        for rows in [10_000, 100_000, 1_000_000] {
            let options = try SQLiteScaleArguments([
                "measure", "/tmp/fixture.sqlite", String(rows), "262144", "/tmp/result.json",
            ])
            #expect(options.retainedRows == rows)
            #expect(options.bodyBytes == 262_144)
        }
        for (rows, bytes) in [(0, 64), (1_000_001, 64), (10_000, 0), (10_000, 262_145)] {
            #expect(throws: SQLiteScaleError.self) {
                try SQLiteScaleArguments(["seed", "/tmp/fixture.sqlite", String(rows), String(bytes), "/tmp/result.json"])
            }
        }
    }

    @Test func diskReportCountsPhysicalFilesSeparatelyFromApparentBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scale-disk-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x61, count: 17).write(to: root.appendingPathComponent("history.sqlite"))
        try Data(repeating: 0x62, count: 33).write(to: root.appendingPathComponent("blobs/value"))
        let disk = try SQLiteScaleDisk.read(root: root)
        #expect(disk.apparentBytes == 50)
        #expect(disk.regularFileCount == 2)
        #expect(disk.allocatedBytes >= 0)
    }

    @Test func failedOperationRetainsCompletedAndFailedPhaseEvidence() async throws {
        var samples: [SQLiteScaleSample] = []
        _ = try await measureSQLiteScale(phase: "complete", samples: &samples) { 37 }
        do {
            try await measureSQLiteScale(phase: "failed", samples: &samples) { () async throws -> Void in
                throw SQLiteScaleError.unexpectedResult
            }
            Issue.record("expected the operation failure to propagate")
        } catch SQLiteScaleError.unexpectedResult {
            #expect(samples.map(\.phase) == ["complete", "failed"])
            #expect(samples[0].failure == nil)
            #expect(samples[1].failure != nil)
        }
    }
}
