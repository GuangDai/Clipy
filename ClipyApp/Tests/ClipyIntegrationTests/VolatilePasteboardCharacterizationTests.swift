/// DATA-9a named-candidate characterization (REVIEW `01-findings.md`
/// DATA-9; todo map §4.5): private browser/editor pasteboard identifiers have
/// no Apple stability or semantic contract, so this suite does not classify
/// any identifier as ignorable. It records the current conservative product
/// behavior through the composed path: private NSPasteboard -> real
/// PasteboardAdapter freeze -> real in-memory SwiftDataHistory.
///
/// The names below come from third-party interoperability reports. The bytes
/// are deliberately synthetic and content-free. Consequently these tests
/// prove what Clipy does IF only one named candidate changes; they do not
/// prove that Chrome, Safari, Notes, or any current producer emits that type,
/// how often its bytes change, or that dropping it would preserve paste
/// fidelity. DATA-9b remains a separate evidence-gated representation-role
/// decision.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing

private struct VolatilePasteboardCandidate: Sendable {
    let producerLabel: String
    let typeIdentifier: String
}

private let volatilePasteboardCandidates: [VolatilePasteboardCandidate] = [
    .init(
        producerLabel: "Safari LinkPresentation candidate",
        typeIdentifier: "com.apple.linkpresentation.metadata"
    ),
    .init(
        producerLabel: "WebKit custom-data candidate",
        typeIdentifier: "com.apple.WebKit.custom-pasteboard-data"
    ),
    .init(
        producerLabel: "Chromium custom-data candidate",
        typeIdentifier: "org.chromium.web-custom-data"
    ),
    .init(
        producerLabel: "Chromium source-URL candidate",
        typeIdentifier: "org.chromium.source-url"
    ),
    .init(
        producerLabel: "Chromium source-token candidate",
        typeIdentifier: "org.chromium.internal.source-rfh-token"
    ),
    .init(
        producerLabel: "Notes rich-text candidate",
        typeIdentifier: "com.apple.notes.richtext"
    ),
]

struct VolatilePasteboardCharacterizationTests {

    /// For every named candidate, A and B have byte-identical visible text
    /// and differ only in the candidate payload. Both therefore insert under
    /// today's all-representations Canonical semantics. Replaying exact A
    /// then coalesces into A, proving the two-row result is caused by that
    /// candidate-byte difference rather than observation time or source.
    @Test @MainActor
    func namedCandidateByteChangesRemainDistinctCanonicalContent() async throws {
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
                    "DATA-9a \(candidate.producerLabel) generation A"
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
                    "DATA-9a \(candidate.producerLabel) generation B"
                )
            )
            #expect(
                insertedB.id != insertedA.id,
                "\(candidate.producerLabel): changed candidate bytes insert a second item"
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
                    "DATA-9a \(candidate.producerLabel) exact replay"
                )
            )
            #expect(
                coalescedA.id == insertedA.id,
                "\(candidate.producerLabel): exact A bytes still coalesce into A"
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
                "\(candidate.producerLabel): A/B remain exactly two retained rows"
            )
            #expect(
                copyCountByID[insertedA.id] == 2,
                "\(candidate.producerLabel): exact A replay folds into A"
            )
            #expect(
                copyCountByID[insertedB.id] == 1,
                "\(candidate.producerLabel): changed B remains one distinct copy"
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
            "\(candidate.producerLabel): private pasteboard accepted text"
        )
        try #require(
            item.setData(
                candidateBytes,
                forType: NSPasteboard.PasteboardType(candidate.typeIdentifier)
            ),
            "\(candidate.producerLabel): private pasteboard accepted candidate bytes"
        )
        try #require(
            pasteboard.writeObjects([item]),
            "\(candidate.producerLabel): private pasteboard accepted one complete item"
        )

        let capture = try #require(
            adapter.capture(observedAt: observedAt),
            "\(candidate.producerLabel): adapter produced one complete capture"
        )
        #expect(
            capture.representations.count == 2,
            "\(candidate.producerLabel): text and candidate are both retained"
        )
        #expect(
            capture.representations.contains {
                $0.typeIdentifier == ComposedSupport.plainTextTypeIdentifier
                    && $0.bytes == Data(text.utf8)
            },
            "\(candidate.producerLabel): visible text is byte-exact"
        )
        #expect(
            capture.representations.contains {
                $0.typeIdentifier == candidate.typeIdentifier
                    && $0.bytes == candidateBytes
            },
            "\(candidate.producerLabel): named candidate is byte-exact"
        )
        return capture
    }
}
