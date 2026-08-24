/// PreparedCaptureBundle / IngestPreparationActor — capture preparation
/// performed entirely outside the serial commit interval: raw `ClipboardCapture`
/// validation against the fixed Part VI bounds, normalization, xxh3-64
/// fingerprinting, Canonical Content and signature-entry construction,
/// candidate-ID minting, and the initial content projection.
/// Owning spec: docs/05-authority-kernel.md §6.1 (capture preparation and its
/// fixed order), §16 (failure translation); bounds: docs/06-cross-cutting.md
/// §2; normalized-set requirements: docs/02-domain.md §2.1; fingerprint
/// evidence: docs/02-domain.md §2.2 (D7 — evidence only, never identity).
///
/// This is the only target that imports xxh3 (docs/01-architecture.md §1–§2);
/// the import appears here and nowhere else in the target's preparation path.
/// The serial commit interval performs no pasteboard access, rich-text
/// parsing, fingerprinting, or initial projection (§6.1): everything the
/// Authority needs arrives inside the returned `PreparedCaptureBundle`.
import Foundation
import HistoryCore
import HistoryDomain
import xxh3

/// The production wrapper around the pinned xxHash v0.8.3 entry point.
/// Keeping the C call behind this package-internal seam lets known-answer
/// tests exercise the exact implementation used by ingest preparation.
internal enum XXH3Fingerprint {
    internal static func digest(_ bytes: Data) -> UInt64 {
        bytes.withUnsafeBytes { buffer in
            clipy_xxh3_64bits(buffer.baseAddress, buffer.count)
        }
    }
}

// MARK: - Prepared bundle (docs/05-authority-kernel.md §6.1)

/// Everything capture preparation hands to the Authority for planning and
/// stamping. docs/05-authority-kernel.md §6.1
///
/// §6.1 prints this value with `domain` and `projection`; it additionally
/// carries `signatureEntries` because the same section's fixed order assigns
/// signature-entry construction to this actor (step 6) and the Authority's
/// pre-transaction Signature Index delta needs them (§9, §11). The entries
/// derive one-to-one from `domain.canonical` in normalized order — the exact
/// input `SignatureBlobCodec.encode` and the index delta expect.
internal struct PreparedCaptureBundle: Sendable {
    /// The prepared Domain input for `planCapture` (docs/02-domain.md §4).
    internal let domain: PreparedCapture
    /// One signature entry per Canonical representation, in the Canonical
    /// order (§6.1 step 6; docs/02-domain.md §2.2). Evidence only — byte
    /// confirmation decides every dedup match (D7).
    internal let signatureEntries: [ContentSignatureEntry]
    /// The initial content projection from Canonical-as-Effective Content
    /// (§6.1 step 8, §15).
    internal let projection: ContentProjection

    /// Reuses the already validated/fingerprinted capture while Storage
    /// replaces only an occupied candidate identity. Collision recovery must
    /// not repeat payload work or let the pure Domain mint identifiers
    /// (Card 2B-2; docs/05-authority-kernel.md §6.1 step 7).
    internal func replacingCandidateID(
        with candidateID: HistoryItemID
    ) -> PreparedCaptureBundle {
        PreparedCaptureBundle(
            domain: PreparedCapture(
                candidateID: candidateID,
                canonical: domain.canonical,
                origin: domain.origin,
                observedAt: domain.observedAt
            ),
            signatureEntries: signatureEntries,
            projection: projection
        )
    }
}

// MARK: - Preparation actor (docs/05-authority-kernel.md §6.1)

/// Converts a raw `ClipboardCapture` into a `PreparedCaptureBundle` off the
/// Authority, following §6.1's fixed order:
///
/// 1. Reject a pasteboard-level exclusion, an empty capture, or a hard-limit
///    violation.
/// 2. Reject invalid/oversized type identifiers and bytes.
/// 3. Enforce that transient/private marker types exclude the whole capture;
///    they are never filtered as independently retainable representations.
/// 4. Sort by type identifier and reject duplicate identifiers, including
///    duplicates with equal bytes.
/// 5. Compute xxh3-64 once for every remaining representation.
/// 6. Construct validated Canonical Content and signature entries.
/// 7. Mint a candidate History Item ID through the package ID source.
/// 8. Project initial title/search/type summary from Canonical-as-Effective
///    Content.
///
/// The actor holds only immutable configuration, so every preparation is
/// independent and only immutable `Sendable` values cross its boundary
/// (docs/05-authority-kernel.md Part I-facing confinement rules;
/// docs/02-domain.md D17).
internal actor IngestPreparationActor {
    /// Pasteboard marker types that exclude the whole capture at steps 1/3.
    /// docs/05-authority-kernel.md §6.1, docs/02-domain.md §2.1
    ///
    /// V1 recognizes six third-party convention strings as a best-effort
    /// private/transient denylist. None is a framework guarantee; a marker is
    /// one defense-in-depth property of the pasteboard item. Its sibling
    /// plaintext or rich representations must not survive by merely filtering
    /// the marker.
    internal static let standardTransientTypeIdentifiers: Set<String> = [
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    /// The fixed `HistoryLimits.standard` safety profile in production
    /// (docs/06-cross-cutting.md §2); focused tests inject smaller bounds.
    private let limits: HistoryLimits

    /// The configured transient/private framework type set (step 3).
    private let transientTypeIdentifiers: Set<String>

    /// The representation fingerprint function — xxh3-64 in production.
    /// docs/02-domain.md §2.2
    ///
    /// Injectable so tests can substitute the deterministic collision double
    /// of `ForcedCollisionFingerprint` and exercise the §7.6 forced-collision
    /// path (docs/06-cross-cutting.md §7.6: equal fingerprints still require
    /// byte confirmation, D7).
    private let fingerprint: @Sendable (Data) -> UInt64

    /// Package-injected History Item identity source. Production supplies
    /// UUID entropy; focused tests pin identities without putting generation
    /// in the pure Domain (docs/01-architecture.md §4).
    private let makeCandidateID: @Sendable () -> HistoryItemID

    /// Creates the preparation actor. Production uses every default:
    /// `HistoryLimits.standard`, the standard transient type set, and the
    /// real xxh3-64 digest over the vendored C target.
    internal init(
        limits: HistoryLimits = .standard,
        transientTypeIdentifiers: Set<String> = IngestPreparationActor.standardTransientTypeIdentifiers,
        fingerprint: @escaping @Sendable (Data) -> UInt64 = XXH3Fingerprint.digest,
        makeCandidateID: @escaping @Sendable () -> HistoryItemID = {
            HistoryItemID(rawValue: UUID())
        }
    ) {
        self.limits = limits
        self.transientTypeIdentifiers = transientTypeIdentifiers
        self.fingerprint = fingerprint
        self.makeCandidateID = makeCandidateID
    }

    /// Prepares one raw capture for ingest planning, in §6.1's fixed order.
    ///
    /// - Throws: `HistoryFailure.invalidInput` for every caller-observable
    ///   preparation rejection (§16: capture/size problems → `.invalidInput`),
    ///   and `HistoryFailure.persistence(.invariantViolation)` only as the
    ///   defensive backstop if the already-validated Canonical construction
    ///   still fails (§16: internal invariant failures → persistence).
    internal func prepare(_ capture: ClipboardCapture) throws -> PreparedCaptureBundle {
        let representations = capture.representations

        // Step 1 — privacy is a whole-pasteboard-item property. Reject an
        // explicit adapter observation OR any known sibling marker before
        // inspecting/fingerprinting payload bytes. This defense also protects
        // direct HistoryCore callers that omit the observation flag but pass
        // through the raw marker (V1-Verified/03d).
        guard !capture.isConcealed,
              !representations.contains(where: { representation in
                  transientTypeIdentifiers.contains(representation.typeIdentifier)
              })
        else {
            throw HistoryFailure.invalidInput(.excludedFromHistory)
        }

        // Step 1 continued — reject an empty capture or hard-limit violation
        // (docs/06-cross-cutting.md §2 bounds). Totals use checked arithmetic;
        // no byte-count calculation wraps (§2).
        guard !representations.isEmpty else {
            throw HistoryFailure.invalidInput(.emptyCapture)
        }
        guard representations.count <= limits.maximumRepresentationsPerCaptureOrRevision else {
            throw HistoryFailure.invalidInput(.representationLimit)
        }
        guard capture.observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HistoryFailure.invalidInput(.invalidTimestamp)
        }
        var totalBytes = 0
        for representation in representations {
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(representation.bytes.count)
            guard !overflow, newTotal <= limits.maximumCaptureBytes else {
                throw HistoryFailure.invalidInput(.byteLimit)
            }
            totalBytes = newTotal
        }
        // §6.1 does not name the source-application observation, but Part VI
        // §2 binds it (1,024 UTF-8 bytes) and HistoryCore states that
        // HistoryStorage validates the raw capture; an oversized observation
        // is therefore rejected here as a capture byte-limit violation
        // rather than truncated (only title/search projection may truncate).
        if let sourceApplication = capture.origin.sourceApplication {
            guard sourceApplication.utf8.count <= limits.maximumSourceApplicationObservationUTF8Bytes else {
                throw HistoryFailure.invalidInput(.byteLimit)
            }
        }

        // Step 2 — reject invalid/oversized type identifiers and bytes. A
        // normalized content set forbids empty identifiers and empty bytes
        // (docs/02-domain.md §2.1); identifier problems report the identifier
        // reason, byte problems the byte reason.
        for representation in representations {
            let typeIdentifier = representation.typeIdentifier
            guard !typeIdentifier.isEmpty,
                  typeIdentifier.utf8.count <= limits.maximumTypeIdentifierUTF8Bytes
            else {
                throw HistoryFailure.invalidInput(.unsupportedRepresentationType(typeIdentifier))
            }
            guard !representation.bytes.isEmpty,
                  representation.bytes.count <= limits.maximumRepresentationBytes
            else {
                throw HistoryFailure.invalidInput(.byteLimit)
            }
        }

        // Step 3 — no per-representation privacy filtering is permitted.
        // Step 1 proved that no exclusion marker is present; retaining a
        // marker's sibling values would leak the very content it protects.

        // Step 4 — sort by stable Unicode scalar order (docs/02-domain.md §2.1),
        // then reject duplicate identifiers, including duplicates with equal
        // bytes (§6.1: preparation never chooses one by iteration order).
        // Swift String equality is canonically equivalent, while scalar order
        // distinguishes composed and decomposed spellings. The duplicate pass
        // must therefore track the whole sorted sequence: equivalent
        // identifiers need not be adjacent when a third scalar sequence sorts
        // between them.
        let sorted = representations.sorted { lhs, rhs in
            lhs.typeIdentifier.unicodeScalars.lexicographicallyPrecedes(
                rhs.typeIdentifier.unicodeScalars
            )
        }
        var seenTypeIdentifiers = Set<String>()
        seenTypeIdentifiers.reserveCapacity(sorted.count)
        for representation in sorted {
            guard seenTypeIdentifiers.insert(representation.typeIdentifier).inserted else {
                throw HistoryFailure.invalidInput(
                    .duplicateRepresentationType(representation.typeIdentifier)
                )
            }
        }

        // Step 5 — compute xxh3-64 exactly once for every remaining
        // representation; step 6 — construct validated Canonical Content and
        // derive one signature entry per representation (docs/02-domain.md
        // §2.2–§2.3).
        let canonicalRepresentations = sorted.map { representation in
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: representation.typeIdentifier,
                    bytes: representation.bytes
                ),
                fingerprint: ContentFingerprint(rawValue: fingerprint(representation.bytes))
            )
        }
        let canonical: CanonicalContent
        do {
            canonical = try CanonicalContent(representations: canonicalRepresentations)
        } catch {
            // Unreachable: steps 1–4 enforce every normalized-set requirement
            // the validator re-proves. A throw is a preparation bug, not
            // caller input — the §16 internal-invariant mapping.
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let signatureEntries = canonical.representations.map { representation in
            ContentSignatureEntry(
                typeIdentifier: representation.content.typeIdentifier,
                fingerprint: representation.fingerprint,
                byteCount: representation.content.bytes.count
            )
        }

        // Step 7 — mint the candidate History Item ID through the package ID
        // source (§6.1 step 7; minting is centralized in HistoryStorage,
        // docs/03a-instruction-set.md §2). Used only if planning inserts.
        let candidateID = makeCandidateID()

        // Step 8 — project the initial title/search/type summary from
        // Canonical-as-Effective Content: a new item starts with no revision,
        // so Effective Content equals Canonical Content with fingerprints
        // stripped (§6.1 step 8, §15; docs/02-domain.md §2.6).
        let projection = ContentProjector.project(
            EffectiveContent(representations: canonical.representations.map(\.content)),
            limits: limits
        )

        return PreparedCaptureBundle(
            domain: PreparedCapture(
                candidateID: candidateID,
                canonical: canonical,
                origin: CopyOrigin(
                    lineageHint: capture.origin.lineageHint,
                    sourceApplication: capture.origin.sourceApplication
                ),
                observedAt: capture.observedAt
            ),
            signatureEntries: signatureEntries,
            projection: projection
        )
    }

    /// Mints only a replacement candidate after the Authority proves the
    /// previous candidate is already occupied. The facade calls this between
    /// isolated Authority attempts, so no context or stored row crosses the
    /// actor hop (Card 2B-2; docs/05-authority-kernel.md §5/§6.1).
    internal func remintCandidateID(
        in prepared: PreparedCaptureBundle
    ) -> PreparedCaptureBundle {
        prepared.replacingCandidateID(with: makeCandidateID())
    }
}
