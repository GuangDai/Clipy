/// A public-API-only restart tracer for Review Evidence Card 1C-1, the bounded
/// X-HCR post-success crash fixture, and the REVIEW §4.3 Retention-config
/// restart tail. Its separate Card 11C phase is a store-free Foundation regexp
/// engine child used only for process-bounded characterization. Every storage
/// invocation owns one `SwiftDataHistory` for one short process; no SwiftData
/// object or generated identity crosses a phase boundary.
/// The Retention phases prove exact configured-value persistence across
/// terminated owners only; they do not prove migration or crash durability
/// (`11-ai-todo-map-2026-08-23.md` §4.3; `V2-02-retention.md` §8.1/§12).
/// The full-disk cells (pressureCapture plus the Card 6B pressureRevise
/// trio and the openFullVolume/openSeededFullVolume pair) run only on the
/// dispatch-only APFS ENOSPC lane (`docs/05-authority-kernel.md` §16): a
/// filled volume must refuse a positive-demand capture and an 8 MiB
/// `.replace` revision through the stamped-plan admission —
/// `.temporarilyUnavailable(.insufficientDiskSpace)` with every seed byte
/// unchanged — must then commit the identical revision once space returns,
/// and must prove that commit from a fresh owner. Open on a full volume
/// writes only SQLite/WAL scalar files that never pass admission, so the
/// open cells record the observed branch of a closed typed-or-opened
/// disjunction instead of a single outcome. Nowhere proven here:
/// post-admission mid-transaction exhaustion (the Apple framework crash
/// ceiling), remove/clear full-disk tails (zero-demand plans are never
/// admission-refused), and V1→V2 migration on a full volume (no public
/// API path mints a V1 store).
/// The validateSeed/validateAll pair closes doc 11 §4.3's "External-clone
/// 验证子进程" row and the 05 blind spot
/// (`05-evidence-and-open-questions.md`:165, "未证明逐个 hydrate 所有
/// external-backed canonical/revision payload"): a terminated seed child
/// commits the fixed six-fixture table, then a fresh validator child
/// hydrates every canonical, effective, and revision payload through the
/// public browse/details/pastePayload reads and compares full bytes —
/// never digests — with the deterministic fixtures. As with largeBlob, the
/// schema's `@Attribute(.externalStorage)` is only an opaque placement
/// hint (Apple documents that a value *may* be externalized, with no
/// threshold or locator contract), so this evidence asserts neither an
/// external file nor any sidecar on disk.
/// The largeBlobMidTransactionKill*/largeBlobMidTransactionVerify trio
/// closes 05-OQ9/05-CE26 (Card 1C-2): the two kill children terminate
/// strictly INSIDE the in-flight capture commit transaction — window A in
/// the transaction closure after staging (deterministic complete-OLD),
/// window B anchored at the save interval's start via `ModelContext.willSave`
/// (old-or-new binary) — and the fresh verify child accepts only a complete
/// old or complete new state, then proves the reopened store still writes
/// (DATA-13). Process-kill evidence only, with largeBlobCrashCommit's same
/// ceiling: no fsync, sudden-power-loss, or sidecar-layout claim.
/// The leaseHold/openRejectLeasedStore pair closes DATA-7a's cross-process
/// single-writer lease (REVIEW 01-findings.md DATA-7; PLAY-DISK-0B): a live
/// owner child parked on stdin holds the StoreRoot lease, a second process's
/// open of the same root must fail `.persistence(.storeAlreadyOpen)` before
/// any `ModelContainer` exists, and after the owner's clean exit a fresh
/// child reacquires.
import Foundation
import HistoryCore
import HistoryStorage

private enum ProbePhase: String {
    case seed
    case operate
    case crashCommit
    case verify
    case pressureCapture
    case verifySeed
    case openFullVolume
    case openSeededFullVolume
    case pressureRevise
    case pressureReviseCommit
    case pressureReviseVerify
    case retentionSeed
    case retentionVerify
    case retentionUpdate
    case retentionVerifyUpdated
    case retentionRejectMalformed
    case retentionRejectWrongKey
    case openRejectFutureSchema
    case openRejectCorruptBytes
    case openRejectReadOnlyDirectory
    case openRejectLeasedStore
    case leaseHold
    case gatewayAuditSeed
    case gatewayAuditCrash
    case gatewayAuditVerify
    case largeBlobCrashCommit
    case largeBlobVerify
    case largeBlobMidTransactionKillClosure
    case largeBlobMidTransactionKillSave
    case largeBlobMidTransactionVerify
    case validateSeed
    case validateAll
    case regexpCharacterize
}

private enum ProbeFailure: Error {
    case unexpectedState
}

private let textType = "public.utf8-plain-text"
private let alphaText = "restart alpha"
private let bravoText = "restart bravo"
private let alphaFirstDate = Date(timeIntervalSinceReferenceDate: 10_000)
private let bravoDate = Date(timeIntervalSinceReferenceDate: 20_000)
private let alphaSecondDate = Date(timeIntervalSinceReferenceDate: 30_000)
private let alphaFirstSource = "restart.seed.alpha"
private let bravoSource = "restart.seed.bravo"
private let alphaSecondSource = "restart.operate.alpha"
private let pressureCaptureDate = Date(timeIntervalSinceReferenceDate: 40_000)
private let pressureCaptureSource = "restart.pressure.capture"
private let pressureCaptureByteCount = 8 * 1_048_576
private let pressureReviseDate = Date(timeIntervalSinceReferenceDate: 130_000)
private let pressureReviseSource = "restart.pressure.revise"
private let gatewayAuditText = "gateway audit crash publication fixture"
private let gatewayAuditDate = Date(timeIntervalSinceReferenceDate: 50_000)
private let gatewayAuditSource = "restart.gateway.audit"
private let largeBlobType = "public.data"
private let largeBlobDate = Date(timeIntervalSinceReferenceDate: 60_000)
private let largeBlobSource = "restart.large-blob.capture"
private let largeBlobByteCount = 8 * 1_048_576
private let midTransactionWritabilityText = "restart mid-transaction writability capture"
private let midTransactionWritabilityDate = Date(timeIntervalSinceReferenceDate: 130_000)
private let midTransactionWritabilitySource = "restart.mid-transaction.writability"
private let validationManifestFileName = "validation-manifest.txt"
private let validationFixtureCount = 6
private let validationRevisedFixtureIndex = 4
private let validationPNGType = "public.png"
private let validationPNGByteCount = 70
/// A real minimal 1×1 8-bit grayscale PNG as one fixed 140-character
/// lowercase-hex literal, kept verbatim from the reviewed design: PNG
/// signature, IHDR (width 1, height 1, bit depth 8, color type 0), one
/// stored zlib block covering the single filtered gray pixel, and IEND —
/// exactly 70 bytes (`validationPNGByteCount` pins the decoded length).
private let validationPNGHex = "89504e470d0a1a0a0000000d49484452000000010000000108000000003a7e9b550000000d494441547801010200fdff008000820081c36e25e00000000049454e44ae426082"
private let validationAlphaText = "validation alpha text"
private let validationBravoText = "validation bravo 文字📋"
private let validationDeltaText = "validation delta text"
private let validationFoxtrotText = "validation foxtrot text"
private let validationAlphaSource = "restart.validate.alpha"
private let validationBravoSource = "restart.validate.bravo"
private let validationPNGSource = "restart.validate.png"
private let validationDeltaSource = "restart.validate.delta"
private let validationBlobSource = "restart.validate.data"
private let validationFoxtrotSource = "restart.validate.foxtrot"
private let validationAlphaDate = Date(timeIntervalSinceReferenceDate: 70_000)
private let validationBravoDate = Date(timeIntervalSinceReferenceDate: 80_000)
private let validationPNGDate = Date(timeIntervalSinceReferenceDate: 90_000)
private let validationDeltaDate = Date(timeIntervalSinceReferenceDate: 100_000)
private let validationBlobDate = Date(timeIntervalSinceReferenceDate: 110_000)
private let validationFoxtrotDate = Date(timeIntervalSinceReferenceDate: 120_000)
private let regexpCharacterizationInput = String(repeating: "a", count: 1_000)
private let initialMaximumUnpinnedItems = 73
private let initialRetentionPolicies = HistoryRetentionPolicies(
    age: AgeRetention(maxAge: 7 * 86_400),
    storage: StorageRetention(maxTotalBytes: 128 * 1_048_576),
    revisions: RevisionRetention(
        maxRevisionsPerItem: 7,
        maxRevisionBytesPerItem: 32 * 1_048_576
    )
)
private let updatedMaximumUnpinnedItems = 91
private let updatedRetentionPolicies = HistoryRetentionPolicies(
    age: nil,
    storage: StorageRetention(maxTotalBytes: 96 * 1_048_576),
    revisions: RevisionRetention(
        maxRevisionsPerItem: nil,
        maxRevisionBytesPerItem: 24 * 1_048_576
    )
)
private let manifestFileName = "restart-manifest.txt"
private let largeBlobManifestFileName = "large-blob-manifest.txt"
private let diagnosticsEnabled = ProcessInfo.processInfo.environment[
    "CLIPY_APFS_PROBE_DIAGNOSTICS"
] == "1"
private let runtimeErrorDiagnosticsEnabled = diagnosticsEnabled
    && ProcessInfo.processInfo.environment["CLIPY_RUNTIME_DIAGNOSTICS"] == "1"

/// Probe-only, opt-in diagnostics for the physical APFS evidence workflow.
/// Fixed stage messages remain content-free. When the evidence-only runtime
/// diagnostic switch is also enabled, failures retain bounded NSError paths,
/// descriptions, and userInfo needed to debug the runner. `Data` values report
/// only their byte count. `HistoryRestartProbe` has no package product and the
/// app never executes it.
private func diagnostic(_ event: String) {
    guard diagnosticsEnabled else {
        return
    }
    FileHandle.standardError.write(Data("CLIPY_PROBE event=\(event)\n".utf8))
}

private func diagnostic(error: any Error) {
    if let failure = error as? HistoryFailure {
        let kind: String
        if failure == .temporarilyUnavailable(.insufficientDiskSpace) {
            kind = "history-insufficient-disk-space"
        } else if failure == .persistence(.transaction) {
            kind = "history-transaction"
        } else {
            kind = "history-other"
        }
        diagnostic("failure kind=\(kind)")
    }

    guard runtimeErrorDiagnosticsEnabled else {
        return
    }
    for line in probeErrorDiagnosticLines(for: error) {
        diagnostic(line)
    }
}

#if DEBUG || CLIPY_RUNTIME_DIAGNOSTICS
private func probeErrorDiagnosticLines(for error: any Error) -> [String] {
    let errorDepthLimit = 8
    let userInfoEntryLimit = 64
    var candidates: [String] = []
    var seenErrors: Set<ObjectIdentifier> = []
    var swiftError: any Error = error
    var platformError = error as NSError
    var chainWasTruncated = false

    for depth in 0..<errorDepthLimit {
        let edge = depth == 0 ? "root" : "underlying"
        guard seenErrors.insert(ObjectIdentifier(platformError)).inserted else {
            candidates.append(
                "platform-error depth=\(depth) edge=\(edge) cycle=true "
                    + "swift_type=\(probeQuoted(probeReflectedType(of: swiftError)))"
            )
            break
        }
        candidates.append(
            "platform-error depth=\(depth) edge=\(edge) "
                + "swift_type=\(probeQuoted(probeReflectedType(of: swiftError))) "
                + "domain=\(probeQuoted(platformError.domain)) "
                + "code=\(platformError.code) "
                + "localized_description=\(probeQuoted(platformError.localizedDescription)) "
                + "user_info_count=\(platformError.userInfo.count)"
        )

        let keys = platformError.userInfo.keys.sorted()
        for (index, key) in keys.prefix(userInfoEntryLimit).enumerated() {
            guard let value = platformError.userInfo[key] else {
                continue
            }
            var visitedContainers: Set<ObjectIdentifier> = []
            let renderedValue = probeValueDescription(
                value,
                depth: 0,
                visitedContainers: &visitedContainers
            )
            candidates.append(
                "platform-error-user-info depth=\(depth) index=\(index) "
                    + "key=\(probeQuoted(key)) "
                    + "value_type=\(probeQuoted(probeReflectedType(of: value))) "
                    + "value=\(probeQuoted(renderedValue))"
            )
        }
        if keys.count > userInfoEntryLimit {
            candidates.append(
                "platform-error-user-info depth=\(depth) "
                    + "truncated_entries=\(keys.count - userInfoEntryLimit) "
                    + "entry_limit=\(userInfoEntryLimit)"
            )
        }

        guard let underlying = platformError.userInfo[
            NSUnderlyingErrorKey
        ] as? NSError else {
            break
        }
        if depth == errorDepthLimit - 1 {
            chainWasTruncated = true
        }
        swiftError = underlying
        platformError = underlying
    }
    if chainWasTruncated {
        candidates.append(
            "platform-error truncated_error_chain=true depth_limit=\(errorDepthLimit)"
        )
    }
    return boundedProbeErrorLines(candidates)
}

private func probeReflectedType(of value: Any) -> String {
    String(reflecting: Swift.type(of: value))
}

private func probeQuoted(_ value: String) -> String {
    "\"\(boundedProbeText(escapedProbeText(value), utf8Limit: 1_024))\""
}

private func escapedProbeText(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x09:
            result += "\\t"
        case 0x0A:
            result += "\\n"
        case 0x0D:
            result += "\\r"
        case 0x22:
            result += "\\\""
        case 0x5C:
            result += "\\\\"
        case 0x00...0x1F, 0x7F:
            result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}

private func probeValueDescription(
    _ value: Any,
    depth: Int,
    visitedContainers: inout Set<ObjectIdentifier>
) -> String {
    let valueDepthLimit = 6
    let collectionEntryLimit = 16
    guard depth < valueDepthLimit else {
        return "<value-depth-limit type=\(probeReflectedType(of: value))>"
    }
    if let data = value as? Data {
        return "Data(byte_count=\(data.count))"
    }
    if let string = value as? String {
        return string
    }
    if let url = value as? URL {
        return url.absoluteString
    }
    if let error = value as? NSError {
        return "NSError(type=\(probeReflectedType(of: error)), "
            + "domain=\(error.domain), code=\(error.code), "
            + "localized_description=\(error.localizedDescription))"
    }
    if value is NSNull {
        return "null"
    }
    if let dictionary = value as? NSDictionary {
        let identity = ObjectIdentifier(dictionary)
        guard visitedContainers.insert(identity).inserted else {
            return "<cycle type=\(probeReflectedType(of: value))>"
        }
        defer { visitedContainers.remove(identity) }
        var entries: [(key: String, value: Any)] = []
        for key in dictionary.allKeys {
            entries.append((
                key: String(describing: key),
                value: dictionary.object(forKey: key) ?? NSNull()
            ))
        }
        entries.sort { $0.key < $1.key }
        let rendered = entries.prefix(collectionEntryLimit).map { entry in
            "\(entry.key): " + probeValueDescription(
                entry.value,
                depth: depth + 1,
                visitedContainers: &visitedContainers
            )
        }
        let omitted = entries.count - rendered.count
        let suffix = omitted > 0 ? ", <truncated_entries=\(omitted)>" : ""
        return "Dictionary(count=\(entries.count)){\(rendered.joined(separator: ", "))\(suffix)}"
    }
    if let array = value as? NSArray {
        let identity = ObjectIdentifier(array)
        guard visitedContainers.insert(identity).inserted else {
            return "<cycle type=\(probeReflectedType(of: value))>"
        }
        defer { visitedContainers.remove(identity) }
        let retainedCount = min(array.count, collectionEntryLimit)
        var rendered: [String] = []
        for index in 0..<retainedCount {
            rendered.append(probeValueDescription(
                array[index],
                depth: depth + 1,
                visitedContainers: &visitedContainers
            ))
        }
        let omitted = array.count - rendered.count
        let suffix = omitted > 0 ? ", <truncated_entries=\(omitted)>" : ""
        return "Array(count=\(array.count))[\(rendered.joined(separator: ", "))\(suffix)]"
    }
    return String(describing: value)
}

private func boundedProbeText(_ value: String, utf8Limit: Int) -> String {
    guard value.utf8.count > utf8Limit else {
        return value
    }
    let suffix = "…<truncated utf8_bytes=\(value.utf8.count)>"
    let prefixLimit = max(0, utf8Limit - suffix.utf8.count)
    var prefix = ""
    var prefixByteCount = 0
    for scalar in value.unicodeScalars {
        let scalarByteCount = String(scalar).utf8.count
        guard prefixByteCount + scalarByteCount <= prefixLimit else {
            break
        }
        prefix.unicodeScalars.append(scalar)
        prefixByteCount += scalarByteCount
    }
    return prefix + suffix
}

private func boundedProbeErrorLines(_ candidates: [String]) -> [String] {
    let lineLimit = 128
    let totalUTF8Limit = 60_000
    let truncationLine = "platform-error diagnostics_truncated=true"
    var lines: [String] = []
    var totalByteCount = 0
    for candidate in candidates {
        let line = boundedProbeText(candidate, utf8Limit: 4_096)
        let separatorByteCount = lines.isEmpty ? 0 : 1
        guard lines.count < lineLimit,
              totalByteCount + separatorByteCount + line.utf8.count
                <= totalUTF8Limit else {
            if lines.count == lineLimit {
                let removed = lines.removeLast()
                totalByteCount -= removed.utf8.count
                if !lines.isEmpty {
                    totalByteCount -= 1
                }
            }
            while !lines.isEmpty,
                  totalByteCount + (lines.isEmpty ? 0 : 1) + truncationLine.utf8.count
                    > totalUTF8Limit {
                let removed = lines.removeLast()
                totalByteCount -= removed.utf8.count
                if !lines.isEmpty {
                    totalByteCount -= 1
                }
            }
            lines.append(truncationLine)
            break
        }
        lines.append(line)
        totalByteCount += separatorByteCount + line.utf8.count
    }
    return lines
}
#else
private func probeErrorDiagnosticLines(for _: any Error) -> [String] { [] }
#endif

private struct ProbeManifest {
    let alpha: UUID
    let bravo: UUID

    static func read(siblingOf storeURL: URL) throws -> Self {
        let data = try Data(contentsOf: manifestURL(siblingOf: storeURL))
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProbeFailure.unexpectedState
        }
        let lines = text.split(separator: "\n")
        guard lines.count == 2,
              lines[0].hasPrefix("alpha="),
              lines[1].hasPrefix("bravo="),
              let alpha = UUID(uuidString: String(lines[0].dropFirst(6))),
              let bravo = UUID(uuidString: String(lines[1].dropFirst(6))),
              alpha != bravo else {
            throw ProbeFailure.unexpectedState
        }
        return Self(alpha: alpha, bravo: bravo)
    }

    func write(siblingOf storeURL: URL) throws {
        let text = "alpha=\(alpha.uuidString)\nbravo=\(bravo.uuidString)\n"
        try Data(text.utf8).write(to: manifestURL(siblingOf: storeURL))
    }
}

private struct LargeBlobManifest {
    let itemID: UUID

    static func read(siblingOf storeURL: URL) throws -> Self {
        let data = try Data(contentsOf: Self.manifestURL(siblingOf: storeURL))
        guard let text = String(data: data, encoding: .utf8),
              text.last == "\n",
              text.dropLast().hasPrefix("item="),
              let itemID = UUID(
                uuidString: String(text.dropLast().dropFirst(5))
              ) else {
            throw ProbeFailure.unexpectedState
        }
        return Self(itemID: itemID)
    }

    func write(siblingOf storeURL: URL) throws {
        try Data("item=\(itemID.uuidString)\n".utf8).write(
            to: Self.manifestURL(siblingOf: storeURL)
        )
    }

    private static func manifestURL(siblingOf storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appendingPathComponent(largeBlobManifestFileName)
    }
}

/// Cross-process identity manifest for the external-clone validation pair:
/// the seed child's six inserted item IDs (seed order) plus the revised
/// item's ID. Strictly line-parsed like `LargeBlobManifest`; only public
/// item identity crosses the process boundary — never content, byte
/// counts, or digests — so the validator's byte comparisons stay fully
/// independent of what the seed child wrote.
private struct ValidationManifest {
    let itemIDs: [UUID]
    let revisedItemID: UUID

    static func read(siblingOf storeURL: URL) throws -> Self {
        let data = try Data(contentsOf: Self.manifestURL(siblingOf: storeURL))
        guard let text = String(data: data, encoding: .utf8),
              text.last == "\n" else {
            throw ProbeFailure.unexpectedState
        }
        let lines = text.dropLast()
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == validationFixtureCount + 2,
              lines[0] == "count=\(validationFixtureCount)" else {
            throw ProbeFailure.unexpectedState
        }
        var itemIDs: [UUID] = []
        for line in lines[1...validationFixtureCount] {
            guard line.hasPrefix("item=") else {
                throw ProbeFailure.unexpectedState
            }
            itemIDs.append(try validationUUID(String(line.dropFirst(5))))
        }
        guard Set(itemIDs).count == validationFixtureCount,
              lines[validationFixtureCount + 1].hasPrefix("revised=") else {
            throw ProbeFailure.unexpectedState
        }
        let revisedItemID = try validationUUID(
            String(lines[validationFixtureCount + 1].dropFirst(8))
        )
        guard revisedItemID == itemIDs[validationRevisedFixtureIndex] else {
            throw ProbeFailure.unexpectedState
        }
        return Self(itemIDs: itemIDs, revisedItemID: revisedItemID)
    }

    func write(siblingOf storeURL: URL) throws {
        var text = "count=\(itemIDs.count)\n"
        for itemID in itemIDs {
            text += "item=\(itemID.uuidString)\n"
        }
        text += "revised=\(revisedItemID.uuidString)\n"
        try Data(text.utf8).write(
            to: Self.manifestURL(siblingOf: storeURL)
        )
    }

    private static func manifestURL(siblingOf storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appendingPathComponent(validationManifestFileName)
    }
}

/// Parses one manifest UUID in canonical uppercase form, mirroring the
/// strictness of `HistoryItemID(uuidString:)`.
private func validationUUID(_ payload: String) throws -> UUID {
    guard let id = UUID(uuidString: payload),
          id.uuidString == payload else {
        throw ProbeFailure.unexpectedState
    }
    return id
}

private func manifestURL(siblingOf storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent()
        .appendingPathComponent(manifestFileName)
}

private func capture(
    _ text: String,
    at date: Date,
    source: String
) -> ClipboardCapture {
    ClipboardCapture(
        representations: [CapturedRepresentation(
            typeIdentifier: textType,
            bytes: Data(text.utf8)
        )],
        origin: CopyOriginObservation(
            sourceApplication: source,
            lineageHint: nil
        ),
        observedAt: date
    )
}

private func largeBlobBytes() -> Data {
    let pattern = Data((0..<4_096).map { index in
        UInt8(truncatingIfNeeded: index &* 31 &+ 17)
    })
    var bytes = Data(capacity: largeBlobByteCount)
    for _ in 0..<(largeBlobByteCount / pattern.count) {
        bytes.append(pattern)
    }
    return bytes
}

private func largeBlobCapture() -> ClipboardCapture {
    ClipboardCapture(
        representations: [CapturedRepresentation(
            typeIdentifier: largeBlobType,
            bytes: largeBlobBytes()
        )],
        origin: CopyOriginObservation(
            sourceApplication: largeBlobSource,
            lineageHint: nil
        ),
        observedAt: largeBlobDate
    )
}

/// This lane's dedicated 8 MiB patternA blob capture (`largeBlobBytes`):
/// byte-distinct from the patternB revision payload, with its own
/// observedAt/source so row order and occurrence facts stay determined.
private func pressureReviseCapture() -> ClipboardCapture {
    ClipboardCapture(
        representations: [CapturedRepresentation(
            typeIdentifier: largeBlobType,
            bytes: largeBlobBytes()
        )],
        origin: CopyOriginObservation(
            sourceApplication: pressureReviseSource,
            lineageHint: nil
        ),
        observedAt: pressureReviseDate
    )
}

/// The revise cell's single request, replayed byte-identically by the commit
/// half: `.replace` the 8 MiB patternA blob with the byte-distinct 8 MiB
/// patternB (`validationRevisedBlobBytes`). The §16 stamped-plan admission
/// counts the revision's wire bytes (≈ 4/3 × the raw payload) against the
/// store volume's spare capacity, so this ~11 MiB positive demand
/// deterministically exceeds the post-fill slack plus the 1 MiB margin —
/// the reason the cell revises a blob instead of a small text payload.
private func pressureReviseRequest(
    itemID: HistoryItemID,
    expected: ContentVersion
) -> HistoryAction {
    .revise(RevisionRequest(
        itemID: itemID,
        expected: expected,
        intent: .replace(RevisionDraft(decisions: [RevisionDecision(
            typeIdentifier: largeBlobType,
            action: .replace(bytes: validationRevisedBlobBytes())
        )]))
    ))
}

/// Expected bytes for one projection slot of the validation table.
/// `HistoryRepresentation`'s initializer is package-only, so the probe
/// compares field-by-field (`map(\.typeIdentifier)` / `map(\.bytes)`)
/// instead of constructing the public DTO — the same stance as
/// `largeBlobVerify`.
private struct ValidationRepresentation {
    let typeIdentifier: String
    let bytes: Data

    init(typeIdentifier: String, bytes: Data) {
        self.typeIdentifier = typeIdentifier
        self.bytes = bytes
    }
}

/// One fixed row of the external-clone validation table: the capture the
/// seed child commits, plus every public-projection expectation a fresh
/// validator owner must reproduce byte exactly.
private struct ValidationFixture {
    let capture: ClipboardCapture
    let title: String
    let canonical: [ValidationRepresentation]
    let effective: [ValidationRepresentation]
    let expectedContentVersion: UInt64
    let expectedRevisionCount: Int
    let expectedRevisionByteCount: Int?
}

/// Decodes one reviewed lowercase-hex literal, failing closed on an odd
/// length, a non-hex pair, or a byte count that misses the fixture
/// contract. The probe never hashes; expected bytes are compared directly.
private func validationHexBytes(
    _ hex: String,
    expectedByteCount: Int
) throws -> Data {
    var bytes = Data()
    bytes.reserveCapacity(hex.count / 2)
    var start = hex.startIndex
    while start < hex.endIndex {
        let end = hex.index(after: start)
        guard end < hex.endIndex,
              let byte = UInt8(hex[start...end], radix: 16) else {
            throw ProbeFailure.unexpectedState
        }
        bytes.append(byte)
        start = hex.index(after: end)
    }
    guard bytes.count == expectedByteCount else {
        throw ProbeFailure.unexpectedState
    }
    return bytes
}

/// patternB for fixture 4's `.replace` revision: byte i is
/// `UInt8(truncatingIfNeeded: i &* 59 &+ 23)`. Repeating a 4_096-byte
/// pattern is byte-identical to the per-index formula because
/// 59 &* 4_096 ≡ 0 (mod 256). It differs from `largeBlobBytes()`'s
/// patternA at EVERY index: 31·i + 17 ≡ 59·i + 23 (mod 256) would require
/// 28·i ≡ 250 (mod 256), which has no solution since gcd(28, 256) = 4 does
/// not divide 250 — so the canonical-versus-effective comparison is a
/// per-byte distinction, not same-bytes aliasing.
private func validationRevisedBlobBytes() -> Data {
    let pattern = Data((0..<4_096).map { index in
        UInt8(truncatingIfNeeded: index &* 59 &+ 23)
    })
    var bytes = Data(capacity: largeBlobByteCount)
    for _ in 0..<(largeBlobByteCount / pattern.count) {
        bytes.append(pattern)
    }
    return bytes
}

private func validationCapture(
    _ representations: [CapturedRepresentation],
    at date: Date,
    source: String
) -> ClipboardCapture {
    ClipboardCapture(
        representations: representations,
        origin: CopyOriginObservation(
            sourceApplication: source,
            lineageHint: nil
        ),
        observedAt: date
    )
}

/// The fixed external-clone validation fixture table. Every value is a
/// reviewed literal (plus the two deterministic 8 MiB pattern builders);
/// content differs across all six entries so ingest can never coalesce
/// them, and every observedAt/source is distinct so row order and
/// occurrence facts stay fully determined.
private func validationFixtureTable() throws -> [ValidationFixture] {
    let pngBytes = try validationHexBytes(
        validationPNGHex,
        expectedByteCount: validationPNGByteCount
    )
    let alphaTextBytes = Data(validationAlphaText.utf8)
    let bravoTextBytes = Data(validationBravoText.utf8)
    let deltaTextBytes = Data(validationDeltaText.utf8)
    let foxtrotTextBytes = Data(validationFoxtrotText.utf8)
    let canonicalBlobBytes = largeBlobBytes()
    let revisedBlobBytes = validationRevisedBlobBytes()
    return [
        // 0 — one plain-text representation.
        ValidationFixture(
            capture: validationCapture(
                [CapturedRepresentation(
                    typeIdentifier: textType,
                    bytes: alphaTextBytes
                )],
                at: validationAlphaDate,
                source: validationAlphaSource
            ),
            title: validationAlphaText,
            canonical: [ValidationRepresentation(
                typeIdentifier: textType,
                bytes: alphaTextBytes
            )],
            effective: [ValidationRepresentation(
                typeIdentifier: textType,
                bytes: alphaTextBytes
            )],
            expectedContentVersion: 1,
            expectedRevisionCount: 0,
            expectedRevisionByteCount: nil
        ),
        // 1 — non-ASCII text; identical shape, distinct bytes and title.
        ValidationFixture(
            capture: validationCapture(
                [CapturedRepresentation(
                    typeIdentifier: textType,
                    bytes: bravoTextBytes
                )],
                at: validationBravoDate,
                source: validationBravoSource
            ),
            title: validationBravoText,
            canonical: [ValidationRepresentation(
                typeIdentifier: textType,
                bytes: bravoTextBytes
            )],
            effective: [ValidationRepresentation(
                typeIdentifier: textType,
                bytes: bravoTextBytes
            )],
            expectedContentVersion: 1,
            expectedRevisionCount: 0,
            expectedRevisionByteCount: nil
        ),
        // 2 — a real 1×1 grayscale PNG; no textual representation, so the
        // row title is the frozen type-based fallback "Image".
        ValidationFixture(
            capture: validationCapture(
                [CapturedRepresentation(
                    typeIdentifier: validationPNGType,
                    bytes: pngBytes
                )],
                at: validationPNGDate,
                source: validationPNGSource
            ),
            title: "Image",
            canonical: [ValidationRepresentation(
                typeIdentifier: validationPNGType,
                bytes: pngBytes
            )],
            effective: [ValidationRepresentation(
                typeIdentifier: validationPNGType,
                bytes: pngBytes
            )],
            expectedContentVersion: 1,
            expectedRevisionCount: 0,
            expectedRevisionByteCount: nil
        ),
        // 3 — one capture carrying two representations: the same PNG plus
        // text. Canonical/effective order follows the stable Unicode
        // scalar sort (docs/02-domain.md §2.1) — "public.png" sorts before
        // "public.utf8-plain-text" — even though the capture input listed
        // the text first; the textual representation still owns the title.
        ValidationFixture(
            capture: validationCapture(
                [
                    CapturedRepresentation(
                        typeIdentifier: textType,
                        bytes: deltaTextBytes
                    ),
                    CapturedRepresentation(
                        typeIdentifier: validationPNGType,
                        bytes: pngBytes
                    ),
                ],
                at: validationDeltaDate,
                source: validationDeltaSource
            ),
            title: validationDeltaText,
            canonical: [
                ValidationRepresentation(
                    typeIdentifier: validationPNGType,
                    bytes: pngBytes
                ),
                ValidationRepresentation(
                    typeIdentifier: textType,
                    bytes: deltaTextBytes
                ),
            ],
            effective: [
                ValidationRepresentation(
                    typeIdentifier: validationPNGType,
                    bytes: pngBytes
                ),
                ValidationRepresentation(
                    typeIdentifier: textType,
                    bytes: deltaTextBytes
                ),
            ],
            expectedContentVersion: 1,
            expectedRevisionCount: 0,
            expectedRevisionByteCount: nil
        ),
        // 4 — the 8 MiB patternA blob (same generator as the largeBlob
        // phases); validateSeed then revises it to the byte-distinct 8 MiB
        // patternB. Canonical keeps patternA, effective becomes patternB,
        // the content version is 2, and exactly one active 8 MiB revision
        // exists. No textual representation, so the fallback title is the
        // sole type identifier itself.
        ValidationFixture(
            capture: validationCapture(
                [CapturedRepresentation(
                    typeIdentifier: largeBlobType,
                    bytes: canonicalBlobBytes
                )],
                at: validationBlobDate,
                source: validationBlobSource
            ),
            title: largeBlobType,
            canonical: [ValidationRepresentation(
                typeIdentifier: largeBlobType,
                bytes: canonicalBlobBytes
            )],
            effective: [ValidationRepresentation(
                typeIdentifier: largeBlobType,
                bytes: revisedBlobBytes
            )],
            expectedContentVersion: 2,
            expectedRevisionCount: 1,
            expectedRevisionByteCount: largeBlobByteCount
        ),
        // 5 — plain text again, newest observedAt, so recent-browse lists
        // it first.
        ValidationFixture(
            capture: validationCapture(
                [CapturedRepresentation(
                    typeIdentifier: textType,
                    bytes: foxtrotTextBytes
                )],
                at: validationFoxtrotDate,
                source: validationFoxtrotSource
            ),
            title: validationFoxtrotText,
            canonical: [ValidationRepresentation(
                typeIdentifier: textType,
                bytes: foxtrotTextBytes
            )],
            effective: [ValidationRepresentation(
                typeIdentifier: textType,
                bytes: foxtrotTextBytes
            )],
            expectedContentVersion: 1,
            expectedRevisionCount: 0,
            expectedRevisionByteCount: nil
        ),
    ]
}

private func openHistory(at storeURL: URL) async throws -> SwiftDataHistory {
    try await SwiftDataHistory.open(configuration: HistoryConfiguration(
        persistence: .persistent(storeURL: storeURL),
        initialMaximumUnpinnedItems: 200
    ))
}

private func requireEmptyHistory(
    _ history: SwiftDataHistory,
    position: UInt64
) async throws {
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .recent,
        limit: 1
    ))
    guard page.position.rawValue == position,
          page.rows.isEmpty,
          page.next == nil else {
        throw ProbeFailure.unexpectedState
    }
}

private func requireRetentionConfigurationAndEmptyHistoryPosition(
    _ history: SwiftDataHistory,
    maximumUnpinnedItems: Int,
    policies: HistoryRetentionPolicies,
    position: UInt64
) async throws {
    let configuration = try await history.retentionConfiguration()
    guard configuration.maximumUnpinnedItems == maximumUnpinnedItems,
          configuration.policies == policies else {
        throw ProbeFailure.unexpectedState
    }
    try await requireEmptyHistory(history, position: position)
}

private func setRetentionConfiguration(
    _ history: SwiftDataHistory,
    maximumUnpinnedItems: Int,
    policies: HistoryRetentionPolicies,
    maximumUnpinnedItemsPosition: UInt64,
    policiesPosition: UInt64
) async throws {
    let countReceipt = try await history.perform(
        .setRetentionPolicy(maximumUnpinnedItems: maximumUnpinnedItems)
    )
    guard case .committed(let countCommit) = countReceipt,
          countCommit.position.rawValue == maximumUnpinnedItemsPosition,
          case .retentionPolicySet(removedCount: 0) = countCommit.outcome else {
        throw ProbeFailure.unexpectedState
    }

    let policiesReceipt = try await history.perform(
        .setRetentionPolicies(policies)
    )
    guard case .committed(let policiesCommit) = policiesReceipt,
          policiesCommit.position.rawValue == policiesPosition,
          case .retentionPoliciesSet(
              retiredItems: 0,
              prunedRevisions: 0
          ) = policiesCommit.outcome else {
        throw ProbeFailure.unexpectedState
    }
}

private func retentionSeed(storeURL: URL) async throws {
    let history = try await openHistory(at: storeURL)
    try await requireRetentionConfigurationAndEmptyHistoryPosition(
        history,
        maximumUnpinnedItems: 200,
        policies: HistoryRetentionPolicies(
            age: nil,
            storage: nil,
            revisions: nil
        ),
        position: 0
    )
    try await setRetentionConfiguration(
        history,
        maximumUnpinnedItems: initialMaximumUnpinnedItems,
        policies: initialRetentionPolicies,
        maximumUnpinnedItemsPosition: 1,
        policiesPosition: 2
    )
}

private func retentionVerify(storeURL: URL) async throws {
    let history = try await openHistory(at: storeURL)
    try await requireRetentionConfigurationAndEmptyHistoryPosition(
        history,
        maximumUnpinnedItems: initialMaximumUnpinnedItems,
        policies: initialRetentionPolicies,
        position: 2
    )
}

private func retentionUpdate(storeURL: URL) async throws {
    let history = try await openHistory(at: storeURL)
    try await requireRetentionConfigurationAndEmptyHistoryPosition(
        history,
        maximumUnpinnedItems: initialMaximumUnpinnedItems,
        policies: initialRetentionPolicies,
        position: 2
    )
    try await setRetentionConfiguration(
        history,
        maximumUnpinnedItems: updatedMaximumUnpinnedItems,
        policies: updatedRetentionPolicies,
        maximumUnpinnedItemsPosition: 3,
        policiesPosition: 4
    )
}

private func retentionVerifyUpdated(storeURL: URL) async throws {
    let history = try await openHistory(at: storeURL)
    try await requireRetentionConfigurationAndEmptyHistoryPosition(
        history,
        maximumUnpinnedItems: updatedMaximumUnpinnedItems,
        policies: updatedRetentionPolicies,
        position: 4
    )
}

/// REVIEW §4.3 Retention-config restart tail, extended to the DATA-14
/// open-failure fixtures (REVIEW 05 §7 Q13): the fixture process must
/// observe the production public-open classifier itself. Every
/// `ModelContainer` construction failure — an impossible stored shape, a
/// future schema, non-SQLite bytes, an existing read-only store
/// directory — currently surfaces as one
/// `.persistence(.openStore)` (03b §10); until a classification proof
/// exists, no caller may auto-quarantine or silently recreate a store on
/// that single outcome. The test owner creates the impossible on-disk shape
/// before launching this process; this executable neither imports SwiftData
/// nor repairs/inspects storage.
private func requirePublicOpenFailure(
    at storeURL: URL,
    expected: HistoryFailure
) async throws {
    do {
        _ = try await openHistory(at: storeURL)
    } catch let failure as HistoryFailure {
        guard failure == expected else {
            throw ProbeFailure.unexpectedState
        }
        return
    } catch {
        throw ProbeFailure.unexpectedState
    }
    throw ProbeFailure.unexpectedState
}

/// DATA-7a cross-process lease owner (REVIEW 01-findings.md DATA-7;
/// PLAY-DISK-0B): opens the store through the public facade — acquiring the
/// StoreRoot's single-writer lease — reports the held lease with one fixed
/// marker line, then parks until this process's stdin reaches EOF, the
/// parent's deterministic clean-release signal. Reused for both cells of the
/// lease proof: with the parent holding the write end open this child is the
/// live owner a second process must fail against; with a null stdin it is
/// the fresh reacquire child, returning immediately. The trailing read pins
/// the leased store's healthy empty projection at position 0 on both paths.
private func leaseHold(storeURL: URL) async throws {
    let history = try await openHistory(at: storeURL)
    FileHandle.standardOutput.write(Data("LEASEHOLD_READY\n".utf8))
    // The facade (and so the lease) is fenced across the park, mirroring
    // crashCommit's explicit lifetime discipline.
    withExtendedLifetime(history) {
        _ = FileHandle.standardInput.readDataToEndOfFile()
    }
    try await requireEmptyHistory(history, position: 0)
}

private func requireInserted(
    _ receipt: HistoryReceipt,
    position: UInt64
) throws -> HistoryItemReference {
    guard case .committed(let commit) = receipt,
          commit.position.rawValue == position,
          case .inserted(let reference) = commit.outcome,
          reference.contentVersion.rawValue == 1 else {
        throw ProbeFailure.unexpectedState
    }
    return reference
}

private func requireInitialProjection(
    _ history: SwiftDataHistory,
    manifest: ProbeManifest
) async throws {
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .recent,
        limit: 10
    ))
    guard page.position.rawValue == 2,
          page.next == nil,
          page.rows.count == 2,
          page.rows[0].item.id.rawValue == manifest.bravo,
          page.rows[0].title == bravoText,
          page.rows[0].typeIdentifiers == [textType],
          page.rows[0].lastCopiedAt == bravoDate,
          page.rows[0].copyCount == 1,
          page.rows[0].lastSource == bravoSource,
          page.rows[0].pinnedPosition == nil,
          page.rows[0].search == nil,
          page.rows[1].item.id.rawValue == manifest.alpha,
          page.rows[1].title == alphaText,
          page.rows[1].typeIdentifiers == [textType],
          page.rows[1].lastCopiedAt == alphaFirstDate,
          page.rows[1].copyCount == 1,
          page.rows[1].lastSource == alphaFirstSource,
          page.rows[1].pinnedPosition == nil,
          page.rows[1].search == nil else {
        throw ProbeFailure.unexpectedState
    }

    let bravo = try await history.details(for: page.rows[0].item.id)
    let alpha = try await history.details(for: page.rows[1].item.id)
    guard bravo.item.id.rawValue == manifest.bravo,
          bravo.item == page.rows[0].item,
          alpha.item.id.rawValue == manifest.alpha,
          alpha.item == page.rows[1].item else {
        throw ProbeFailure.unexpectedState
    }
}

private func requireSeedState(
    _ history: SwiftDataHistory,
    manifest: ProbeManifest
) async throws {
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .recent,
        limit: 10
    ))
    guard page.position.rawValue == 2,
          page.next == nil,
          page.rows.count == 2,
          page.rows[0].item.id.rawValue == manifest.bravo,
          page.rows[0].item.contentVersion.rawValue == 1,
          page.rows[0].title == bravoText,
          page.rows[0].typeIdentifiers == [textType],
          page.rows[0].lastCopiedAt == bravoDate,
          page.rows[0].copyCount == 1,
          page.rows[0].lastSource == bravoSource,
          page.rows[0].pinnedPosition == nil,
          page.rows[0].search == nil,
          page.rows[1].item.id.rawValue == manifest.alpha,
          page.rows[1].item.contentVersion.rawValue == 1,
          page.rows[1].title == alphaText,
          page.rows[1].typeIdentifiers == [textType],
          page.rows[1].lastCopiedAt == alphaFirstDate,
          page.rows[1].copyCount == 1,
          page.rows[1].lastSource == alphaFirstSource,
          page.rows[1].pinnedPosition == nil,
          page.rows[1].search == nil else {
        throw ProbeFailure.unexpectedState
    }

    let bravo = try await history.details(for: page.rows[0].item.id)
    guard bravo.item.id.rawValue == manifest.bravo,
          bravo.item == page.rows[0].item,
          bravo.canonical.map(\.typeIdentifier) == [textType],
          bravo.canonical.map(\.bytes) == [Data(bravoText.utf8)],
          bravo.effective == bravo.canonical,
          bravo.revisions.isEmpty,
          bravo.occurrence.firstCopiedAt == bravoDate,
          bravo.occurrence.lastCopiedAt == bravoDate,
          bravo.occurrence.count == 1,
          bravo.occurrence.firstSource == bravoSource,
          bravo.occurrence.lastSource == bravoSource,
          bravo.pinnedPosition == nil else {
        throw ProbeFailure.unexpectedState
    }

    let alpha = try await history.details(for: page.rows[1].item.id)
    guard alpha.item.id.rawValue == manifest.alpha,
          alpha.item == page.rows[1].item,
          alpha.canonical.map(\.typeIdentifier) == [textType],
          alpha.canonical.map(\.bytes) == [Data(alphaText.utf8)],
          alpha.effective == alpha.canonical,
          alpha.revisions.isEmpty,
          alpha.occurrence.firstCopiedAt == alphaFirstDate,
          alpha.occurrence.lastCopiedAt == alphaFirstDate,
          alpha.occurrence.count == 1,
          alpha.occurrence.firstSource == alphaFirstSource,
          alpha.occurrence.lastSource == alphaFirstSource,
          alpha.pinnedPosition == nil else {
        throw ProbeFailure.unexpectedState
    }
}

/// One alpha/bravo seed row of the full-disk revise cells — the exact
/// field-for-field facts `requireSeedState` pins, factored so the
/// position-3 and position-4 tables can assert the untouched seed rows
/// without re-stating the whole table shape.
private func requireSeedTextRow(
    _ row: HistoryRow,
    id: UUID,
    text: String,
    date: Date,
    source: String
) throws {
    guard row.item.id.rawValue == id,
          row.item.contentVersion.rawValue == 1,
          row.title == text,
          row.typeIdentifiers == [textType],
          row.lastCopiedAt == date,
          row.copyCount == 1,
          row.lastSource == source,
          row.pinnedPosition == nil,
          row.search == nil else {
        throw ProbeFailure.unexpectedState
    }
}

/// The matching alpha/bravo detail projection: hydrated canonical bytes
/// compared directly (`Data ==`, never a digest), effective identical to
/// canonical, no revisions, occurrence facts and pin state unchanged.
private func requireSeedTextDetails(
    _ details: HistoryDetails,
    row: HistoryRow,
    id: UUID,
    text: String,
    date: Date,
    source: String
) throws {
    guard details.item.id.rawValue == id,
          details.item == row.item,
          details.canonical.map(\.typeIdentifier) == [textType],
          details.canonical.map(\.bytes) == [Data(text.utf8)],
          details.effective == details.canonical,
          details.revisions.isEmpty,
          details.occurrence.firstCopiedAt == date,
          details.occurrence.lastCopiedAt == date,
          details.occurrence.count == 1,
          details.occurrence.firstSource == source,
          details.occurrence.lastSource == source,
          details.pinnedPosition == nil else {
        throw ProbeFailure.unexpectedState
    }
}

/// Position-3 seed table of the full-disk revise cell: the seed's
/// alpha/bravo rows plus this lane's dedicated 8 MiB patternA blob row,
/// asserted byte-for-byte unchanged after the §16 admission refusal.
/// Returns the blob row's public reference so the commit half replays the
/// identical revision request against the exact identity and Content
/// Version the rejection left behind.
@discardableResult
private func requireBlobSeedState(
    _ history: SwiftDataHistory,
    manifest: ProbeManifest,
    blobItemID: UUID
) async throws -> HistoryItemReference {
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .recent,
        limit: 10
    ))
    guard page.position.rawValue == 3,
          page.next == nil,
          page.rows.count == 3 else {
        throw ProbeFailure.unexpectedState
    }
    try requireSeedTextRow(
        page.rows[1],
        id: manifest.bravo,
        text: bravoText,
        date: bravoDate,
        source: bravoSource
    )
    try requireSeedTextRow(
        page.rows[2],
        id: manifest.alpha,
        text: alphaText,
        date: alphaFirstDate,
        source: alphaFirstSource
    )
    guard page.rows[0].item.id.rawValue == blobItemID,
          page.rows[0].item.contentVersion.rawValue == 1,
          page.rows[0].title == largeBlobType,
          page.rows[0].typeIdentifiers == [largeBlobType],
          page.rows[0].lastCopiedAt == pressureReviseDate,
          page.rows[0].copyCount == 1,
          page.rows[0].lastSource == pressureReviseSource,
          page.rows[0].pinnedPosition == nil,
          page.rows[0].search == nil else {
        throw ProbeFailure.unexpectedState
    }

    let expected = largeBlobBytes()
    let blobDetails = try await history.details(for: page.rows[0].item.id)
    guard blobDetails.item == page.rows[0].item,
          blobDetails.canonical.count == 1,
          blobDetails.canonical[0].typeIdentifier == largeBlobType,
          blobDetails.canonical[0].bytes == expected,
          blobDetails.effective == blobDetails.canonical,
          blobDetails.revisions.isEmpty,
          blobDetails.occurrence.firstCopiedAt == pressureReviseDate,
          blobDetails.occurrence.lastCopiedAt == pressureReviseDate,
          blobDetails.occurrence.count == 1,
          blobDetails.occurrence.firstSource == pressureReviseSource,
          blobDetails.occurrence.lastSource == pressureReviseSource,
          blobDetails.pinnedPosition == nil else {
        throw ProbeFailure.unexpectedState
    }

    let bravoDetails = try await history.details(for: page.rows[1].item.id)
    try requireSeedTextDetails(
        bravoDetails,
        row: page.rows[1],
        id: manifest.bravo,
        text: bravoText,
        date: bravoDate,
        source: bravoSource
    )
    let alphaDetails = try await history.details(for: page.rows[2].item.id)
    try requireSeedTextDetails(
        alphaDetails,
        row: page.rows[2],
        id: manifest.alpha,
        text: alphaText,
        date: alphaFirstDate,
        source: alphaFirstSource
    )
    return page.rows[0].item
}

private func seed(storeURL: URL) async throws {
    diagnostic("seed.phase-start")
    let history = try await openHistory(at: storeURL)
    diagnostic("seed.store-opened")
    let alpha = try requireInserted(
        try await history.perform(.capture(capture(
            alphaText,
            at: alphaFirstDate,
            source: alphaFirstSource
        ))),
        position: 1
    )
    diagnostic("seed.first-capture-committed")
    let bravo = try requireInserted(
        try await history.perform(.capture(capture(
            bravoText,
            at: bravoDate,
            source: bravoSource
        ))),
        position: 2
    )
    diagnostic("seed.second-capture-committed")
    try ProbeManifest(
        alpha: alpha.id.rawValue,
        bravo: bravo.id.rawValue
    ).write(siblingOf: storeURL)
    diagnostic("seed.manifest-written")
}

private func operate(
    storeURL: URL,
    crashAfterCommit: Bool = false
) async throws {
    let manifest = try ProbeManifest.read(siblingOf: storeURL)
    let history = try await openHistory(at: storeURL)
    try await requireInitialProjection(history, manifest: manifest)
    let receipt = try await history.perform(.capture(capture(
        alphaText,
        at: alphaSecondDate,
        source: alphaSecondSource
    )))
    guard case .committed(let commit) = receipt,
          commit.position.rawValue == 3,
          case .coalesced(let reference) = commit.outcome,
          reference.id.rawValue == manifest.alpha,
          reference.contentVersion.rawValue == 1 else {
        throw ProbeFailure.unexpectedState
    }
    if crashAfterCommit {
        // Keep the concrete History facade (and therefore its Authority and
        // ModelContainer ownership) alive through the abnormal termination.
        // Without this explicit lifetime fence, an optimizer may release the
        // last local owner before the intentional fatal signal.
        withExtendedLifetime(history) {
            fatalError("intentional crash after committed History transaction")
        }
    }
}

/// Commits the same phase-B coalesce, validates its receipt, then terminates
/// abnormally before any success token or graceful process teardown. The
/// parent requires an uncaught signal and a fresh third process proves open.
private func crashCommit(storeURL: URL) async throws -> Never {
    try await operate(storeURL: storeURL, crashAfterCommit: true)
    fatalError("crash phase unexpectedly returned")
}

/// Prepares one ordinary App Intents browse grant and one retained row. The
/// following crash phase can therefore exercise the production public facade
/// without test-only model setup or an empty-result shortcut.
private func gatewayAuditSeed(storeURL: URL) async throws {
    let history = try await openHistory(at: storeURL)
    _ = try requireInserted(
        try await history.perform(.capture(capture(
            gatewayAuditText,
            at: gatewayAuditDate,
            source: gatewayAuditSource
        ))),
        position: 1
    )
    let appIntentsConnections = try await history.connections().filter {
        $0.enrollKind == .appIntents && $0.status == .active
    }
    guard appIntentsConnections.count == 1 else {
        throw ProbeFailure.unexpectedState
    }
    try await history.grantCapability(
        .browse,
        to: appIntentsConnections[0].id
    )
}

/// V2-05 §5.2 / PLAY-PY-D5: terminate after the succeeded read audit save
/// boundary but before `ExternalReadResult` crosses the Authority boundary.
/// The DEBUG TaskLocal hook is process-local and absent from Release builds;
/// the actual read still enters through the public connection-bound facade.
private func gatewayAuditCrash(storeURL: URL) async throws -> Never {
#if DEBUG
    let history = try await openHistory(at: storeURL)
    let facade = history.makeAppIntentsHistoryFacade()
    try await ExternalReadPublicationDebugInstrumentation
        .$afterSynchronousSuccessfulAuditCommit.withValue({
            // The callback's strong capture keeps the owner alive through the
            // exact post-commit boundary; its declared result remains `Void`
            // even though this fixture intentionally never returns.
            _ = history
            fatalError("intentional crash after external read audit commit")
        }) {
            _ = try await facade.read(.recent(limit: 1))
        }
    fatalError("gateway audit crash phase unexpectedly returned")
#else
    fatalError("gateway audit crash phase requires a Debug build")
#endif
}

/// Fresh public administration read proves that the crashed call left exactly
/// one durable succeeded read audit. `auditLog` appends its own raw-19 record
/// only after freezing the returned page, so that record cannot contaminate
/// this count (`V2-05` §4.5/§5.2).
private func gatewayAuditVerify(storeURL: URL) async throws {
    let history = try await openHistory(at: storeURL)
    // Sequence 1 is the retained floor after the seed phase's administration
    // read. Start at that inclusive floor rather than below it; the frozen
    // snapshot head, not `since`, is the exclusive bound.
    let matching = try await history.auditLog(since: 1).filter {
        $0.operationKind == .readRecent
    }
    guard matching.count == 1,
          matching[0].outcome == .succeeded,
          matching[0].capability == .browse,
          matching[0].connectionID != nil,
          matching[0].changePosition == nil,
          matching[0].failureKind == nil,
          matching[0].denialReason == nil else {
        throw ProbeFailure.unexpectedState
    }
}

/// Commits one payload large enough for the schema's opaque
/// `@Attribute(.externalStorage)` placement hint, records only its public
/// business identity, then terminates abnormally with the facade/container
/// owner kept alive. This is process-crash evidence, not a file-layout, fsync,
/// sudden-power-loss, or permanent external-placement claim.
private func largeBlobCrashCommit(storeURL: URL) async throws -> Never {
    let history = try await openHistory(at: storeURL)
    let reference = try requireInserted(
        try await history.perform(.capture(largeBlobCapture())),
        position: 1
    )
    try LargeBlobManifest(itemID: reference.id.rawValue)
        .write(siblingOf: storeURL)
    withExtendedLifetime(history) {
        fatalError("intentional crash after committed large payload")
    }
}

/// A new process forces the large value through each public V1 projection and
/// compares the hydrated bytes directly with the independent deterministic
/// fixture. No SwiftData model or sidecar path crosses the process boundary.
private func largeBlobVerify(storeURL: URL) async throws {
    let manifest = try LargeBlobManifest.read(siblingOf: storeURL)
    let history = try await openHistory(at: storeURL)
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .recent,
        limit: 10
    ))
    guard page.position.rawValue == 1,
          page.next == nil,
          page.rows.count == 1,
          page.rows[0].item.id.rawValue == manifest.itemID,
          page.rows[0].item.contentVersion.rawValue == 1,
          page.rows[0].typeIdentifiers == [largeBlobType],
          page.rows[0].lastCopiedAt == largeBlobDate,
          page.rows[0].copyCount == 1,
          page.rows[0].lastSource == largeBlobSource,
          page.rows[0].pinnedPosition == nil,
          page.rows[0].search == nil else {
        throw ProbeFailure.unexpectedState
    }

    let expected = largeBlobBytes()
    let itemID = page.rows[0].item.id
    let details = try await history.details(for: itemID)
    guard details.item == page.rows[0].item,
          details.canonical.count == 1,
          details.canonical[0].typeIdentifier == largeBlobType,
          details.canonical[0].bytes == expected,
          details.effective == details.canonical,
          details.revisions.isEmpty,
          details.occurrence.firstCopiedAt == largeBlobDate,
          details.occurrence.lastCopiedAt == largeBlobDate,
          details.occurrence.count == 1,
          details.occurrence.firstSource == largeBlobSource,
          details.occurrence.lastSource == largeBlobSource,
          details.pinnedPosition == nil else {
        throw ProbeFailure.unexpectedState
    }

    let paste = try await history.pastePayload(for: itemID)
    guard paste.item == details.item,
          paste.lineageHint == itemID,
          paste.representations.count == 1,
          paste.representations[0].typeIdentifier == largeBlobType,
          paste.representations[0].bytes == expected else {
        throw ProbeFailure.unexpectedState
    }
}

#if DEBUG
/// Shared kill half of the 05-OQ9/05-CE26 mid-transaction cell (Card 1C-2):
/// prove the store healthy through the public surface first, then terminate
/// strictly INSIDE the in-flight commit transaction of one 8 MiB capture
/// (the seed's positions 1–2 mean the capture would commit as position 3).
/// The TaskLocal wrapper propagates across the `perform` → `commitCapture`
/// actor hop within this task — the same shape `gatewayAuditCrash` already
/// proves for this path.
///
/// Lifetime fence argument (the `crashCommit`/`largeBlobCrashCommit`
/// precedents): no explicit `withExtendedLifetime` is needed because the
/// kill fires synchronously inside the pending `history.perform(...)`
/// call — window A inside the Authority actor's own method (the actor, and
/// with it the container owner, is necessarily live), window B inside the
/// `willSave` notification callback before `perform` can return (the live
/// call frame keeps the facade owner retained). The optimizer cannot
/// release the owner out from under a call it is executing in.
private func largeBlobMidTransactionKill(
    storeURL: URL,
    at killPoint: TransactionKillDebugInstrumentation.KillPoint
) async throws -> Never {
    let manifest = try ProbeManifest.read(siblingOf: storeURL)
    let history = try await openHistory(at: storeURL)
    try await requireInitialProjection(history, manifest: manifest)
    try await TransactionKillDebugInstrumentation.$killPoint.withValue(
        killPoint
    ) {
        _ = try await history.perform(.capture(largeBlobCapture()))
    }
    // The armed seam must have terminated the process inside `perform`;
    // reaching here means the kill point never fired. The signal this
    // produces carries no seam marker, so the parent fixture fails closed.
    fatalError("kill phase unexpectedly returned")
}
#endif

/// Window A of the mid-transaction kill cell: death inside the
/// `ModelContext.transaction` closure at the X-HCR.2 WS-J1-5 window (b)
/// interleave — after all staging, before the singleton write, with the
/// save not yet attempted — so the following verify child must observe the
/// deterministic complete-OLD outcome. DEBUG TaskLocal seam, absent from
/// Release builds.
private func largeBlobMidTransactionKillClosure(
    storeURL: URL
) async throws -> Never {
#if DEBUG
    return try await largeBlobMidTransactionKill(
        storeURL: storeURL,
        at: .inClosurePreSave
    )
#else
    fatalError("mid-transaction kill phase requires a Debug build")
#endif
}

/// Window B of the mid-transaction kill cell: death anchored at the save
/// interval's start through the `ModelContext.willSave` notification of the
/// capture's operation-local context — the closest public anchor to the
/// SQLite commit and any externalStorage write-out. Only an old-or-new
/// verdict is admissible afterwards (Apple publishes no write-time
/// contract), so the verify child adjudicates the binary. DEBUG TaskLocal
/// seam, absent from Release builds.
private func largeBlobMidTransactionKillSave(
    storeURL: URL
) async throws -> Never {
#if DEBUG
    return try await largeBlobMidTransactionKill(
        storeURL: storeURL,
        at: .saveAttemptWillSave
    )
#else
    fatalError("mid-transaction kill phase requires a Debug build")
#endif
}

/// Adjudication half of the mid-transaction kill cell (Card 1C-2: "fresh
/// child重开只能看到完整old或完整new state，不能有orphan、duplicate或半个
/// external blob"). A fresh child reopens the store and accepts exactly one
/// of the two complete outcomes; every torn residue — a third row under the
/// seed position, a short or overlong table under position 3, a row whose
/// fields or hydrated bytes miss the deterministic fixture — fails closed.
/// The durable Change Position is the adjudication input; the large blob's
/// item identity is taken from this browse (the fixture bytes are the
/// oracle — no ID crosses the process boundary, the validateAll stance).
/// The tail capture then proves the reopened store still commits new writes
/// at exactly the next position (DATA-13's recovery concern).
private func largeBlobMidTransactionVerify(storeURL: URL) async throws {
    let manifest = try ProbeManifest.read(siblingOf: storeURL)
    let history = try await openHistory(at: storeURL)
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .recent,
        limit: 10
    ))
    guard page.next == nil else {
        throw ProbeFailure.unexpectedState
    }

    // complete-OLD = position 2 (the seed's last commit, capture absent);
    // complete-NEW = position 3 (the killed child's capture landed whole).
    let captureCommitted: Bool
    switch page.position.rawValue {
    case 2:
        captureCommitted = false
    case 3:
        captureCommitted = true
    default:
        throw ProbeFailure.unexpectedState
    }

    if !captureCommitted {
        // complete-OLD, field-for-field the seed projection — including
        // that exactly two rows remain, so the blob row is provably absent
        // (no orphan survived the in-flight death).
        try await requireInitialProjection(history, manifest: manifest)
    } else {
        // complete-NEW: the blob row first, then the untouched seed rows.
        guard page.rows.count == 3,
              page.rows[0].item.contentVersion.rawValue == 1,
              page.rows[0].title == largeBlobType,
              page.rows[0].typeIdentifiers == [largeBlobType],
              page.rows[0].lastCopiedAt == largeBlobDate,
              page.rows[0].copyCount == 1,
              page.rows[0].lastSource == largeBlobSource,
              page.rows[0].pinnedPosition == nil,
              page.rows[0].search == nil,
              page.rows[1].item.id.rawValue == manifest.bravo,
              page.rows[1].title == bravoText,
              page.rows[1].typeIdentifiers == [textType],
              page.rows[1].lastCopiedAt == bravoDate,
              page.rows[1].copyCount == 1,
              page.rows[1].lastSource == bravoSource,
              page.rows[1].pinnedPosition == nil,
              page.rows[1].search == nil,
              page.rows[2].item.id.rawValue == manifest.alpha,
              page.rows[2].title == alphaText,
              page.rows[2].typeIdentifiers == [textType],
              page.rows[2].lastCopiedAt == alphaFirstDate,
              page.rows[2].copyCount == 1,
              page.rows[2].lastSource == alphaFirstSource,
              page.rows[2].pinnedPosition == nil,
              page.rows[2].search == nil else {
            throw ProbeFailure.unexpectedState
        }

        // Byte-level oracle: regenerate the deterministic fixture and
        // compare directly — never a digest.
        let blobItemID = page.rows[0].item.id
        let expected = largeBlobBytes()
        let details = try await history.details(for: blobItemID)
        guard details.item == page.rows[0].item,
              details.canonical.count == 1,
              details.canonical[0].typeIdentifier == largeBlobType,
              details.canonical[0].bytes == expected,
              details.effective == details.canonical,
              details.revisions.isEmpty,
              details.occurrence.firstCopiedAt == largeBlobDate,
              details.occurrence.lastCopiedAt == largeBlobDate,
              details.occurrence.count == 1,
              details.occurrence.firstSource == largeBlobSource,
              details.occurrence.lastSource == largeBlobSource,
              details.pinnedPosition == nil else {
            throw ProbeFailure.unexpectedState
        }

        let paste = try await history.pastePayload(for: blobItemID)
        guard paste.item == details.item,
              paste.lineageHint == blobItemID,
              paste.representations.count == 1,
              paste.representations[0].typeIdentifier == largeBlobType,
              paste.representations[0].bytes == expected else {
            throw ProbeFailure.unexpectedState
        }
    }

    // DATA-13 writability tail: one distinct small capture must commit at
    // exactly the next position — OLD → 3, NEW → 4 — proving the reopened
    // store accepts new writes after the mid-transaction death.
    _ = try requireInserted(
        try await history.perform(.capture(capture(
            midTransactionWritabilityText,
            at: midTransactionWritabilityDate,
            source: midTransactionWritabilitySource
        ))),
        position: captureCommitted ? 4 : 3
    )
}

/// External-clone validation, seed half: one fresh owner commits the fixed
/// six-fixture table (positions 1–6, each `.inserted`), then revises
/// fixture 4's 8 MiB blob from patternA to patternB (position 7, content
/// version 2) and records the six public item identities in the manifest.
/// The process then exits normally, so the validator half proves a
/// terminated owner's payloads, not a shared in-process container.
private func validateSeed(storeURL: URL) async throws {
    let fixtures = try validationFixtureTable()
    guard fixtures.count == validationFixtureCount else {
        throw ProbeFailure.unexpectedState
    }
    let history = try await openHistory(at: storeURL)
    var references: [HistoryItemReference] = []
    references.reserveCapacity(fixtures.count)
    for (index, fixture) in fixtures.enumerated() {
        let reference = try requireInserted(
            try await history.perform(.capture(fixture.capture)),
            position: UInt64(index + 1)
        )
        references.append(reference)
    }
    let revisedReference = references[validationRevisedFixtureIndex]
    let reviseReceipt = try await history.perform(.revise(RevisionRequest(
        itemID: revisedReference.id,
        expected: revisedReference.contentVersion,
        intent: .replace(RevisionDraft(decisions: [RevisionDecision(
            typeIdentifier: largeBlobType,
            action: .replace(bytes: validationRevisedBlobBytes())
        )]))
    )))
    guard case .committed(let commit) = reviseReceipt,
          commit.position.rawValue == UInt64(validationFixtureCount + 1),
          case .revised(let revised) = commit.outcome,
          revised.id == revisedReference.id,
          revised.contentVersion.rawValue == 2 else {
        throw ProbeFailure.unexpectedState
    }
    try ValidationManifest(
        itemIDs: references.map { $0.id.rawValue },
        revisedItemID: revisedReference.id.rawValue
    ).write(siblingOf: storeURL)
}

/// External-clone validation, validator half: a fresh process reopens the
/// store, walks the public browse/details/pastePayload surface for every
/// fixture, and compares each hydrated canonical, effective, and revision
/// payload byte-for-byte with the deterministic fixtures — no digest
/// anywhere in the chain. Rows come back lastCopiedAt-descending (fixture
/// 5 first, fixture 0 last); the position-7 revise never changes
/// lastCopiedAt (`RetentionReviseComposition.swift` §7).
private func validateAll(storeURL: URL) async throws {
    let fixtures = try validationFixtureTable()
    guard fixtures.count == validationFixtureCount else {
        throw ProbeFailure.unexpectedState
    }
    let manifest = try ValidationManifest.read(siblingOf: storeURL)
    let history = try await openHistory(at: storeURL)
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .recent,
        limit: 10
    ))
    guard page.position.rawValue == UInt64(validationFixtureCount + 1),
          page.next == nil,
          page.rows.count == validationFixtureCount else {
        throw ProbeFailure.unexpectedState
    }

    for rowIndex in 0..<validationFixtureCount {
        let fixtureIndex = validationFixtureCount - 1 - rowIndex
        let fixture = fixtures[fixtureIndex]
        let row = page.rows[rowIndex]
        guard row.item.id.rawValue == manifest.itemIDs[fixtureIndex],
              row.item.contentVersion.rawValue == fixture.expectedContentVersion,
              row.title == fixture.title,
              row.typeIdentifiers == fixture.effective.map(\.typeIdentifier),
              row.lastCopiedAt == fixture.capture.observedAt,
              row.copyCount == 1,
              row.lastSource == fixture.capture.origin.sourceApplication,
              row.pinnedPosition == nil,
              row.search == nil else {
            throw ProbeFailure.unexpectedState
        }
    }

    for fixtureIndex in 0..<validationFixtureCount {
        let fixture = fixtures[fixtureIndex]
        let row = page.rows[validationFixtureCount - 1 - fixtureIndex]
        let itemID = row.item.id
        let details = try await history.details(for: itemID)
        guard details.item == row.item,
              details.item.id.rawValue == manifest.itemIDs[fixtureIndex],
              details.canonical.map(\.typeIdentifier)
                  == fixture.canonical.map(\.typeIdentifier),
              details.canonical.map(\.bytes) == fixture.canonical.map(\.bytes),
              details.effective.map(\.typeIdentifier)
                  == fixture.effective.map(\.typeIdentifier),
              details.effective.map(\.bytes) == fixture.effective.map(\.bytes),
              details.revisions.count == fixture.expectedRevisionCount,
              details.occurrence.firstCopiedAt == fixture.capture.observedAt,
              details.occurrence.lastCopiedAt == fixture.capture.observedAt,
              details.occurrence.count == 1,
              details.occurrence.firstSource
                  == fixture.capture.origin.sourceApplication,
              details.occurrence.lastSource
                  == fixture.capture.origin.sourceApplication,
              details.pinnedPosition == nil else {
            throw ProbeFailure.unexpectedState
        }
        if let expectedRevisionByteCount = fixture.expectedRevisionByteCount {
            // The minted revision ID and createdAt stay unasserted; only
            // the public byte facts are this evidence's concern.
            guard details.revisions[0].isActive,
                  details.revisions[0].byteCount == expectedRevisionByteCount
            else {
                throw ProbeFailure.unexpectedState
            }
        }

        let paste = try await history.pastePayload(for: itemID)
        guard paste.item == details.item,
              paste.lineageHint == itemID,
              paste.representations == details.effective,
              paste.representations.count == fixture.effective.count,
              paste.representations.map(\.typeIdentifier)
                  == fixture.effective.map(\.typeIdentifier),
              paste.representations.map(\.bytes)
                  == fixture.effective.map(\.bytes) else {
            throw ProbeFailure.unexpectedState
        }
    }
}

private func readExactStandardInput(byteCount: Int) throws -> Data {
    var result = Data()
    while result.count < byteCount {
        guard let chunk = try FileHandle.standardInput.read(
            upToCount: byteCount - result.count
        ), !chunk.isEmpty else {
            throw ProbeFailure.unexpectedState
        }
        result.append(chunk)
    }
    return result
}

private func pressureCapture(storeURL: URL) async throws {
    diagnostic("pressure.phase-start")
    let manifest = try ProbeManifest.read(siblingOf: storeURL)
    diagnostic("pressure.manifest-read")
    let history = try await openHistory(at: storeURL)
    diagnostic("pressure.store-opened")
    try await requireSeedState(history, manifest: manifest)
    diagnostic("pressure.seed-before-verified")

    FileHandle.standardOutput.write(Data("APFS_PRESSURE_READY\n".utf8))
    diagnostic("pressure.ready-published")
    guard try readExactStandardInput(byteCount: 3) == Data("GO\n".utf8) else {
        throw ProbeFailure.unexpectedState
    }
    diagnostic("pressure.go-received")

    let pressureCapture = ClipboardCapture(
        representations: [CapturedRepresentation(
            typeIdentifier: "public.data",
            bytes: Data(repeating: 0xA5, count: pressureCaptureByteCount)
        )],
        origin: CopyOriginObservation(
            sourceApplication: pressureCaptureSource,
            lineageHint: nil
        ),
        observedAt: pressureCaptureDate
    )
    diagnostic("pressure.capture-built bytes=8388608")
    do {
        _ = try await history.perform(.capture(pressureCapture))
        diagnostic("pressure.capture-unexpectedly-committed")
        throw ProbeFailure.unexpectedState
    } catch {
        diagnostic(error: error)
        guard let failure = error as? HistoryFailure,
              failure == .temporarilyUnavailable(.insufficientDiskSpace) else {
            throw ProbeFailure.unexpectedState
        }
    }
    diagnostic("pressure.capture-rejected-as-insufficient-disk-space")

    try await requireSeedState(history, manifest: manifest)
    diagnostic("pressure.seed-after-verified")
}

private func verifySeed(storeURL: URL) async throws {
    diagnostic("verify-seed.phase-start")
    let manifest = try ProbeManifest.read(siblingOf: storeURL)
    diagnostic("verify-seed.manifest-read")
    let history = try await openHistory(at: storeURL)
    diagnostic("verify-seed.store-opened")
    try await requireSeedState(history, manifest: manifest)
    diagnostic("verify-seed.projection-verified")
}

/// Full-disk revise cell (doc 11 §4.3 Card 6B; `docs/05-authority-kernel.md`
/// §16), under-pressure half. Before publishing readiness this child commits
/// the lane's dedicated 8 MiB patternA blob (position 3) and records its
/// public identity, so the parent's fill starts only with the seed table
/// durable. After `GO` the `.replace` request — byte-identical to the one
/// the commit half replays — must be refused by the stamped-plan admission
/// as exactly `.temporarilyUnavailable(.insufficientDiskSpace)` (mirroring
/// the pressureCapture refusal shape), and the refusal must leave every
/// byte of the seed table and the blob row unchanged.
private func pressureRevise(storeURL: URL) async throws {
    diagnostic("revise.phase-start")
    let manifest = try ProbeManifest.read(siblingOf: storeURL)
    diagnostic("revise.manifest-read")
    let history = try await openHistory(at: storeURL)
    diagnostic("revise.store-opened")
    try await requireSeedState(history, manifest: manifest)
    diagnostic("revise.seed-before-verified")

    let blobReference = try requireInserted(
        try await history.perform(.capture(pressureReviseCapture())),
        position: 3
    )
    diagnostic("revise.blob-capture-committed")
    try LargeBlobManifest(itemID: blobReference.id.rawValue)
        .write(siblingOf: storeURL)
    diagnostic("revise.blob-manifest-written")

    FileHandle.standardOutput.write(Data("APFS_PRESSURE_READY\n".utf8))
    diagnostic("revise.ready-published")
    guard try readExactStandardInput(byteCount: 3) == Data("GO\n".utf8) else {
        throw ProbeFailure.unexpectedState
    }
    diagnostic("revise.go-received")

    do {
        _ = try await history.perform(pressureReviseRequest(
            itemID: blobReference.id,
            expected: blobReference.contentVersion
        ))
        diagnostic("revise.unexpectedly-committed")
        throw ProbeFailure.unexpectedState
    } catch {
        diagnostic(error: error)
        guard let failure = error as? HistoryFailure,
              failure == .temporarilyUnavailable(.insufficientDiskSpace) else {
            throw ProbeFailure.unexpectedState
        }
    }
    diagnostic("revise.rejected-as-insufficient-disk-space")

    try await requireBlobSeedState(
        history,
        manifest: manifest,
        blobItemID: blobReference.id.rawValue
    )
    diagnostic("revise.seed-after-verified")
}

/// Full-disk revise cell, commit half: with the competitor filler removed,
/// a fresh owner re-verifies the unchanged position-3 table, then replays
/// the byte-identical `.replace` request. The under-pressure refusal was a
/// capacity fact, not a durable state change, so the same request must now
/// commit at exactly position 4 with the blob's Content Version 2.
private func pressureReviseCommit(storeURL: URL) async throws {
    diagnostic("revise-commit.phase-start")
    let manifest = try ProbeManifest.read(siblingOf: storeURL)
    let blobManifest = try LargeBlobManifest.read(siblingOf: storeURL)
    diagnostic("revise-commit.manifest-read")
    let history = try await openHistory(at: storeURL)
    diagnostic("revise-commit.store-opened")
    let blobReference = try await requireBlobSeedState(
        history,
        manifest: manifest,
        blobItemID: blobManifest.itemID
    )
    diagnostic("revise-commit.seed-verified")

    let receipt = try await history.perform(pressureReviseRequest(
        itemID: blobReference.id,
        expected: blobReference.contentVersion
    ))
    guard case .committed(let commit) = receipt,
          commit.position.rawValue == 4,
          case .revised(let revised) = commit.outcome,
          revised.id == blobReference.id,
          revised.contentVersion.rawValue == 2 else {
        throw ProbeFailure.unexpectedState
    }
    diagnostic("revise-commit.revision-committed")
}

/// Full-disk revise cell, durable-verify half: a fresh process proves the
/// post-release commit survived its owner's termination — position 4, the
/// blob's canonical still patternA while effective is now patternB, exactly
/// one active revision of `largeBlobByteCount` bytes, occurrence facts
/// untouched (a revise never moves lastCopiedAt,
/// `RetentionReviseComposition.swift` §7), and the alpha/bravo seed rows
/// byte-for-byte as `requireSeedState` pins them. All payload comparisons
/// are direct `Data ==` — never digests.
private func pressureReviseVerify(storeURL: URL) async throws {
    diagnostic("revise-verify.phase-start")
    let manifest = try ProbeManifest.read(siblingOf: storeURL)
    let blobManifest = try LargeBlobManifest.read(siblingOf: storeURL)
    diagnostic("revise-verify.manifest-read")
    let history = try await openHistory(at: storeURL)
    diagnostic("revise-verify.store-opened")
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .recent,
        limit: 10
    ))
    guard page.position.rawValue == 4,
          page.next == nil,
          page.rows.count == 3 else {
        throw ProbeFailure.unexpectedState
    }
    try requireSeedTextRow(
        page.rows[1],
        id: manifest.bravo,
        text: bravoText,
        date: bravoDate,
        source: bravoSource
    )
    try requireSeedTextRow(
        page.rows[2],
        id: manifest.alpha,
        text: alphaText,
        date: alphaFirstDate,
        source: alphaFirstSource
    )
    guard page.rows[0].item.id.rawValue == blobManifest.itemID,
          page.rows[0].item.contentVersion.rawValue == 2,
          page.rows[0].title == largeBlobType,
          page.rows[0].typeIdentifiers == [largeBlobType],
          page.rows[0].lastCopiedAt == pressureReviseDate,
          page.rows[0].copyCount == 1,
          page.rows[0].lastSource == pressureReviseSource,
          page.rows[0].pinnedPosition == nil,
          page.rows[0].search == nil else {
        throw ProbeFailure.unexpectedState
    }

    let canonicalBytes = largeBlobBytes()
    let revisedBytes = validationRevisedBlobBytes()
    let blobItemID = page.rows[0].item.id
    let blobDetails = try await history.details(for: blobItemID)
    guard blobDetails.item == page.rows[0].item,
          blobDetails.canonical.count == 1,
          blobDetails.canonical[0].typeIdentifier == largeBlobType,
          blobDetails.canonical[0].bytes == canonicalBytes,
          blobDetails.effective.count == 1,
          blobDetails.effective[0].typeIdentifier == largeBlobType,
          blobDetails.effective[0].bytes == revisedBytes,
          blobDetails.revisions.count == 1,
          blobDetails.revisions[0].isActive,
          blobDetails.revisions[0].byteCount == largeBlobByteCount,
          blobDetails.occurrence.firstCopiedAt == pressureReviseDate,
          blobDetails.occurrence.lastCopiedAt == pressureReviseDate,
          blobDetails.occurrence.count == 1,
          blobDetails.occurrence.firstSource == pressureReviseSource,
          blobDetails.occurrence.lastSource == pressureReviseSource,
          blobDetails.pinnedPosition == nil else {
        throw ProbeFailure.unexpectedState
    }

    let bravoDetails = try await history.details(for: page.rows[1].item.id)
    try requireSeedTextDetails(
        bravoDetails,
        row: page.rows[1],
        id: manifest.bravo,
        text: bravoText,
        date: bravoDate,
        source: bravoSource
    )
    let alphaDetails = try await history.details(for: page.rows[2].item.id)
    try requireSeedTextDetails(
        alphaDetails,
        row: page.rows[2],
        id: manifest.alpha,
        text: alphaText,
        date: alphaFirstDate,
        source: alphaFirstSource
    )
    diagnostic("revise-verify.durable-state-verified")
}

/// Prints one closed-set characterization token and terminates the child
/// successfully: the observed branch — not this process's exit status — is
/// the recorded evidence. Self-managed termination precedent: the crash and
/// regexp characterization phases own their exits.
private func publishOpenCharacterizationToken(_ token: String) -> Never {
    FileHandle.standardOutput.write(Data("\(token)\n".utf8))
    exit(EXIT_SUCCESS)
}

/// Maps one caught open failure onto the closed typed-or-opened
/// disjunction: `.persistence(.openStore)` (ModelContainer construction,
/// DATA-14's flat exit) and `.persistence(.transaction)` (the startup
/// singleton transaction failing on ENOSPC) are the only accepted typed
/// branches on a full volume. Any other typed failure is a closed-set
/// violation and fails the cell rather than silently widening the set.
private func fullVolumeOpenToken(
    for failure: HistoryFailure,
    refusedOpenStore: String,
    refusedTransaction: String
) throws -> String {
    switch failure {
    case .persistence(.openStore):
        return refusedOpenStore
    case .persistence(.transaction):
        return refusedTransaction
    default:
        throw ProbeFailure.unexpectedState
    }
}

/// Full-disk fresh-open characterization (Card 6B; doc 11 §4.3): a fresh
/// store's `open` writes only SQLite/WAL scalar files, which never pass the
/// §16 stamped-plan admission (`externalDemandBytes` counts only
/// create/revise/prune plans), so the honest assertion on a filled volume
/// is the closed disjunction of typed outcomes — each branch a recorded
/// empirical fact, never a failure. Success stays possible because dd's
/// fixed-block fill can leave more slack than SQLite's first allocations
/// need. A crash, any other typed failure, or a non-HistoryFailure throw
/// fails the cell with the throw site preserved on stderr.
private func openFullVolume(storeURL: URL) async throws -> Never {
    do {
        _ = try await openHistory(at: storeURL)
    } catch let failure as HistoryFailure {
        publishOpenCharacterizationToken(try fullVolumeOpenToken(
            for: failure,
            refusedOpenStore: "OPENFULLVOLUME_OPENSTORE_REFUSED",
            refusedTransaction: "OPENFULLVOLUME_TRANSACTION_REFUSED"
        ))
    } catch {
        throw ProbeFailure.unexpectedState
    }
    publishOpenCharacterizationToken("OPENFULLVOLUME_OPENED")
}

/// Full-disk reopen characterization of the already-seeded main store: the
/// same closed typed-or-opened disjunction, with one stronger success
/// criterion — "readable" requires the position-2 seed projection to
/// hydrate through the public browse/details reads, not merely the
/// container to construct. WAL/shm creation on a full volume can itself
/// hit ENOSPC, so both refusal branches are equally legal recorded facts.
private func openSeededFullVolume(storeURL: URL) async throws -> Never {
    let manifest = try ProbeManifest.read(siblingOf: storeURL)
    let history: SwiftDataHistory
    do {
        history = try await openHistory(at: storeURL)
    } catch let failure as HistoryFailure {
        publishOpenCharacterizationToken(try fullVolumeOpenToken(
            for: failure,
            refusedOpenStore: "OPENSEEDEDONFULLVOLUME_OPENSTORE_REFUSED",
            refusedTransaction: "OPENSEEDEDONFULLVOLUME_TRANSACTION_REFUSED"
        ))
    } catch {
        throw ProbeFailure.unexpectedState
    }
    try await requireSeedState(history, manifest: manifest)
    publishOpenCharacterizationToken("OPENSEEDEDONFULLVOLUME_OK")
}

private func verify(storeURL: URL) async throws {
    let manifest = try ProbeManifest.read(siblingOf: storeURL)
    let history = try await openHistory(at: storeURL)
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .recent,
        limit: 10
    ))
    guard page.position.rawValue == 3,
          page.next == nil,
          page.rows.count == 2,
          page.rows[0].item.id.rawValue == manifest.alpha,
          page.rows[0].title == alphaText,
          page.rows[0].typeIdentifiers == [textType],
          page.rows[0].item.contentVersion.rawValue == 1,
          page.rows[0].lastCopiedAt == alphaSecondDate,
          page.rows[0].copyCount == 2,
          page.rows[0].lastSource == alphaSecondSource,
          page.rows[0].pinnedPosition == nil,
          page.rows[0].search == nil,
          page.rows[1].item.id.rawValue == manifest.bravo,
          page.rows[1].title == bravoText,
          page.rows[1].typeIdentifiers == [textType],
          page.rows[1].item.contentVersion.rawValue == 1,
          page.rows[1].lastCopiedAt == bravoDate,
          page.rows[1].copyCount == 1,
          page.rows[1].lastSource == bravoSource,
          page.rows[1].pinnedPosition == nil,
          page.rows[1].search == nil else {
        throw ProbeFailure.unexpectedState
    }

    let alpha = try await history.details(for: page.rows[0].item.id)
    guard alpha.item.id.rawValue == manifest.alpha,
          alpha.item == page.rows[0].item,
          alpha.canonical.map(\.typeIdentifier) == [textType],
          alpha.canonical.map(\.bytes) == [Data(alphaText.utf8)],
          alpha.effective == alpha.canonical,
          alpha.revisions.isEmpty,
          alpha.occurrence.firstCopiedAt == alphaFirstDate,
          alpha.occurrence.lastCopiedAt == alphaSecondDate,
          alpha.occurrence.count == 2,
          alpha.occurrence.firstSource == alphaFirstSource,
          alpha.occurrence.lastSource == alphaSecondSource,
          alpha.pinnedPosition == nil else {
        throw ProbeFailure.unexpectedState
    }

    let bravo = try await history.details(for: page.rows[1].item.id)
    guard bravo.item.id.rawValue == manifest.bravo,
          bravo.item == page.rows[1].item,
          bravo.canonical.map(\.typeIdentifier) == [textType],
          bravo.canonical.map(\.bytes) == [Data(bravoText.utf8)],
          bravo.effective == bravo.canonical,
          bravo.revisions.isEmpty,
          bravo.occurrence.firstCopiedAt == bravoDate,
          bravo.occurrence.lastCopiedAt == bravoDate,
          bravo.occurrence.count == 1,
          bravo.occurrence.firstSource == bravoSource,
          bravo.occurrence.lastSource == bravoSource,
          bravo.pinnedPosition == nil else {
        throw ProbeFailure.unexpectedState
    }
}

/// REVIEW Card 11C's engine experiment runs only in this disposable helper
/// process. Foundation matching is synchronous, so the parent test — not a
/// detached Task in the product — owns the deadline and can terminate the
/// complete process if ICU does not return. Every named scenario is fixed: no
/// caller-provided regexp or clipboard text enters this probe.
private func regexpCharacterize(scenario: String) throws {
    let pattern: String
    switch scenario {
    case "safe-control":
        pattern = "a+b"
    case "top-level-chain-current", "top-level-chain-progress":
        // This repeated ambiguous top-level quantifier shape is outside the
        // rejected group grammar frozen by 03b §8. Whether macOS 26 ICU
        // completes it within the parent's bound is the fact under test.
        pattern = "a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b"
    default:
        throw ProbeFailure.unexpectedState
    }

    FileHandle.standardOutput.write(Data(
        (
            "REGEXP_CHARACTERIZATION_CHILD scenario=\(scenario) "
                + "pattern=\(pattern) started=true\n"
        ).utf8
    ))
    let expression = try NSRegularExpression(pattern: pattern)
    let range = NSRange(
        regexpCharacterizationInput.startIndex
            ..< regexpCharacterizationInput.endIndex,
        in: regexpCharacterizationInput
    )
    if scenario == "top-level-chain-progress" {
        expression.enumerateMatches(
            in: regexpCharacterizationInput,
            options: .reportProgress,
            range: range
        ) { result, flags, stop in
            if result != nil {
                // Every fixed scenario requires a `b` that the input lacks.
                // Treat any result as a broken probe, without sharing mutable
                // state through Foundation's callback.
                exit(EXIT_FAILURE)
            }
            if flags.contains(.progress) {
                FileHandle.standardOutput.write(Data(
                    "REGEXP_CHARACTERIZATION_CHILD callback=progress\n".utf8
                ))
                stop.pointee = true
            }
        }
    } else {
        let match = expression.firstMatch(
            in: regexpCharacterizationInput,
            range: range
        )
        guard match == nil else {
            throw ProbeFailure.unexpectedState
        }
    }
    FileHandle.standardOutput.write(Data(
        "REGEXP_CHARACTERIZATION_CHILD operation-returned=true\n".utf8
    ))
}

@main
private struct HistoryRestartProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2,
              let phase = ProbePhase(rawValue: arguments[0]) else {
            FileHandle.standardOutput.write(Data("USAGE\n".utf8))
            exit(EXIT_FAILURE)
        }

        do {
            let storeURL = URL(fileURLWithPath: arguments[1])
            diagnostic("process.phase=\(phase.rawValue) start")
            switch phase {
            case .seed:
                try await seed(storeURL: storeURL)
            case .operate:
                try await operate(storeURL: storeURL)
            case .crashCommit:
                try await crashCommit(storeURL: storeURL)
            case .verify:
                try await verify(storeURL: storeURL)
            case .pressureCapture:
                try await pressureCapture(storeURL: storeURL)
            case .verifySeed:
                try await verifySeed(storeURL: storeURL)
            case .openFullVolume:
                try await openFullVolume(storeURL: storeURL)
            case .openSeededFullVolume:
                try await openSeededFullVolume(storeURL: storeURL)
            case .pressureRevise:
                try await pressureRevise(storeURL: storeURL)
            case .pressureReviseCommit:
                try await pressureReviseCommit(storeURL: storeURL)
            case .pressureReviseVerify:
                try await pressureReviseVerify(storeURL: storeURL)
            case .retentionSeed:
                try await retentionSeed(storeURL: storeURL)
            case .retentionVerify:
                try await retentionVerify(storeURL: storeURL)
            case .retentionUpdate:
                try await retentionUpdate(storeURL: storeURL)
            case .retentionVerifyUpdated:
                try await retentionVerifyUpdated(storeURL: storeURL)
            case .retentionRejectMalformed:
                try await requirePublicOpenFailure(
                    at: storeURL,
                    expected: .persistence(.corruptStoredValue)
                )
            case .retentionRejectWrongKey:
                try await requirePublicOpenFailure(
                    at: storeURL,
                    expected: .persistence(.invariantViolation)
                )
            case .openRejectFutureSchema:
                try await requirePublicOpenFailure(
                    at: storeURL,
                    expected: .persistence(.openStore)
                )
            case .openRejectCorruptBytes:
                try await requirePublicOpenFailure(
                    at: storeURL,
                    expected: .persistence(.openStore)
                )
            case .openRejectReadOnlyDirectory:
                try await requirePublicOpenFailure(
                    at: storeURL,
                    expected: .persistence(.openStore)
                )
            case .openRejectLeasedStore:
                try await requirePublicOpenFailure(
                    at: storeURL,
                    expected: .persistence(.storeAlreadyOpen)
                )
            case .leaseHold:
                try await leaseHold(storeURL: storeURL)
            case .gatewayAuditSeed:
                try await gatewayAuditSeed(storeURL: storeURL)
            case .gatewayAuditCrash:
                try await gatewayAuditCrash(storeURL: storeURL)
            case .gatewayAuditVerify:
                try await gatewayAuditVerify(storeURL: storeURL)
            case .largeBlobCrashCommit:
                try await largeBlobCrashCommit(storeURL: storeURL)
            case .largeBlobVerify:
                try await largeBlobVerify(storeURL: storeURL)
            case .largeBlobMidTransactionKillClosure:
                try await largeBlobMidTransactionKillClosure(storeURL: storeURL)
            case .largeBlobMidTransactionKillSave:
                try await largeBlobMidTransactionKillSave(storeURL: storeURL)
            case .largeBlobMidTransactionVerify:
                try await largeBlobMidTransactionVerify(storeURL: storeURL)
            case .validateSeed:
                try await validateSeed(storeURL: storeURL)
            case .validateAll:
                try await validateAll(storeURL: storeURL)
            case .regexpCharacterize:
                try regexpCharacterize(scenario: arguments[1])
            }
            diagnostic("process.phase=\(phase.rawValue) complete")
            FileHandle.standardOutput.write(Data("\(phase.rawValue.uppercased())_OK\n".utf8))
            exit(EXIT_SUCCESS)
        } catch {
            diagnostic(error: error)
            diagnostic("process.phase=\(phase.rawValue) failed")
            FileHandle.standardOutput.write(Data("\(phase.rawValue.uppercased())_FAIL\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
