/// Thumbnail single-flight service + its owned decode worker
/// (docs/04-coherence.md §9; docs/05-authority-kernel.md §14.5).
///
/// The `SwiftDataHistory` facade's `thumbnail(for:pixels:)` pipeline
/// (SwiftDataHistory.swift): the `HistoryAuthority.thumbnailSource` method
/// validates the dimensions, fetches exactly one item, verifies the requested
/// Content Version equals the durable one, derives Effective Content, selects
/// the supported image representation, and returns immutable source image
/// bytes (answering `nil` itself when no supported representation exists) —
/// all inside one non-suspending Authority interval (§9 steps 1–4). This
/// service then owns §9 steps 5–7: join/create the single-flight for the exact
/// `(ID, ContentVersion, dimensions)` key, decode/downsample off the Authority,
/// enforce output bounds, encode PNG, and return a payload carrying the same
/// key values; the flight entry is removed on success, failure, or
/// cancellation, and completed bytes are NOT retained by HistoryStorage.
///
/// The version fence (WS15, docs/06-cross-cutting.md §8): ImageIO decode
/// occurs only after all SwiftData objects and context have been released —
/// the facade guarantees that by construction: `thumbnailSource` returns
/// immutable `Data` across the actor boundary, so this service never touches a
/// `ModelContext` or `@Model` value (§14.5). If the item changes during decode
/// the result remains tagged with the old reference (the payload's `item` IS
/// the request's reference); the caller applies it only if its row still
/// carries that reference. A request whose reference was already stale before
/// `thumbnailSource` fails there with `.staleContent`; current bytes are never
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
/// outside the harness (no `#if DEBUG`). The point is placed where an
/// `await` is legal — after the Authority's version fence returned immutable
/// source bytes, before the flight is joined/created.
internal enum ThumbnailServiceSuspensionPoint: String, Sendable {
    /// On `thumbnail` entry, before the flight is joined/created — the WS15
    /// fence-to-decode window: a revision committing here changes the item
    /// "during decode", and the result must stay tagged with the verified old
    /// reference (docs/04-coherence.md §9).
    case decodeEntry = "ThumbnailService.thumbnail.entry"
}

// MARK: - ThumbnailService (docs/04-coherence.md §9)

/// Owns the thumbnail flight table and its decode worker
/// (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9).
///
/// Single-flight, not a completed-result cache: an existing in-flight `Task`
/// for the exact key is shared — the second caller awaits the same `Task` —
/// and on completion (success, failure, OR cancellation) the entry is removed.
/// Completed bytes are NOT retained (§9 step 7; the G1 completed-thumbnail
/// cache is deferred, docs/06-cross-cutting.md §3).
///
/// The actor holds the flight dictionary and the owned `ThumbnailWorker`; the
/// worker owns no state, so every decode is independent and only immutable
/// `Sendable` values cross the actor boundary (§14.5; Part VI §6).
internal actor ThumbnailService {

    /// One in-flight decode per exact key; the value is shared so concurrent
    /// callers for the same key await the same `Task` (§9 step 5).
    private var flights: [ThumbnailFlightKey: Task<ThumbnailPayload, Error>] = [:]

    /// The owned off-Authority decode worker (§9 step 6; §14.5).
    private let worker = ThumbnailWorker()

    /// The roadmap-owned WS15 suspension handler; `nil` in production
    /// (test seam — see `ThumbnailServiceSuspensionPoint`).
    private var suspensionHandler: (
        @Sendable (ThumbnailServiceSuspensionPoint) async -> Void
    )?

    internal init() {}

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

    /// Suspends at `point` when the harness has installed a handler; a no-op
    /// otherwise and always in production.
    private func suspendIfRequested(_ point: ThumbnailServiceSuspensionPoint) async {
        await suspensionHandler?(point)
    }

    /// Joins or creates the single-flight for the exact key, then decodes
    /// `sourceBytes` into an encoded PNG thumbnail (§9 steps 5–7).
    ///
    /// The facade already validated dimensions, verified the Content Version,
    /// and returned immutable source bytes inside one Authority interval
    /// (§9 steps 1–4); this method owns the off-Authority decode. The returned
    /// payload carries the SAME key values it was requested with — the
    /// payload's `item` IS the request's reference — so a decode that completes
    /// after the item changed is still correctly tagged with the verified old
    /// reference (§9; WS15).
    ///
    /// - Parameters:
    ///   - sourceBytes: Immutable source image bytes derived from the item's
    ///     Effective Content by the Authority (§9 step 3); never a SwiftData
    ///     object.
    ///   - item: The reference the decode result is tagged with.
    ///   - pixels: The requested thumbnail extent.
    /// - Returns: A PNG-encoded `ThumbnailPayload` tagged with `item`.
    /// - Throws: `HistoryFailure.persistence(.corruptStoredValue)` when the
    ///   source bytes are not a decodable image (§16: decode failure →
    ///   corrupt stored value); `HistoryFailure.persistence(.invariantViolation)`
    ///   when the encoded PNG exceeds `maximumEncodedThumbnailBytes` (the
    ///   16 MiB output bound is a defensive safety envelope — §16 has no
    ///   thumbnail-capacity case and a bounded downsample cannot realistically
    ///   hit it).
    internal func thumbnail(
        _ sourceBytes: Data,
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload {
        // Roadmap-owned WS15 test seam: the legal suspension point of this
        // path — source bytes verified, flight not yet joined/created, so a
        // revision can commit in the fence-to-decode window (§9).
        await suspendIfRequested(.decodeEntry)

        let key = ThumbnailFlightKey(item: item, pixels: pixels)

        // §9 step 5: join an existing in-flight decode for the exact key, or
        // create a new one. The second caller awaits the same Task.
        if let existing = flights[key] {
            return try await existing.value
        }

        // Create the flight. The Task hops onto the worker actor for the
        // off-Authority ImageIO decode (§14.5); only immutable values cross.
        let task = Task<ThumbnailPayload, Error> {
            try await self.worker.decodeThumbnail(
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
}

// MARK: - ThumbnailWorker (docs/05-authority-kernel.md §14.5; §9 step 6)

/// The off-Authority ImageIO decode worker
/// (docs/05-authority-kernel.md §14.5; docs/04-coherence.md §9 step 6).
///
/// Owns no state: every decode is independent and only immutable `Sendable`
/// values cross the actor boundary (`Data` in, `ThumbnailPayload` out). The
/// worker never touches SwiftData — the facade's `thumbnailSource` returns
/// immutable source bytes after releasing all `@Model` values and context
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
    ///    16 MiB). §16 has no thumbnail-capacity case and a bounded downsample
    ///    cannot realistically hit 16 MiB, so this is a defensive backstop —
    ///    exceed maps to `.persistence(.invariantViolation)` (an internal
    ///    safety-envelope violation, not a caller-input or capacity failure).
    ///
    /// The payload carries the SAME key values it was requested with: `item`
    /// is the request's reference, `pixels` is the request's extent — so the
    /// result is tagged with the verified old reference regardless of
    /// intervening commits (§9; WS15).
    ///
    /// - Throws: `HistoryFailure.persistence(.corruptStoredValue)` for a
    ///   nil source or nil thumbnail; `HistoryFailure.persistence(.invariantViolation)`
    ///   when the encoded PNG exceeds the output bound.
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
        // so `Int` (bridged to NSNumber/CFNumber) and `CFBoolean` coexist.
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: kCFBooleanTrue,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: kCFBooleanTrue
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions
        ) else {
            // The source was recognized but the thumbnail could not be created
            // — the stored image data is corrupt (§16: .corruptStoredValue).
            throw HistoryFailure.persistence(.corruptStoredValue)
        }

        // Phase 2 — re-encode as PNG and enforce the output bound (06 §2).
        //
        // The encoded bytes must be ≤ maximumEncodedThumbnailBytes (16 MiB).
        // §16 has no thumbnail-capacity case and no CapacityKind fits a
        // thumbnail output bound; a bounded downsample of a decodable image
        // cannot realistically produce a 16 MiB PNG, so this is a defensive
        // safety envelope — exceed is an internal invariant violation.
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
            throw HistoryFailure.persistence(.invariantViolation)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            // Finalize failed — the downsampled image could not be encoded.
            throw HistoryFailure.persistence(.corruptStoredValue)
        }

        let encodedBytes = mutableData as Data

        guard encodedBytes.count <= limits.maximumEncodedThumbnailBytes else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        return ThumbnailPayload(
            item: item,
            pixels: pixels,
            format: .png,
            encodedBytes: encodedBytes
        )
    }
}
