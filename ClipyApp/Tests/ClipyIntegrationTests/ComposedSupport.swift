/// ComposedSupport — shared fixtures for the M3 re-verification suites
/// (docs/roadmap/06-clipyapp.md "Acceptance"; docs/roadmap/README.md §3):
/// every WS1–WS21 path re-run end-to-end through the COMPOSED app stack —
/// the real `SwiftDataHistory` facade, the real `PasteboardAdapter` over a
/// PRIVATE `NSPasteboard` (never `.general`), and the real PresentationUI
/// `HistoryViewState` — instead of the storage-side seams the step-5–8
/// suites use.
///
/// Conventions carried over from `Tests/HistoryStorageTests/Support/
/// WalkingSkeletonSupport.swift` (the storage-side skeleton this suite
/// re-verifies in composed form): fixed observation timestamps, one observed
/// source per capture, temp store directories created upfront so CoreData
/// logs no file-status diagnostics, and receipt-shaped guard helpers that
/// record an issue instead of trapping.
///
/// This target is OUTSIDE the SwiftPM package (XcodeGen-hosted, app-hosted),
/// so package-only initializers (`HistoryItemID(rawValue:)`,
/// `ContentVersion(rawValue:)`, `PastePayload(…)`) are NOT available here:
/// every ID/version/payload flows from a real receipt, detail, or paste
/// read — exactly the caller position ClipyApp itself occupies
/// (docs/03a-instruction-set.md §2 minting-centralization note).
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import Testing

// MARK: - Support

enum ComposedSupport {

    /// The plain-text type identifier the adapter freezes for
    /// `NSPasteboard.PasteboardType.string` — the same normalized UTI the
    /// ingest path stores (docs/02-domain.md §2.1).
    static let plainTextTypeIdentifier =
        NSPasteboard.PasteboardType.string.rawValue

    // MARK: Stores

    /// Opens a REAL `SwiftDataHistory` over an in-memory store — same
    /// Authority, planners, codecs, and transaction path as a persistent
    /// store; only the durability medium differs (docs/05-authority-kernel.md
    /// §2). Used for every suite that needs no restart.
    static func openMemoryHistory(
        maximumUnpinned: Int = 200
    ) async throws -> SwiftDataHistory {
        try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .memory,
                initialMaximumUnpinnedItems: maximumUnpinned
            )
        )
    }

    /// A unique temporary store directory for one restart-oriented test,
    /// created up front (repo convention: CoreData otherwise logs
    /// file-status diagnostics into CI log scans). The caller removes the
    /// directory in a `defer` (see `removeStore`).
    static func tempStoreURL(_ testName: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-composed-\(testName)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("store.sqlite")
    }

    /// Removes the store directory created for `url` (its parent directory).
    static func removeStore(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: Deterministic-origin captures (no pasteboard)

    /// A normalized raw text capture with a FIXED origin observation — the
    /// composed-suite twin of `WSSupport.textCapture`: single-line text keeps
    /// the §15 projection deterministic (title == body == text), and the
    /// caller-controlled source/lineage fields drive the scenarios where the
    /// adapter's live `NSWorkspace` observation would be non-deterministic
    /// (WS19 out-of-order `lastSource`, WS4's mismatched-hint counter).
    static func textCapture(
        _ text: String,
        observedAt: Date,
        source: String? = nil,
        lineageHint: HistoryItemID? = nil,
        extra: [(typeIdentifier: String, bytes: [UInt8])] = []
    ) -> ClipboardCapture {
        var representations = [CapturedRepresentation(
            typeIdentifier: plainTextTypeIdentifier,
            bytes: Data(text.utf8)
        )]
        for item in extra {
            representations.append(CapturedRepresentation(
                typeIdentifier: item.typeIdentifier,
                bytes: Data(item.bytes)
            ))
        }
        return ClipboardCapture(
            representations: representations,
            origin: CopyOriginObservation(
                sourceApplication: source,
                lineageHint: lineageHint
            ),
            observedAt: observedAt
        )
    }

    // MARK: Private pasteboard fixtures (never .general)

    /// A fresh, uniquely named private pasteboard per test — the suite never
    /// reads or mutates the user's clipboard (same stance as
    /// `Tests/PasteboardAdapterTests`).
    @MainActor
    static func makePasteboard() -> NSPasteboard {
        NSPasteboard(
            name: NSPasteboard.Name(
                "com.clipy.clipyintegrationtests." + UUID().uuidString
            )
        )
    }

    /// Writes `text` (plus an optional html sibling) onto the private
    /// pasteboard the way a copying application would: clear, then one typed
    /// payload per representation (docs/03a-instruction-set.md §4 raw shape).
    @MainActor
    static func setPasteboardContents(
        _ text: String,
        html: String? = nil,
        on pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        pasteboard.setData(Data(text.utf8), forType: .string)
        if let html {
            pasteboard.setData(
                Data(html.utf8),
                forType: NSPasteboard.PasteboardType("public.html")
            )
        }
    }

    /// The pasteboard-environment probe failure. swift-testing has no
    /// runtime-skip API, so an unusable `NSPasteboard` in the hosted
    /// environment is a hard, descriptive error: on the macOS runner this
    /// probe always passes, and a regression there must not hide (the
    /// storage-only suites would still run and fail independently).
    enum ProbeFailure: Error {
        case unusablePasteboard
    }

    /// Probes private-pasteboard usability and FAILS the calling test when
    /// `NSPasteboard` cannot round-trip in this hosted environment
    /// (docs/roadmap/06-clipyapp.md acceptance runs on a macOS host where
    /// this probe always passes).
    @MainActor
    static func requireUsablePasteboard() throws {
        let probe = makePasteboard()
        probe.clearContents()
        probe.setData(Data("clipy-probe".utf8), forType: .string)
        guard probe.pasteboardItems?.first?.data(forType: .string)
            == Data("clipy-probe".utf8) else {
            throw ProbeFailure.unusablePasteboard
        }
    }

    // MARK: Receipt guards (issue-recording, never trapping)

    /// The commit inside a `.committed` receipt, or a recorded issue.
    static func commit(
        of receipt: HistoryReceipt,
        _ clause: String
    ) -> HistoryCommit? {
        guard case let .committed(commit) = receipt else {
            Issue.record("\(clause): expected a .committed receipt, got \(receipt)")
            return nil
        }
        return commit
    }

    /// The inserted reference inside a committed capture receipt.
    static func insertedReference(
        from receipt: HistoryReceipt,
        _ clause: String
    ) -> HistoryItemReference? {
        guard let commit = commit(of: receipt, clause),
              case let .inserted(reference) = commit.outcome else {
            Issue.record("\(clause): expected .inserted(reference), got \(receipt)")
            return nil
        }
        return reference
    }

    /// The coalesced winner reference inside a committed capture receipt.
    static func coalescedReference(
        from receipt: HistoryReceipt,
        _ clause: String
    ) -> HistoryItemReference? {
        guard let commit = commit(of: receipt, clause),
              case let .coalesced(reference) = commit.outcome else {
            Issue.record("\(clause): expected .coalesced(reference), got \(receipt)")
            return nil
        }
        return reference
    }

    /// The revised reference inside a committed revision receipt.
    static func revisedReference(
        from receipt: HistoryReceipt,
        _ clause: String
    ) -> HistoryItemReference? {
        guard let commit = commit(of: receipt, clause),
              case let .revised(reference) = commit.outcome else {
            Issue.record("\(clause): expected .revised(reference), got \(receipt)")
            return nil
        }
        return reference
    }

    // MARK: View-state waiting

    /// Spins the awaiting test in small sleep slices until `condition`
    /// holds or `timeout` elapses. Called from `@MainActor` tests only: the
    /// `Task.sleep` suspension frees the main actor, so the view state's own
    /// MainActor-inherited observation/mutation tasks can run between slices
    /// (the async analog of the RunLoop spinning in
    /// `Tests/PasteboardAdapterTests`).
    @MainActor
    static func waitFor(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Search range indexing (docs/03b-instruction-set.md §8)

    /// Extracts the substring at `range` from `text` via the UTF-16 view,
    /// verifying the UTF-16 offsets index correctly — the same check the
    /// storage-side WS17 suites perform on `SearchPresentation.matchedRanges`.
    static func substring(
        _ text: String,
        utf16Range: UTF16TextRange
    ) -> String {
        let view = text.utf16
        let start = view.index(view.startIndex, offsetBy: utf16Range.location)
        let end = view.index(start, offsetBy: utf16Range.length)
        return String(decoding: view[start..<end], as: UTF16.self)
    }
}
