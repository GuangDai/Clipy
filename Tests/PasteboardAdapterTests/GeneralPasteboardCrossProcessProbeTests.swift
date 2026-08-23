/// Dispatch-only General pasteboard cross-process evidence. Ordinary
/// `swift test` runs skip both phases; the dedicated workflow launches two
/// independent, short-lived test-host processes in one login session.
///
/// The writer crosses the production `PasteboardAdapter.write` interface.
/// Only after that process exits does the reader use AppKit directly and
/// byte-compare an independently declared synthetic literal. Failures report
/// content-free messages and do not infer TCC, timeout, atomicity, target-app
/// paste behavior, App Intents behavior, or WindowServer behavior.
import AppKit
import Foundation
import HistoryCore
import Testing
@testable import PasteboardAdapter

@Suite("General pasteboard cross-process proof")
@MainActor
struct GeneralPasteboardCrossProcessProbeTests {
    private static let phaseEnvironmentKey =
        "CLIPY_GENERAL_PASTEBOARD_PROBE_PHASE"
    private static let markerDirectoryEnvironmentKey =
        "CLIPY_GENERAL_PASTEBOARD_PROBE_MARKER_DIR"
    private static let type = NSPasteboard.PasteboardType(
        "com.clipy.probe.cross-process"
    )

    @Test(
        "adapter writer publishes synthetic bytes to General pasteboard",
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "CLIPY_GENERAL_PASTEBOARD_PROBE_PHASE"
            ] == "writer",
            "dispatch-only writer phase"
        )
    )
    func writerWritesSyntheticBytesThroughAdapter() {
        let bytes = Data([
            0x43, 0x4C, 0x49, 0x50, 0x59, 0x00, 0xFF, 0x10,
            0x80, 0x7F, 0x01, 0xA5, 0x5A, 0x0A, 0x00, 0xC3,
        ])
        let itemID = HistoryItemID(rawValue: UUID())
        let payload = PastePayload(
            item: HistoryItemReference(
                id: itemID,
                contentVersion: ContentVersion(rawValue: 1)
            ),
            representations: [HistoryRepresentation(
                typeIdentifier: Self.type.rawValue,
                bytes: bytes
            )],
            lineageHint: itemID
        )
        let pasteboard = NSPasteboard.general

        Self.reportProcess(phase: "writer")
        Self.reportPasteboard(
            phase: "writer",
            boundary: "before-adapter-write",
            pasteboard: pasteboard,
            expectedBytes: bytes
        )

        do {
            try PasteboardAdapter(pasteboard: pasteboard).write(payload)
        } catch {
            Self.report(
                "phase=writer boundary=adapter-write result=threw " +
                    "error_type=\(String(reflecting: Swift.type(of: error)))"
            )
            Issue.record("General pasteboard writer failed")
            return
        }

        let observedBytes = pasteboard.data(forType: Self.type)
        Self.reportPasteboard(
            phase: "writer",
            boundary: "after-adapter-write",
            pasteboard: pasteboard,
            expectedBytes: bytes
        )
        #expect(observedBytes?.count == bytes.count)
        guard observedBytes == bytes else {
            Issue.record("General pasteboard writer could not read back exact bytes")
            return
        }
        Self.markPassed(phase: "writer")
    }

    @Test(
        "native reader sees exact synthetic bytes after writer exit",
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "CLIPY_GENERAL_PASTEBOARD_PROBE_PHASE"
            ] == "reader",
            "dispatch-only reader phase"
        )
    )
    func nativeReaderByteComparesAfterWriterExit() {
        let independentlyDeclaredExpectedBytes = Data([
            0x43, 0x4C, 0x49, 0x50, 0x59, 0x00, 0xFF, 0x10,
            0x80, 0x7F, 0x01, 0xA5, 0x5A, 0x0A, 0x00, 0xC3,
        ])
        let pasteboard = NSPasteboard.general

        Self.reportProcess(phase: "reader")
        Self.reportPasteboard(
            phase: "reader",
            boundary: "before-native-read",
            pasteboard: pasteboard,
            expectedBytes: independentlyDeclaredExpectedBytes
        )
        let observedBytes = pasteboard.data(forType: Self.type)
        #expect(observedBytes?.count == independentlyDeclaredExpectedBytes.count)
        guard observedBytes == independentlyDeclaredExpectedBytes
        else {
            Issue.record("General pasteboard reader did not observe exact bytes")
            return
        }
        Self.report("phase=reader boundary=native-read result=matched")
        Self.markPassed(phase: "reader")
    }

    /// This evidence target is never linked into the app. The diagnostics are
    /// additionally phase-gated so ordinary package tests do not execute them.
    /// Values intentionally exclude pasteboard bytes (06 §10.4, Card 9B).
    private static func reportProcess(phase: String) {
        let process = ProcessInfo.processInfo
        report(
            "phase=\(phase) boundary=process " +
                "pid=\(process.processIdentifier) " +
                "process_name=\(process.processName) " +
                "declared_phase=\(process.environment[phaseEnvironmentKey] ?? \"missing\")"
        )
    }

    private static func reportPasteboard(
        phase: String,
        boundary: String,
        pasteboard: NSPasteboard,
        expectedBytes: Data
    ) {
        let advertisedTypes = pasteboard.types ?? []
        let observedBytes = pasteboard.data(forType: type)
        report(
            "phase=\(phase) boundary=\(boundary) " +
                "change_count=\(pasteboard.changeCount) " +
                "advertised_type_count=\(advertisedTypes.count) " +
                "probe_type_present=\(advertisedTypes.contains(type)) " +
                "observed_byte_count=\(observedBytes?.count ?? -1) " +
                "expected_byte_count=\(expectedBytes.count) " +
                "bytes_match=\(observedBytes == expectedBytes)"
        )
    }

    private static func report(_ message: String) {
        print("[CLIPY_PB_XPROC] \(message)")
    }

    private static func markPassed(phase: String) {
        guard let markerDirectory = ProcessInfo.processInfo.environment[
            markerDirectoryEnvironmentKey
        ] else {
            report("phase=\(phase) boundary=passed-marker result=missing-directory")
            Issue.record("General pasteboard probe marker directory is missing")
            return
        }
        let markerURL = URL(
            fileURLWithPath: markerDirectory,
            isDirectory: true
        ).appendingPathComponent("\(phase).passed", isDirectory: false)
        do {
            try Data().write(to: markerURL, options: .atomic)
            report("phase=\(phase) boundary=passed-marker result=written")
        } catch {
            report(
                "phase=\(phase) boundary=passed-marker result=threw " +
                    "error_type=\(String(reflecting: Swift.type(of: error)))"
            )
            Issue.record("General pasteboard probe could not write passed marker")
        }
    }
}
