/// A public-API-only restart tracer for Review Evidence Card 1C-1, the bounded
/// X-HCR post-success crash fixture, and the REVIEW §4.3 Retention-config
/// restart tail. Each invocation owns one `SwiftDataHistory` for one short
/// process; no SwiftData object or generated identity crosses a phase boundary.
/// The Retention phases prove exact configured-value persistence across
/// terminated owners only; they do not prove migration, full-disk behavior,
/// or crash durability (`11-ai-todo-map-2026-08-23.md` §4.3;
/// `V2-02-retention.md` §8.1/§12).
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
    case retentionSeed
    case retentionVerify
    case retentionUpdate
    case retentionVerifyUpdated
    case gatewayAuditSeed
    case gatewayAuditCrash
    case gatewayAuditVerify
    case largeBlobCrashCommit
    case largeBlobVerify
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
private let gatewayAuditText = "gateway audit crash publication fixture"
private let gatewayAuditDate = Date(timeIntervalSinceReferenceDate: 50_000)
private let gatewayAuditSource = "restart.gateway.audit"
private let largeBlobType = "public.data"
private let largeBlobDate = Date(timeIntervalSinceReferenceDate: 60_000)
private let largeBlobSource = "restart.large-blob.capture"
private let largeBlobByteCount = 8 * 1_048_576
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
            withExtendedLifetime(history) {
                fatalError(
                    "intentional crash after external read audit commit"
                )
            }
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
    let matching = try await history.auditLog(since: 0).filter {
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
            case .retentionSeed:
                try await retentionSeed(storeURL: storeURL)
            case .retentionVerify:
                try await retentionVerify(storeURL: storeURL)
            case .retentionUpdate:
                try await retentionUpdate(storeURL: storeURL)
            case .retentionVerifyUpdated:
                try await retentionVerifyUpdated(storeURL: storeURL)
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
