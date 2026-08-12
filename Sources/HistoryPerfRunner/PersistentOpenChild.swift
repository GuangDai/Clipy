/// Fresh-process support for WL2's warm persistent-open complexity envelope.
/// The parent never owns a ModelContainer for this workload: one child builds
/// the untimed corpus, then one warmup child and five measured children each
/// execute the public `SwiftDataHistory.open` path and terminate independently.
import Foundation

internal let persistentOpenChildSampleCount = 5

internal enum PersistentOpenChildMode: String, Sendable {
    case populate = "--wl2-populate-store"
    case measure = "--wl2-measure-open"
}

internal enum PersistentOpenChildError: Error, Equatable, Sendable {
    case invalidArguments
    case invalidMeasurement
    case executableUnavailable
    case childLaunchFailed
    case childFailed(status: Int32)
    case unexpectedOutput
}

/// The measured child writes exactly one positive finite millisecond value to
/// stdout. Process launch, argument parsing, encoding, and teardown all occur
/// outside the child's clock interval.
internal func encodePersistentOpenChildDuration(
    _ milliseconds: Double
) throws -> Data {
    guard milliseconds.isFinite, milliseconds > 0 else {
        throw PersistentOpenChildError.invalidMeasurement
    }
    return Data("\(milliseconds)\n".utf8)
}

/// Accepts one scalar token and rejects banners or multiple samples. This
/// keeps parent-side timing impossible: only the child's internal open value
/// can enter WL2's median.
internal func decodePersistentOpenChildDuration(_ data: Data) throws -> Double {
    guard let text = String(data: data, encoding: .utf8) else {
        throw PersistentOpenChildError.invalidMeasurement
    }
    let tokens = text.split(whereSeparator: { $0.isWhitespace })
    guard tokens.count == 1,
          let milliseconds = Double(tokens[0]),
          milliseconds.isFinite,
          milliseconds > 0
    else {
        throw PersistentOpenChildError.invalidMeasurement
    }
    return milliseconds
}

/// Runs the complete per-size lifecycle: one untimed population child, one
/// discarded warmup child, then exactly five measured children. Keeping this
/// orchestration injectable makes process-count and ordering drift testable
/// without launching SwiftData from a helper test.
internal func runPersistentOpenChildSequence(
    populate: () throws -> Void,
    measure: () throws -> Double
) throws -> [Double] {
    try populate()
    _ = try validatedPersistentOpenChildMeasurement(measure())

    var samples: [Double] = []
    samples.reserveCapacity(persistentOpenChildSampleCount)
    for _ in 0..<persistentOpenChildSampleCount {
        samples.append(
            try validatedPersistentOpenChildMeasurement(measure())
        )
    }
    return samples
}

private func validatedPersistentOpenChildMeasurement(
    _ milliseconds: Double
) throws -> Double {
    guard milliseconds.isFinite, milliseconds > 0 else {
        throw PersistentOpenChildError.invalidMeasurement
    }
    return milliseconds
}

internal func performanceRunnerExecutableURL() throws -> URL {
    guard let executableURL = Bundle.main.executableURL,
          FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
        throw PersistentOpenChildError.executableUnavailable
    }
    return executableURL
}

/// Child failures deliberately omit the store URL and underlying error. Both
/// can contain runner paths, while persistence errors can also echo values
/// derived from the measured store. The fixed mode name is enough to locate
/// the failed phase without copying child diagnostics into CI evidence.
internal func persistentOpenChildFailureOutput(
    mode: PersistentOpenChildMode
) -> Data {
    let phase = switch mode {
    case .populate: "populate"
    case .measure: "measure"
    }
    return Data("HistoryPerfRunner WL2 child failed mode=\(phase)\n".utf8)
}

private func runPersistentOpenChildProcess(
    executableURL: URL,
    mode: PersistentOpenChildMode,
    arguments: [String]
) throws -> Data {
    let process = Process()
    let combinedOutput = Pipe()
    process.executableURL = executableURL
    process.arguments = [mode.rawValue] + arguments
    process.standardInput = FileHandle.nullDevice
    // Drain one combined stream while the child is alive. Waiting before
    // draining separate stdout/stderr pipes can deadlock when CoreData emits
    // enough diagnostics to fill either pipe's kernel buffer.
    process.standardOutput = combinedOutput
    process.standardError = combinedOutput

    do {
        try process.run()
    } catch {
        throw PersistentOpenChildError.childLaunchFailed
    }

    let output: Data
    do {
        // `readToEnd` drains concurrently with execution and returns after the
        // child closes both inherited descriptors. Output is intentionally
        // interpreted only after termination, never surfaced verbatim.
        output = try combinedOutput.fileHandleForReading.readToEnd() ?? Data()
    } catch {
        // A failed reader cannot keep draining. Break the writer side before
        // reaping so this exceptional cleanup path cannot recreate the same
        // full-pipe wait cycle that the normal path avoids.
        try? combinedOutput.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        throw PersistentOpenChildError.unexpectedOutput
    }
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw PersistentOpenChildError.childFailed(
            status: process.terminationStatus
        )
    }
    return output
}

internal func populatePersistentOpenStoreInChild(
    executableURL: URL,
    storeURL: URL,
    rowCount: Int
) throws {
    let output = try runPersistentOpenChildProcess(
        executableURL: executableURL,
        mode: .populate,
        arguments: [storeURL.path, String(rowCount)]
    )
    guard String(decoding: output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
    else {
        throw PersistentOpenChildError.unexpectedOutput
    }
}

internal func measurePersistentOpenInChild(
    executableURL: URL,
    storeURL: URL
) throws -> Double {
    let output = try runPersistentOpenChildProcess(
        executableURL: executableURL,
        mode: .measure,
        arguments: [storeURL.path]
    )
    return try decodePersistentOpenChildDuration(output)
}

/// Runs one hidden WL2 child mode. Population is untimed and emits no stdout;
/// measurement emits only the internally-clocked public-open duration.
internal func runPersistentOpenChild(
    mode: PersistentOpenChildMode,
    arguments: [String]
) async -> Int {
    do {
        switch mode {
        case .populate:
            guard arguments.count == 2,
                  let rowCount = Int(arguments[1]),
                  rowCount > 0
            else {
                throw PersistentOpenChildError.invalidArguments
            }
            let storeURL = URL(fileURLWithPath: arguments[0])
            guard !FileManager.default.fileExists(atPath: storeURL.path) else {
                throw PersistentOpenChildError.invalidArguments
            }
            let history = try await openStore(url: storeURL)
            try await populateItems(history, count: rowCount)

        case .measure:
            guard arguments.count == 1 else {
                throw PersistentOpenChildError.invalidArguments
            }
            let storeURL = URL(fileURLWithPath: arguments[0])
            guard FileManager.default.fileExists(atPath: storeURL.path) else {
                throw PersistentOpenChildError.invalidArguments
            }
            let clock = ContinuousClock()
            let start = clock.now
            let history = try await openStore(url: storeURL)
            let elapsed = durationToMs(start.duration(to: clock.now))
            withExtendedLifetime(history) {}
            try FileHandle.standardOutput.write(
                contentsOf: encodePersistentOpenChildDuration(elapsed)
            )
        }
        return 0
    } catch {
        try? FileHandle.standardError.write(
            contentsOf: persistentOpenChildFailureOutput(mode: mode)
        )
        return 1
    }
}
