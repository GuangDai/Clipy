/// HistoryDomain value-construction tests and the index for the direct
/// D1–D19 planner suite (docs/02-domain.md §14; docs/06-cross-cutting.md §8)
/// plus the V2-02 expansion invariants D23–D24 (docs/v2/V2-02-retention.md
/// §11).
///
/// The runtime matrix is split by owning seam:
///
/// - `CapturePlannerInvariantTests`: D1, D3, D7, D9–D11, D13–D14, D16,
///   D18–D19 through `planCapture` plus `effectiveContent`;
/// - `PinRevisionPlannerInvariantTests`: D2–D4, D12, D15–D16, D18 through
///   `planPinnedPlacement`, `planUnpin`, `planRemove`, `planClear`, and
///   `planRevision`;
/// - `RetentionPlannerTests`: D13, D16, D18–D19 through `planRetention`;
/// - `RetentionExpansionPlannerTests` (V2-02): D13–D14, D16, D19-as-extended
///   by D24, D24(a)/(b) victim-safety and deduplicated-union shape through
///   `planItemRetentionExpansion` (docs/v2/V2-02-retention.md §4.1/§4.2/
///   §6.5; `RET-SELECT-1` Domain half);
/// - `RevisionPrunePlannerTests` (V2-02): D3, D16, D23 through
///   `planRevisionRetentionExpansion` (docs/v2/V2-02-retention.md §5/§6.5;
///   `RET-PRUNE-1` Domain half);
/// - this file: Canonical value validation/fingerprint-independent equality
///   (D7), immutable value construction (D17), PinOrdinal ordering (D12), and
///   the admitted retention floor value (D19).
///
/// D5/D6 token stamping belongs to HistoryStorage rather than a Domain
/// planner; D8 fact completeness and D17 Sendable/import purity are structural
/// proofs enforced by fact types and portable gates. The single-commit half
/// of D24(a) (one `MutationPlan`, one `ChangePosition`) and the R3-then-R2
/// composition (`RET-PRUNE-2`) are Storage composition proofs owned by
/// roadmap slices R.4–R.6. Package-only members are
/// reachable from this same-package test target via `@testable import`.
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
