/// Record-only Release A/B for the exact literal matcher (IND-07).
/// Split out of Admission.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

struct AdmissionMatcherPairSamples {
    let foundation: [Double]
    let compiled: [Double]
    let pairedRatios: [Double]
    let checksum: UInt64
}

func foundationExactMatch(
    term: String,
    in body: String
) -> ExactLiteralMatch? {
    guard let range = body.range(
        of: term,
        options: [.caseInsensitive, .literal]
    ) else {
        return nil
    }
    let utf16Range = NSRange(range, in: body)
    return ExactLiteralMatch(
        characterOffset: body.distance(
            from: body.startIndex,
            to: range.lowerBound
        ),
        characterLength: body.distance(
            from: range.lowerBound,
            to: range.upperBound
        ),
        utf16Offset: utf16Range.location,
        utf16Length: utf16Range.length
    )
}

func admissionMix(_ value: Int, into checksum: inout UInt64) {
    checksum ^= UInt64(value) &+ 0x9E37_79B9_7F4A_7C15
    checksum &*= 1_099_511_628_211
}

func admissionMix(
    _ match: ExactLiteralMatch?,
    ordinal: Int,
    into checksum: inout UInt64
) {
    admissionMix(ordinal + 1, into: &checksum)
    guard let match else {
        admissionMix(0, into: &checksum)
        return
    }
    admissionMix(1, into: &checksum)
    admissionMix(match.characterOffset + 1, into: &checksum)
    admissionMix(match.characterLength + 1, into: &checksum)
    admissionMix(match.utf16Offset + 1, into: &checksum)
    admissionMix(match.utf16Length + 1, into: &checksum)
}

func foundationExactChecksum(
    term: String,
    bodies: [String]
) -> UInt64 {
    var checksum: UInt64 = 14_695_981_039_346_656_037
    for (ordinal, body) in bodies.enumerated() {
        admissionMix(
            foundationExactMatch(term: term, in: body),
            ordinal: ordinal,
            into: &checksum
        )
    }
    return checksum
}

func compiledExactChecksum(
    matcher: ExactLiteralMatcher,
    bodies: [String]
) -> UInt64 {
    var checksum: UInt64 = 14_695_981_039_346_656_037
    for (ordinal, body) in bodies.enumerated() {
        admissionMix(
            matcher.firstMatch(in: body),
            ordinal: ordinal,
            into: &checksum
        )
    }
    return checksum
}

func timedMatcherOperation(
    _ operation: () -> UInt64
) -> (elapsedMs: Double, checksum: UInt64) {
    let clock = ContinuousClock()
    let start = clock.now
    let checksum = autoreleasepool(invoking: operation)
    return (durationToMs(start.duration(to: clock.now)), checksum)
}

/// Measures one Foundation/compiled pair per round, alternating AB and BA.
/// The paired ratios therefore compare the same warmed corpus at adjacent
/// points instead of comparing two separately blocked 11-sample runs.
func measurePairedMatcherSamples(
    warmups: Int,
    iterations: Int,
    foundation: () -> UInt64,
    compiled: () -> UInt64
) throws -> AdmissionMatcherPairSamples {
    var foundationSamples: [Double] = []
    var compiledSamples: [Double] = []
    var pairedRatios: [Double] = []
    foundationSamples.reserveCapacity(iterations)
    compiledSamples.reserveCapacity(iterations)
    pairedRatios.reserveCapacity(iterations)
    var checksum: UInt64 = 0

    for round in 0..<(warmups + iterations) {
        let foundationResult: (elapsedMs: Double, checksum: UInt64)
        let compiledResult: (elapsedMs: Double, checksum: UInt64)
        if round.isMultiple(of: 2) {
            foundationResult = timedMatcherOperation(foundation)
            compiledResult = timedMatcherOperation(compiled)
        } else {
            compiledResult = timedMatcherOperation(compiled)
            foundationResult = timedMatcherOperation(foundation)
        }
        guard foundationResult.checksum == compiledResult.checksum else {
            throw AdmissionError.exactMatcherMismatch
        }
        guard foundationResult.elapsedMs.isFinite,
              compiledResult.elapsedMs.isFinite,
              foundationResult.elapsedMs > 0,
              compiledResult.elapsedMs > 0
        else {
            throw AdmissionError.invalidExactMatcherMeasurement
        }
        guard round >= warmups else { continue }
        foundationSamples.append(foundationResult.elapsedMs)
        compiledSamples.append(compiledResult.elapsedMs)
        pairedRatios.append(
            compiledResult.elapsedMs / foundationResult.elapsedMs
        )
        checksum &+= foundationResult.checksum &* UInt64(round + 1)
    }

    return AdmissionMatcherPairSamples(
        foundation: foundationSamples,
        compiled: compiledSamples,
        pairedRatios: pairedRatios,
        checksum: checksum
    )
}

func measureMatcherConstruction(
    term: String,
    warmups: Int,
    iterations: Int,
    constructionsPerSample: Int
) throws -> (samples: [Double], checksum: UInt64) {
    let operation = {
        var checksum: UInt64 = 14_695_981_039_346_656_037
        for ordinal in 0..<constructionsPerSample {
            let matcher = ExactLiteralMatcher(term: term)
            admissionMix(
                matcher.firstMatch(in: term),
                ordinal: ordinal,
                into: &checksum
            )
        }
        return checksum
    }
    for _ in 0..<warmups {
        _ = timedMatcherOperation(operation)
    }
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    var checksum: UInt64 = 0
    for ordinal in 0..<iterations {
        let result = timedMatcherOperation(operation)
        guard result.elapsedMs.isFinite, result.elapsedMs > 0 else {
            throw AdmissionError.invalidExactMatcherMeasurement
        }
        samples.append(result.elapsedMs)
        checksum &+= result.checksum &* UInt64(ordinal + 1)
    }
    return (samples, checksum)
}

/// One unbuffered stderr line per case so a stalled A/B dispatch shows
/// exactly which case (and side) consumed the budget in the artifact log.
func admissionMatcherABProgress(_ line: String) {
    try? FileHandle.standardError.write(
        contentsOf: Data("matcher-ab: \(line)\n".utf8)
    )
}

func measureAdmissionExactMatcherAB(outputPath: String) throws {
    // 32 MiB exceeds the private/cache footprint of the supported Apple-
    // silicon runner class while remaining a short, allocation-stable lane.
    let bodiesPerSample = 128
    let warmups = 2
    let iterations = 11
    let constructionsPerSample = 256
    var fixtures: [AdmissionExactMatcherABCase] = []

    let progressClock = ContinuousClock()
    for input in admissionExactMatcherABInputs() {
        admissionMatcherABProgress(
            "case \(input.name) begin bodies=\(input.bodiesPerSample)"
        )
        let caseStart = progressClock.now
        let bodies = (0..<input.bodiesPerSample).map(input.makeBody)
        precondition(bodies.allSatisfy {
            $0.utf8.count == admissionSearchBodyBytes
        })
        let matcher = ExactLiteralMatcher(term: input.term)

        // Correctness is outside the timed region and compares every row and
        // all four coordinate fields. The rolling hash below is only an
        // optimization barrier, never the semantic proof.
        let expected = bodies.map {
            foundationExactMatch(term: input.term, in: $0)
        }
        let actual = bodies.map { matcher.firstMatch(in: $0) }
        guard expected == actual else {
            throw AdmissionError.exactMatcherMismatch
        }

        let paired = try measurePairedMatcherSamples(
            warmups: warmups,
            iterations: iterations,
            foundation: {
                foundationExactChecksum(term: input.term, bodies: bodies)
            },
            compiled: {
                compiledExactChecksum(matcher: matcher, bodies: bodies)
            }
        )
        let construction = try measureMatcherConstruction(
            term: input.term,
            warmups: warmups,
            iterations: iterations,
            constructionsPerSample: constructionsPerSample
        )
        let foundationMedian = median(paired.foundation)
        let compiledMedian = median(paired.compiled)
        let pairedMedian = median(paired.pairedRatios)
        let caseElapsedMs = Int(
            durationToMs(caseStart.duration(to: progressClock.now))
        )
        admissionMatcherABProgress(
            "case \(input.name) end elapsed_ms=\(caseElapsedMs)"
        )
        fixtures.append(AdmissionExactMatcherABCase(
            name: input.name,
            decisionClass: input.decisionClass,
            maximumPairedMedianRatio: input.maximumPairedMedianRatio,
            termUTF8Bytes: input.term.utf8.count,
            bodiesPerSample: input.bodiesPerSample,
            logicalBytesPerSample: input.bodiesPerSample
                * admissionSearchBodyBytes,
            foundationRawSamplesMs: paired.foundation,
            compiledRawSamplesMs: paired.compiled,
            pairedRawRatios: paired.pairedRatios,
            foundationMedianMs: foundationMedian,
            compiledMedianMs: compiledMedian,
            compiledToFoundationRatio: compiledMedian / foundationMedian,
            pairedMedianRatio: pairedMedian,
            pairedP25Ratio: nearestRankPercentile(
                paired.pairedRatios,
                percentile: 0.25
            ),
            pairedP75Ratio: nearestRankPercentile(
                paired.pairedRatios,
                percentile: 0.75
            ),
            passesDecisionThreshold: pairedMedian
                <= input.maximumPairedMedianRatio,
            compiledConstructionRawSamplesMs: construction.samples,
            compiledConstructionMedianMs: median(construction.samples),
            checksum: paired.checksum ^ construction.checksum
        ))
    }

    try writeAdmissionFixture(AdmissionExactMatcherABFixture(
        schemaVersion: 2,
        mode: AdmissionMode.exactMatcherAB.rawValue,
        evidenceClass: "release-matcher-ab-record-only",
        machine: admissionMachineMetadata(),
        swiftVersion: commandOutput(
            "/usr/bin/xcrun",
            arguments: ["swift", "--version"]
        ),
        date: admissionDate(),
        bodiesPerSample: bodiesPerSample,
        bodyBytes: admissionSearchBodyBytes,
        warmupCount: warmups,
        sampleCount: iterations,
        constructionsPerSample: constructionsPerSample,
        productionIntegrationEligible: fixtures.allSatisfy(
            \.passesDecisionThreshold
        ),
        scopeLimitations: [
            "Record-only matcher screening; not G2, G8, or candidate-index evidence.",
            "Logical bytes are corpus size, not bytes actually inspected by early-hit or fallback paths.",
            "Production integration also requires a one-to-three-call same-store Release end-to-end comparison.",
        ],
        cases: fixtures
    ), to: outputPath)
}

