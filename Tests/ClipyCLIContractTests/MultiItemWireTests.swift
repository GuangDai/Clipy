import ClipyCLIContract
import Foundation
import Testing

struct MultiItemWireTests {
    private struct EffectiveReply: Decodable {
        struct Result: Decodable {
            let contentVersion: UInt64
        }

        let result: Result
    }

    @Test func repeatedTypeAtDifferentPositionsRoundTripsEffectiveBytes() throws {
        let request = try #require(decodedRequest(ClipyCLIContract.decodeRequest(requestBytes(
            operation: "detailsEffective", arguments: #"{"locator":"i1_items"}"#
        ))))
        let result = try ClipyCLIEffectiveResult(locator: "i1_items", contentVersion: UInt64.max, representations: [
            .init(typeIdentifier: "public.text", bytes: Data([0, 255])),
            .init(typeIdentifier: "public.text", bytes: Data([128, 1]), pasteboardItemIndex: 1),
        ])
        let output = ClipyCLIContract.render(.success(for: request, effective: result))
        #expect(output.exitCode == 0)
        let versioned = try JSONDecoder().decode(EffectiveReply.self, from: output.stdout)
        #expect(versioned.result.contentVersion == UInt64.max)
        let root = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        let body = try #require(root["result"] as? [String: Any])
        #expect(Set(body.keys) == ["contentVersion", "locator", "representations"])
        let values = try #require(body["representations"] as? [[String: Any]])
        try #require(values.count == 2)
        #expect(values[0]["pasteboardItemIndex"] as? Int == 0)
        #expect(values[1]["pasteboardItemIndex"] as? Int == 1)
        #expect(values[0]["bytesBase64"] as? String == Data([0, 255]).base64EncodedString())
        #expect(values[1]["bytesBase64"] as? String == Data([128, 1]).base64EncodedString())
    }

    @Test func revisionAddressesSameTypeSeparatelyAndDefaultsSingleItemToZero() throws {
        let request = try #require(decodedRequest(ClipyCLIContract.decodeRequest(requestBytes(
            operation: "reviseContent", arguments: #"{"locator":"i1_items","expectedContentVersion":1,"representations":[{"typeIdentifier":"public.text","bytesBase64":"AQ=="},{"typeIdentifier":"public.text","bytesBase64":"Ag==","pasteboardItemIndex":1}]}"#
        ))))
        guard case .reviseContent(_, _, _, let values) = request else {
            Issue.record("Expected revision request")
            return
        }
        #expect(values.map(\.pasteboardItemIndex) == [0, 1])
        #expect(values.map(\.bytes) == [Data([1]), Data([2])])
    }

    @Test(arguments: ["-1", "32", "1.0", "true", "null", "\"1\""])
    func invalidItemIndicesAreRejected(index: String) {
        let arguments = "{\"locator\":\"i1_items\",\"expectedContentVersion\":1,\"representations\":[{\"typeIdentifier\":\"public.text\",\"bytesBase64\":\"AQ==\",\"pasteboardItemIndex\":\(index)}]}"
        #expect(failure(ClipyCLIContract.decodeRequest(requestBytes(
            operation: "reviseContent", arguments: arguments
        )))?.code == .invalidRequest)
    }
}
