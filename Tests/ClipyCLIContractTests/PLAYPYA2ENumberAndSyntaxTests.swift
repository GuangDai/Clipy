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

    @Test func malformedUTF8InStringsAndBetweenEscapesIsRejectedBeforeTypedDecoding() {
        let malformed = [
            Data([0x80]),
            Data([0xC0, 0xAF]), // overlong encoding
            Data([0xED, 0xA0, 0x80]), // UTF-8 surrogate
            Data([0xF4, 0x90, 0x80, 0x80]), // beyond U+10FFFF
            Data([0xC2]) + Data(#"\u0080"#.utf8),
            Data(#"\u0080"#.utf8) + Data([0x80]),
        ]
        for spelling in malformed {
            let input = Data("{\"protocolVersion\":1,\"requestID\":\"\(validRequestID)\",\"operation\":\"".utf8)
                + spelling + Data("\",\"arguments\":{}}".utf8)
            let rejection = failure(ClipyCLIContract.decodeRequest(input))
            #expect(rejection?.code == .invalidJSON)
            #expect(rejection?.requestID == nil)
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
