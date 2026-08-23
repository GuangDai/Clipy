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

        do {
            try PasteboardAdapter(pasteboard: .general).write(payload)
        } catch {
            Issue.record("General pasteboard writer failed")
        }
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
        guard NSPasteboard.general.data(forType: Self.type)
                == independentlyDeclaredExpectedBytes
        else {
            Issue.record("General pasteboard reader did not observe exact bytes")
            return
        }
    }
}
