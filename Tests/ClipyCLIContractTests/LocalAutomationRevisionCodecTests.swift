import ClipyCLIContract
import Foundation
import Testing

struct LocalAutomationRevisionCodecTests {
    @Test func versionRemainsAnExactUnsignedIntegerAndBinaryIsNotTextDecoded() throws {
        let request = try #require(decodedRequest(ClipyCLIContract.decodeRequest(Self.request(
            version: "18446744073709551615", encoded: "AP8KAFw="
        ))))
        guard case let .reviseContent(_, locator, expected, representations) = request else {
            Issue.record("expected the explicit revision operation")
            return
        }
        #expect(request.isMutation)
        #expect(locator == "i1_exact")
        #expect(expected == UInt64.max)
        #expect(representations.count == 1)
        #expect(representations.first?.typeIdentifier == "com.example.binary")
        #expect(representations.first?.bytes == Data([0, 255, 10, 0, 92]))
    }

    @Test(arguments: ["0", "-1", "1.0", "1e0", "18446744073709551616", "\"1\"", "true", "null"])
    func invalidExpectedVersionsAreRejected(version: String) {
        #expect(failure(ClipyCLIContract.decodeRequest(Self.request(version: version)))?.code == .invalidRequest)
    }

    @Test(arguments: ["", "AA", "A===", "AA==\n", "AA== ", "AB==", "-w==", "@@=="])
    func noncanonicalOrEmptyBase64IsRejected(encoded: String) throws {
        // JSON encoding only escapes the supplied string; the codec must
        // reject whitespace, URL-safe spelling, and nonzero padding bits.
        let encodedJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: encoded, options: [.fragmentsAllowed]
        ), as: UTF8.self)
        let arguments = "{\"locator\":\"i1_exact\",\"expectedContentVersion\":1," +
            "\"representations\":[{\"typeIdentifier\":\"com.example.binary\",\"bytesBase64\":\(encodedJSON)}]}"
        #expect(failure(ClipyCLIContract.decodeRequest(requestBytes(
            operation: "reviseContent", arguments: arguments
        )))?.code == .invalidRequest)
    }

    @Test func completeSetRejectsDuplicateTypesForeignFieldsAndCountOverflow() {
        let representation = #"{"typeIdentifier":"public.utf8-plain-text","bytesBase64":"AA=="}"#
        let invalid = [
            "[]", "[\(representation),\(representation)]",
            #"[{"typeIdentifier":"","bytesBase64":"AA=="}]"#,
            #"[{"typeIdentifier":"public.utf8-plain-text","bytesBase64":"AA==","action":"replace"}]"#,
            "[" + (0..<33).map {
                "{\"typeIdentifier\":\"com.example.\($0)\",\"bytesBase64\":\"AA==\"}"
            }.joined(separator: ",") + "]",
        ]
        for representations in invalid {
            let arguments = "{\"locator\":\"i1_exact\",\"expectedContentVersion\":1,\"representations\":\(representations)}"
            #expect(failure(ClipyCLIContract.decodeRequest(requestBytes(
                operation: "reviseContent", arguments: arguments
            )))?.code == .invalidRequest)
        }
    }

    @Test func revisionUsesTheExistingWholeRequestByteLimit() {
        var exact = Self.request()
        exact.append(Data(repeating: 0x20, count: ClipyCLIContract.maximumRequestBytes - exact.count))
        #expect(decodedRequest(ClipyCLIContract.decodeRequest(exact)) != nil)
        exact.append(0x20)
        #expect(failure(ClipyCLIContract.decodeRequest(exact))?.code == .requestTooLarge)
    }

    private static func request(version: String = "1", encoded: String = "AA==") -> Data {
        requestBytes(operation: "reviseContent", arguments:
            "{\"locator\":\"i1_exact\",\"expectedContentVersion\":\(version)," +
            "\"representations\":[{\"typeIdentifier\":\"com.example.binary\",\"bytesBase64\":\"\(encoded)\"}]}"
        )
    }
}
