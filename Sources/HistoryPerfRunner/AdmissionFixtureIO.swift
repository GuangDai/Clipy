/// Admission fixture encode/decode IO.
/// Split out of Admission.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

func makeAdmissionFixture(
    mode: AdmissionMode,
    profile: AdmissionProfile = .full,
    sampleUnit: String,
    samples: [Double],
    setupWallTimeMs: Double? = nil,
    validation: [String: String],
    notes: [String]
) -> AdmissionFixture {
    precondition(samples.isEmpty == (setupWallTimeMs != nil))
    precondition(
        setupWallTimeMs.map { $0.isFinite && $0 > 0 } ?? true
    )
    return AdmissionFixture(
        schemaVersion: 2,
        mode: mode.rawValue,
        sampleUnit: sampleUnit,
        machine: admissionMachineMetadata(),
        swiftVersion: commandOutput(
            "/usr/bin/xcrun",
            arguments: ["swift", "--version"]
        ),
        date: admissionDate(),
        corpusRows: profile.retainedRows,
        bodyBytesPerRow: profile.searchBodyBytes,
        warmupCount: mode.isSetupFixture ? 0 : profile.warmupCount,
        setupWallTimeMs: setupWallTimeMs,
        rawSamplesMs: samples,
        percentiles: admissionPercentilesIfSupported(samples),
        validation: validation,
        notes: notes
    )
}

func writeAdmissionFixture<Fixture: Encodable>(
    _ fixture: Fixture,
    to outputPath: String
) throws {
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(fixture).write(to: outputURL)
}

func readAdmissionSeedFixture(
    from outputPath: String
) throws -> AdmissionSeedFixture {
    let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
    return try JSONDecoder().decode(AdmissionSeedFixture.self, from: data)
}

@discardableResult
func validateAdmissionSeedFixture(
    _ fixture: AdmissionSeedFixture,
    for mode: AdmissionMode,
    profile: AdmissionProfile
) throws -> AdmissionSeedFixture {
    guard let expectedSeedMode = mode.expectedSeedMode,
          fixture.schemaVersion == 1,
          fixture.mode == expectedSeedMode.rawValue,
          fixture.corpusRows == profile.retainedRows,
          fixture.bodyBytesPerRow == profile.searchBodyBytes,
          fixture.seededRows == profile.retainedRows - 1,
          fixture.seedBatchSize == SwiftDataHistory.performanceFixtureSeedBatchSize
    else {
        throw AdmissionError.unexpectedSeedFixture
    }
    let completeBatches = fixture.seededRows / fixture.seedBatchSize
    let partialBatch = fixture.seededRows % fixture.seedBatchSize == 0 ? 0 : 1
    guard fixture.seedTransactions == completeBatches + partialBatch,
          fixture.seedPosition == UInt64(fixture.seedTransactions),
          fixture.seedWallTimeMs.isFinite,
          fixture.seedWallTimeMs > 0
    else {
        throw AdmissionError.unexpectedSeedFixture
    }
    return fixture
}

