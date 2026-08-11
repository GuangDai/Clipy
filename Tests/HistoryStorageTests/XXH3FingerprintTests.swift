/// Known-answer vectors for the exact vendored xxHash v0.8.3 implementation
/// used to create durable Canonical signature metadata (D7).
import Foundation
import Testing
@testable import HistoryStorage

struct XXH3FingerprintTests {
    @Test(arguments: [
        (Data(), UInt64(0x2D06_8005_38D3_94C2)),
        (Data("a".utf8), UInt64(0xE6C6_32B6_1E96_4E1F)),
        (Data("abc".utf8), UInt64(0x78AF_5F94_892F_3950)),
        (Data("Clipy".utf8), UInt64(0xE406_7A4D_3059_0056)),
    ])
    func pinnedV083DigestIsByteStable(bytes: Data, expected: UInt64) {
        #expect(XXH3Fingerprint.digest(bytes) == expected)
    }
}
