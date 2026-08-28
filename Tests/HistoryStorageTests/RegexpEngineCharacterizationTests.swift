/// REVIEW Card 11C / PERF-3 platform-regression observation for the macOS 26
/// Foundation regexp engine. The 03b §8 adjudication has landed: the product
/// scan now runs Apple's interruptible `enumerateMatches` iterator under a
/// fixed typed engine deadline, and this suite keeps watching the platform
/// facts that mechanism depends on — it still does not broaden the frozen
/// rejection grammar. The risky matcher runs in the existing disposable probe
/// executable so a synchronous ICU call cannot wedge the SwiftPM test process
/// or the actor used by product searches.
import Darwin
import Foundation
import Testing
@testable import HistoryStorage

@Suite("Foundation regexp bounded child characterization (REVIEW Card 11C)")
struct RegexpEngineCharacterizationTests {
    private enum ProbeOutcome {
        case completed(sawProgress: Bool, report: String)
        case watchdogTerminated
    }

    /// Independent from the helper executable by design: the test binds the
    /// exact current-admission fact to the exact fixed child experiment rather
    /// than trusting one shared constant to make mismatched patterns agree.
    private static let riskyPattern = "a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b"

    private enum FixtureError: Error {
        case probeUnavailable
        case childFailed
        case childCouldNotBeTerminated
    }

    /// Pure admission fixtures stay inside the authoritative frozen grammar.
    /// They pin known nested/quantified-alternation rejections; the 03b §8
    /// Card 11C adjudication keeps the top-level ambiguous-quantifier chain
    /// admissible and bounds it with the interruptible scan plus the typed
    /// engine deadline instead of a new rejection shape.
    @Test("contracted ambiguous group shapes remain rejected purely")
    func contractedAmbiguousGroupShapesRemainRejected() {
        for pattern in [
            "(a+)+b",
            "((a){2})+b",
            "(a|a)+b",
            "(a|ab)+c",
        ] {
            #expect(SearchWorker.containsRejectedPatternShape(pattern))
        }
    }

    @Test("fixed top-level chain reaches the current product engine boundary")
    func fixedTopLevelChainIsCurrentlyAdmitted() {
        #expect(
            !SearchWorker.containsRejectedPatternShape(Self.riskyPattern)
        )
    }

    @Test("fixed macOS matcher experiment cannot wedge the test owner")
    func fixedMatcherExperimentIsProcessBounded() throws {
        let probeURL = try Self.probeURL()

        // A simple non-match over the same 1,000-Character input must finish;
        // otherwise the probe/host is unhealthy and the risky observation is
        // not interpretable.
        let control = try Self.runProbe(
            scenario: "safe-control",
            expectedPattern: "a+b",
            probeURL: probeURL
        )
        guard case .completed = control else {
            throw FixtureError.childFailed
        }

        // `firstMatch` is no longer the product operation after the
        // adjudication; this scenario stays as report-only historical
        // evidence that it runs uninterruptibly past the watchdog bound.
        let currentOutcome = try Self.runProbe(
            scenario: "top-level-chain-current",
            expectedPattern: Self.riskyPattern,
            probeURL: probeURL
        )
        Self.report(
            currentOutcome,
            operation: "current-first-match"
        )

        // Apple's documented progress callback is meaningful only for
        // enumerateMatches — now the product's scan operation. The product
        // mechanism depends on this platform fact: the fixed chain completes
        // through the progress+stop interruptible iterator, so the outcome is
        // a hard completion assertion. It deliberately does NOT bind
        // `sawProgress`: a future engine that turns this pattern fast also
        // completes safely, while an OS that loses progress reporting
        // entirely (regressing the product toward an unbounded scan) turns
        // this red instead of silently degrading.
        let progressOutcome = try Self.runProbe(
            scenario: "top-level-chain-progress",
            expectedPattern: Self.riskyPattern,
            probeURL: probeURL
        )
        guard case .completed = progressOutcome else {
            throw FixtureError.childFailed
        }
        Self.report(
            progressOutcome,
            operation: "enumerate-report-progress"
        )
    }

    private static func report(
        _ outcome: ProbeOutcome,
        operation: String
    ) {
        switch outcome {
        case .completed(let sawProgress, let report):
            print(
                "REGEXP_CHARACTERIZATION operation=\(operation) "
                    + "outcome=completed sawProgress=\(sawProgress) \(report)"
            )
        case .watchdogTerminated:
            print(
                "REGEXP_CHARACTERIZATION operation=\(operation) "
                    + "outcome=watchdog-terminated"
            )
        }
    }

    private static func probeURL() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let result = packageRoot.appendingPathComponent(
            ".build/debug/HistoryRestartProbe"
        )
        guard FileManager.default.isExecutableFile(atPath: result.path) else {
            throw FixtureError.probeUnavailable
        }
        return result
    }

    private static func runProbe(
        scenario: String,
        expectedPattern: String,
        probeURL: URL
    ) throws -> ProbeOutcome {
        let process = Process()
        let output = Pipe()
        process.executableURL = probeURL
        process.arguments = ["regexpCharacterize", scenario]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let clock = ContinuousClock()
        var requestedSignals: Set<Int32> = []
        let matchDeadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning, clock.now < matchDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }

        if process.isRunning {
            requestedSignals.insert(SIGTERM)
            process.terminate()
            let terminationDeadline = clock.now.advanced(by: .seconds(1))
            while process.isRunning, clock.now < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if process.isRunning {
                requestedSignals.insert(SIGKILL)
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                let killDeadline = clock.now.advanced(by: .seconds(1))
                while process.isRunning, clock.now < killDeadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            guard !process.isRunning else {
                throw FixtureError.childCouldNotBeTerminated
            }
        }

        process.waitUntilExit()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        return try Self.classifyReapedProbe(
            process,
            output: result,
            scenario: scenario,
            expectedPattern: expectedPattern,
            requestedSignals: requestedSignals
        )
    }

    /// Final process state is authoritative. A child can finish naturally
    /// after the deadline check but before TERM is delivered; classifying from
    /// the branch taken would falsely turn that successful race into a
    /// watchdog observation. Conversely, an unrequested crash signal is a
    /// child failure, not evidence that this parent watchdog bounded ICU.
    private static func classifyReapedProbe(
        _ process: Process,
        output: Data,
        scenario: String,
        expectedPattern: String,
        requestedSignals: Set<Int32>
    ) throws -> ProbeOutcome {
        switch process.terminationReason {
        case .exit:
            guard process.terminationStatus == EXIT_SUCCESS else {
                throw FixtureError.childFailed
            }
            let evidence = try Self.characterizationEvidence(
                output,
                scenario: scenario,
                expectedPattern: expectedPattern,
                requiresReturn: true
            )
            let text = String(decoding: output, as: UTF8.self)
            let sawProgress = text.split(separator: "\n").contains(where: {
                String($0)
                    == "REGEXP_CHARACTERIZATION_CHILD callback=progress"
            })
            return .completed(
                sawProgress: sawProgress,
                report: evidence
            )
        case .uncaughtSignal:
            let signal = process.terminationStatus
            guard (signal == SIGTERM || signal == SIGKILL),
                  requestedSignals.contains(signal) else {
                throw FixtureError.childFailed
            }
            _ = try Self.characterizationEvidence(
                output,
                scenario: scenario,
                expectedPattern: expectedPattern,
                requiresReturn: false
            )
            return .watchdogTerminated
        @unknown default:
            throw FixtureError.childFailed
        }
    }

    private static func characterizationEvidence(
        _ data: Data,
        scenario: String,
        expectedPattern: String,
        requiresReturn: Bool
    ) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FixtureError.childFailed
        }
        let lines = text.split(separator: "\n")
        let expectedStart =
            "REGEXP_CHARACTERIZATION_CHILD scenario=\(scenario) "
                + "pattern=\(expectedPattern) started=true"
        guard lines.contains(where: { String($0) == expectedStart }) else {
            throw FixtureError.childFailed
        }
        if requiresReturn {
            guard text.hasSuffix("REGEXPCHARACTERIZE_OK\n"),
                  lines.contains(where: {
                    String($0)
                        == "REGEXP_CHARACTERIZATION_CHILD operation-returned=true"
                  }) else {
                throw FixtureError.childFailed
            }
        }
        return lines
            .filter { String($0) != "REGEXPCHARACTERIZE_OK" }
            .joined(separator: " ")
    }
}
