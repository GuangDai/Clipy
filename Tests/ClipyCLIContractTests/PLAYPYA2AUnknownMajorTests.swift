/// PLAY-PY-A2A — protocol major is a closed, fail-closed field.
import ClipyCLIContract
import Testing

struct PLAYPYA2AUnknownMajorTests {
    @Test func unknownMajorHasDedicatedFailureAndEchoesValidatedRequestID() {
        let rejected = failure(ClipyCLIContract.decodeRequest(requestBytes(version: "2")))

        #expect(rejected?.code == .unsupportedProtocolVersion)
        #expect(rejected?.requestID?.rawValue == validRequestID)
    }
}
