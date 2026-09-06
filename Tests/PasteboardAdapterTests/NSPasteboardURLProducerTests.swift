/// Characterize AppKit's real NSURL producer, not a manually supplied URL
/// representation. The byte oracle is independent of NSURL.absoluteString;
/// neither URL is opened and the file fixture is never created or inspected.
import AppKit
import Foundation
import Testing

struct NSPasteboardURLProducerTests {
    @Test @MainActor
    func httpsProducerWritesTheCompletePercentEncodedURLAsUTF8() throws {
        let producer = try #require(NSURL(string:
            "https://example.invalid/%E4%B8%AD%E6%96%87/a%20b?q=%E4%B8%AD%E6%96%87%20words#part%20one"
        ))
        let expectedWire =
            "https://example.invalid/%E4%B8%AD%E6%96%87/a%20b?q=%E4%B8%AD%E6%96%87%20words#part%20one"
        let readback = try Self.writeAndRead(
            producer,
            requiredType: NSPasteboard.PasteboardType("public.url"),
            expectedWire: expectedWire
        )
        #expect(!readback.isFileURL)
        #expect(readback.scheme == "https")
        #expect(readback.host == "example.invalid")
        #expect(readback.path == "/中文/a b")
    }

    @Test @MainActor
    func nonexistentFileProducerWritesAFileURLNotAPathOrBookmark() throws {
        let producer = NSURL(
            fileURLWithPath: "/clipy-nonexistent-url-fixture/中文 folder/note 1.txt",
            isDirectory: false
        )
        let expectedWire =
            "file:///clipy-nonexistent-url-fixture/%E4%B8%AD%E6%96%87%20folder/note%201.txt"
        let readback = try Self.writeAndRead(
            producer,
            requiredType: NSPasteboard.PasteboardType("public.file-url"),
            expectedWire: expectedWire
        )
        #expect(readback.isFileURL)
        #expect(readback.scheme == "file")
        #expect(readback.path == "/clipy-nonexistent-url-fixture/中文 folder/note 1.txt")
    }

    @MainActor
    private static func writeAndRead(
        _ producer: NSURL,
        requiredType: NSPasteboard.PasteboardType,
        expectedWire: String
    ) throws -> NSURL {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "com.clipy.nsurl-producer-tests." + UUID().uuidString
        ))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try #require(pasteboard.writeObjects([producer]))

        let items = try #require(pasteboard.pasteboardItems)
        let item = try #require(items.first)
        #expect(item.types.contains(requiredType))
        let raw = try #require(item.data(forType: requiredType))
        #expect(raw == Data(expectedWire.utf8))

        // AppKit may publish extra types. Check any additional URL wire
        // representation without claiming an exhaustive system type list.
        for type in item.types where
            type != requiredType
                && (type.rawValue == "public.url" || type.rawValue == "public.file-url")
        {
            let additionalRaw = try #require(item.data(forType: type))
            #expect(additionalRaw == Data(expectedWire.utf8))
        }

        let objects = try #require(pasteboard.readObjects(
            forClasses: [NSURL.self], options: nil
        ) as? [NSURL])
        #expect(objects.count == 1)
        let readback = try #require(objects.first)
        #expect(readback.absoluteString == expectedWire)
        return readback
    }
}
