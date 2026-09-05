/// HistoryRowFilteringTests — the panel's client-side row filter: the UTI
/// classification families, filter admission over the loaded lanes,
/// pinned-only narrowing, the guarantee that filter edits never restart
/// observation (front-end narrowing over already-loaded pages; docs/
/// 04-coherence.md §5's replacement pages stay the only row source), and
/// the drag provider's registered-representation choice. Driven through the
/// scripted `ClipboardHistory` double exactly like `HistoryViewStateTests`.
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct HistoryRowFilteringTests {

    // MARK: - Classification vocabulary

    @Test(
        arguments: [
            ["public.image"],
            ["public.png"],
            ["public.jpeg"],
            ["public.tiff"],
            ["public.heic"],
            ["public.heif"],
            ["com.microsoft.bmp"],
            ["com.compuserve.gif"],
        ]
    )
    func imageRepresentationsClassifyAsImage(typeIdentifiers: [String]) {
        #expect(
            HistoryRowKind.classify(effectiveTypeIdentifiers: typeIdentifiers)
                == .image
        )
        #expect(HistoryRowView.typeSymbol(for: typeIdentifiers) == "photo")
        let row = filterFixtureRow(
            id: "00000000-0000-0000-0000-00000000F106",
            title: "image",
            typeIdentifiers: typeIdentifiers
        )
        #expect(HistoryTypeFilter.images.admits(row))
        #expect(!HistoryTypeFilter.text.admits(row))
        #expect(!HistoryTypeFilter.links.admits(row))
    }

    @Test(arguments: [["public.url"], ["public.file-url"]])
    func urlRepresentationsClassifyAsLink(typeIdentifiers: [String]) {
        #expect(
            HistoryRowKind.classify(effectiveTypeIdentifiers: typeIdentifiers)
                == .link
        )
    }

    @Test(
        arguments: [
            ["public.text"],
            ["public.plain-text"],
            ["public.utf8-plain-text"],
            ["public.utf16-plain-text"],
            ["public.utf16-external-plain-text"],
            ["public.html"],
            ["public.rtf"],
            ["com.apple.flat-rtfd"],
        ]
    )
    func textRepresentationsClassifyAsText(typeIdentifiers: [String]) {
        #expect(
            HistoryRowKind.classify(effectiveTypeIdentifiers: typeIdentifiers)
                == .text
        )
    }

    @Test(
        arguments: [
            ["com.adobe.pdf"],
            ["public.data"],
            ["com.example.custom-type"],
            ["public.image.private"],
            ["public.png-custom"],
            ["public.heif-private"],
            ["com.microsoft.bmp-private"],
            ["public.url-private"],
            ["public.html-private"],
            ["public.utf8-plain-text-private"],
            ["public.utf8-external-plain-text"],
            ["dyn.example"],
            [],
        ]
    )
    func unrecognizedRepresentationsClassifyAsOther(typeIdentifiers: [String]) {
        #expect(
            HistoryRowKind.classify(effectiveTypeIdentifiers: typeIdentifiers)
                == .other
        )
        #expect(HistoryRowView.typeSymbol(for: typeIdentifiers) == "doc.on.clipboard")
        let row = filterFixtureRow(
            id: "00000000-0000-0000-0000-00000000F107",
            title: "opaque",
            typeIdentifiers: typeIdentifiers
        )
        #expect(HistoryTypeFilter.all.admits(row))
        #expect(!HistoryTypeFilter.images.admits(row))
        #expect(!HistoryTypeFilter.text.admits(row))
        #expect(!HistoryTypeFilter.links.admits(row))
    }

    /// Priority matches the row's fallback symbol: a row carrying BOTH a URL
    /// and its plain-text title is a link; an image with text metadata is an
    /// image.
    @Test func classificationPriorityMatchesFallbackSymbolOrder() {
        #expect(
            HistoryRowKind.classify(
                effectiveTypeIdentifiers: ["public.utf8-plain-text", "public.png"]
            ) == .image
        )
        #expect(
            HistoryRowKind.classify(
                effectiveTypeIdentifiers: ["public.utf8-plain-text", "public.url"]
            ) == .link
        )
        #expect(
            HistoryRowKind.classify(
                effectiveTypeIdentifiers: ["public.html", "public.file-url"]
            ) == .link
        )
    }

    // MARK: - Filter vocabulary

    /// Case order, raw values, and exhaustiveness are the pinned vocabulary.
    @Test func typeFilterVocabularyIsStable() {
        #expect(HistoryTypeFilter.allCases == [.all, .text, .images, .links])
        #expect(HistoryTypeFilter.all.rawValue == "all")
        #expect(HistoryTypeFilter.text.rawValue == "text")
        #expect(HistoryTypeFilter.images.rawValue == "images")
        #expect(HistoryTypeFilter.links.rawValue == "links")
    }

    /// `.other` rows (PDFs, files, app-specific types) pass only `.all`.
    @Test func otherRowsPassOnlyTheAllFilter() {
        let pdf = filterFixtureRow(
            id: "00000000-0000-0000-0000-00000000F109",
            title: "pdf",
            typeIdentifiers: ["com.adobe.pdf"]
        )
        #expect(HistoryTypeFilter.all.admits(pdf))
        #expect(!HistoryTypeFilter.text.admits(pdf))
        #expect(!HistoryTypeFilter.images.admits(pdf))
        #expect(!HistoryTypeFilter.links.admits(pdf))
    }

    // MARK: - Displayed-row filtering (client-side; 04 §5 pages untouched)

    /// Defaults pass every loaded row through to the displayed lanes.
    @Test func defaultsPassAllRowsThrough() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        #expect(state.typeFilter == .all)
        #expect(!state.showsPinnedOnly)
        #expect(state.displayedPinnedRows == state.pinnedRows)
        #expect(state.displayedUnpinnedRows == state.unpinnedRows)

        state.deactivate()
        await history.finishObservation()
    }

    /// The type filter narrows both displayed lanes; the raw `pinnedRows`/
    /// `unpinnedRows` accessors stay untouched (existing tests pin them).
    @Test func textAndImageFiltersNarrowDisplayedLanesOnly() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        state.typeFilter = .text
        #expect(state.displayedPinnedRows.map(\.title) == ["pinned-text"])
        #expect(state.displayedUnpinnedRows.map(\.title) == ["recent-text"])

        state.typeFilter = .images
        #expect(state.displayedPinnedRows.isEmpty)
        #expect(state.displayedUnpinnedRows.map(\.title) == ["recent-image"])

        state.typeFilter = .links
        #expect(state.displayedPinnedRows.map(\.title) == ["pinned-link"])
        #expect(state.displayedUnpinnedRows.isEmpty)

        // The unfiltered lanes never changed.
        #expect(state.pinnedRows.count == 2)
        #expect(state.unpinnedRows.count == 3)
        #expect(state.rows.count == 5)

        state.deactivate()
        await history.finishObservation()
    }

    /// Pinned Only empties the Recent lane and leaves the pinned lane —
    /// still type-filtered — intact.
    @Test func pinnedOnlyEmptiesOnlyTheRecentLane() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        state.showsPinnedOnly = true
        #expect(state.displayedUnpinnedRows.isEmpty)
        #expect(
            state.displayedPinnedRows.map(\.title)
                == ["pinned-text", "pinned-link"]
        )
        #expect(state.unpinnedRows.count == 3)

        state.typeFilter = .links
        #expect(state.displayedPinnedRows.map(\.title) == ["pinned-link"])

        state.deactivate()
        await history.finishObservation()
    }

    /// A filter matching nothing empties both displayed lanes while the raw
    /// rows stay loaded (the list then reuses the "No Results" empty state).
    @Test func unmatchedFilterEmptiesDisplayedLanesOnly() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        // No pinned image exists in the fixture.
        state.typeFilter = .images
        state.showsPinnedOnly = true

        #expect(state.displayedPinnedRows.isEmpty)
        #expect(state.displayedUnpinnedRows.isEmpty)
        #expect(state.rows.count == 5)

        state.deactivate()
        await history.finishObservation()
    }

    /// Filter edits are pure in-memory narrowing: no new observe request, no
    /// debounce — the History query is untouched.
    @Test func filterEditsNeverRestartObservation() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })
        #expect(await history.observeRequests.count == 1)

        state.typeFilter = .images
        state.showsPinnedOnly = true
        state.typeFilter = .links
        state.showsPinnedOnly = false

        // Stable negative: settle past a full search debounce window (the
        // sanctioned settle sleep of the sibling suites).
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await history.observeRequests.count == 1)

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Drag-out provider (01 §5.6; 03b §9)

    /// Register the actual row types without inventing UTF-8 for a URL or
    /// UTF-16 representation; references absent from the display offer none.
    @Test func dragProviderRegistersActualAdvertisedTypes() async {
        let (state, history) = activatedMixedState()
        #expect(await pollUntil { state.rows.count == 5 })

        // Rows are the fixture page in order (03b §8 lane ordering is a list
        // concern; `rows` itself is the page order).
        #expect(
            state.dragItemProvider(for: state.rows[0].item)
                .registeredTypeIdentifiers == ["public.utf8-plain-text"]
        )
        // A URL remains a URL; it is not a guessed UTF-8 representation.
        #expect(
            state.dragItemProvider(for: state.rows[1].item)
                .registeredTypeIdentifiers == ["public.url"]
        )
        // UTF-16 is offered with its exact encoding identifier.
        #expect(
            state.dragItemProvider(for: state.rows[2].item)
                .registeredTypeIdentifiers == ["public.utf16-plain-text"]
        )
        #expect(
            state.dragItemProvider(for: state.rows[3].item)
                .registeredTypeIdentifiers == ["public.png"]
        )
        let stranger = HistoryItemReference(
            id: HistoryItemID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000F0")!
            ),
            contentVersion: ContentVersion(rawValue: 1)
        )
        #expect(
            state.dragItemProvider(for: stranger)
                .registeredTypeIdentifiers.isEmpty
        )

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Fixtures

    /// One activated view state over a five-row mixed-type page (two pinned,
    /// three recent). The caller owns `deactivate`/`finishObservation`.
    private func activatedMixedState() -> (HistoryViewState, ScriptedHistory) {
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(
                rows: [
                    filterFixtureRow(
                        id: "00000000-0000-0000-0000-00000000F101",
                        title: "pinned-text",
                        typeIdentifiers: ["public.utf8-plain-text"],
                        pinned: 0
                    ),
                    filterFixtureRow(
                        id: "00000000-0000-0000-0000-00000000F102",
                        title: "pinned-link",
                        typeIdentifiers: ["public.url"],
                        pinned: 1
                    ),
                    filterFixtureRow(
                        id: "00000000-0000-0000-0000-00000000F103",
                        title: "recent-text",
                        typeIdentifiers: ["public.utf16-plain-text"]
                    ),
                    filterFixtureRow(
                        id: "00000000-0000-0000-0000-00000000F104",
                        title: "recent-image",
                        typeIdentifiers: ["public.png"]
                    ),
                    filterFixtureRow(
                        id: "00000000-0000-0000-0000-00000000F105",
                        title: "recent-other",
                        typeIdentifiers: ["com.adobe.pdf"]
                    ),
                ],
                next: nil
            )
        )
        let state = HistoryViewState(history: history)
        state.activate()
        return (state, history)
    }

    /// One canned row with explicit representation types. Fixed UUID literals
    /// keep assertions readable; the force unwrap cannot fail for a
    /// well-formed literal — a malformed one is a fixture-authoring bug that
    /// must fail loudly.
    private func filterFixtureRow(
        id rawValue: String,
        title: String,
        typeIdentifiers: [String],
        pinned: Int? = nil
    ) -> HistoryRow {
        HistoryRow(
            item: HistoryItemReference(
                id: HistoryItemID(rawValue: UUID(uuidString: rawValue)!),
                contentVersion: ContentVersion(rawValue: 1)
            ),
            title: title,
            typeIdentifiers: typeIdentifiers,
            lastCopiedAt: Date(timeIntervalSince1970: 1_787_000_000),
            copyCount: 1,
            lastSource: nil,
            pinnedPosition: pinned,
            search: nil
        )
    }
}
