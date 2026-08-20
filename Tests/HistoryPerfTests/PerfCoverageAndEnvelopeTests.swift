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

    @Test func section9CoverageMapAcceptsEveryRequiredWorkloadAndBullet() {
        let fixtures = section9WorkloadCoverage.map { key, expectation in
            Self.fixture(key: key, bullet: expectation.bulletLabel)
        }
        #expect(section9CoverageIssues(fixtures).isEmpty)
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

    @Test func section9CoverageMapRequiresEveryFrozenSearchMode() {
        let searchKeys = [
            "exactSearchScalesWithRetainedCount",
            "fuzzySearchScalesWithRetainedCount",
            "regexpSearchScalesWithRetainedCount",
        ]
        for key in searchKeys {
            #expect(section9WorkloadCoverage[key]?.bulletLabel == "7")
            #expect(section9WorkloadCoverage[key]?.bulletNumbers == Set([7]))
        }

        var fixtures = section9WorkloadCoverage.map { key, expectation in
            Self.fixture(key: key, bullet: expectation.bulletLabel)
        }
        fixtures.removeAll { $0.key == "fuzzySearchScalesWithRetainedCount" }

        let issues = section9CoverageIssues(fixtures)
        #expect(issues.contains { $0.contains("fuzzySearchScalesWithRetainedCount") })
    }

    @Test func section9CoverageMapNamesTheWarmPersistentOpenConstruct() {
        let key = "persistentStoreOpenScalesWithRetainedMetadata"
        #expect(section9WorkloadCoverage[key]?.bulletLabel == "3")
        #expect(section9WorkloadCoverage[key]?.bulletNumbers == Set([3]))
        #expect(
            section9WorkloadCoverage[
                "indexRebuildLinearInRetainedSignatureMetadata"
            ]?.bulletLabel == nil
        )
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

    @Test func wl1aExplicitlyUsesTheDocumentedOnePointTwoHeadroomException() throws {
        let envelope = try #require(
            section9WorkloadEnvelopes["captureScalesWithRetainedCount"]
        )

        #expect(envelope.measurementScales == [200, 1_000])
        #expect(envelope.scaleSpan == 5)
        #expect(envelope.theoreticalRatio == 5)
        #expect(envelope.bound == 6)
        #expect(envelope.headroomFactor == 1.2)
        switch envelope.headroomPolicy {
        case .standard:
            Issue.record("WL1a silently inherited the general 1.5× floor")
        case .wl1aRetainedInventoryException:
            break
        }
    }

    @Test func standardLinearEnvelopeDerivesRatioAndHeadroomFromItsScale() throws {
        let envelope = try #require(
            section9WorkloadEnvelopes[
                "persistentStoreOpenScalesWithRetainedMetadata"
            ]
        )

        #expect(envelope.measurementScales == [200, 500, 1_000])
        #expect(envelope.scaleSpan == 5)
        #expect(envelope.theoreticalRatio == 5)
        #expect(envelope.bound == 8)
        #expect(envelope.headroomFactor == 1.6)
        switch envelope.headroomPolicy {
        case .standard:
            break
        case .wl1aRetainedInventoryException:
            Issue.record("A standard workload used WL1a's narrow exception")
        }
    }

    @Test func constantEnvelopeUsesOneAsItsTheoreticalRatio() throws {
        let envelope = try #require(
            section9WorkloadEnvelopes[
                "recentBrowseIndependentOfRetainedCount"
            ]
        )

        #expect(envelope.scaleSpan == 4)
        #expect(envelope.theoreticalRatio == 1)
        #expect(envelope.bound == 3)
        #expect(envelope.headroomFactor == 3)
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
