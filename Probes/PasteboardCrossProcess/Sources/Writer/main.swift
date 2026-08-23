import AppKit
import Darwin
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter

/// Short-lived writer for the REVIEW General pasteboard cross-process leaf.
/// It obtains a real `PastePayload` through the public History seam, then
/// crosses the production `PasteboardAdapter.write` interface over `.general`.
@main
enum ClipyPasteboardWriter {
    private static let typeIdentifier = "com.clipy.probe.cross-process"
    private static let syntheticBytes = Data([
        0x43, 0x4C, 0x49, 0x50, 0x59, 0x00, 0xFF, 0x10,
        0x80, 0x7F, 0x01, 0xA5, 0x5A, 0x0A, 0x00, 0xC3,
    ])

    @MainActor
    static func main() async {
        do {
            let history = try await SwiftDataHistory.open(
                configuration: HistoryConfiguration(persistence: .memory)
            )
            let receipt = try await history.perform(.capture(ClipboardCapture(
                representations: [CapturedRepresentation(
                    typeIdentifier: typeIdentifier,
                    bytes: syntheticBytes
                )],
                origin: CopyOriginObservation(
                    sourceApplication: "com.clipy.probe.writer",
                    lineageHint: nil
                ),
                observedAt: Date(timeIntervalSinceReferenceDate: 1_000_000)
            )))
            guard case let .committed(commit) = receipt,
                  case let .inserted(reference) = commit.outcome
            else {
                fail()
            }

            let payload = try await history.pastePayload(for: reference.id)
            guard payload.representations.count == 1,
                  payload.representations[0].typeIdentifier == typeIdentifier,
                  payload.representations[0].bytes == syntheticBytes
            else {
                fail()
            }

            try PasteboardAdapter(pasteboard: .general).write(payload)
            FileHandle.standardOutput.write(Data("WRITER_OK\n".utf8))
        } catch {
            fail()
        }
    }

    private static func fail() -> Never {
        FileHandle.standardError.write(Data("WRITER_FAILED\n".utf8))
        Darwin.exit(EXIT_FAILURE)
    }
}
