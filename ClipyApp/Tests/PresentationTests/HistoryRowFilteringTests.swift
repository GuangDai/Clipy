/// HistoryRowFilteringTests — classification and the panel's authoritative
/// filter query replacement. Scripted pages verify UI request/lifecycle
/// behavior; real storage coverage lives in RealHistoryViewStateWindowTests.
import Foundation
@testable import HistoryCore
@testable import ClipyApp
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

    // MARK: - Authoritative filtered pages

    @Test func defaultsPassAllRowsThrough() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        #expect(state.typeFilter == .all)
        #expect(!state.showsPinnedOnly)
        #expect(await history.observeRequests.last?.filter == .all)
        #expect(state.displayedPinnedRows == state.pinnedRows)
        #expect(state.displayedUnpinnedRows == state.unpinnedRows)
        await history.finishObservation()
    }

    @Test func typeFilterReplacesBothLanesWithAuthoritativeRows() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        let original = state.rows
        for (filter, type, indexes) in [
            (HistoryTypeFilter.text, HistoryContentType.text, [0, 2]),
            (.images, .images, [3]),
            (.links, .links, [1]),
        ] {
            let count = await history.observeRequests.count
            state.typeFilter = filter
            #expect(state.rows.isEmpty)
            #expect(state.isLoadingFirstPage)
            #expect(!state.hasAuthoritativeFirstPage)
            try #require(await pollUntil { await history.observeRequests.count == count + 1 })
            #expect(await history.observeRequests.last?.filter == HistoryFilter(type: type))
            let replacement = indexes.map { original[$0] }
            await history.emitObservedPage(fixturePage(rows: replacement, next: nil))
            try #require(await pollUntil { state.rows == replacement })
            #expect(state.displayedRows == replacement)
            #expect(state.hasAuthoritativeFirstPage)
        }
        await history.finishObservation()
    }

    @Test func pinnedOnlyCombinesWithTypeInTheHistoryRequest() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        let pinned = Array(state.rows.prefix(2))
        state.showsPinnedOnly = true
        #expect(state.rows.isEmpty)
        try #require(await pollUntil { await history.observeRequests.count == 2 })
        #expect(await history.observeRequests.last?.filter == HistoryFilter(pinnedOnly: true))
        await history.emitObservedPage(fixturePage(rows: pinned, next: nil))
        try #require(await pollUntil { state.rows == pinned })
        #expect(state.displayedUnpinnedRows.isEmpty)
        state.typeFilter = .links
        try #require(await pollUntil { await history.observeRequests.count == 3 })
        #expect(await history.observeRequests.last?.filter == HistoryFilter(type: .links, pinnedOnly: true))
        await history.emitObservedPage(fixturePage(rows: [pinned[1]], next: nil))
        try #require(await pollUntil { state.rows == [pinned[1]] })
        #expect(state.displayedPinnedRows == [pinned[1]])
        await history.finishObservation()
    }

    @Test func emptyFilteredSnapshotCompletesLoadingAndRetiresOldRows() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        state.typeFilter = .images
        state.showsPinnedOnly = true
        #expect(state.rows.isEmpty)
        try #require(await pollUntil {
            await history.observeRequests.last?.filter == HistoryFilter(type: .images, pinnedOnly: true)
        })
        await history.emitObservedPage(fixturePage(rows: [], next: nil))
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(!state.isLoadingFirstPage)
        #expect(state.rows.isEmpty)
        #expect(state.displayedRows.isEmpty)
        await history.finishObservation()
    }

    @Test func filterReplacementIgnoresTheSupersededObservation() async throws {
        let (state, history) = activatedMixedState()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 5 })
        let oldRows = state.rows
        state.typeFilter = .links
        try #require(await pollUntil { await history.observeRequests.count == 2 })
        #expect(await history.observeRequests.last?.filter == HistoryFilter(type: .links))
        await history.emitObservedPage(fixturePage(rows: oldRows, next: nil), observationIndex: 0)
        let replacement = [oldRows[1]]
        await history.emitObservedPage(fixturePage(rows: replacement, next: nil), observationIndex: 1)
        try #require(await pollUntil { state.rows == replacement })
        #expect(state.displayedRows == replacement)
        #expect(state.hasAuthoritativeFirstPage)
        // Reassigning the current filter preserves the authoritative page.
        state.typeFilter = .links
        #expect(state.rows == replacement)
        #expect(state.hasAuthoritativeFirstPage)
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
            ),
            repeatsObservedFirstPage: false
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
