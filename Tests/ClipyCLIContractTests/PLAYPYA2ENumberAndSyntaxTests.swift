/// PLAY-PY-A2E — JSON syntax failures and typed integer policy stay distinct.
import ClipyCLIContract
import Foundation
import Testing

struct PLAYPYA2ENumberAndSyntaxTests {
    @Test func malformedEncodingBOMAndNonfiniteExtensionsAreInvalidJSON() {
        let inputs = [
            Data([0xFF]),
            Data([0xEF, 0xBB, 0xBF]) + requestBytes(),
            requestBytes(version: "NaN"),
            requestBytes(version: "Infinity"),
            requestBytes(version: "01"),
            requestBytes() + Data("{}".utf8),
        ]

        for input in inputs {
            #expect(failure(ClipyCLIContract.decodeRequest(input))?.code == .invalidJSON)
        }
    }

    @Test func fractionsExponentsAndOverflowAreTypedInvalidRequests() {
        let inputs = [
            requestBytes(version: "1.0"),
            requestBytes(arguments: "{\"limit\":2e1}"),
            requestBytes(arguments: "{\"limit\":999999999999999999999999999999}"),
        ]

        for input in inputs {
            #expect(failure(ClipyCLIContract.decodeRequest(input))?.code == .invalidRequest)
        }
    }

    @Test func oneRootAllowsOnlyRFCJSONWhitespaceAroundIt() {
        let accepted = Data(" \t\r\n".utf8) + requestBytes() + Data("\n".utf8)
        let rejected = requestBytes() + Data([0xC2, 0xA0])

        #expect(decodedRequest(ClipyCLIContract.decodeRequest(accepted)) != nil)
        #expect(failure(ClipyCLIContract.decodeRequest(rejected))?.code == .invalidJSON)
    }
}
