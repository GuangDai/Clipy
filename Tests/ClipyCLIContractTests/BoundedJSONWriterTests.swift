/// Exact UTF-8 emission and escaped-byte budgets (V2-05 §0.1.2).
@testable import ClipyCLIContract
import Foundation
import Testing

struct BoundedJSONWriterTests {
    @Test func base64PreservesEveryByteAndPaddingWithinTheRemainingBudget() {
        // Exercise all byte values and every padding length after an existing
        // prefix, including rejection one byte below the complete JSON string.
        for count in 0...258 {
            let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
            let prefix = Data("[".utf8)
            let expected = prefix + Data(("\"" + bytes.base64EncodedString() + "\"").utf8)
            for capacity in [expected.count - 1, expected.count] {
                var writer = BoundedJSONWriter(maximumBytes: capacity)
                writer.appendASCII("[")
                writer.appendBase64(bytes)

                #expect(writer.exceeded == (capacity < expected.count))
                #expect(writer.data == (writer.exceeded ? prefix : expected))
                if writer.exceeded {
                    writer.appendBase64(Data([1]))
                    #expect(writer.data == prefix)
                }
            }
        }
    }

    @Test func allASCIIControlsUseTheStableJSONEscapes() {
        let controls = String(decoding: Array(UInt8(0)...UInt8(31)), as: UTF8.self)
        let expected = #""\u0000\u0001\u0002\u0003\u0004\u0005\u0006\u0007\b\t\n\u000b\f\r\u000e\u000f\u0010\u0011\u0012\u0013\u0014\u0015\u0016\u0017\u0018\u0019\u001a\u001b\u001c\u001d\u001e\u001f""#
        var writer = BoundedJSONWriter(maximumBytes: expected.utf8.count)

        writer.appendJSON(controls)

        #expect(!writer.exceeded)
        #expect(writer.data == Data(expected.utf8))
    }

    @Test func escapedRunsPreserveUnicodeBytesAndDoNotNormalize() throws {
        let value = "前缀é\u{0065}\u{0301}\"🧩\\/\n尾部\u{2028}\u{2029}"
        let expected = "\"前缀é\u{0065}\u{0301}\\\"🧩\\\\/\\n尾部\u{2028}\u{2029}\""
        var writer = BoundedJSONWriter(maximumBytes: expected.utf8.count)

        writer.appendJSON(value)

        #expect(!writer.exceeded)
        #expect(writer.data == Data(expected.utf8))
        let decoded = try #require(
            JSONSerialization.jsonObject(with: writer.data, options: .fragmentsAllowed) as? String
        )
        #expect(Data(decoded.utf8) == Data(value.utf8))
    }

    @Test func escapedOutputHonorsEveryCapacityBoundary() {
        let value = "前\"\u{0001}🧩\\后"
        let expected = Data("\"前\\\"\\u0001🧩\\\\后\"".utf8)
        for capacity in 0...expected.count {
            var writer = BoundedJSONWriter(maximumBytes: capacity)
            writer.appendJSON(value)

            #expect(writer.data.count <= capacity)
            #expect(writer.exceeded == (capacity < expected.count))
            if capacity == expected.count {
                #expect(writer.data == expected)
            } else {
                let partial = writer.data
                writer.appendJSON("ignored")
                writer.appendASCII("ignored")
                writer.appendByte(0x0A)
                #expect(writer.data == partial)
            }
        }
    }
}
