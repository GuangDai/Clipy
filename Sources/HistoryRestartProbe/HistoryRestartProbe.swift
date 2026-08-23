/// A public-API-only restart tracer for Review Evidence Card 1C-1 and the
/// bounded X-HCR post-success crash fixture. Each invocation owns one
/// `SwiftDataHistory` for one short process; no SwiftData object or generated
/// identity crosses a phase boundary.
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
private let manifestFileName = "restart-manifest.txt"
private let diagnosticsEnabled = ProcessInfo.processInfo.environment[
    "CLIPY_APFS_PROBE_DIAGNOSTICS"
] == "1"

/// Probe-only, opt-in diagnostics for the physical APFS evidence workflow.
/// Messages use a frozen, content-free vocabulary: no store path, clipboard
/// bytes, identifiers, descriptions, or `NSError.userInfo` values are emitted.
/// `HistoryRestartProbe` has no package product and the app never executes it.
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

    var platformError = error as NSError
    for depth in 0..<4 {
        let domain: String
        switch platformError.domain {
        case NSCocoaErrorDomain:
            domain = "cocoa"
        case NSPOSIXErrorDomain:
            domain = "posix"
        case "NSSQLiteErrorDomain":
            domain = "sqlite"
        default:
            domain = "other"
        }
        diagnostic(
            "platform-error depth=\(depth) domain=\(domain) code=\(platformError.code)"
        )
        guard let underlying = platformError.userInfo[
            NSUnderlyingErrorKey
        ] as? NSError else {
            break
        }
        platformError = underlying
    }
}

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

private func openHistory(at storeURL: URL) async throws -> SwiftDataHistory {
    try await SwiftDataHistory.open(configuration: HistoryConfiguration(
        persistence: .persistent(storeURL: storeURL),
        initialMaximumUnpinnedItems: 200
    ))
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
