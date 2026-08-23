/// Dispatch-only General pasteboard cross-process evidence. Ordinary
/// `swift test` runs skip both phases; the dedicated workflow launches two
/// independent, short-lived test-host processes in one login session.
///
/// The writer crosses the production `PasteboardAdapter.write` interface.
/// Only after that process exits does the reader use AppKit directly and
/// byte-compare an independently declared synthetic literal. Failures report
/// bounded runner diagnostics without pasteboard bytes and do not infer TCC,
/// timeout, atomicity, target-app paste behavior, App Intents behavior, or
/// WindowServer behavior.
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
            Self.reportError(
                phase: "writer",
                boundary: "adapter-write",
                error: error
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
        let declaredPhase = process.environment[phaseEnvironmentKey] ?? "missing"
        report(
            "phase=\(phase) boundary=process " +
                "pid=\(process.processIdentifier) " +
                "process_name=\(process.processName) " +
                "declared_phase=\(declaredPhase)"
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

    /// Dispatch-only failure detail. User-info `Data` values are represented
    /// by type and count only; no pasteboard payload bytes are rendered.
    private static func reportError(
        phase: String,
        boundary: String,
        error: any Error
    ) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment[phaseEnvironmentKey] == phase
        else {
            return
        }

        let nsError = error as NSError
        report(
            "phase=\(phase) boundary=\(boundary) result=threw " +
                "error_type=\(String(reflecting: Swift.type(of: error)))"
        )
        report(
            "phase=\(phase) boundary=\(boundary) error_reflection=" +
                boundedSingleLine(String(reflecting: error), limit: 4_096)
        )
        report(
            "phase=\(phase) boundary=\(boundary) nserror_domain=" +
                "\(boundedSingleLine(nsError.domain, limit: 1_024)) " +
                "nserror_code=\(nsError.code) localized_description=" +
                boundedSingleLine(nsError.localizedDescription, limit: 4_096)
        )

        let entries = nsError.userInfo.sorted { $0.key < $1.key }
        report(
            "phase=\(phase) boundary=\(boundary) " +
                "user_info_count=\(entries.count) emitted_count=" +
                "\(min(entries.count, 64))"
        )
        for (key, value) in entries.prefix(64) {
            report(
                "phase=\(phase) boundary=\(boundary) user_info_key=" +
                    "\(boundedSingleLine(key, limit: 1_024)) " +
                    "value_type=\(String(reflecting: Swift.type(of: value))) " +
                    "value=\(printableUserInfoValue(value))"
            )
        }
        #endif
    }

    #if DEBUG
    private static func printableUserInfoValue(_ value: Any) -> String {
        switch value {
        case let data as Data:
            return "<Data count=\(data.count)>"
        case let string as String:
            return boundedSingleLine(string, limit: 4_096)
        case let number as NSNumber:
            return boundedSingleLine(number.stringValue, limit: 1_024)
        case let url as URL:
            return boundedSingleLine(url.absoluteString, limit: 4_096)
        case let uuid as UUID:
            return uuid.uuidString
        case let date as Date:
            return boundedSingleLine(
                date.formatted(.iso8601),
                limit: 1_024
            )
        case let strings as [String]:
            return boundedSingleLine(String(reflecting: strings), limit: 4_096)
        case let numbers as [NSNumber]:
            return boundedSingleLine(String(reflecting: numbers), limit: 4_096)
        case let nestedError as NSError:
            return boundedSingleLine(
                "<NSError domain=\(nestedError.domain) " +
                    "code=\(nestedError.code) " +
                    "localizedDescription=\(nestedError.localizedDescription)>",
                limit: 4_096
            )
        case is NSNull:
            return "<null>"
        default:
            return "<unprinted value_type=" +
                "\(String(reflecting: Swift.type(of: value)))>"
        }
    }

    private static func boundedSingleLine(_ value: String, limit: Int) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        guard escaped.count > limit else {
            return escaped
        }
        let end = escaped.index(escaped.startIndex, offsetBy: limit)
        return String(escaped[..<end]) +
            "<truncated total_characters=\(escaped.count)>"
    }
    #endif

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
            reportError(
                phase: phase,
                boundary: "passed-marker",
                error: error
            )
            Issue.record("General pasteboard probe could not write passed marker")
        }
    }
}
