import AppKit
import Darwin
import Foundation

/// Independent short-lived native reader for the REVIEW General pasteboard
/// cross-process leaf. The literal expected bytes do not come from the writer
/// process, a shared file, stdout, an App Intent, or a target-app paste.
@main
enum ClipyPasteboardReader {
    private static let typeIdentifier = "com.clipy.probe.cross-process"
    private static let expectedBytes = Data([
        0x43, 0x4C, 0x49, 0x50, 0x59, 0x00, 0xFF, 0x10,
        0x80, 0x7F, 0x01, 0xA5, 0x5A, 0x0A, 0x00, 0xC3,
    ])

    @MainActor
    static func main() {
        let type = NSPasteboard.PasteboardType(typeIdentifier)
        guard NSPasteboard.general.data(forType: type) == expectedBytes else {
            fail()
        }
        FileHandle.standardOutput.write(Data("READER_OK\n".utf8))
    }

    private static func fail() -> Never {
        FileHandle.standardError.write(Data("READER_FAILED\n".utf8))
        Darwin.exit(EXIT_FAILURE)
    }
}
