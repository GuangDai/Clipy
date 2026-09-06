/// A complete UTF-16 code unit followed by one byte is still malformed.
/// Foundation decoding must not silently admit only the complete prefix
/// into durable title/search projection (05 §15).
import Foundation
import HistoryDomain
import Testing
@testable import HistoryStorage

struct UTF16OddByteProjectionTests {
    struct Fixture: Sendable {
        let type: String
        let valid: Data
    }

    @Test(arguments: [
        Fixture(type: "public.utf16-plain-text", valid: Data([0x41, 0x00])),
        Fixture(type: "public.utf16-external-plain-text", valid: Data([0x00, 0x41])),
        Fixture(type: "public.utf16-plain-text", valid: Data([0xFF, 0xFE, 0x41, 0x00])),
        Fixture(type: "public.utf16-external-plain-text", valid: Data([0xFE, 0xFF, 0x00, 0x41])),
    ])
    func anOddTrailingByteCannotBecomeAValidPrefixProjection(_ fixture: Fixture) {
        let valid = EffectiveContent(representations: [ContentRepresentation(
            typeIdentifier: fixture.type, bytes: fixture.valid
        )])
        let validProjection = ContentProjector.project(valid)
        #expect(validProjection.title == "A")
        #expect(validProjection.searchBody == "A")

        let malformed = EffectiveContent(representations: [ContentRepresentation(
            typeIdentifier: fixture.type, bytes: fixture.valid + Data([0xFF])
        )])
        let projection = ContentProjector.project(malformed)
        #expect(projection.title == fixture.type)
        #expect(projection.searchBody.isEmpty)
        #expect(ContentProjector.projectTitle(malformed) == fixture.type)
    }
}
