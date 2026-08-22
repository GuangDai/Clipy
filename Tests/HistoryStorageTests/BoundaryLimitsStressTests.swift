/// Boundary-limits stress slice: the docs/06-cross-cutting.md §2 admission
/// bounds proven at their exact edges with SYNTHESIZED payloads — no fixture
/// tree required, so this suite is NOT gated on `FixtureCatalog.available`
/// and runs in every `swift test` (the generator deliberately ships no
/// boundary-size binary blobs; see `scripts/generate_fixtures.py`).
///
/// All four assertions pin the inclusive-`≤` admission semantics of
/// `IngestPreparation.prepare` (docs/05-authority-kernel.md §6.1 steps 1–2)
/// against `HistoryLimits.standard` (06 §2):
/// - one representation of EXACTLY 64 MiB is admitted; 64 MiB + 1 throws
///   `.invalidInput(.byteLimit)`;
/// - 32 representations are admitted; 33 throw
///   `.invalidInput(.representationLimit)`;
/// - a capture whose checked total exceeds 128 MiB throws
///   `.invalidInput(.byteLimit)` (06 §2 totals use checked arithmetic; no
///   byte-count calculation wraps).
///
/// The stores are in-memory (`HistoryPersistence.memory`, 05 §2: same
/// Authority/planner/transaction path, no durability) so the 64–128 MiB
/// payloads never touch disk. Large `Data` values are scoped to one call
/// each and released before the next allocation; `.serialized` keeps the
/// suite's peak memory independent of its own tests' timing. Peak transient
/// usage is ≈ 128 MiB + 1 byte in the total-bytes test — inherent to
/// proving a 128 MiB bound end-to-end.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

@Suite("HistoryStorage admission boundary stress (synthesized)", .serialized)
struct BoundaryLimitsStressTests {

// MARK: - Suite-local helpers

/// Opens the real facade over an in-memory store (05 §2).
private static func openMemoryHistory() async throws -> SwiftDataHistory {
    try await SwiftDataHistory.open(
        configuration: HistoryConfiguration(persistence: .memory)
    )
}

/// One raw capture of the given representations at a fixed deterministic
/// observation time (03a §4).
private static func makeCapture(
    _ representations: [CapturedRepresentation]
) -> ClipboardCapture {
    ClipboardCapture(
        representations: representations,
        origin: CopyOriginObservation(
            sourceApplication: "com.example.boundary.stress",
            lineageHint: nil
        ),
        observedAt: Date(timeIntervalSinceReferenceDate: 700_400_000)
    )
}

/// `count` one-byte representations with distinct type identifiers (a
/// duplicate identifier would throw `.duplicateRepresentationType` first,
/// which is not the path under test).
private static func makeRepresentations(count: Int) -> [CapturedRepresentation] {
    (0..<count).map { index in
        CapturedRepresentation(
            typeIdentifier: "com.example.boundary.rep-\(index)",
            bytes: Data([UInt8(index % 256)])
        )
    }
}

// MARK: - Representation byte bound (06 §2: "Bytes in one representation" — 64 MiB)

/// 06 §2 + 05 §6.1 step 2: the representation byte bound is INCLUSIVE — a
/// single representation of exactly `maximumRepresentationBytes` (64 MiB)
/// is admitted and commits as `.inserted`. The admitted payload is retained
/// whole: detail hydration returns the same byte count (03b §9).
@Test func representationAtExactly64MiBIsAdmitted() async throws {
    let history = try await Self.openMemoryHistory()
    let limit = HistoryLimits.standard.maximumRepresentationBytes

    let receipt = try await history.perform(.capture(Self.makeCapture([
        CapturedRepresentation(typeIdentifier: "public.data", bytes: Data(count: limit)),
    ])))
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome
    else {
        Issue.record("boundary 64 MiB: expected .committed(.inserted), got \(receipt)")
        return
    }
    #expect(commit.position.rawValue == 1)

    // The retained Canonical representation is the full 64 MiB (03b §9
    // detail is the byte-returning read).
    let details = try await history.details(for: reference.id)
    #expect(details.canonical.map(\.bytes.count) == [limit])
}

/// 06 §2 + 05 §6.1 step 2 + 03b §10: one byte over the bound is rejected as
/// `.invalidInput(.byteLimit)` before fingerprinting or persistence — no
/// receipt, no commit.
@Test func representationOneByteOver64MiBIsRejected() async throws {
    let history = try await Self.openMemoryHistory()
    let limit = HistoryLimits.standard.maximumRepresentationBytes

    await #expect(throws: HistoryFailure.invalidInput(.byteLimit)) {
        try await history.perform(.capture(Self.makeCapture([
            CapturedRepresentation(typeIdentifier: "public.data", bytes: Data(count: limit + 1)),
        ])))
    }
}

// MARK: - Representation count bound (06 §2: "Representations per capture/revision" — 32)

/// 06 §2 + 05 §6.1 step 1: the representation count bound is INCLUSIVE —
/// 32 distinct one-byte representations commit as `.inserted`; 33 throw
/// `.invalidInput(.representationLimit)` before any byte is fingerprinted.
@Test func thirtyTwoRepresentationsAdmittedThirtyThreeRejected() async throws {
    let history = try await Self.openMemoryHistory()
    let limit = HistoryLimits.standard.maximumRepresentationsPerCaptureOrRevision

    let receipt = try await history.perform(.capture(
        Self.makeCapture(Self.makeRepresentations(count: limit))
    ))
    guard case let .committed(commit) = receipt,
          case .inserted = commit.outcome
    else {
        Issue.record("boundary 32 reps: expected .committed(.inserted), got \(receipt)")
        return
    }
    #expect(commit.position.rawValue == 1)

    await #expect(throws: HistoryFailure.invalidInput(.representationLimit)) {
        try await history.perform(.capture(
            Self.makeCapture(Self.makeRepresentations(count: limit + 1))
        ))
    }
}

// MARK: - Capture total bound (06 §2: "Total bytes in one capture" — 128 MiB)

/// 06 §2 + 05 §6.1 step 1: the capture-total bound is enforced with checked
/// running-total arithmetic — three individually-legal representations
/// (64 MiB + 64 MiB + 1 byte = 128 MiB + 1) throw
/// `.invalidInput(.byteLimit)`. The ≈ 128 MiB payload is scoped to this one
/// call and released at its return.
@Test func captureTotalOneByteOver128MiBIsRejected() async throws {
    let history = try await Self.openMemoryHistory()
    let representationLimit = HistoryLimits.standard.maximumRepresentationBytes
    let captureLimit = HistoryLimits.standard.maximumCaptureBytes

    // Guard the fixture arithmetic against a §2 table edit: the test only
    // proves what it claims while 2 × 64 MiB + 1 exceeds the capture bound.
    try #require(2 * representationLimit + 1 > captureLimit)

    await #expect(throws: HistoryFailure.invalidInput(.byteLimit)) {
        try await history.perform(.capture(Self.makeCapture([
            CapturedRepresentation(
                typeIdentifier: "com.example.boundary.total-a",
                bytes: Data(count: representationLimit)
            ),
            CapturedRepresentation(
                typeIdentifier: "com.example.boundary.total-b",
                bytes: Data(count: representationLimit)
            ),
            CapturedRepresentation(
                typeIdentifier: "com.example.boundary.total-c",
                bytes: Data([0x00])
            ),
        ])))
    }
}
}
