/// PLAY-PY-A2F — request IDs are canonical correlation only, never identity.
import ClipyCLIContract
import Foundation
import Testing

struct PLAYPYA2FRequestIDTests {
    @Test func uppercaseMalformedAndNilUUIDsAreRejectedWithoutEcho() {
        let invalidIDs = [
            validRequestID.uppercased(),
            "00000000-0000-0000-0000-000000000000",
            "{\(validRequestID)}",
            " \(validRequestID)",
            validRequestID.replacingOccurrences(of: "-", with: ""),
            "gbd92054-bd3f-4d20-8f8a-5d77aa63b726",
            "not-a-uuid",
        ]

        for requestID in invalidIDs {
            let rejected = failure(
                ClipyCLIContract.decodeRequest(requestBytes(requestID: requestID))
            )
            #expect(rejected?.code == .invalidRequest)
            #expect(rejected?.requestID == nil)
        }
    }

    @Test func callerMayReuseOneCanonicalIDAcrossSeparateCalls() {
        let first = decodedRequest(ClipyCLIContract.decodeRequest(requestBytes()))
        let second = decodedRequest(ClipyCLIContract.decodeRequest(requestBytes()))

        #expect(first?.requestID.rawValue == validRequestID)
        #expect(second == first)
    }
}
