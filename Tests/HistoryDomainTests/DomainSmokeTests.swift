/// Canonical construction rejects invalid representations and compares content
/// bytes independently of candidate fingerprints (docs/architecture.md).
import Foundation
import Testing
@testable import HistoryDomain

// MARK: - CanonicalContent validation (docs/architecture.md, §2.3)

private let plainText = "public.utf8-plain-text"
private let pngImage = "public.png"

private func canonicalRepresentation(
    _ typeIdentifier: String,
    _ bytes: [UInt8],
    fingerprint: UInt64 = 0
) -> CanonicalRepresentation {
    CanonicalRepresentation(
        content: ContentRepresentation(typeIdentifier: typeIdentifier, bytes: Data(bytes)),
        fingerprint: ContentFingerprint(rawValue: fingerprint)
    )
}

@Test func canonicalContentAcceptsNormalizedInput() throws {
    let content = try CanonicalContent(representations: [
        canonicalRepresentation(pngImage, [0x89, 0x50], fingerprint: 1),
        canonicalRepresentation(plainText, [0x68, 0x69], fingerprint: 2),
    ])

    #expect(content.representations.count == 2)

    // §2.2/§2.3: equality and hashing use `content` only — diverging
    // fingerprints never change a Canonical value's identity (D7).
    let sameContentDifferentFingerprints = try CanonicalContent(representations: [
        canonicalRepresentation(pngImage, [0x89, 0x50], fingerprint: 41),
        canonicalRepresentation(plainText, [0x68, 0x69], fingerprint: 42),
    ])
    #expect(content == sameContentDifferentFingerprints)
}

@Test(arguments: [
    ([CanonicalRepresentation](), CanonicalContentRejection.emptyRepresentations),
    ([canonicalRepresentation(plainText, [0x61]), canonicalRepresentation(plainText, [0x62])],
        CanonicalContentRejection.duplicateTypeIdentifier(plainText)),
    ([canonicalRepresentation(plainText, [])], CanonicalContentRejection.emptyBytes(typeIdentifier: plainText)),
    ([canonicalRepresentation(plainText, [0x68, 0x69]), canonicalRepresentation(pngImage, [0x89, 0x50])],
        CanonicalContentRejection.nonNormalizedOrder),
])
func canonicalContentRejectsInvalidRepresentations(
    representations: [CanonicalRepresentation], expected: CanonicalContentRejection
) {
    #expect(throws: expected) {
        try CanonicalContent(representations: representations)
    }
}
