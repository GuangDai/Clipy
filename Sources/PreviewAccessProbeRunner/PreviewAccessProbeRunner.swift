/// PreviewAccessProbeRunner — one short-lived child process running the
/// DEBUG-only package `PreviewAccessProbe` (Sources/ContentPreview/
/// PreviewAccessProbe.swift) over ONE fixture for the PLAY-TIER-1A decoder
/// access-mode characterization (docs/v2/V2-08-decoder-access-modes.md;
/// docs/reviews/2026-08-22-clipy-maccy-deep-review/
/// 04-tdd-remediation-playbook.md §26 TIER row 1).
///
/// Why a child (the HistoryRestartProbe posture): the incremental-range
/// mode decodes DELIBERATELY TRUNCATED payloads, and framework decoders log
/// on partial data — libpng partial-decode error lines failed the CI log
/// self-scan in run 32259544566 (see scripts/generate_fixtures.py's
/// fixture-exclusion note). The parent test drops the child's stderr, so
/// those diagnostics never reach the CI log, and the process boundary
/// contains any partial-data decoder crash. stdout carries exactly one
/// content-free completion marker; the records land in the JSONL out-file
/// through the package `PreviewAccessMeasurement` sink.
///
/// Usage: PreviewAccessProbeRunner <fixtureID> <typeIdentifier>
/// <maximumPixelExtent> <fixturePath> <outJSONLPath>
import ContentPreview
import Foundation

@main
private struct PreviewAccessProbeRunnerMain {
    static func main() {
        #if DEBUG
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 5,
              let maximumPixelExtent = Int(arguments[2]) else {
            FileHandle.standardOutput.write(Data("USAGE\n".utf8))
            exit(EXIT_FAILURE)
        }
        do {
            let bytes = try Data(
                contentsOf: URL(fileURLWithPath: arguments[3])
            )
            let records = PreviewAccessProbe.characterize(
                fixtureID: arguments[0],
                typeIdentifier: arguments[1],
                bytes: bytes,
                maximumPixelExtent: maximumPixelExtent
            )
            let sink = PreviewAccessMeasurement(
                fileURL: URL(fileURLWithPath: arguments[4])
            )
            for var record in records {
                sink.record(&record)
            }
            FileHandle.standardOutput.write(Data("PROBE_OK\n".utf8))
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardOutput.write(Data("PROBE_FAIL\n".utf8))
            exit(EXIT_FAILURE)
        }
        #else
        // The probe exists only in DEBUG; a Release build of this runner is
        // inert by construction (the probe types compile out with it).
        FileHandle.standardOutput.write(Data("RELEASE_INERT\n".utf8))
        exit(EXIT_FAILURE)
        #endif
    }
}
