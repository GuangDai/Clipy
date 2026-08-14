/// §9 workloads 6–8: search modes, detail/paste, thumbnail single-flight.
/// Split out of PerformanceSuite.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

// MARK: - Workload 6: all search modes scan bounded projections (§9 bullet 7)

func workloadSearchModesScaling() async -> [WorkloadFixture] {
    let bullet = "7"
    // A 4× retained-row span with an 8× bound leaves 2× linear headroom
    // while rejecting the nominal 16× ratio of a quadratic regression.
    let definitions: [(key: String, label: String, mode: SearchMode, term: String)] = [
        ("exactSearchScalesWithRetainedCount", "exact", .exact, "needle"),
        ("fuzzySearchScalesWithRetainedCount", "fuzzy", .fuzzy, "nedle"),
        (
            "regexpSearchScalesWithRetainedCount",
            "regexp",
            .regexp,
            "needle-in-haystack-[0-9]+"
        ),
    ]
    let envelopes = definitions.map { definition in
        complexityEnvelope(for: definition.key)
    }
    let measurementScales = envelopes[0].measurementScales
    precondition(
        envelopes.dropFirst().allSatisfy { envelope in
            envelope.measurementScales == measurementScales
        },
        "search modes must share one §9 corpus span"
    )

    do {
        var medians: [[(Int, Double)]] =
            Array(repeating: [], count: definitions.count)
        var allMatched = Array(repeating: true, count: definitions.count)
        for count in measurementScales {
            // The three modes reuse one populated store at each size. This
            // keeps fixture construction identical and prevents population
            // cost from tripling merely to characterize another evaluator.
            let store = try await openMemoryStore()

            // Populate with deterministic items; embed "needle" in the middle item.
            for i in 0..<count {
                let text = (i == count / 2) ? "needle-in-haystack-\(i)" : "perf-search-\(i)"
                let capture = ClipboardCapture(
                    representations: [CapturedRepresentation(
                        typeIdentifier: "public.utf8-plain-text",
                        bytes: Data(text.utf8)
                    )],
                    origin: CopyOriginObservation(
                        sourceApplication: "perf-runner",
                        lineageHint: nil
                    ),
                    observedAt: Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(i))
                )
                _ = try await store.perform(.capture(capture))
            }

            // §9 bullet 7: exact, fuzzy, and regexp each evaluate the same
            // bounded scalar corpus; no cache is added without G2 evidence.
            for definitionIndex in definitions.indices {
                let definition = definitions[definitionIndex]
                let request = HistoryBrowseRequest(
                    kind: .search(text: definition.term, mode: definition.mode),
                    limit: 50
                )
                let medianMs = try await measureMedian {
                    _ = try await store.browse(request)
                }
                medians[definitionIndex].append((count, medianMs))

                // The performance gate cannot pass on an empty or otherwise
                // semantically wrong evaluation merely because it completed
                // quickly. Every frozen mode must return the planted row.
                let page = try await store.browse(request)
                if !page.rows.contains(where: { $0.title.contains("needle") }) {
                    allMatched[definitionIndex] = false
                }
            }
        }

        return definitions.indices.map { definitionIndex in
            let definition = definitions[definitionIndex]
            let envelope = envelopes[definitionIndex]
            let modeMedians = medians[definitionIndex]
            let ratio = safeRatio(
                modeMedians[modeMedians.count - 1].1,
                modeMedians[0].1
            )
            let passed = allMatched[definitionIndex] && ratio <= envelope.bound
            let fixture = WorkloadFixture(
                key: definition.key,
                bullet: bullet,
                sizes: modeMedians.map { "\($0.0)-retained" },
                mediansMs: modeMedians.map { $0.1 },
                ratio: ratio,
                bound: envelope.bound,
                pass: passed,
                note: "\(definition.label) search over the bounded scalar projection corpus (§9 bullet 7). The expected planted row must match; \(envelope.scaleSpan)× retained rows and an \(envelope.bound)× bound leave \(envelope.headroomFactor)× linear headroom while rejecting nominal quadratic scaling. This complexity envelope is not G2 absolute-latency evidence."
            )
            printResult(
                definition.key,
                bullet,
                ratio,
                envelope.bound,
                passed
            )
            return fixture
        }
    } catch {
        return definitions.map { definition in
            failureFixture(key: definition.key, bullet: bullet, error: error)
        }
    }
}

// MARK: - Workload 7: detail and paste decode one item (§9 bullet 8)

func workloadDetailAndPaste() async -> [WorkloadFixture] {
    let bullet = "8"
    let detailKey = "detailDecodeOneItem"
    let detailEnvelope = complexityEnvelope(for: detailKey)
    let pasteKey = "pastePayloadDecodeOneItem"
    let pasteEnvelope = complexityEnvelope(for: pasteKey)
    var fixtures: [WorkloadFixture] = []

    // --- Details ---
    // §9 bullet 8: detail/paste decode one item's bounded lineage.
    do {
        var medians: [(Int, Double)] = []
        for count in detailEnvelope.measurementScales {
            let store = try await openMemoryStore()
            let firstRef = try await populateAndReturnFirstRef(store, count: count)
            let medianMs = try await measureMedian {
                _ = try await store.details(for: firstRef.id)
            }
            medians.append((count, medianMs))
        }
        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= detailEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: detailKey,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: detailEnvelope.bound,
            pass: passed,
            note: "Detail decodes one item's bounded lineage (§9 bullet 8). \(detailEnvelope.scaleSpan)× retained, theoretical ratio \(detailEnvelope.theoreticalRatio)×, and \(detailEnvelope.bound)× bound leave \(detailEnvelope.headroomFactor)× headroom for O(1) retained-count behavior."
        ))
        printResult(
            detailKey,
            bullet,
            ratio,
            detailEnvelope.bound,
            passed
        )
    } catch {
        fixtures.append(failureFixture(
            key: detailKey,
            bullet: bullet,
            error: error
        ))
    }

    // --- Paste payload ---
    do {
        var medians: [(Int, Double)] = []
        for count in pasteEnvelope.measurementScales {
            let store = try await openMemoryStore()
            let firstRef = try await populateAndReturnFirstRef(store, count: count)
            let medianMs = try await measureMedian {
                _ = try await store.pastePayload(for: firstRef.id)
            }
            medians.append((count, medianMs))
        }
        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= pasteEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: pasteKey,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: pasteEnvelope.bound,
            pass: passed,
            note: "Paste payload decodes one item's current Effective Content (§9 bullet 8). \(pasteEnvelope.scaleSpan)× retained, theoretical ratio \(pasteEnvelope.theoreticalRatio)×, and \(pasteEnvelope.bound)× bound leave \(pasteEnvelope.headroomFactor)× headroom for O(1) retained-count behavior."
        ))
        printResult(
            pasteKey,
            bullet,
            ratio,
            pasteEnvelope.bound,
            passed
        )
    } catch {
        fixtures.append(failureFixture(
            key: pasteKey,
            bullet: bullet,
            error: error
        ))
    }

    return fixtures
}

// MARK: - Workload 8: thumbnail single-flight shares decode (§9 bullet 9)

/// PNG's CRC-32/ISO-HDLC checksum (polynomial 0x04C11DB7 in reflected form).
/// Kept as a pure package-internal helper so the fixture's chunk integrity is
/// pinned by published known-answer vectors rather than trusted transitively
/// through ImageIO decode success.
func pngCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB8_8320 : 0)
        }
    }
    return crc ^ 0xFFFF_FFFF
}

/// Deterministic Marsaglia xorshift32 stream used only to make the thumbnail
/// fixture incompressible. The explicit state value and recurrence give tests
/// a stable KAT seam without introducing system entropy into perf fixtures.
struct XorShift32: Sendable {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    mutating func next() -> UInt32 {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return state
    }

    mutating func nextByte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }
}

/// Builds a deterministic 1024×1024 RGB PNG at runtime (Foundation-only).
/// The WS15 1×1 fixture decodes in microseconds and a compressible pattern
/// inflates as LZ77 match-copies — both make the single-flight ratio measure
/// Authority version-fence scheduling instead of decode sharing (runs
/// 30734054783, 30734466775). Incompressible xorshift noise forces genuine
/// inflate + unfilter cost (~ms for 3 MB scanlines), so the decode dominates
/// per-call cost and concurrent-8 ≈ one shared decode (§9 bullet 9). The
/// zlib stream comes from NSData's COMPRESSION_ZLIB — RFC 1950, the IDAT
/// payload format.
func makeNoisePNG(width: Int, height: Int) throws -> Data {
    func chunk(_ tag: String, _ payload: Data) -> Data {
        var out = Data()
        var length = UInt32(payload.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        let tagData = Data(tag.utf8)
        out.append(tagData)
        out.append(payload)
        var crc = pngCRC32(tagData + payload).bigEndian
        out.append(Data(bytes: &crc, count: 4))
        return out
    }

    // Signature + IHDR (bit depth 8, color type 2 = truecolor RGB).
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    var ihdr = Data()
    var widthBE = UInt32(width).bigEndian
    var heightBE = UInt32(height).bigEndian
    ihdr.append(Data(bytes: &widthBE, count: 4))
    ihdr.append(Data(bytes: &heightBE, count: 4))
    ihdr.append(contentsOf: [8, 2, 0, 0, 0])
    png.append(chunk("IHDR", ihdr))

    // Scanlines: filter byte 0 per row + deterministic xorshift32 noise.
    // Incompressible pixels make the deflate stream carry 3 MB of literals,
    // so the decoder pays real inflate + unfilter cost per decode.
    var byteGenerator = XorShift32(seed: 0x9E37_79B9)
    var raw = Data()
    raw.reserveCapacity(height * (1 + width * 3))
    for _ in 0..<height {
        raw.append(0)
        for _ in 0..<(width * 3) {
            raw.append(byteGenerator.nextByte())
        }
    }

    // zlib stream: real deflate via Foundation's COMPRESSION_ZLIB (RFC 1950),
    // so the ImageIO decode pays genuine inflate cost — stored blocks would
    // decompress as a memcpy and the decode would not dominate the ratio.
    let zstream = try (raw as NSData).compressed(using: .zlib) as Data
    png.append(chunk("IDAT", zstream))

    png.append(chunk("IEND", Data()))
    return png
}

func workloadThumbnailSingleFlight() async -> [WorkloadFixture] {
    let bullet = "9"
    let key = "thumbnailSingleFlightSharesDecode"
    let envelope = complexityEnvelope(for: key)
    precondition(
        envelope.measurementScales == [1, 8],
        "thumbnail single-flight fixture is structurally sequential-1/concurrent-8"
    )

    do {
        let store = try await openMemoryStore()

        let pngData = try makeNoisePNG(width: 1024, height: 1024)
        // Capture a text+png item so the thumbnail path has a valid image source.
        let capture = ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("thumbnail-perf-item".utf8)),
                CapturedRepresentation(typeIdentifier: "public.png", bytes: pngData),
            ],
            origin: CopyOriginObservation(sourceApplication: "perf-runner", lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 600_000_000)
        )
        let receipt = try await store.perform(.capture(capture))
        guard case .committed(let commit) = receipt,
              case .inserted(let ref) = commit.outcome else {
            throw PerfError.captureUnexpectedOutcome
        }
        let pixels = PixelSize(width: 32, height: 32)

        // Untimed end-to-end smoke: steps 1–7 remain wired through the public
        // facade. The single-flight ratio below deliberately isolates steps
        // 5–7; otherwise eight actor-serialized Authority source fetches hide
        // whether the decode itself is shared (V1-Verified/04).
        _ = try await store.thumbnail(for: ref, pixels: pixels)

        // The immutable source bytes are prepared exactly once before either
        // measurement. This package-only seam is the production service, not
        // a benchmark double; it removes only the source-fetch prefix from the
        // timed construct while retaining the real flight table and worker.
        let thumbnailService = ThumbnailService()

        // (a) 8 SEQUENTIAL thumbnail calls — record median per-call time.
        // Warmup.
        _ = try await thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        let clock = ContinuousClock()
        var seqSamples: [Double] = []
        for _ in 0..<8 {
            let start = clock.now
            _ = try await thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
            seqSamples.append(durationToMs(start.duration(to: clock.now)))
        }
        let seqMedian = median(seqSamples)

        // (b) 8 CONCURRENT identical-key calls via async let — record total
        // wall time. §9 bullet 9: after one bounded source fetch, thumbnail
        // performs one shared concurrent decode for an identical key. With
        // single-flight, concurrent-8 total ≈ 1 decode; without, ≈ 8 decodes.
        // Concurrent warmup (2 calls).
        async let warmA = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let warmB = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        _ = try await warmA
        _ = try await warmB

        let concStart = clock.now
        async let c1 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c2 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c3 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c4 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c5 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c6 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c7 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c8 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        _ = try await c1
        _ = try await c2
        _ = try await c3
        _ = try await c4
        _ = try await c5
        _ = try await c6
        _ = try await c7
        _ = try await c8
        let concTotal = durationToMs(concStart.duration(to: clock.now))

        let ratio = safeRatio(concTotal, seqMedian)
        let bound = envelope.bound
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: key,
            bullet: bullet,
            sizes: ["sequential-1"],
            mediansMs: [seqMedian],
            wallTimeMs: concTotal,
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "After one prefetched immutable source, the production ThumbnailService shares one decode for an identical key (§9 steps 5–7). Concurrent-8 total ≤ \(bound)× sequential-1 median (\(envelope.headroomFactor)× headroom over the one-decode theoretical ratio) proves a single shared decode, not eight; an untimed public-facade call smoke-tests the complete source-fetch pipeline."
        )
        printResult(key, bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: key, bullet: bullet, error: error)]
    }
}

