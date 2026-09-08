import ClipyCLIContract
import Foundation
import Testing

struct MultiItemWireTests {
    @Test func repeatedTypeAtDifferentPositionsRoundTripsEffectiveBytes() throws {
        let request = try #require(decodedRequest(ClipyCLIContract.decodeRequest(requestBytes(
            operation: "detailsEffective", arguments: #"{"locator":"i1_items"}"#
        ))))
        let result = try ClipyCLIEffectiveResult(locator: "i1_items", contentVersion: 1, representations: [
            .init(typeIdentifier: "public.text", bytes: Data([0, 255])),
            .init(typeIdentifier: "public.text", bytes: Data([128, 1]), pasteboardItemIndex: 1),
        ])
        let output = ClipyCLIContract.render(.success(for: request, effective: result))
        #expect(output.exitCode == 0)
        let root = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        let body = try #require(root["result"] as? [String: Any])
        let values = try #require(body["representations"] as? [[String: Any]])
        #expect(values.count == 2)
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
