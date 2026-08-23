/// PLAY-PY-A2B — the byte envelope is checked before parser-owned nodes exist.
import ClipyCLIContract
import Foundation
import Testing

struct PLAYPYA2BRequestEnvelopeTests {
    @Test func firstByteBeyondEnvelopeIsRequestTooLarge() {
        let input = Data(repeating: 0x20, count: 65_537)

        #expect(failure(ClipyCLIContract.decodeRequest(input))?.code == .requestTooLarge)
    }

    @Test func exactEnvelopeRemainsAdmissible() {
        var input = requestBytes()
        input.append(Data(repeating: 0x20, count: 65_536 - input.count))

        #expect(decodedRequest(ClipyCLIContract.decodeRequest(input)) != nil)
    }
}
