import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct UTF16ContentMarkerProjectionTests {
    @Test(arguments: [
        ("public.utf16-plain-text", Data([0xFF, 0xFE, 0xFF, 0xFE, 0x42, 0x00, 0x3E, 0xD8, 0x8A, 0xDD])),
        ("public.utf16-external-plain-text", Data([0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x42, 0xD8, 0x3E, 0xDD, 0x8A])),
    ])
    func titleAndBodyRetainTheContentMarker(type: String, bytes: Data) {
        let content = EffectiveContent(representations: [
            ContentRepresentation(typeIdentifier: type, bytes: bytes),
        ])
        let projection = ContentProjector.project(content)
        // Independent byte oracle for U+FEFF + B + fox, after consuming
        // only the first UTF-16 byte-order marker.
        let expected = Data([0xEF, 0xBB, 0xBF, 0x42, 0xF0, 0x9F, 0xA6, 0x8A])
        #expect(Data(projection.title.utf8) == expected)
        #expect(Data(projection.searchBody.utf8) == expected)
        #expect(Data(ContentProjector.projectTitle(content).utf8) == expected)
    }
}
