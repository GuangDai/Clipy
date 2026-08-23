/// PLAY-PY-A2I — protocol v1 admits only the exact browsePreview union.
import ClipyCLIContract
import Foundation
import Testing

struct PLAYPYA2IClosedRequestGrammarTests {
    @Test func recentAndSearchGoldenRequestsDecode() {
        let recent = decodedRequest(ClipyCLIContract.decodeRequest(requestBytes()))
        let search = decodedRequest(
            ClipyCLIContract.decodeRequest(
                requestBytes(
                    arguments: "{\"query\":\"needle\",\"mode\":\"regexp\"," +
                        "\"limit\":20,\"cursor\":\"opaque\"}"
                )
            )
        )

        #expect(recent?.arguments == .recent(limit: 20, cursor: nil))
        #expect(
            search?.arguments
                == .search(
                    query: "needle",
                    mode: .regexp,
                    limit: 20,
                    cursor: "opaque"
                )
        )
    }

    @Test func unknownOperationUsesDedicatedClosedSetFailure() {
        let rejected = failure(
            ClipyCLIContract.decodeRequest(
                requestBytes(operation: "readEffectiveContent")
            )
        )

        #expect(rejected?.code == .unknownOperation)
        #expect(rejected?.requestID?.rawValue == validRequestID)
    }

    @Test func unknownFieldsAreRejectedAtRootAndArguments() {
        let root = Data(
            #"{"protocolVersion":1,"requestID":"9bd92054-bd3f-4d20-8f8a-5d77aa63b726","operation":"browsePreview","arguments":{"limit":20},"extra":null}"#.utf8
        )
        let arguments = requestBytes(arguments: "{\"limit\":20,\"extra\":null}")

        #expect(failure(ClipyCLIContract.decodeRequest(root))?.code == .invalidRequest)
        #expect(failure(ClipyCLIContract.decodeRequest(arguments))?.code == .invalidRequest)
    }

    @Test func argumentUnionAndBoundsFailClosed() {
        let invalidArguments = [
            "{\"query\":\"needle\",\"limit\":20}",
            "{\"mode\":\"exact\",\"limit\":20}",
            "{\"limit\":0}",
            "{\"limit\":501}",
            "{\"limit\":20,\"cursor\":\"\"}",
            "{\"limit\":20,\"cursor\":null}",
            "{\"query\":\"\",\"mode\":\"exact\",\"limit\":20}",
            "{\"query\":\"needle\",\"mode\":\"unknown\",\"limit\":20}",
            "{\"query\":\"" + String(repeating: "x", count: 65)
                + "\",\"mode\":\"fuzzy\",\"limit\":20}",
            "{\"query\":\"" + String(repeating: "x", count: 513)
                + "\",\"mode\":\"regexp\",\"limit\":20}",
        ]

        for arguments in invalidArguments {
            #expect(
                failure(
                    ClipyCLIContract.decodeRequest(requestBytes(arguments: arguments))
                )?.code == .invalidRequest
            )
        }
    }

    @Test func limitAdmitsBothEndpointsAndRejectsAdjacentValues() {
        for limit in [1, 500] {
            let arguments = "{\"limit\":\(limit)}"
            #expect(
                decodedRequest(
                    ClipyCLIContract.decodeRequest(
                        requestBytes(arguments: arguments)
                    )
                ) != nil
            )
        }
        for limit in [0, 501] {
            let arguments = "{\"limit\":\(limit)}"
            #expect(
                failure(
                    ClipyCLIContract.decodeRequest(
                        requestBytes(arguments: arguments)
                    )
                )?.code == .invalidRequest
            )
        }
    }

    @Test func decodedQueryUTF8AndPerModeCharacterBoundsAreExact() {
        let exact4096 = String(repeating: "\\u0078", count: 4_096)
        let exact4097 = exact4096 + "\\u0078"
        let fuzzy64 = String(repeating: "🧩", count: 64)
        let fuzzy65 = fuzzy64 + "🧩"
        let regexp512 = String(repeating: "x", count: 512)
        let regexp513 = regexp512 + "x"

        func search(_ encodedQuery: String, mode: String) -> Data {
            requestBytes(
                arguments: "{\"query\":\"\(encodedQuery)\","
                    + "\"mode\":\"\(mode)\",\"limit\":1}"
            )
        }

        #expect(decodedRequest(ClipyCLIContract.decodeRequest(search(exact4096, mode: "exact"))) != nil)
        #expect(failure(ClipyCLIContract.decodeRequest(search(exact4097, mode: "exact")))?.code == .invalidRequest)
        #expect(decodedRequest(ClipyCLIContract.decodeRequest(search(fuzzy64, mode: "fuzzy"))) != nil)
        #expect(failure(ClipyCLIContract.decodeRequest(search(fuzzy65, mode: "fuzzy")))?.code == .invalidRequest)
        #expect(decodedRequest(ClipyCLIContract.decodeRequest(search(regexp512, mode: "regexp"))) != nil)
        #expect(failure(ClipyCLIContract.decodeRequest(search(regexp513, mode: "regexp")))?.code == .invalidRequest)
    }

    @Test func cursorDecodedUTF8BoundIsExact() {
        func recent(cursor: String) -> Data {
            requestBytes(
                arguments: "{\"limit\":1,\"cursor\":\"\(cursor)\"}"
            )
        }

        #expect(
            decodedRequest(
                ClipyCLIContract.decodeRequest(
                    recent(cursor: String(repeating: "x", count: 4_096))
                )
            ) != nil
        )
        #expect(
            failure(
                ClipyCLIContract.decodeRequest(
                    recent(cursor: String(repeating: "x", count: 4_097))
                )
            )?.code == .invalidRequest
        )
    }
}
