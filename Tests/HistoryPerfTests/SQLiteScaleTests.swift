import Foundation
import HistoryCore
import Testing
@testable import HistoryPerfRunner

struct SQLiteScaleTests {
    @Test func argumentsAcceptDocumentedScalesWithoutWideningPayloadBounds() throws {
        for rows in [10_000, 100_000] {
            let options = try SQLiteScaleArguments([
                "measure", "/tmp/fixture.sqlite", String(rows), "262144", "/tmp/result.json",
            ])
            #expect(options.retainedRows == rows)
            #expect(options.bodyBytes == 262_144)
        }
        for (rows, bytes) in [(0, 64), (100_001, 64), (10_000, 0), (10_000, 262_145)] {
            #expect(throws: SQLiteScaleError.self) {
                try SQLiteScaleArguments(["seed", "/tmp/fixture.sqlite", String(rows), String(bytes), "/tmp/result.json"])
            }
        }
    }

    @Test func mixedProfileHasEightyVeryLargeValuesWithoutRetainingTheirContents() {
        let profile = SQLiteScaleFixtureProfile(kind: .mixed, fixedBodyBytes: 1_024)
        let histogram = sqliteScaleRawLengthHistogram(profile: profile, count: 100_000)
        #expect(histogram.values.reduce(0, +) == 100_000)
        #expect(histogram.filter { $0.key <= 512 }.values.reduce(0, +) == 20_000)
        #expect(histogram.filter { $0.key >= 1_048_576 }.values.reduce(0, +) == 80)
        #expect(histogram.count <= 5 * 2_048)
    }

    @Test func mixedContentHasExactByteLengthsAndValidUTF8() throws {
        let profile = SQLiteScaleFixtureProfile(kind: .mixed, fixedBodyBytes: 1_024)
        let firstLargeIndex = try #require((0..<10_000).first { profile.byteCount(at: $0) >= 1_048_576 })
        for index in [0, 1, 2, 3, 4, 5, 6, firstLargeIndex, 99_999] {
            let capture = profile.capture(at: index)
            let bytes = try #require(capture.representations.first?.bytes)
            let text = try #require(String(data: bytes, encoding: .utf8))
            #expect(bytes.count == profile.byteCount(at: index))
            #expect(text.hasPrefix("perf-item-\(index)-\n"))
            #expect(!text.contains("1234567"))
            #expect(!text.contains("1111111"))
            #expect(!text.lowercased().contains("z"))
        }
    }

    @Test func designatedLargeMarkerStaysInsideTheDurableUTF8Prefix() throws {
        for profile in [
            SQLiteScaleFixtureProfile(kind: .mixed, fixedBodyBytes: 1_024),
            SQLiteScaleFixtureProfile(kind: .fixed, fixedBodyBytes: 64),
            SQLiteScaleFixtureProfile(kind: .fixed, fixedBodyBytes: 262_144),
        ] {
            let index = profile.largestBodyIndex(in: 10_000)
            let bytes = try #require(profile.capture(at: index, includeLargeBodyHit: true).representations.first?.bytes)
            let text = try #require(String(data: bytes, encoding: .utf8))
            let marker = try #require(text.range(of: "largebodyhit"))
            let markerStart = text[..<marker.lowerBound].utf8.count
            let markerEnd = text[..<marker.upperBound].utf8.count
            #expect(bytes.count == profile.byteCount(at: index))
            #expect(markerEnd <= HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes)
            #expect(markerStart >= min(bytes.count, HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes) - 20)
            #expect(text.range(of: "largebodyhit", range: marker.upperBound..<text.endIndex) == nil)
            if profile.kind == .mixed { #expect(bytes.count >= 1_048_576) }
        }
    }

    @Test func weightedHistogramReportsPopulationVarianceAndNearestRankQuantiles() {
        let statistics = SQLiteScaleLengthStatistics(histogram: [10: 2, 20: 1, 30: 1])
        #expect(statistics.count == 4)
        #expect(statistics.totalBytes == 70)
        #expect(statistics.meanBytes == 17.5)
        #expect(abs(statistics.populationVarianceBytesSquared - 68.75) < 0.000_001)
        #expect(statistics.minimumBytes == 10)
        #expect(statistics.maximumBytes == 30)
        #expect(statistics.p50Bytes == 10)
        #expect(statistics.p90Bytes == 30)
        #expect(statistics.p999Bytes == 30)
    }

    @Test func argumentsSelectMixedWithoutChangingTheFixedComparison() throws {
        let fixed = try SQLiteScaleArguments(["seed", "/tmp/fixture.sqlite", "100000", "1024", "/tmp/out.json"])
        let mixed = try SQLiteScaleArguments(["seed", "/tmp/fixture.sqlite", "100000", "1024", "/tmp/out.json", "mixed"])
        #expect(fixed.fixtureProfile.kind == .fixed)
        #expect(fixed.fixtureProfile.byteCount(at: 5) == 1_024)
        #expect(mixed.fixtureProfile.kind == .mixed)
        #expect(mixed.fixtureProfile.byteCount(at: 5) != 1_024)
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

    @Test func representativeSearchCasesMatchIndependentRecentPages() async throws {
        let history = try await openMemoryStore()
        let profile = SQLiteScaleFixtureProfile(kind: .mixed, fixedBodyBytes: 128)
        let largeBodyIndex = profile.largestBodyIndex(in: 120)
        _ = try await history.seedPerformanceFixture(rowCount: 120) { index in
            profile.capture(at: index, includeLargeBodyHit: index == largeBodyIndex)
        }
        let corpus = try await traverseSQLiteScale(history: history, expectedCount: 120, largeBodyIndex: largeBodyIndex)
        let position = try await history.usage().position
        var samples: [SQLiteScaleSample] = []
        try await exerciseSQLiteScaleSearches(
            history: history, corpus: corpus, position: position, samples: &samples
        )
        #expect(samples.allSatisfy { $0.failure == nil })
        for repetitions in Dictionary(grouping: samples, by: \.phase).values {
            #expect(repetitions.count == sqliteScaleSearchTimedSampleCount + 1)
            #expect(repetitions.compactMap(\.sampleIndex) == Array(0...sqliteScaleSearchTimedSampleCount))
            #expect(repetitions.filter { $0.isWarmup == true }.map(\.sampleIndex) == [0])
            #expect(repetitions.filter { $0.isWarmup == false }.count == sqliteScaleSearchTimedSampleCount)
            #expect(repetitions.allSatisfy {
                $0.query != nil && $0.searchWork != nil && $0.elapsedMilliseconds.isFinite
                    && $0.elapsedMilliseconds > 0
            })
        }
        for phase in [
            "search-exact-body-dense-page1", "search-exact-body-dense-page2",
            "search-exact-body-rare-page1", "search-expression-common-rare-page1",
            "search-expression-rare-common-page1", "search-exact-body-rare-large-page1",
            "search-expression-rare-large-common-title-page1",
        ] {
            let measured = try #require(samples.first { $0.phase == phase })
            #expect(measured.returnedRows == (phase.contains("dense") ? 50 : 1))
            #expect(measured.query?.expectedSnippetMatch != nil)
            #expect((measured.searchWork?.matchesFound ?? 0) > 0)
        }
        let titleAndLarge = try #require(samples.first { $0.phase == "search-expression-common-title-rare-large-page1" })
        #expect(titleAndLarge.returnedRows == 1)
        #expect(titleAndLarge.query?.expectedSnippetMatch == nil)
        let repeatedCommon = try #require(samples.first { $0.phase == "search-expression-repeated-common-page1" })
        #expect(repeatedCommon.returnedRows == 50)
        #expect(repeatedCommon.query?.expectedTotalMatches == 120)
        #expect((repeatedCommon.searchWork?.matchesFound ?? 0) >= 50)
        let sparse = try #require(samples.first { $0.phase == "search-exact-oldest-page1" })
        #expect(sparse.returnedRows == 1)
        let work = try #require(sparse.searchWork)
        #expect(work.rowsDecoded >= 1)
        #expect(work.rowsEvaluated >= 1)
        #expect(work.matchesFound == 1)
        #expect(work.batchCount >= 1)
        let typoSecond = try #require(samples.first { $0.phase == "search-fuzzy-typo-page2" })
        #expect(typoSecond.returnedRows == 50)
        #expect(typoSecond.query?.expectedTotalMatches == 120)
        for phase in [
            "search-exact-common-grams-no-intersection-page1",
            "search-exact-repeated-gram-no-hit-page1",
            "search-regexp-common-grams-no-intersection-page1",
            "search-regexp-structural-no-hit-page1",
            "search-fuzzy-mixed-presence-no-hit-page1",
        ] {
            let measured = try #require(samples.first { $0.phase == phase })
            #expect(measured.failure == nil)
            #expect(measured.returnedRows == 0)
            #expect(measured.query?.expectedTotalMatches == 0)
        }
    }

    @Test func largeBodyTailExcerptAndIdentityMatchTheOriginalFixture() async throws {
        let history = try await openMemoryStore()
        let profile = SQLiteScaleFixtureProfile(kind: .mixed, fixedBodyBytes: 128)
        let index = profile.largestBodyIndex(in: 10_000)
        let capture = profile.capture(at: index, includeLargeBodyHit: true)
        let expectedBytes = try #require(capture.representations.first?.bytes)
        let expectedText = try #require(String(data: expectedBytes, encoding: .utf8))
        _ = try await history.seedPerformanceFixture(rowCount: 3) { row in
            row == 2 ? capture : profile.capture(at: row)
        }
        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 3))
        let expected = try #require(recent.rows.first)
        #expect(expected.title == "perf-item-\(index)-")
        let original = try await history.pastePayload(for: expected.item.id)
        #expect(original.representations.first?.bytes == expectedBytes)

        for (query, mode) in [
            ("largebodyhit", SearchMode.exact),
            ("largebodyhit AND perf-item-", SearchMode.expression),
        ] {
            let measured = await history.measureSearch(HistoryBrowseRequest(kind: .search(text: query, mode: mode), limit: 3))
            let page = try measured.result.get()
            try validateSQLiteScaleSearchPage(
                page, expectedRows: [expected], expectedPosition: recent.position,
                expectedTotalMatches: 1, pageIndex: 0, limit: 3, expectedSnippetMatch: "largebodyhit"
            )
            let snippet = try #require(page.rows.first?.search?.snippet)
            #expect(snippet.count <= HistoryLimits.standard.maximumBodySearchSnippetCharacters)
            #expect(snippet.hasPrefix("…"))
            let sourceWindow = snippet.dropFirst().hasSuffix("…")
                ? snippet.dropFirst().dropLast() : snippet.dropFirst()
            #expect(expectedText.contains(sourceWindow))
            #expect(measured.metrics.matchesFound == 1)
        }
    }

    @Test func failedMeasuredSearchKeepsItsRequestWorkAlongsideTheFailure() async throws {
        let history = try await openMemoryStore()
        var samples: [SQLiteScaleSample] = []
        do {
            _ = try await measureSQLiteScale(
                phase: "invalid-regexp", samples: &samples, sampleIndex: 3, isWarmup: false
            ) {
                await history.measureSearch(HistoryBrowseRequest(
                    kind: .search(text: "[", mode: .regexp), limit: 50
                ))
            } facts: { measured in
                (try measured.result.get().rows.count, 0)
            } searchWork: { SQLiteScaleSearchWork($0.metrics) }
            Issue.record("expected invalid regexp failure")
        } catch {
            let sample = try #require(samples.first)
            #expect(sample.failure != nil)
            #expect(sample.sampleIndex == 3)
            #expect(sample.isWarmup == false)
            #expect(sample.returnedRows == nil)
            let work = try #require(sample.searchWork)
            #expect(work.rowsDecoded == 0)
            #expect(work.rowsEvaluated == 0)
            #expect(work.stopReason == "failed")
        }
    }

    @Test func failedSearchValidationKeepsLaterEvidenceButFailsTheWholeWorkload() async throws {
        let count = 4
        let history = try await openMemoryStore()
        let profile = SQLiteScaleFixtureProfile(kind: .mixed, fixedBodyBytes: 128)
        let largeBodyIndex = profile.largestBodyIndex(in: count)
        _ = try await history.seedPerformanceFixture(rowCount: count) { index in
            profile.capture(at: index, includeLargeBodyHit: index == largeBodyIndex)
        }
        let actual = try await traverseSQLiteScale(
            history: history, expectedCount: count, largeBodyIndex: largeBodyIndex
        )
        // Deliberately remove one known expected identity. The real oldest
        // query still returns that row and must fail result validation.
        let wrongExpectedRows = SQLiteScaleBrowseEvidence(
            count: actual.count, leadingRows: actual.leadingRows, oldestRow: nil, largeBodyRow: actual.largeBodyRow
        )
        let position = try await history.usage().position
        var samples: [SQLiteScaleSample] = []
        await #expect(throws: SQLiteScaleError.self) {
            try await exerciseSQLiteScaleSearches(
                history: history, corpus: wrongExpectedRows, position: position, samples: &samples
            )
        }
        let failed = try #require(samples.first { $0.phase == "search-exact-oldest-page1" })
        #expect(failed.failure != nil)
        #expect(failed.returnedRows == nil)
        #expect(failed.searchWork?.matchesFound == 1)
        #expect(failed.sampleIndex == 0)
        let later = samples.filter { $0.phase == "search-fuzzy-typo-page1" }
        #expect(later.count == sqliteScaleSearchTimedSampleCount + 1)
        #expect(later.allSatisfy { $0.failure == nil && $0.returnedRows == count })
    }

    @Test func historicalSamplesDecodeWithoutSearchRepetitionFields() throws {
        let historical = Data(#"{"phase":"search-exact-oldest-page1","elapsedMilliseconds":7.2,"before":{"residentBytes":16000000,"peakResidentBytesSinceLaunch":17000000,"footprintBytes":5000000},"returnedRows":1,"searchWork":{"rowsDecoded":1,"rowsEvaluated":1,"matchesFound":1,"batchCount":1,"stopReason":"exhausted"}}"#.utf8)
        let decoded = try JSONDecoder().decode(SQLiteScaleSample.self, from: historical)
        #expect(decoded.sampleIndex == nil)
        #expect(decoded.isWarmup == nil)
        #expect(decoded.returnedRows == 1)
        #expect(decoded.searchWork?.rowsDecoded == 1)
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
            #expect(samples.allSatisfy { $0.sampleIndex == nil && $0.isWarmup == nil })
            #expect(samples[1].returnedRows == nil)
            #expect(samples[1].returnedContentBytes == nil)
        }
    }
}
