/// Test-only deterministic fingerprint double for the pinned xxh3-64 content
/// fingerprint (`ContentFingerprint.rawValue`, docs/02-domain.md §2.2).
///
/// A fingerprint is evidence only — never identity, never sufficient for Copy
/// Coalescing (D7): docs/06-cross-cutting.md §7.6 requires that a forced xxh3
/// collision still demands byte confirmation. Finding a real XXH3-64 collision
/// is impractical, so docs/01-architecture.md §4 permits a package-only
/// deterministic collision double in Domain/Storage tests. This double forces
/// the collision path deterministically, without any chance collision in the
/// real hash.
///
/// Created at roadmap step 3 (docs/roadmap/07-external-deps.md); first
/// exercised at step 5 by the §7.6 forced-collision tests of the
/// `IngestPreparationActor` (docs/05-authority-kernel.md §6.1). It imports
/// nothing from HistoryStorage: tests substitute it for the real xxh3 digest.
enum ForcedCollisionFingerprint {
    /// The single digest every input maps to under ``digest(of:)``.
    static let collisionValue: UInt64 = 0xC011_1510_5EED_C0DE

    /// Colliding digest: returns ``collisionValue`` for **every** input, so any
    /// two byte strings share a fingerprint. Storage tests use this to prove
    /// that equal fingerprints with different bytes still fail Copy Coalescing
    /// at the byte-confirmation step (docs/06-cross-cutting.md §7.6).
    static func digest(of bytes: some Sequence<UInt8>) -> UInt64 {
        _ = bytes
        return collisionValue
    }

    /// Length digest: returns the input's byte count, so inputs of different
    /// lengths produce different digests. Tests use this when they need a
    /// deterministic double that still distinguishes items — the
    /// non-colliding counterpart to ``digest(of:)``.
    static func lengthDigest(of bytes: some Sequence<UInt8>) -> UInt64 {
        var count: UInt64 = 0
        for _ in bytes { count &+= 1 }
        return count
    }
}
