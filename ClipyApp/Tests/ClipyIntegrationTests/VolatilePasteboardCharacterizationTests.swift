/// DATA-9a candidate characterization (REVIEW `01-findings.md` DATA-9; todo
/// map §4.5): unknown pasteboard identifiers have no Apple stability or
/// semantic contract, so this suite does not classify any identifier as
/// ignorable. It records the current conservative product behavior through
/// the composed path: private NSPasteboard -> real PasteboardAdapter freeze ->
/// real in-memory SwiftDataHistory.
///
/// The named candidates below come from third-party interoperability reports;
/// the four requested cases use explicitly synthetic unknown-UTI labels in a
/// Clipy-owned test namespace. Every payload is synthetic and content-free.
/// This proves only Canonical byte sensitivity: A and B remain distinct when
/// that unknown representation changes, while an exact A replay coalesces.
/// It does not prove that Chrome, Safari, Notes, a password manager, or any
/// current producer emits a tested type, nor establish real-world volatility
/// frequency or that dropping one would preserve paste fidelity. DATA-9a
/// remains Partial pending authorized real-producer fixtures and frequency
/// evidence; DATA-9b remains a separate evidence-gated representation-role
/// decision.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing

private struct VolatilePasteboardCandidate: Sendable {
    let fixtureLabel: String
    let typeIdentifier: String
}

private let volatilePasteboardCandidates: [VolatilePasteboardCandidate] = [
    // Explicitly synthetic unknown-UTI labels for the four requested cases.
    // These are not additions to either product marker set and make no claim
    // about a real application's current pasteboard declarations or the
    // frequency with which any real representation changes.
    .init(
        fixtureLabel: "synthetic unknown-UTI label (Chrome case)",
        typeIdentifier: "com.clipy.tests.synthetic.chrome.bookkeeping"
    ),
    .init(
        fixtureLabel: "synthetic unknown-UTI label (Safari case)",
        typeIdentifier: "com.clipy.tests.synthetic.safari.bookkeeping"
    ),
    .init(
        fixtureLabel: "synthetic unknown-UTI label (Notes case)",
        typeIdentifier: "com.clipy.tests.synthetic.notes.bookkeeping"
    ),
    .init(
        fixtureLabel: "synthetic unknown-UTI label (password-manager case)",
        typeIdentifier: "com.clipy.tests.synthetic.password-manager.bookkeeping"
    ),
    // Named candidates remain characterization inputs only. Their presence
    // here neither admits an ignore role nor claims current producer use.
    .init(
        fixtureLabel: "Safari LinkPresentation candidate",
        typeIdentifier: "com.apple.linkpresentation.metadata"
    ),
    .init(
        fixtureLabel: "WebKit custom-data candidate",
        typeIdentifier: "com.apple.WebKit.custom-pasteboard-data"
    ),
    .init(
        fixtureLabel: "Chromium custom-data candidate",
        typeIdentifier: "org.chromium.web-custom-data"
    ),
    .init(
        fixtureLabel: "Chromium source-URL candidate",
        typeIdentifier: "org.chromium.source-url"
    ),
    .init(
        fixtureLabel: "Chromium source-token candidate",
        typeIdentifier: "org.chromium.internal.source-rfh-token"
    ),
    .init(
        fixtureLabel: "Notes rich-text candidate",
        typeIdentifier: "com.apple.notes.richtext"
    ),
]

struct VolatilePasteboardCharacterizationTests {

    /// For every candidate, A and B have byte-identical visible text and
    /// differ only in the candidate payload. Both therefore insert under
    /// today's all-representations Canonical semantics. Replaying exact A
    /// then coalesces into A. This is a byte-sensitivity proof, not producer-
    /// emission or volatility-frequency evidence.
    @Test @MainActor
    func candidateByteChangesRemainDistinctCanonicalContent() async throws {
        try ComposedSupport.requireUsablePasteboard()

        for (index, candidate) in volatilePasteboardCandidates.enumerated() {
            let history = try await ComposedSupport.openMemoryHistory()
            let pasteboard = ComposedSupport.makePasteboard()
            let adapter = PasteboardAdapter(pasteboard: pasteboard)
            let visibleText = "DATA-9a fixed text \(index)"
            let generationA = Data("candidate-generation-A".utf8)
            let generationB = Data("candidate-generation-B".utf8)
            let timestampBase = 701_000_000 + TimeInterval(index * 10)

            let captureA = try Self.freeze(
                text: visibleText,
                candidate: candidate,
                candidateBytes: generationA,
                observedAt: Date(
                    timeIntervalSinceReferenceDate: timestampBase + 1
                ),
                pasteboard: pasteboard,
                adapter: adapter
            )
            let receiptA = try await history.perform(.capture(captureA))
            let insertedA = try #require(
                ComposedSupport.insertedReference(
                    from: receiptA,
                    "DATA-9a \(candidate.fixtureLabel) generation A"
                )
            )

            let captureB = try Self.freeze(
                text: visibleText,
                candidate: candidate,
                candidateBytes: generationB,
                observedAt: Date(
                    timeIntervalSinceReferenceDate: timestampBase + 2
                ),
                pasteboard: pasteboard,
                adapter: adapter
            )
            let receiptB = try await history.perform(.capture(captureB))
            let insertedB = try #require(
                ComposedSupport.insertedReference(
                    from: receiptB,
                    "DATA-9a \(candidate.fixtureLabel) generation B"
                )
            )
            #expect(
                insertedB.id != insertedA.id,
                "\(candidate.fixtureLabel): changed candidate bytes insert a second item"
            )

            let replayedA = try Self.freeze(
                text: visibleText,
                candidate: candidate,
                candidateBytes: generationA,
                observedAt: Date(
                    timeIntervalSinceReferenceDate: timestampBase + 3
                ),
                pasteboard: pasteboard,
                adapter: adapter
            )
            let replayReceipt = try await history.perform(.capture(replayedA))
            let coalescedA = try #require(
                ComposedSupport.coalescedReference(
                    from: replayReceipt,
                    "DATA-9a \(candidate.fixtureLabel) exact replay"
                )
            )
            #expect(
                coalescedA.id == insertedA.id,
                "\(candidate.fixtureLabel): exact A bytes still coalesce into A"
            )

            let page = try await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 10)
            )
            let copyCountByID = Dictionary(
                uniqueKeysWithValues: page.rows.map {
                    ($0.item.id, $0.copyCount)
                }
            )
            #expect(
                page.rows.count == 2,
                "\(candidate.fixtureLabel): A/B remain exactly two retained rows"
            )
            #expect(
                copyCountByID[insertedA.id] == 2,
                "\(candidate.fixtureLabel): exact A replay folds into A"
            )
            #expect(
                copyCountByID[insertedB.id] == 1,
                "\(candidate.fixtureLabel): changed B remains one distinct copy"
            )
        }
    }

    @MainActor
    private static func freeze(
        text: String,
        candidate: VolatilePasteboardCandidate,
        candidateBytes: Data,
        observedAt: Date,
        pasteboard: NSPasteboard,
        adapter: PasteboardAdapter
    ) throws -> ClipboardCapture {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        try #require(
            item.setData(Data(text.utf8), forType: .string),
            "\(candidate.fixtureLabel): private pasteboard accepted text"
        )
        try #require(
            item.setData(
                candidateBytes,
                forType: NSPasteboard.PasteboardType(candidate.typeIdentifier)
            ),
            "\(candidate.fixtureLabel): private pasteboard accepted candidate bytes"
        )
        try #require(
            pasteboard.writeObjects([item]),
            "\(candidate.fixtureLabel): private pasteboard accepted one complete item"
        )

        let capture = try #require(
            adapter.capture(observedAt: observedAt),
            "\(candidate.fixtureLabel): adapter produced one complete capture"
        )
        #expect(
            capture.representations.count == 2,
            "\(candidate.fixtureLabel): text and candidate are both retained"
        )
        #expect(
            capture.representations.contains {
                $0.typeIdentifier == ComposedSupport.plainTextTypeIdentifier
                    && $0.bytes == Data(text.utf8)
            },
            "\(candidate.fixtureLabel): visible text is byte-exact"
        )
        #expect(
            capture.representations.contains {
                $0.typeIdentifier == candidate.typeIdentifier
                    && $0.bytes == candidateBytes
            },
            "\(candidate.fixtureLabel): candidate is byte-exact"
        )
        return capture
    }
}
