/// Test-only deterministic fingerprint double for the pinned xxh3-64 content
/// fingerprint (`ContentFingerprint.rawValue`, docs/architecture.md).
///
/// A fingerprint is evidence only — never identity, never sufficient for Copy
/// Coalescing (D7): docs/testing.md requires that a forced xxh3
/// collision still demands byte confirmation. Finding a real XXH3-64 collision
/// is impractical, so docs/architecture.md permits a package-only
/// deterministic collision double in Domain/Storage tests. This double forces
/// the collision path deterministically, without any chance collision in the
/// real hash.
///
/// Created at roadmap step 3 (docs/architecture.md); first
/// exercised at step 5 by the §7.6 forced-collision tests of the
/// `IngestPreparationActor` (docs/storage.md). It imports
/// nothing from HistoryStorage: tests substitute it for the real xxh3 digest.
enum ForcedCollisionFingerprint {
    /// The single digest every input maps to under ``digest(of:)``.
    static let collisionValue: UInt64 = 0xC011_1510_5EED_C0DE

    /// Colliding digest: returns ``collisionValue`` for **every** input, so any
    /// two byte strings share a fingerprint. Storage tests use this to prove
    /// that equal fingerprints with different bytes still fail Copy Coalescing
    /// at the byte-confirmation step (docs/testing.md).
    static func digest(of bytes: some Sequence<UInt8>) -> UInt64 {
        _ = bytes
        return collisionValue
    }
}
