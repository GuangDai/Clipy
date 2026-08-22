/// Thumbnail single-flight service + its owned decode worker
/// (docs/04-coherence.md §9; docs/05-authority-kernel.md §14.5).
///
/// The `SwiftDataHistory` facade's `thumbnail(for:pixels:)` pipeline enters
/// this service before source hydration. The service atomically joins or
/// installs one exact-key source-to-decode task. The creator task asks
/// `HistoryAuthority.thumbnailSource` to validate dimensions, fetch and fully
/// hydrate exactly one item, verify its Content Version, derive Effective
/// Content, and select immutable source bytes in one non-suspending Authority
/// interval. It then decodes/downsamples off the Authority, enforces output
/// bounds, and encodes PNG. An existing-flight caller first asks the Authority
/// for a scalar dimension/existence/version fence, then awaits that same task.
/// The flight entry is removed when its task completes, and completed bytes
/// are NOT retained by HistoryStorage.
///
/// The version fence (WS15, docs/06-cross-cutting.md §8): ImageIO decode
/// occurs only after all SwiftData objects and context have been released —
/// the facade guarantees that by construction: `thumbnailSource` returns one
/// immutable selection and the facade passes only its `Data` into this
/// service, so the service never touches a `ModelContext` or `@Model` value
/// (§14.5). If the item changes during decode
/// the result remains tagged with the old reference (the payload's `item` IS
/// the request's reference); the caller applies it only if its row still
/// carries that reference. A request whose reference was already stale before
/// the creator's complete source fence, or before an existing-flight caller's
/// scalar join fence, fails with `.staleContent`; current bytes are never
/// returned under an old key (§9).
///
/// Only immutable `Sendable` values cross actor boundaries: `Data` in,
/// `ThumbnailPayload` out (docs/01-architecture.md §6; Part VI §6).
import Foundation
import HistoryCore
import ImageIO
import UniformTypeIdentifiers

// MARK: - Single-flight key (docs/04-coherence.md §9)

/// The single-flight key: one flight per (item reference, pixel dimensions).
/// The reference carries both the item ID and the Content Version
/// (`HistoryItemReference`), so two requests for the same item at different
/// Effective Content states produce different flights and different payloads,
/// and a stale-reference result cannot be misapplied to a newer row
/// (docs/04-coherence.md §9; WS15).
internal struct ThumbnailFlightKey: Sendable, Hashable {
    internal let item: HistoryItemReference
    internal let pixels: PixelSize
}

// MARK: - WS15 suspension point (docs/06-cross-cutting.md §8)

/// Named suspension point of `ThumbnailService` for the deterministic
/// concurrency harness (`SuspensionGate` in HistoryStorageTests; WS15).
/// docs/roadmap/03-historystorage.md step-5 note (concurrency harness).
///
/// Test seam, compiled in always and harmless in production: the handler is
/// `nil` unless a test installs one via @testable, so the point is a no-op
/// outside the harness (no `#if DEBUG`). The point is placed where an `await`
/// is legal — after the creator's Authority version fence returned immutable
/// source bytes and after the flight was installed, but before ImageIO decode.
internal enum ThumbnailServiceSuspensionPoint: String, Sendable {
    /// At decode entry, after the source-inclusive flight is installed — the
    /// WS15 fence-to-decode window: a revision committing here changes the
    /// item "during decode", and the result must stay tagged with the verified
    /// old reference (docs/04-coherence.md §9).
    case decodeEntry = "ThumbnailService.thumbnail.entry"
}

// MARK: - ThumbnailService (docs/04-coherence.md §9)

/// Owns the thumbnail flight table and its decode worker
/// (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9).
///
/// Single-flight, not a completed-result cache: an existing in-flight
/// source-to-decode `Task` for the exact key is shared, and on completion
/// (success, failure, OR cancellation) the entry is removed. Completed bytes
/// are NOT retained (§9 step 7; the G1 completed-thumbnail cache is deferred,
/// docs/06-cross-cutting.md §3).
///
/// The actor holds the flight dictionary and the owned `ThumbnailWorker`; the
/// worker owns no state, so every decode is independent and only immutable
/// `Sendable` values cross the actor boundary (§14.5; Part VI §6).
package actor ThumbnailService {

    /// One source-to-decode task per exact key. Source hydration lives inside
    /// the shared task, so concurrent callers retain one bounded source value
    /// rather than one value per caller.
    private var flights: [
        ThumbnailFlightKey: Task<ThumbnailPayload?, Error>
    ] = [:]

    /// The owned off-Authority decode worker (§9 step 6; §14.5).
    private let worker = ThumbnailWorker()

    /// The roadmap-owned WS15 suspension handler; `nil` in production
    /// (test seam — see `ThumbnailServiceSuspensionPoint`).
    private var suspensionHandler: (
        @Sendable (ThumbnailServiceSuspensionPoint) async -> Void
    )?

    package init() {}

    // MARK: Roadmap-owned test seam (docs/roadmap/03-historystorage.md step-5 note; WS15)

    /// Installs (or clears) the suspension handler the deterministic
    /// concurrency harness drives for WS15 (docs/06-cross-cutting.md §8).
    /// Test seam — `nil` in production, compiled in always, set via
    /// @testable; see `ThumbnailServiceSuspensionPoint`.
    internal func setSuspensionHandler(
        _ handler: (@Sendable (ThumbnailServiceSuspensionPoint) async -> Void)?
    ) {
        suspensionHandler = handler
    }

    /// Joins or creates the source-inclusive single-flight for one exact key.
    /// The creator installs the task before the first suspension; that task
    /// performs the complete Authority source load and off-Authority decode.
    /// A caller finding an existing task first runs its own lightweight
    /// dimension/existence/version fence, then awaits the shared result. This
    /// preserves the rule that a request already stale when it joins cannot
    /// receive old bytes, without re-materializing the content blob.
    ///
    /// `loadSource` and `validateJoin` are production dependency operations
    /// supplied by `SwiftDataHistory`, not a second storage implementation.
    /// The former returns only immutable `Data`, and the latter returns no
    /// model value; focused tests substitute these operations at this seam.
    internal func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize,
        loadSource: @escaping @Sendable () async throws -> Data?,
        validateJoin: @Sendable () async throws -> Void
    ) async throws -> ThumbnailPayload? {
        let key = ThumbnailFlightKey(item: item, pixels: pixels)

        // Existing-key callers cross their own scalar version fence before
        // sharing the creator's source/decode result. A failed join never
        // cancels or removes the creator-owned flight.
        if let existing = flights[key] {
            try await validateJoin()
            return try await existing.value
        }

        // Snapshot actor-owned immutable dependencies, then install the task
        // without suspension. Its source phase runs the Authority's complete
        // non-suspending fence/derivation; no source Data exists outside this
        // one shared task.
        let worker = worker
        let handler = suspensionHandler
        let task = Task<ThumbnailPayload?, Error> {
            guard let sourceBytes = try await loadSource() else {
                return nil
            }

            // WS15 parks after the source/version fence and before ImageIO.
            // The flight is already visible, so a concurrent stale caller
            // takes the validated join path instead of creating another load.
            await handler?(.decodeEntry)

            return try await worker.decodeThumbnail(
                sourceBytes: sourceBytes,
                item: item,
                pixels: pixels
            )
        }
        flights[key] = task

        // §9 step 7: remove the flight entry on success, failure, OR
        // cancellation — completed bytes are NOT retained. The deferred
        // removal runs unconditionally before the value/error propagates.
        defer {
            flights.removeValue(forKey: key)
        }
        return try await task.value
    }

    /// Package-only direct-source convenience used by the Part VI §9 runner
    /// to isolate decode sharing. Production facade calls use the
    /// source-inclusive overload above. A non-optional source cannot produce
    /// the overload's `nil` result.
    package func thumbnail(
        _ sourceBytes: Data,
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload {
        let payload = try await thumbnail(
            for: item,
            pixels: pixels,
            loadSource: { sourceBytes },
            validateJoin: {}
        )
        guard let payload else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return payload
    }
}

// MARK: - ThumbnailWorker (docs/05-authority-kernel.md §14.5; §9 step 6)

/// The off-Authority ImageIO decode worker
/// (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9 step 6).
///
/// Owns no state: every decode is independent and only immutable `Sendable`
/// values cross the actor boundary (`Data` in, `ThumbnailPayload` out). The
/// worker never touches SwiftData — the facade extracts immutable source bytes
/// from `thumbnailSource` after releasing all `@Model` values and context
/// (§14.5: "ImageIO decode occurs only after all SwiftData objects and context
/// have been released"). The worker is a separate actor from
/// `ThumbnailService` so the ImageIO decode does not block the flight table's
/// hop — the service joins/creates flights while the worker decodes.
internal actor ThumbnailWorker {

    internal init() {}

    /// Decodes `sourceBytes`, downsamples to `pixels`, enforces the output
    /// bound, and re-encodes as PNG (§9 step 6; §14.5).
    ///
    /// Two phases, both pure ImageIO with no SwiftData access:
    ///
    /// 1. **Decode/downsample**: `CGImageSourceCreateWithData` wraps the
    ///    source bytes; a `nil` source means the stored representation is not
    ///    a decodable image — §16 maps a decode failure to
    ///    `.persistence(.corruptStoredValue)` (an in-store image
    ///    representation that fails decode is a stored-value problem).
    ///    `CGImageSourceCreateThumbnailAtIndex` downsamples with
    ///    `MaxPixelSize` = `max(pixels.width, pixels.height)`,
    ///    `CreateThumbnailFromImageAlways` = true, and
    ///    `CreateThumbnailWithTransform` = true. A `nil` thumbnail is the
    ///    same corrupt-stored-value failure.
    /// 2. **Encode/bound**: `CGImageDestination` re-encodes the downsampled
    ///    `CGImage` as PNG (`UTType.png.identifier`); the encoded bytes must
    ///    be ≤ `HistoryLimits.standard.maximumEncodedThumbnailBytes` (06 §2:
    ///    16 MiB). Valid high-entropy output can exceed that envelope, so the
    ///    public result is `.capacityExceeded(.thumbnailBytes)` rather than a
    ///    persistence or invariant failure. Destination/finalization failure
    ///    remains an encode-side `.persistence(.invariantViolation)`.
    ///
    /// The payload carries the SAME key values it was requested with: `item`
    /// is the request's reference, `pixels` is the request's extent — so the
    /// result is tagged with the verified old reference regardless of
    /// intervening commits (§9; WS15).
    ///
    /// - Throws: `HistoryFailure.persistence(.corruptStoredValue)` for a
    ///   nil source or nil thumbnail; `.capacityExceeded(.thumbnailBytes)`
    ///   when the encoded PNG exceeds the output bound; or
    ///   `.persistence(.invariantViolation)` when PNG encoding itself fails.
    internal func decodeThumbnail(
        sourceBytes: Data,
        item: HistoryItemReference,
        pixels: PixelSize
    ) throws -> ThumbnailPayload {
        let limits = HistoryLimits.standard

        // Phase 1 — decode/downsample (§9 step 6; §14.5).
        //
        // CGImageSourceCreateWithData returns nil when the bytes are not a
        // recognizable image container — a stored image representation that
        // fails to decode is a corrupt stored value (§16: decode/schema
        // invariant failures → .persistence(.corruptStoredValue)).
        guard let source = CGImageSourceCreateWithData(
            sourceBytes as CFData,
            nil
        ) else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }

        // The MaxPixelSize bounds the thumbnail's longer axis; ImageIO
        // preserves aspect ratio, so the requested width/height are upper
        // bounds and the actual decoded extent may be smaller.
        let maxPixelSize = max(pixels.width, pixels.height)

        // The `as CFDictionary` target makes the literal values infer as `Any`,
        // so `Int` (bridged to NSNumber/CFNumber) and `CFBoolean` coexist. The
        // `kCFBooleanTrue` constants are non-nil CoreFoundation globals —
        // unwrapped explicitly so the IUO never coerces to `Any` (zero-warning
        // rule, docs/AGENTS §4).
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: kCFBooleanTrue!,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: kCFBooleanTrue!
        ] as CFDictionary

        // Primary-image index (audit
        // docs/reviews/2026-08-20-clipy-maccy-audit/03-apple-platform.md
        // §7 APL-C-06): a HEIF/HEIC container may carry auxiliary images
        // and designate a primary image other than index 0, so forcing 0
        // can decode the wrong image. CGImageSourceGetPrimaryImageIndex
        // honors the container's designation and returns 0 for non-HEIF
        // sources, so GIF/TIFF decoding stays first-frame — a deliberate
        // product simplification (the audit's "GIF/TIFF first-frame may
        // be deliberate"), not an oversight.
        let imageIndex = CGImageSourceGetPrimaryImageIndex(source)

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            imageIndex,
            thumbnailOptions
        ) else {
            // The source was recognized but the thumbnail could not be created
            // — the stored image data is corrupt (§16: .corruptStoredValue).
            throw HistoryFailure.persistence(.corruptStoredValue)
        }

        // Phase 2 — re-encode as PNG and enforce the output bound (06 §2).
        //
        // The encoded bytes must be ≤ maximumEncodedThumbnailBytes (16 MiB).
        // A valid high-entropy image may exceed the envelope after PNG
        // overhead, so exceeding it is a typed capacity failure.
        let mutableData = CFDataCreateMutable(
            kCFAllocatorDefault,
            0
        )!
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            // Could not create the encoder — a defensive internal failure.
            throw Self.encodingFailure
        }

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            // The source decoded successfully; failure to encode the derived
            // image is an encode-side invariant, not stored-value corruption.
            throw Self.encodingFailure
        }

        let encodedBytes = mutableData as Data

        try Self.validateEncodedThumbnailByteCount(
            encodedBytes.count,
            limits: limits
        )

        return ThumbnailPayload(
            item: item,
            pixels: pixels,
            format: .png,
            encodedBytes: encodedBytes
        )
    }

    /// One owner for PNG destination/finalization failure classification.
    internal static let encodingFailure = HistoryFailure.persistence(
        .invariantViolation
    )

    /// Pure byte-envelope validation shared with the boundary regression.
    internal static func validateEncodedThumbnailByteCount(
        _ found: Int,
        limits: HistoryLimits
    ) throws {
        guard found <= limits.maximumEncodedThumbnailBytes else {
            throw HistoryFailure.capacityExceeded(.thumbnailBytes)
        }
    }
}
