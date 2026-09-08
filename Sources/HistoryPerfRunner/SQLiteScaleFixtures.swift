/// Deterministic synthetic clipboard profiles. The mixture is a reproducible
/// reference workload, not a distribution inferred from actual user histories.
import Foundation
import HistoryCore

struct SQLiteScaleFixtureProfile: Sendable {
    enum Kind: String, Sendable { case fixed, mixed }
    let kind: Kind
    let fixedBodyBytes: Int

    /// Every 10,000-row block contains exactly 2000/6400/1440/152/8 rows in
    /// these bands. A coprime stride spreads large rows through seed batches.
    func byteCount(at index: Int) -> Int {
        guard kind == .mixed else { return fixedBodyBytes }
        let slot = (index * 37) % 10_000
        let range: ClosedRange<Int>
        switch slot {
        case 0..<2_000: range = 32...512
        case 2_000..<8_400: range = 1_024...8_192
        case 8_400..<9_840: range = 8_192...65_536
        case 9_840..<9_992: range = 65_536...524_288
        default: range = 1_048_576...8_388_608
        }
        // Uniformly spaced discrete length samples keep exact histograms
        // bounded (at most 2048 lengths per band), without retaining a corpus.
        let sample = (index * 977 + (index / 10_000) * 37) % 2_048
        return range.lowerBound + (range.upperBound - range.lowerBound) * sample / 2_047
    }

    func capture(at index: Int) -> ClipboardCapture {
        guard kind == .mixed else {
            return deterministicTextCapture(index: index, bodyBytes: fixedBodyBytes)
        }
        let length = byteCount(at: index)
        let prefix = Data("perf-item-\(index)-\n".utf8)
        let block = Self.textBlocks[index % Self.textBlocks.count]
        var bytes = Data()
        bytes.reserveCapacity(length)
        bytes.append(prefix)
        while bytes.count + block.count <= length { bytes.append(block) }
        let remaining = length - bytes.count
        var tailLength = min(remaining, block.count)
        // Back up only over an unfinished UTF-8 scalar; pad the final 0...3
        // bytes with ASCII spaces so the requested byte length stays exact.
        while tailLength > 0, tailLength < block.count,
              block[tailLength] & 0xC0 == 0x80 {
            tailLength -= 1
        }
        bytes.append(block.prefix(tailLength))
        bytes.append(Data(repeating: 0x20, count: length - bytes.count))
        return ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: bytes)],
            origin: CopyOriginObservation(sourceApplication: "perf-runner", lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(index))
        )
    }

    /// ASCII 'z' and seven-digit runs are intentionally absent, preserving
    /// the negative-query oracle. These are ordinary text-shaped samples,
    /// with a stable first-line marker for exact per-item assertions.
    private static let textBlocks: [Data] = [
        "Please keep the meeting notes and send the next draft after lunch.\n",
        "请保留会议记录，下午讨论下一版方案。复制的短文与较长段落共同组成示例。\n",
        "https://example.test/docs/search?mode=exact&page=2\n",
        "rg --files Sources | head -n 20\nswift build --configuration release\n",
        "func greeting(name: String) -> String { return name + \" hello\" }\n",
        "2026-09-08 10:24:12 INFO request complete status=200 elapsed=42ms\n",
        "{\"kind\":\"note\",\"count\":42,\"active\":true,\"text\":\"meeting notes\"}\n",
    ].map { text in
        let fragment = Data(text.utf8)
        var block = Data()
        // A fixed roughly 8 KiB reusable block avoids a small append per sentence
        // when constructing the occasional multi-MiB item.
        while block.count + fragment.count <= 8_192 { block.append(fragment) }
        return block
    }
}

struct SQLiteScaleLengthStatistics: Codable, Sendable {
    let count: Int
    let totalBytes: Int64
    let meanBytes: Double
    let populationVarianceBytesSquared: Double
    let standardDeviationBytes: Double
    let minimumBytes: Int
    let maximumBytes: Int
    let p50Bytes: Int
    let p90Bytes: Int
    let p95Bytes: Int
    let p99Bytes: Int
    let p999Bytes: Int

    /// Weighted Welford moments and exact nearest-rank quantiles over a
    /// length-frequency histogram. Counts represent values, never item IDs.
    init(histogram: [Int: Int]) {
        let lengths = histogram.keys.sorted()
        var count = 0
        var total: Int64 = 0
        var mean = 0.0
        var m2 = 0.0
        for length in lengths {
            let frequency = histogram[length, default: 0]
            guard frequency > 0 else { continue }
            let nextCount = count + frequency
            let delta = Double(length) - mean
            mean += delta * Double(frequency) / Double(nextCount)
            m2 += delta * delta * Double(count) * Double(frequency) / Double(nextCount)
            count = nextCount
            total += Int64(length) * Int64(frequency)
        }
        func percentile(_ fraction: Double) -> Int {
            let rank = max(1, Int(ceil(Double(count) * fraction)))
            var cumulative = 0
            for length in lengths {
                cumulative += histogram[length, default: 0]
                if cumulative >= rank { return length }
            }
            return 0
        }
        self.count = count
        totalBytes = total
        meanBytes = mean
        populationVarianceBytesSquared = count == 0 ? 0 : m2 / Double(count)
        standardDeviationBytes = sqrt(populationVarianceBytesSquared)
        minimumBytes = lengths.first ?? 0
        maximumBytes = lengths.last ?? 0
        p50Bytes = percentile(0.5)
        p90Bytes = percentile(0.9)
        p95Bytes = percentile(0.95)
        p99Bytes = percentile(0.99)
        p999Bytes = percentile(0.999)
    }
}

struct SQLiteScaleFixtureStatistics: Codable, Sendable {
    let profile: String
    let rawUTF8Bytes: SQLiteScaleLengthStatistics?
    /// Actual persisted production projections, measured before mutations.
    let indexedTitleUTF8Bytes: SQLiteScaleLengthStatistics?
    let indexedSearchBodyUTF8Bytes: SQLiteScaleLengthStatistics?
}

func sqliteScaleRawLengthHistogram(profile: SQLiteScaleFixtureProfile, count: Int) -> [Int: Int] {
    var histogram: [Int: Int] = [:]
    for index in 0..<count { histogram[profile.byteCount(at: index), default: 0] += 1 }
    return histogram
}
