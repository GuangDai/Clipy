/// §9 coverage-map, complexity-envelope, and deterministic-vector helper proofs.
/// Split out of HistoryPerfRunnerHelperTests.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import Testing
@testable import HistoryPerfRunner

extension HistoryPerfRunnerHelperTests {
    @Test func admissionCaptureUsesProfileBoundAndUniqueEdgeMarkers() throws {
        let profile = AdmissionProfile(
            retainedRows: 2,
            searchBodyBytes: 128,
            sampleCount: 0,
            warmupCount: 0,
            pageLimit: 1
        )
        let first = admissionCapture(index: 7, profile: profile)
        let second = admissionCapture(index: 8, profile: profile)
        let firstBytes = try #require(first.representations.first?.bytes)
        let secondBytes = try #require(second.representations.first?.bytes)

        #expect(firstBytes.count == 128)
        #expect(secondBytes.count == 128)
        #expect(firstBytes != secondBytes)
        #expect(firstBytes.starts(with: Data("admission-row-7-".utf8)))
        let expectedSuffix = Data("-tail-7".utf8)
        #expect(Data(firstBytes.suffix(expectedSuffix.count)) == expectedSuffix)
    }

    @Test func pngCRC32MatchesPublishedCheckAndIHDRVectors() {
        // CRC-32/ISO-HDLC's published ASCII check vector.
        #expect(pngCRC32(Data("123456789".utf8)) == 0xCBF4_3926)

        // PNG 1×1, 8-bit truecolor IHDR: type bytes followed by its 13-byte
        // payload. The expected CRC is the widely published minimal-PNG
        // chunk value, independent from makeNoisePNG's construction.
        let ihdrTypeAndPayload = Data([
            0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00,
        ])
        #expect(pngCRC32(ihdrTypeAndPayload) == 0x9077_53DE)
    }

    @Test func xorshift32MatchesFixedStateAndProductionByteVectors() {
        // Marsaglia xorshift32 with shifts 13, 17, 5 and seed 1.
        var stateGenerator = XorShift32(seed: 1)
        var states: [UInt32] = []
        for _ in 0..<5 {
            states.append(stateGenerator.next())
        }
        #expect(states == [
            0x0004_2021,
            0x0408_0601,
            0x9DCC_A8C5,
            0x1255_994F,
            0x8EF9_17D1,
        ])

        var byteGenerator = XorShift32(seed: 0x9E37_79B9)
        var bytes: [UInt8] = []
        for _ in 0..<8 {
            bytes.append(byteGenerator.nextByte())
        }
        #expect(bytes == [
            0x19, 0x3E, 0x3A, 0xB5, 0x1F, 0x37, 0xD0, 0xBF,
        ])
    }

    @Test func section9CoverageMapDetectsDeletionAndLabelDrift() {
        var fixtures = section9WorkloadCoverage.map { key, expectation in
            Self.fixture(key: key, bullet: expectation.bulletLabel)
        }
        fixtures.removeAll { $0.key == "thumbnailSingleFlightSharesDecode" }
        if let recentIndex = fixtures.firstIndex(where: {
            $0.key == "recentBrowseIndependentOfRetainedCount"
        }) {
            fixtures[recentIndex] = Self.fixture(
                key: "recentBrowseIndependentOfRetainedCount",
                bullet: "7"
            )
        }

        let issues = section9CoverageIssues(fixtures)
        #expect(issues.contains { $0.contains("thumbnailSingleFlightSharesDecode") })
        #expect(issues.contains { $0.contains("recentBrowseIndependentOfRetainedCount") })
        #expect(issues.contains { $0.contains("emitted workloads cover") })
    }

    internal static func isCompletedWarmup(
        _ event: AdmissionProgressEvent,
        index: Int,
        total: Int
    ) -> Bool {
        guard case let .warmupCompleted(
            actualIndex,
            actualTotal,
            elapsedMs
        ) = event else {
            return false
        }
        return actualIndex == index && actualTotal == total && elapsedMs >= 0
    }

    internal static func isCompletedSample(
        _ event: AdmissionProgressEvent,
        index: Int,
        total: Int
    ) -> Bool {
        guard case let .sampleCompleted(
            actualIndex,
            actualTotal,
            elapsedMs
        ) = event else {
            return false
        }
        return actualIndex == index && actualTotal == total && elapsedMs >= 0
    }

    @Test func section9ComplexityEnvelopeTableIsInternallyValid() {
        #expect(section9ComplexityEnvelopeIssues().isEmpty)
        #expect(
            Set(section9WorkloadEnvelopes.keys)
                == Set(section9WorkloadCoverage.keys)
                    .subtracting(section9RecordOnlyWorkloads)
        )
    }

    @Test func complexityEnvelopeValidationRejectsBadSpanAndHeadroom() {
        var envelopes = section9WorkloadEnvelopes
        envelopes["pinReorderLinearInPinnedCount"] = WorkloadComplexityEnvelope(
            measurementScales: [50, 200],
            growth: .linear,
            bound: 5.9,
            headroomPolicy: .standard
        )
        envelopes["exactSearchScalesWithRetainedCount"] = WorkloadComplexityEnvelope(
            measurementScales: [400, 100],
            growth: .linear,
            bound: 8,
            headroomPolicy: .standard
        )
        envelopes["recentBrowseIndependentOfRetainedCount"] =
            WorkloadComplexityEnvelope(
                measurementScales: [100, 400],
                growth: .constant,
                bound: 3,
                headroomPolicy: .wl1aRetainedInventoryException
            )

        let issues = section9ComplexityEnvelopeIssues(envelopes: envelopes)
        #expect(issues.contains { issue in
            issue.contains("pinReorderLinearInPinnedCount")
                && issue.contains("headroom")
        })
        #expect(issues.contains { issue in
            issue.contains("exactSearchScalesWithRetainedCount")
                && issue.contains("strictly increasing")
        })
        #expect(issues.contains { issue in
            issue.contains("recentBrowseIndependentOfRetainedCount")
                && issue.contains("cannot use WL1a")
        })
    }

    internal static func fixture(key: String, bullet: String) -> WorkloadFixture {
        WorkloadFixture(
            key: key,
            bullet: bullet,
            sizes: [],
            mediansMs: [],
            ratio: nil,
            bound: nil,
            pass: true,
            note: "coverage-map test fixture"
        )
    }
}
