/// Real AppKit characterization for the remaining provider/empty-payload
/// edges at the adapter seam (01 §5.1; REVIEW Card 5B / open question 23).
///
/// Apple documents that `setDataProvider` registers callbacks for declared
/// types and that `data(forType:)` returns optional data. It does not document
/// a timeout or a cause for a nil result. These tests therefore record only
/// the observable facts: which declared types AppKit requested, which bytes
/// it returned, and the production adapter outcome. Every fixture uses a
/// uniquely named private pasteboard and never touches the user's clipboard.
import AppKit
import Foundation
import HistoryCore
import Synchronization
import Testing
@testable import PasteboardAdapter

private final class RefusingPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let requestedTypes = Mutex<[String]>([])

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        requestedTypes.withLock { $0.append(type.rawValue) }
        // Deliberately publish no bytes. A nil read is the only fact under
        // test; this callback makes no timeout, permission, or cause claim.
    }

    func requests() -> [String] {
        requestedTypes.withLock { $0 }
    }
}

@MainActor
private func makeProviderPasteboard() -> NSPasteboard {
    NSPasteboard(
        name: NSPasteboard.Name(
            "com.clipy.pasteboardprovidercharacterizationtests." + UUID().uuidString
        )
    )
}

@Test @MainActor
func providerUnavailableTypesRemainExactAlongsideAnAvailableSibling() throws {
    let pasteboard = makeProviderPasteboard()
    let availableType = NSPasteboard.PasteboardType.string
    let unavailableTypes = [
        NSPasteboard.PasteboardType("com.clipy.fixture.provider-missing-a"),
        NSPasteboard.PasteboardType("com.clipy.fixture.provider-missing-b"),
    ]
    let provider = RefusingPasteboardDataProvider()
    let item = NSPasteboardItem()

    #expect(item.setData(Data("available sibling".utf8), forType: availableType))
    #expect(item.setDataProvider(provider, forTypes: unavailableTypes))
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([item]))

    let outcome = try #require(
        PasteboardAdapter(pasteboard: pasteboard).captureOutcome()
    )
    guard case let .declaredUnavailable(partial) = outcome else {
        Issue.record("expected a declared-unavailable partial freeze")
        return
    }

    let expectedUnavailable = unavailableTypes.map(\.rawValue)
    #expect(partial.changeCount == pasteboard.changeCount)
    #expect(partial.unavailableTypeIdentifiers.count == expectedUnavailable.count)
    #expect(Set(partial.unavailableTypeIdentifiers) == Set(expectedUnavailable))
    #expect(partial.partialCapture.representations == [
        CapturedRepresentation(
            typeIdentifier: availableType.rawValue,
            bytes: Data("available sibling".utf8)
        )
    ])
    #expect(provider.requests().count == expectedUnavailable.count)
    #expect(Set(provider.requests()) == Set(expectedUnavailable))
}

@Test @MainActor
func providerUnavailableTypesRemainExactWhenEveryDeclaredPayloadIsMissing() throws {
    let pasteboard = makeProviderPasteboard()
    let unavailableTypes = [
        NSPasteboard.PasteboardType("com.clipy.fixture.provider-all-missing-a"),
        NSPasteboard.PasteboardType("com.clipy.fixture.provider-all-missing-b"),
    ]
    let provider = RefusingPasteboardDataProvider()
    let item = NSPasteboardItem()

    #expect(item.setDataProvider(provider, forTypes: unavailableTypes))
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([item]))

    let outcome = try #require(
        PasteboardAdapter(pasteboard: pasteboard).captureOutcome()
    )
    guard case let .declaredUnavailable(partial) = outcome else {
        Issue.record("expected an all-unavailable partial freeze")
        return
    }

    let expectedUnavailable = unavailableTypes.map(\.rawValue)
    #expect(partial.changeCount == pasteboard.changeCount)
    #expect(partial.partialCapture.representations.isEmpty)
    #expect(partial.unavailableTypeIdentifiers.count == expectedUnavailable.count)
    #expect(Set(partial.unavailableTypeIdentifiers) == Set(expectedUnavailable))
    #expect(provider.requests().count == expectedUnavailable.count)
    #expect(Set(provider.requests()) == Set(expectedUnavailable))
}

@Test @MainActor
func zeroByteRepresentationIsSkippedWhileAValidSiblingCompletes() throws {
    let pasteboard = makeProviderPasteboard()
    let emptyType = NSPasteboard.PasteboardType("com.clipy.fixture.zero-byte")
    let siblingType = NSPasteboard.PasteboardType("com.clipy.fixture.nonempty-sibling")
    let siblingBytes = Data([0x43, 0x4C, 0x49, 0x50])
    let item = NSPasteboardItem()

    #expect(item.setData(Data(), forType: emptyType))
    #expect(item.setData(siblingBytes, forType: siblingType))
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([item]))
    #expect(pasteboard.pasteboardItems?.first?.data(forType: emptyType) == Data())

    let outcome = try #require(
        PasteboardAdapter(pasteboard: pasteboard).captureOutcome()
    )
    guard case let .complete(complete) = outcome else {
        Issue.record("expected the nonempty sibling to complete the freeze")
        return
    }
    #expect(complete.capture.representations == [
        CapturedRepresentation(
            typeIdentifier: siblingType.rawValue,
            bytes: siblingBytes
        )
    ])
}

@Test @MainActor
func onlyZeroByteRepresentationProducesNoCaptureOutcome() {
    let pasteboard = makeProviderPasteboard()
    let emptyType = NSPasteboard.PasteboardType("com.clipy.fixture.only-zero-byte")
    let item = NSPasteboardItem()

    #expect(item.setData(Data(), forType: emptyType))
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([item]))
    #expect(pasteboard.pasteboardItems?.first?.data(forType: emptyType) == Data())

    #expect(PasteboardAdapter(pasteboard: pasteboard).captureOutcome() == nil)
}
