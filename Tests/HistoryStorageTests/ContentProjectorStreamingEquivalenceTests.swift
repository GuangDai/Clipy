/// A deliberately full-string oracle for the streaming projector change.
/// Tiny fixtures permit whole normalization, joining, and prefix enumeration
/// here; none of the production normalization/truncation helpers are reused.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct ContentProjectorStreamingEquivalenceTests {
    private struct Source {
        let representation: ContentRepresentation
        // Literal fixture meaning, independent of the production decoder.
        let text: String?
    }

    private let external = "public.utf16-external-plain-text"
    private let native = "public.utf16-plain-text"

    private func source(_ text: String, type: String = "public.utf8-plain-text") -> Source {
        let encoding: String.Encoding = type == external
            ? .utf16BigEndian : (type == native ? .utf16LittleEndian : .utf8)
        return Source(
            representation: ContentRepresentation(typeIdentifier: type, bytes: text.data(using: encoding)!),
            text: text
        )
    }

    private func ordered(_ sources: [Source]) -> [Source] {
        sources.sorted { $0.representation.typeIdentifier < $1.representation.typeIdentifier }
    }

    private func bounded(_ text: String, bytes: Int) -> String {
        // Enumerate complete prefixes instead of mirroring the streaming
        // implementation's remaining-byte counter and append loop.
        let boundaries = Array(text.indices) + [text.endIndex]
        let end = boundaries.last { text[..<$0].utf8.count <= bytes }!
        return String(text[..<end])
    }

    private func oracle(
        _ sources: [Source], titleBytes: Int, bodyBytes: Int
    ) -> (title: String, body: String) {
        let normalized = sources.compactMap(\.text).map {
            $0.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        let title = normalized.flatMap { $0.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? sources[0].representation.typeIdentifier
        let body = normalized.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: "\n")
        return (bounded(title, bytes: titleBytes), bounded(body, bytes: bodyBytes))
    }

    @Test(arguments: [(1, 1), (1, 7), (7, 1), (2, 3), (3, 2), (4, 4), (8, 12), (64, 64)])
    func streamingMatchesFullStringProjection(titleBytes: Int, bodyBytes: Int) {
        let fixtures: [[Source]] = [
            [source(" \r\n\t\r  First\r\nSecond\n")],
            [source("A\r\r\nB\nC\rD")],
            [source("A\r", type: external), source("B", type: native), source("C")],
            [source("A", type: external), source(" \t\r\n\u{00A0}", type: native), source("B")],
            [source("A", type: external), source("🦊", type: native), source("Z")],
            [source("👩🏽‍💻", type: external), source("Z")],
            [source("e\u{301}\r\n👩🏽‍💻", type: external), source(" \r\n", type: native), source("tail")],
            [source("\u{2028}A\u{0085}B\rC")],
            [source("\t\r\n", type: external), source(" \u{00A0}\n")],
        ]
        let limits = limits(titleBytes: titleBytes, bodyBytes: bodyBytes)
        for fixture in fixtures {
            let sources = ordered(fixture)
            let expected = oracle(sources, titleBytes: titleBytes, bodyBytes: bodyBytes)
            let content = EffectiveContent(representations: sources.map(\.representation))
            let actual = ContentProjector.project(content, limits: limits)
            #expect(actual.schemaVersion == 4)
            #expect(actual.effectiveTypeIdentifiers == sources.map(\.representation.typeIdentifier))
            #expect(Data(actual.title.utf8) == Data(expected.title.utf8))
            #expect(Data(actual.searchBody.utf8) == Data(expected.body.utf8))
            #expect(Data(ContentProjector.projectTitle(content, limits: limits).utf8)
                == Data(expected.title.utf8))
        }
    }

    @Test func literalBoundaryExamplesAnchorTheOracleAndProduct() {
        let examples: [([Source], Int, Int, String, String)] = [
            ([source("\r\nX")], 2, 1, "X", "\n"),
            ([source("\r\r\nX")], 1, 2, "X", "\n\n"),
            ([source("A", type: external), source(" \t\r\n", type: native), source("B")],
             7, 2, "A", "A\n"),
            ([source("A", type: external), source("🦊", type: native), source("Z")],
             1, 3, "A", "A\n"),
            ([source("👩🏽‍💻", type: external), source("Z")], 1, 1, "", ""),
            ([source("e\u{301}Z")], 3, 2, "e\u{301}", ""),
            ([source("e\u{301}\r\nZ")], 2, 4, "", "e\u{301}\n"),
            ([source("A\n", type: external), source("B", type: native)], 7, 3, "A", "A\n\n"),
            ([source("\t\r\n")], 7, 7, "public.", ""),
        ]
        for (fixture, titleBytes, bodyBytes, title, body) in examples {
            let sources = ordered(fixture)
            let expected = oracle(sources, titleBytes: titleBytes, bodyBytes: bodyBytes)
            let actual = ContentProjector.project(
                EffectiveContent(representations: sources.map(\.representation)),
                limits: limits(titleBytes: titleBytes, bodyBytes: bodyBytes)
            )
            #expect(Data(expected.title.utf8) == Data(title.utf8))
            #expect(Data(expected.body.utf8) == Data(body.utf8))
            #expect(Data(actual.title.utf8) == Data(title.utf8))
            #expect(Data(actual.searchBody.utf8) == Data(body.utf8))
        }
    }

    @Test func oddUTF16IsSkippedBeforeItCanContributeATitleOrSeparator() {
        let malformed: [(String, [UInt8])] = [
            (external, [0x00, 0x41, 0xFF]),
            (external, [0xFE, 0xFF, 0x00, 0x41, 0xFF]),
            (native, [0x41, 0x00, 0xFF]),
            (native, [0xFF, 0xFE, 0x41, 0x00, 0xFF]),
        ]
        for (type, bytes) in malformed {
            let sources = ordered([
                Source(representation: ContentRepresentation(typeIdentifier: type, bytes: Data(bytes)), text: nil),
                source("valid"),
            ])
            let actual = ContentProjector.project(
                EffectiveContent(representations: sources.map(\.representation)),
                limits: limits(titleBytes: 5, bodyBytes: 5)
            )
            #expect(actual.title == "valid")
            #expect(actual.searchBody == "valid")
            #expect(actual.schemaVersion == 4)
        }
    }

    private func limits(titleBytes: Int, bodyBytes: Int) -> HistoryLimits {
        let standard = HistoryLimits.standard
        return HistoryLimits(
            maximumRepresentationsPerCaptureOrRevision: standard.maximumRepresentationsPerCaptureOrRevision,
            maximumTypeIdentifierUTF8Bytes: standard.maximumTypeIdentifierUTF8Bytes,
            maximumRepresentationBytes: standard.maximumRepresentationBytes,
            maximumCaptureBytes: standard.maximumCaptureBytes,
            maximumProposedRevisionBytes: standard.maximumProposedRevisionBytes,
            maximumRevisionsPerItem: standard.maximumRevisionsPerItem,
            maximumTotalRevisionBytesPerItem: standard.maximumTotalRevisionBytesPerItem,
            hardMaximumRetainedItems: standard.hardMaximumRetainedItems,
            userMaximumUnpinnedLowerBound: standard.userMaximumUnpinnedRange.lowerBound,
            userMaximumUnpinnedUpperBound: standard.userMaximumUnpinnedRange.upperBound,
            defaultMaximumUnpinnedItems: standard.defaultMaximumUnpinnedItems,
            maximumSourceApplicationObservationUTF8Bytes: standard.maximumSourceApplicationObservationUTF8Bytes,
            maximumStoredTitleUTF8Bytes: titleBytes,
            maximumStoredSearchBodyUTF8Bytes: bodyBytes,
            pageRowLimitLowerBound: standard.pageRowLimitRange.lowerBound,
            pageRowLimitUpperBound: standard.pageRowLimitRange.upperBound,
            maximumSearchTermUTF8Bytes: standard.maximumSearchTermUTF8Bytes,
            maximumRegexpPatternCharacters: standard.maximumRegexpPatternCharacters,
            maximumFuzzyQueryCharacters: standard.maximumFuzzyQueryCharacters,
            maximumFuzzyTitleBodyPrefixCharacters: standard.maximumFuzzyTitleBodyPrefixCharacters,
            maximumRegexpTitleBodyPrefixCharacters: standard.maximumRegexpTitleBodyPrefixCharacters,
            maximumBodySearchSnippetCharacters: standard.maximumBodySearchSnippetCharacters,
            thumbnailDimensionLowerBound: standard.thumbnailDimensionRange.lowerBound,
            thumbnailDimensionUpperBound: standard.thumbnailDimensionRange.upperBound,
            maximumEncodedThumbnailBytes: standard.maximumEncodedThumbnailBytes
        )!
    }
}
