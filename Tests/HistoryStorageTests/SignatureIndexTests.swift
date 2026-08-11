/// Pure-value coverage for the complete Signature Index lifecycle and every
/// structural rejection. docs/05-authority-kernel.md §12–§13.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct SignatureIndexTests {
    private let firstID = HistoryItemID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!)
    private let secondID = HistoryItemID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000002"
    )!)
    private let thirdID = HistoryItemID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000003"
    )!)

    private func entry(
        _ typeIdentifier: String,
        fingerprint: UInt64,
        byteCount: Int = 4
    ) -> ContentSignatureEntry {
        ContentSignatureEntry(
            typeIdentifier: typeIdentifier,
            fingerprint: ContentFingerprint(rawValue: fingerprint),
            byteCount: byteCount
        )
    }

    @Test func unreadyAndEmptyLookupAreUnprovable() throws {
        var index = SignatureIndex()
        let text = entry("public.utf8-plain-text", fingerprint: 1)

        #expect(index.state == .unready)
        #expect(index.itemIDs.isEmpty)
        #expect(index.itemCount == 0)
        #expect(index.candidateIDs(matching: [text]) == nil)
        #expect(index.candidateIDs(matching: []) == nil)

        try index.validate(SignatureIndexDelta(additions: [:], removals: []))
        index.apply(SignatureIndexDelta(
            additions: [firstID: [text]],
            removals: []
        ))
        #expect(index.state == .unready)
        #expect(index.itemIDs.isEmpty)
    }

    @Test func buildRejectsMalformedEntryLists() throws {
        let text = entry("public.utf8-plain-text", fingerprint: 1)
        let conflictingText = entry(
            "public.utf8-plain-text",
            fingerprint: 2,
            byteCount: 5
        )

        #expect(throws: SignatureIndexRejection.emptySignatureEntries(item: firstID)) {
            try SignatureIndex.build(from: [firstID: []])
        }
        #expect(throws: SignatureIndexRejection.duplicateEntry(
            item: firstID,
            typeIdentifier: text.typeIdentifier
        )) {
            try SignatureIndex.build(from: [firstID: [text, text]])
        }
        #expect(throws: SignatureIndexRejection.duplicateTypeIdentifier(
            item: firstID,
            typeIdentifier: text.typeIdentifier
        )) {
            try SignatureIndex.build(from: [firstID: [text, conflictingText]])
        }
    }

    @Test func candidateLookupIntersectsEveryPosting() throws {
        let text = entry("public.utf8-plain-text", fingerprint: 1)
        let html = entry("public.html", fingerprint: 2)
        let third = entry("public.rtf", fingerprint: 3)
        let missing = entry("public.jpeg", fingerprint: 4)
        let index = try SignatureIndex.build(from: [
            firstID: [text, html],
            secondID: [text],
            thirdID: [third],
        ])

        #expect(index.state == .ready)
        #expect(index.itemIDs == Set([firstID, secondID, thirdID]))
        #expect(index.itemCount == 3)
        #expect(index.candidateIDs(matching: [text]) == Set([firstID, secondID]))
        #expect(index.candidateIDs(matching: [text, html]) == Set([firstID]))
        #expect(index.candidateIDs(matching: [html, missing]) == Set<HistoryItemID>())
        #expect(index.candidateIDs(matching: [missing]) == Set<HistoryItemID>())
        #expect(index.candidateIDs(matching: []) == nil)
    }

    @Test func validationRejectsEveryMalformedDelta() throws {
        let text = entry("public.utf8-plain-text", fingerprint: 1)
        let conflictingText = entry("public.utf8-plain-text", fingerprint: 2)
        let index = try SignatureIndex.build(from: [firstID: [text]])

        #expect(throws: SignatureIndexRejection.overlappingAdditionAndRemoval(firstID)) {
            try index.validate(SignatureIndexDelta(
                additions: [firstID: [text]],
                removals: [firstID]
            ))
        }
        #expect(throws: SignatureIndexRejection.additionAlreadyIndexed(firstID)) {
            try index.validate(SignatureIndexDelta(
                additions: [firstID: [text]],
                removals: []
            ))
        }
        #expect(throws: SignatureIndexRejection.removalNotIndexed(secondID)) {
            try index.validate(SignatureIndexDelta(additions: [:], removals: [secondID]))
        }
        #expect(throws: SignatureIndexRejection.emptySignatureEntries(item: secondID)) {
            try index.validate(SignatureIndexDelta(additions: [secondID: []], removals: []))
        }
        #expect(throws: SignatureIndexRejection.duplicateEntry(
            item: secondID,
            typeIdentifier: text.typeIdentifier
        )) {
            try index.validate(SignatureIndexDelta(
                additions: [secondID: [text, text]],
                removals: []
            ))
        }
        #expect(throws: SignatureIndexRejection.duplicateTypeIdentifier(
            item: secondID,
            typeIdentifier: text.typeIdentifier
        )) {
            try index.validate(SignatureIndexDelta(
                additions: [secondID: [text, conflictingText]],
                removals: []
            ))
        }
    }

    @Test func invalidPostCommitDeltaFailsClosedToUnready() throws {
        let text = entry("public.utf8-plain-text", fingerprint: 1)
        let conflictingText = entry("public.utf8-plain-text", fingerprint: 2)
        let malformedDeltas = [
            SignatureIndexDelta(additions: [firstID: [text]], removals: [firstID]),
            SignatureIndexDelta(additions: [firstID: [text]], removals: []),
            SignatureIndexDelta(additions: [:], removals: [secondID]),
            SignatureIndexDelta(additions: [secondID: []], removals: []),
            SignatureIndexDelta(additions: [secondID: [text, text]], removals: []),
            SignatureIndexDelta(
                additions: [secondID: [text, conflictingText]],
                removals: []
            ),
        ]

        for delta in malformedDeltas {
            var index = try SignatureIndex.build(from: [firstID: [text]])
            index.apply(delta)
            #expect(index.state == .unready)
            #expect(index.itemIDs.isEmpty)
            #expect(index.itemCount == 0)
            #expect(index.candidateIDs(matching: [text]) == nil)
        }
    }

    @Test func validDeltaUpdatesAllMapsAndKeepsReadiness() throws {
        let text = entry("public.utf8-plain-text", fingerprint: 1)
        let html = entry("public.html", fingerprint: 2)
        var index = try SignatureIndex.build(from: [firstID: [text]])
        let delta = SignatureIndexDelta(
            additions: [secondID: [html]],
            removals: [firstID]
        )

        try index.validate(delta)
        index.apply(delta)

        #expect(index.state == .ready)
        #expect(index.itemIDs == Set([secondID]))
        #expect(index.itemCount == 1)
        #expect(index.candidateIDs(matching: [text]) == Set<HistoryItemID>())
        #expect(index.candidateIDs(matching: [html]) == Set([secondID]))

        let emptyDelta = SignatureIndexDelta(additions: [:], removals: [])
        try index.validate(emptyDelta)
        index.apply(emptyDelta)
        #expect(index.state == .ready)
        #expect(index.itemIDs == Set([secondID]))

        index.markUnready()
        #expect(index.state == .unready)
        #expect(index.itemIDs.isEmpty)
        #expect(index.itemCount == 0)
    }
}
