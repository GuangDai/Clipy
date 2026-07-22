/// HistoryDomain construction smoke tests (roadmap step 2): the validating
/// `CanonicalContent` initializer's accept/reject paths (docs/02-domain.md
/// §2.1, §2.3), `PinOrdinal` ordering (§3.2), and the `RetentionPolicy` value
/// floor (§5.5, D19).
///
/// These keep the test target building while the full D1–D19 invariant suite
/// (docs/02-domain.md §14, docs/06-cross-cutting.md §8) lands in the next
/// slice. Package-only members are reachable from this same-package test
/// target via `@testable import`.
import Foundation
import Testing
@testable import HistoryDomain

// MARK: - CanonicalContent validation (docs/02-domain.md §2.1, §2.3)

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

@Test func canonicalContentRejectsEmptyInput() {
    #expect(throws: CanonicalContentRejection.emptyRepresentations) {
        try CanonicalContent(representations: [])
    }
}

@Test func canonicalContentRejectsDuplicateTypeIdentifier() {
    #expect(throws: CanonicalContentRejection.duplicateTypeIdentifier(plainText)) {
        try CanonicalContent(representations: [
            canonicalRepresentation(plainText, [0x61]),
            canonicalRepresentation(plainText, [0x62]),
        ])
    }
}

@Test func canonicalContentRejectsEmptyBytes() {
    #expect(throws: CanonicalContentRejection.emptyBytes(typeIdentifier: plainText)) {
        try CanonicalContent(representations: [
            canonicalRepresentation(plainText, []),
        ])
    }
}

@Test func canonicalContentRejectsUnsortedInput() {
    #expect(throws: CanonicalContentRejection.nonNormalizedOrder) {
        try CanonicalContent(representations: [
            canonicalRepresentation(plainText, [0x68, 0x69]),
            canonicalRepresentation(pngImage, [0x89, 0x50]),
        ])
    }
}

// MARK: - PinOrdinal ordering (docs/02-domain.md §3.2)

@Test func pinOrdinalOrdersByRawValue() {
    // Swift does not synthesize `Comparable` here; `<` orders by `rawValue`.
    #expect(PinOrdinal(rawValue: 0) < PinOrdinal(rawValue: 1))
    #expect(!(PinOrdinal(rawValue: 1) < PinOrdinal(rawValue: 1)))
    #expect(PinOrdinal(rawValue: 2) > PinOrdinal(rawValue: 1))
    #expect(PinOrdinal(rawValue: 3) == PinOrdinal(rawValue: 3))
}

// MARK: - RetentionPolicy floor (docs/02-domain.md §5.5, D19)

@Test func retentionPolicyStoresMaximumUnpinnedItems() {
    // The ≥1 floor is enforced at the `HistoryStorage` boundary (typed
    // `invalidInput`), so this value type simply stores the admitted policy;
    // planning always receives a policy permitting at least one unpinned item.
    #expect(RetentionPolicy(maximumUnpinnedItems: 1).maximumUnpinnedItems == 1)
    #expect(RetentionPolicy(maximumUnpinnedItems: 5_000).maximumUnpinnedItems == 5_000)
}
