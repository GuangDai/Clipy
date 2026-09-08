/// HistoryDetailsFormatSafetyTests — literal proofs for the Details row's
/// format-safe text presentation boundary (review TYPE-2).
import Foundation
import HistoryCore
import PresentationUI
import Testing

struct HistoryDetailsFormatSafetyTests {
    @Test func equalMetadataDoesNotImplyEqualCanonicalAndEffectiveBytes() throws {
        let canonical = HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("A".utf8))
        let effective = HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("B".utf8))
        let snapshot = details(canonical: [canonical], effective: [effective])
        #expect(snapshot.canonical == snapshot.effective)
        let presentation = try DetailsContentPresentation(details: snapshot)
        #expect(!presentation.effectiveMatchesCanonical,
                "Revert eligibility comes from the byte-exact commit projection, not byte-count equality")
        #expect(presentation.canonical[0].presentation == .metadataOnly)
        #expect(presentation.effective[0].presentation == .metadataOnly)
    }

    /// Literal source vectors distinguish a UTF-16 encoding marker from the
    /// first actual scalar. Details, editor prefill and saved replacement must
    /// all preserve that scalar; paired encode/decode alone could hide a loss.
    @Test func leadingUnicodeMarkersSurviveDetailsAndEditing() throws {
        let fixtures: [(type: String, bytes: Data, text: String, suffix: Data)] = [
            ("public.utf8-plain-text", Data([0xEF, 0xBB, 0xBF, 0x41]), "\u{FEFF}A", Data([0x42])),
            ("public.utf16-plain-text", Data([0xFF, 0xFE, 0xFF, 0xFE, 0x41, 0x00]), "\u{FEFF}A", Data([0x42, 0x00])),
            ("public.utf16-plain-text", Data([0xFF, 0xFE, 0xFE, 0xFF, 0x41, 0x00]), "\u{FFFE}A", Data([0x42, 0x00])),
            ("public.utf16-external-plain-text", Data([0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x41]), "\u{FEFF}A", Data([0x00, 0x42])),
            ("public.utf16-external-plain-text", Data([0xFE, 0xFF, 0xFF, 0xFE, 0x00, 0x41]), "\u{FFFE}A", Data([0x00, 0x42])),
        ]
        for fixture in fixtures {
            let representation = HistoryRepresentation(typeIdentifier: fixture.type, bytes: fixture.bytes)
            let snapshot = details(canonical: [representation], effective: [representation])
            let prepared = try DetailsContentPresentation(details: snapshot)
            #expect(prepared.canonical[0].presentation == .metadataOnly)
            #expect(prepared.effective[0].presentation == .metadataOnly)
            #expect(DetailsRepresentationPresentation.resolve(representation) == .plainText(fixture.text))

            var draft = ReviseEditorDraft(details: snapshot)
            let installed = draft.installReplacementSource(representation)
            #expect(installed)
            #expect(draft.replacementText(for: fixture.type).utf8.elementsEqual(fixture.text.utf8))
            draft.setChoice(.replace, for: fixture.type)
            guard case .replace(let unedited) = draft.revisionRequest().intent else {
                Issue.record("Replace must produce a replacement draft")
                continue
            }
            #expect(unedited.decisions.first?.action == .replace(bytes: fixture.bytes))
            draft.setReplacementText(fixture.text + "B", for: fixture.type)
            guard case .replace(let edited) = draft.revisionRequest().intent else {
                Issue.record("An authored replacement must produce a replacement draft")
                continue
            }
            #expect(edited.decisions.first?.action == .replace(bytes: fixture.bytes + fixture.suffix))
        }
    }

    @Test(arguments: [
        "public.image.private", "public.image-url", "public.png.private",
        "public.url.private", "public.file-url.private", "com.example.curl-data", "dyn.example.url",
    ])
    func similarImageAndURLNamesRemainOpaque(_ identifier: String) throws {
        let representation = HistoryRepresentation(typeIdentifier: identifier, bytes: Data([0xFF, 0x00, 0x41]))
        let prepared = try DetailsContentPresentation(details: details(
            canonical: [representation], effective: [representation]
        ))
        #expect(prepared.symbolName == "doc.on.clipboard")
        #expect(prepared.effective[0].typeIdentifier == identifier)
        #expect(prepared.effective[0].byteCount == 3)
        #expect(!prepared.effective[0].isImage)
        #expect(prepared.effective[0].presentation == .metadataOnly)
    }

    @Test(arguments: [
        "public.image", "public.png", "public.jpeg", "public.tiff",
        "public.heic", "public.heif", "com.compuserve.gif", "com.microsoft.bmp",
    ])
    func exactImageFamiliesKeepTheirPhotoPresentation(_ identifier: String) throws {
        let representation = HistoryRepresentation(typeIdentifier: identifier, bytes: Data([0x41]))
        let prepared = try DetailsContentPresentation(details: details(
            canonical: [representation], effective: [representation]
        ))
        #expect(prepared.symbolName == "photo")
        #expect(prepared.effective[0].isImage)
        #expect(prepared.effective[0].presentation == .metadataOnly)
    }

    @Test(arguments: ["public.url", "public.file-url"])
    func exactURLsKeepTheirLinkIconWithoutTextDecoding(_ identifier: String) throws {
        let representation = HistoryRepresentation(typeIdentifier: identifier, bytes: Data("https://example.invalid".utf8))
        let prepared = try DetailsContentPresentation(details: details(
            canonical: [representation], effective: [representation]
        ))
        #expect(prepared.symbolName == "link")
        #expect(!prepared.effective[0].isImage)
        #expect(prepared.effective[0].presentation == .metadataOnly)
    }

    @Test func anImageSiblingDoesNotTurnAnUnknownRepresentationIntoAnImagePreview() throws {
        let representations = [
            HistoryRepresentation(typeIdentifier: "public.image.private", bytes: Data([0x01])),
            HistoryRepresentation(typeIdentifier: "public.png", bytes: Data([0x89, 0x50, 0x4E, 0x47])),
        ]
        let prepared = try DetailsContentPresentation(details: details(
            canonical: representations, effective: representations
        ))
        #expect(prepared.symbolName == "photo")
        // RepresentationRow uses this flag to show the unknown format's
        // unavailable-preview label and exclude the item's image thumbnail.
        #expect(prepared.effective.map(\.isImage) == [false, true])
        #expect(prepared.effective[0].presentation == .metadataOnly)
    }

    @Test func preparedDetailsKeepBothBasesAndTextSiblingsIndependent() throws {
        let canonical = [
            HistoryRepresentation(typeIdentifier: "public.html", bytes: Data("<p>original</p>".utf8)),
            HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(String(repeating: "🦊", count: 501).utf8)),
            HistoryRepresentation(typeIdentifier: "public.utf16-external-plain-text", bytes: Data([0x00, 0x41])),
        ]
        let effective = [
            HistoryRepresentation(typeIdentifier: "public.html", bytes: Data("<p>current</p>".utf8)),
            HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(String(repeating: "x", count: 501).utf8) + Data([0xFF])),
            HistoryRepresentation(typeIdentifier: "public.utf16-external-plain-text", bytes: Data([0x00, 0x42])),
        ]
        let prepared = try DetailsContentPresentation(details: details(canonical: canonical, effective: effective))

        #expect(!prepared.effectiveMatchesCanonical)
        #expect(prepared.canonical.map(\.typeIdentifier) == canonical.map(\.typeIdentifier))
        #expect(prepared.effective.map(\.byteCount) == effective.map(\.bytes.count))
        #expect(prepared.canonical[0].presentation == .metadataOnly)
        #expect(prepared.canonical[1].presentation == .metadataOnly)
        #expect(prepared.canonical[2].presentation == .metadataOnly)
        #expect(prepared.effective[0].presentation == .metadataOnly)
        #expect(prepared.effective[1].presentation == .metadataOnly)
        #expect(prepared.effective[2].presentation == .metadataOnly)
        #expect(prepared.title == "Metadata title", "the title comes from the scalar projection, not content hydration")
        #expect(DetailsRepresentationPresentation.resolve(effective[1]) == .metadataOnly,
                "an explicit preview still rejects malformed text beyond its display prefix")
    }

    @Test(arguments: [Data([0xD8, 0x00]), Data([0xD8])])
    func preparedUTF16StillValidatesBytesBeyondTheDisplayLimit(tail: Data) throws {
        let bytes = Data(Array(repeating: [UInt8(0x00), 0x41], count: 501).flatMap { $0 })
            + tail
        let representation = HistoryRepresentation(typeIdentifier: "public.utf16-external-plain-text", bytes: bytes)
        let prepared = try DetailsContentPresentation(details: details(
            canonical: [representation], effective: [representation]
        ))
        #expect(prepared.effectiveMatchesCanonical)
        #expect(prepared.canonical[0].presentation == .metadataOnly)
        #expect(prepared.effective[0].presentation == .metadataOnly)
        #expect(prepared.title == "Metadata title")
        #expect(DetailsRepresentationPresentation.resolve(representation) == .metadataOnly)
    }

    @Test(arguments: [false, true])
    func equivalentIdentifiersKeepEachBasesOriginalSpelling(reverse: Bool) throws {
        let composed = "com.example.\u{00E9}"
        let decomposed = "com.example.e\u{0301}"
        let canonicalType = reverse ? decomposed : composed
        let effectiveType = reverse ? composed : decomposed
        let sibling = HistoryRepresentation(typeIdentifier: "com.example.a", bytes: Data([0x00]))
        let canonical = [sibling, HistoryRepresentation(typeIdentifier: canonicalType, bytes: Data([0xFF]))]
        let effective = [sibling, HistoryRepresentation(typeIdentifier: effectiveType, bytes: Data([0xFF]))]
        #expect(canonical == effective, "Domain equality uses Unicode canonical equivalence")
        #expect(Array(canonicalType.utf8) != Array(effectiveType.utf8))

        let prepared = try DetailsContentPresentation(details: details(
            canonical: canonical, effective: effective
        ))
        #expect(prepared.effectiveMatchesCanonical, "Display reuse must not redefine Domain equality")
        // String equality would hide this regression; compare the original
        // UTF-8 spelling of every returned type, including the equal sibling.
        #expect(prepared.canonical.map { Array($0.typeIdentifier.utf8) }
            == canonical.map { Array($0.typeIdentifier.utf8) })
        #expect(prepared.effective.map { Array($0.typeIdentifier.utf8) }
            == effective.map { Array($0.typeIdentifier.utf8) })
        #expect(prepared.canonical.map(\.presentation) == [.metadataOnly, .metadataOnly])
        #expect(prepared.effective.map(\.presentation) == [.metadataOnly, .metadataOnly])
    }

    @Test @MainActor
    func cancelledDetailsPreparationDoesNotPublishPartialRows() async {
        let representation = HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("complete".utf8))
        let snapshot = details(canonical: [representation], effective: [representation])
        let preparation = Task { try DetailsContentPresentation(details: snapshot) }
        preparation.cancel()
        do {
            _ = try await preparation.value
            Issue.record("Cancelled preparation must throw instead of returning display rows")
        } catch is CancellationError {
            // The actual preparation initializer observes task cancellation.
        } catch {
            Issue.record("Unexpected preparation error: \(error)")
        }
    }

    private func details(
        canonical: [HistoryRepresentation], effective: [HistoryRepresentation]
    ) -> HistoryDetails {
        HistoryDetails(
            item: HistoryItemReference(id: HistoryItemID(rawValue: UUID()), contentVersion: .initial),
            title: "Metadata title",
            canonical: canonical.map { HistoryRepresentationMetadata(typeIdentifier: $0.typeIdentifier, byteCount: $0.bytes.count) },
            effective: effective.map { HistoryRepresentationMetadata(typeIdentifier: $0.typeIdentifier, byteCount: $0.bytes.count) },
            effectiveMatchesCanonical: canonical == effective, revisions: [],
            occurrence: CopyOccurrenceSummary(
                firstCopiedAt: Date(timeIntervalSinceReferenceDate: 1),
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 2),
                count: 1, firstSource: nil, lastSource: nil
            ),
            pinnedPosition: nil
        )
    }

    @Test func exactUTF8PlainTextDisplaysDecodedText() {
        let representation = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data("Hello, Clipy — 你好".utf8)
        )

        #expect(
            DetailsRepresentationPresentation.resolve(representation)
                == .plainText("Hello, Clipy — 你好")
        )
    }

    /// Bytes being valid UTF-8 is not an encoding contract for structured,
    /// abstract, or encoding-unspecified text identifiers (review TYPE-2).
    @Test func textWithoutAnExactEncodingContractStaysMetadataOnly() {
        let fixtures: [(String, String)] = [
            ("public.rtf", #"{\rtf1\ansi Literal RTF}"#),
            ("public.html", "<p>Literal HTML</p>"),
            ("public.text", "abstract text"),
            ("public.plain-text", "unspecified encoding"),
            ("public.utf8-external-plain-text", "external text"),
        ]

        for (typeIdentifier, literal) in fixtures {
            let representation = HistoryRepresentation(
                typeIdentifier: typeIdentifier,
                bytes: Data(literal.utf8)
            )

            #expect(
                DetailsRepresentationPresentation.resolve(representation)
                    == .metadataOnly,
                "\(typeIdentifier) must not be presented as UTF-8 plain text"
            )
        }
    }

    @Test func nativeAndExternalUTF16RespectByteOrderAndBOM() {
        let fixtures: [(String, Data)] = [
            ("public.utf16-plain-text", Data([0x41, 0x00, 0xA9, 0x03])),
            ("public.utf16-external-plain-text", Data([0x00, 0x41, 0x03, 0xA9])),
            ("public.utf16-plain-text", Data([0xFE, 0xFF, 0x00, 0x41, 0x03, 0xA9])),
            ("public.utf16-external-plain-text", Data([0xFF, 0xFE, 0x41, 0x00, 0xA9, 0x03])),
        ]
        for (typeIdentifier, bytes) in fixtures {
            #expect(
                DetailsRepresentationPresentation.resolve(
                    HistoryRepresentation(typeIdentifier: typeIdentifier, bytes: bytes)
                ) == .plainText("AΩ")
            )
        }
    }

    @Test func malformedOrEmptyUTF16StaysMetadataOnly() {
        for identifier in ["public.utf16-plain-text", "public.utf16-external-plain-text"] {
            for bytes in [
                Data(), Data([0x41]), Data([0xFF, 0xFE]), Data([0xFE, 0xFF, 0x41]),
                Data([0x00, 0x41, 0x42]), Data([0x41, 0x00, 0x42]),
                Data([0xFE, 0xFF, 0x00, 0x41, 0x42]),
                Data([0xFF, 0xFE, 0x41, 0x00, 0x42]),
            ] {
                #expect(
                    DetailsRepresentationPresentation.resolve(
                        HistoryRepresentation(typeIdentifier: identifier, bytes: bytes)
                    ) == .metadataOnly
                )
            }
        }
    }

    @Test func utf16PreviewPreservesWholeCharactersAtDisplayLimit() throws {
        let body = String(repeating: "🦊", count: 501)
        let bytes = try #require(body.data(using: .utf16BigEndian))
        #expect(
            DetailsRepresentationPresentation.resolve(
                HistoryRepresentation(
                    typeIdentifier: "public.utf16-external-plain-text",
                    bytes: bytes
                )
            ) == .plainText(String(repeating: "🦊", count: 500), wasTruncated: true)
        )
    }

    @Test func structuredRepresentationDoesNotConsumeItsPlainTextSibling() {
        let html = HistoryRepresentation(
            typeIdentifier: "public.html",
            bytes: Data("<p>Semantic sibling</p>".utf8)
        )
        let plainText = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data("Semantic sibling".utf8)
        )

        #expect(
            DetailsRepresentationPresentation.resolve(html) == .metadataOnly
        )
        #expect(
            DetailsRepresentationPresentation.resolve(plainText)
                == .plainText("Semantic sibling")
        )
    }

    @Test func malformedOrEmptyExactUTF8StaysMetadataOnly() {
        let malformed = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data([0xC3, 0x28])
        )
        let empty = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data()
        )

        #expect(
            DetailsRepresentationPresentation.resolve(malformed)
                == .metadataOnly
        )
        #expect(
            DetailsRepresentationPresentation.resolve(empty) == .metadataOnly
        )
    }

    @Test func exactUTF8PreviewIsBoundedToFiveHundredCharacters() {
        let representation = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data(String(repeating: "x", count: 501).utf8)
        )

        #expect(
            DetailsRepresentationPresentation.resolve(representation)
                == .plainText(String(repeating: "x", count: 500), wasTruncated: true)
        )
    }
}
