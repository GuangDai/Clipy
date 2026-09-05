/// Recipe 5 reference projection through the real pure projector. Expected
/// addresses, decoded paths, and names are literal facts, not URL parser output.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct ReferenceContentProjectionTests {
    @Test func addressesAndDecodedFileNamesRemainByteExact() {
        let fixtures: [(String, String, String, String)] = [
            ("public.url", "https://example.invalid/a%2fb?q=%E4%B8%AD%20x#part",
             "https://example.invalid/a%2fb?q=%E4%B8%AD%20x#part",
             "https://example.invalid/a%2fb?q=%E4%B8%AD%20x#part\n/a/b"),
            ("public.url", "https://example.invalid?q=1#fragment",
             "https://example.invalid?q=1#fragment", "https://example.invalid?q=1#fragment"),
            ("public.file-url", "file:///not-a-real-clipy-target/%E4%B8%AD%20name.txt",
             "中 name.txt",
             "file:///not-a-real-clipy-target/%E4%B8%AD%20name.txt\n/not-a-real-clipy-target/中 name.txt"),
            ("public.url", "file:///not-a-real-clipy-target/cafe%CC%81.txt",
             "cafe\u{301}.txt",
             "file:///not-a-real-clipy-target/cafe%CC%81.txt\n/not-a-real-clipy-target/cafe\u{301}.txt"),
            ("public.file-url", "file://remote/share/a%2Fb/name.txt",
             "name.txt", "file://remote/share/a%2Fb/name.txt\n/share/a/b/name.txt"),
            ("public.file-url", "file:///", "/", "file:///\n/"),
            ("public.file-url", "file:///not-a-real-clipy-target/folder/",
             "folder", "file:///not-a-real-clipy-target/folder/\n/not-a-real-clipy-target/folder/"),
            ("public.file-url", "file:///a%0D%0Ab%0Dc/name.txt", "name.txt",
             "file:///a%0D%0Ab%0Dc/name.txt\n/a\nb\nc/name.txt"),
            ("public.file-url", "file:///%EF%BB%BFname.txt", "\u{FEFF}name.txt",
             "file:///%EF%BB%BFname.txt\n/\u{FEFF}name.txt"),
        ]
        for (identifier, address, title, body) in fixtures {
            expectProjection([(identifier, Data(address.utf8))], title: title, body: body)
        }
    }

    @Test func characterBoundariesApplyIndependentlyToTitleAndBody() {
        let fixtures = [
            ("file:///e%CC%81.txt", "e\u{301}.txt", "file:///e%CC%81.txt\n/e\u{301}.txt"),
            ("file:///%F0%9F%91%A9%E2%80%8D%F0%9F%92%BB.txt", "👩‍💻.txt",
             "file:///%F0%9F%91%A9%E2%80%8D%F0%9F%92%BB.txt\n/👩‍💻.txt"),
        ]
        for (address, title, body) in fixtures {
            for (titleBytes, bodyBytes) in [(1, 1), (2, 3), (3, 2), (3, address.utf8.count + 3),
                                          (11, address.utf8.count + 4), (32, 128)] {
                expectProjection(
                    [("public.file-url", Data(address.utf8))],
                    title: wholeCharacterPrefix(title, bytes: titleBytes),
                    body: wholeCharacterPrefix(body, bytes: bodyBytes),
                    limits: limits(titleBytes: titleBytes, bodyBytes: bodyBytes)
                )
            }
        }
        // Literal anchors: neither the decomposed accent nor the ZWJ emoji
        // can be split to fill a title budget smaller than one Character.
        expectProjection(
            [("public.file-url", Data("file:///e%CC%81.txt".utf8))],
            title: "", body: "f", limits: limits(titleBytes: 2, bodyBytes: 1)
        )
        expectProjection(
            [("public.file-url", Data("file:///e%CC%81.txt".utf8))],
            title: "e\u{301}", body: "fi", limits: limits(titleBytes: 3, bodyBytes: 2)
        )
    }

    @Test func referenceCandidateBoundIsSixteenKiBIncludingEverySourceByte() {
        for (identifier, prefix, fallback) in [
            ("public.url", "https://example.invalid/", "URL"),
            ("public.file-url", "file:///", "File"),
        ] {
            let suffix = String(repeating: "a", count: 16_384 - prefix.utf8.count)
            let address = prefix + suffix
            #expect(Data(address.utf8).count == 16_384)
            let file = identifier == "public.file-url"
            let title = file ? suffix : address
            let body = address + "\n/" + suffix
            expectProjection(
                [(identifier, Data(address.utf8))],
                title: wholeCharacterPrefix(title, bytes: HistoryLimits.standard.maximumStoredTitleUTF8Bytes),
                body: body
            )
            expectProjection([(identifier, Data((address + "a").utf8))], title: fallback, body: "")
        }
    }

    @Test func invalidReferencesKeepTypeFallbackWithoutAReplacementCorpus() {
        let malformed = [
            Data(), Data([0xFF]), Data([0xEF, 0xBB, 0xBF]),
            Data("relative/path".utf8), Data("file:relative".utf8),
            Data("https://example.invalid/%GG".utf8),
            Data("https://example.invalid/a\0b".utf8),
            Data([0xEF, 0xBB, 0xBF]) + Data("file:///valid.txt".utf8),
        ]
        for (identifier, fallback) in [("public.url", "URL"), ("public.file-url", "File")] {
            for bytes in malformed {
                expectProjection([(identifier, bytes)], title: fallback, body: "")
            }
        }
        expectProjection(
            [("public.file-url", Data("https://example.invalid/not-a-file".utf8))],
            title: "File", body: ""
        )
        expectProjection(
            [("public.url", Data([0xEF, 0xBB, 0xBF]) + Data("https://example.invalid/".utf8))],
            title: "URL", body: ""
        )
    }

    @Test func firstExactReferenceOwnsSuccessOrFailureInNormalizedTypeOrder() {
        let later = ("public.url", Data("https://example.invalid/later".utf8))
        expectProjection(
            [later, ("public.file-url", Data("file:///first.txt".utf8))],
            title: "first.txt", body: "file:///first.txt\n/first.txt"
        )
        for bytes in [Data("invalid".utf8), Data(repeating: 0x61, count: 16_385)] {
            // Existing fallback categories consider the whole type list:
            // public.url is present, so failure falls back to URL, not File.
            expectProjection([later, ("public.file-url", bytes)], title: "URL", body: "")
        }
    }

    @Test func plainTextAndKnownImagesRetainTheirExistingPriority() {
        let reference = ("public.file-url", Data("file:///reference.txt".utf8))
        let plain = ("public.utf8-plain-text", Data(" \r\n Text title \r\nbody".utf8))
        let image = ("public.png", Data([0xFF]))
        expectProjection([reference, plain], title: "Text title", body: " \n Text title \nbody")
        expectProjection([reference, image], title: "Image", body: "")
        expectProjection([reference, image, plain], title: "Text title", body: " \n Text title \nbody")
        expectProjection(
            [reference, ("public.utf8-plain-text", Data("e\u{301}".utf8))],
            title: "", body: "e\u{301}", limits: limits(titleBytes: 2, bodyBytes: 8)
        )
    }

    @Test func invalidOrWhitespaceOnlyPlainTextCanYieldToAReference() {
        let reference = ("public.url", Data("https://example.invalid/reference".utf8))
        for bytes in [Data([0xFF]), Data(" \t\r\n".utf8)] {
            expectProjection(
                [reference, ("public.utf8-plain-text", bytes)],
                title: "https://example.invalid/reference", body: "https://example.invalid/reference\n/reference"
            )
        }
        expectProjection(
            [reference, ("public.utf16-plain-text", Data([0x41, 0x00, 0xFF]))],
            title: "https://example.invalid/reference", body: "https://example.invalid/reference\n/reference"
        )
    }

    @Test func lookalikeTypesRemainOpaqueButDoNotHideAnExactReference() {
        for identifier in ["public.url.private", "public.file-url.private", "dyn.url"] {
            let opaque = (identifier, Data("file:///not-eligible.txt".utf8))
            expectProjection([opaque], title: identifier, body: "")
            expectProjection(
                [opaque, ("public.url", Data("https://example.invalid/eligible".utf8))],
                title: "https://example.invalid/eligible", body: "https://example.invalid/eligible\n/eligible"
            )
        }
    }

    private func expectProjection(
        _ representations: [(String, Data)], title: String, body: String,
        limits: HistoryLimits = .standard
    ) {
        let ordered = representations.sorted { $0.0 < $1.0 }
        let content = EffectiveContent(representations: ordered.map {
            ContentRepresentation(typeIdentifier: $0.0, bytes: $0.1)
        })
        let actual = ContentProjector.project(content, limits: limits)
        #expect(actual.schemaVersion == 5)
        #expect(actual.effectiveTypeIdentifiers == ordered.map { $0.0 })
        #expect(Data(actual.title.utf8) == Data(title.utf8))
        #expect(Data(actual.searchBody.utf8) == Data(body.utf8))
        #expect(Data(ContentProjector.projectTitle(content, limits: limits).utf8)
            == Data(title.utf8))
    }

    private func wholeCharacterPrefix(_ text: String, bytes: Int) -> String {
        // Enumerating complete prefixes is independent of the production
        // streaming append helper and its remaining-byte accounting.
        let boundaries = Array(text.indices) + [text.endIndex]
        let end = boundaries.last { text[..<$0].utf8.count <= bytes }!
        return String(text[..<end])
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
