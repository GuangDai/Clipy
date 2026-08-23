/// PLAY-PY-A2D — depth and per-container width are independent parser bounds.
import ClipyCLIContract
import Foundation
import Testing

struct PLAYPYA2DStructuralBoundsTests {
    @Test func depthEightParsesButDepthNineIsInvalidJSON() {
        let depthEight = "{\"x\":" + String(repeating: "[", count: 7)
            + "0" + String(repeating: "]", count: 7) + "}"
        let depthNine = "{\"x\":" + String(repeating: "[", count: 8)
            + "0" + String(repeating: "]", count: 8) + "}"

        #expect(
            failure(ClipyCLIContract.decodeRequest(Data(depthEight.utf8)))?.code
                == .invalidRequest
        )
        #expect(
            failure(ClipyCLIContract.decodeRequest(Data(depthNine.utf8)))?.code
                == .invalidJSON
        )
    }

    @Test func thirtyTwoObjectMembersParseButThirtyThirdIsInvalidJSON() {
        func object(memberCount: Int) -> Data {
            let members = (0..<memberCount)
                .map { "\"field\($0)\":null" }
                .joined(separator: ",")
            return Data("{\(members)}".utf8)
        }

        #expect(
            failure(ClipyCLIContract.decodeRequest(object(memberCount: 32)))?.code
                == .invalidRequest
        )
        #expect(
            failure(ClipyCLIContract.decodeRequest(object(memberCount: 33)))?.code
                == .invalidJSON
        )
    }

    @Test func fiveHundredTwelveArrayElementsParseButNextIsInvalidJSON() {
        func object(arrayCount: Int) -> Data {
            let array = "["
                + Array(repeating: "null", count: arrayCount).joined(separator: ",")
                + "]"
            return Data("{\"x\":\(array)}".utf8)
        }

        #expect(
            failure(ClipyCLIContract.decodeRequest(object(arrayCount: 512)))?.code
                == .invalidRequest
        )
        #expect(
            failure(ClipyCLIContract.decodeRequest(object(arrayCount: 513)))?.code
                == .invalidJSON
        )
    }
}
