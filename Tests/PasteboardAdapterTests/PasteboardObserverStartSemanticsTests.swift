/// DEC-OBSERVER-START direct owner tests. These use a private named pasteboard
/// and the production observer entry/poll paths without waiting for a Timer:
/// process startup imports the already-current complete generation, while an
/// explicitly baseline-only restart excludes the stopped interval and admits
/// only a later generation (docs/01-architecture.md §5.1).
import AppKit
import Foundation
import HistoryCore
import Testing
@testable import PasteboardAdapter

#if DEBUG
@Suite("Pasteboard observer start semantics (DEC-OBSERVER-START)")
struct PasteboardObserverStartSemanticsTests {
    @Test("a synchronous stop from initial capture allows the next start to capture")
    @MainActor
    func initialCaptureCanStopObservation() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        Self.replaceString("first-start", on: pasteboard)
        let observer = PasteboardObserver(
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            pollInterval: 60
        )
        defer { observer.stop() }
        var received: [String] = []

        observer.start { outcome in
            if let text = Self.completeText(in: outcome) {
                received.append(text)
            }
            observer.stop()
        }
        Self.replaceString("second-start", on: pasteboard)
        observer.start { outcome in
            if let text = Self.completeText(in: outcome) {
                received.append(text)
            }
        }
        #expect(received == ["first-start", "second-start"])
        observer.pollForTesting()
        #expect(received == ["first-start", "second-start"])
    }

    @Test("stopping in the initial access callback prevents all payload reads")
    @MainActor
    func initialAccessCallbackCanStopBeforeCapture() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        Self.replaceString("do-not-read", on: pasteboard)
        var reads = 0
        var adapter = PasteboardAdapter(pasteboard: pasteboard)
        adapter.payloadReadObserver = { _ in reads += 1 }
        let observer = PasteboardObserver(adapter: adapter, pollInterval: 60)
        defer { observer.stop() }
        var received: [CaptureOutcome] = []

        observer.start(
            onAccessBehaviorChanged: { _ in observer.stop() },
            handler: { received.append($0) }
        )
        #expect(reads == 0)
        #expect(received.isEmpty)

        observer.start { received.append($0) }
        #expect(reads == 1)
        #expect(received.count == 1)
    }

    @Test("a baseline restart in the access callback owns the replacement timer")
    @MainActor
    func accessCallbackCanReplaceStartWithBaselineOnlyObservation() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        Self.replaceString("excluded-baseline", on: pasteboard)
        let observer = PasteboardObserver(
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            pollInterval: 60
        )
        defer { observer.stop() }
        var received: [String] = []
        let receive: @MainActor (CaptureOutcome) -> Void = { outcome in
            if let text = Self.completeText(in: outcome) {
                received.append(text)
            }
        }

        observer.start(
            onAccessBehaviorChanged: { _ in
                observer.stop()
                observer.start(captureCurrent: false, handler: receive)
            },
            handler: receive
        )
        observer.pollForTesting()
        #expect(received.isEmpty)

        Self.replaceString("after-baseline-restart", on: pasteboard)
        observer.pollForTesting()
        #expect(received == ["after-baseline-restart"])
    }

    @Test("startup imports the complete generation already current")
    @MainActor
    func startupImportsCurrentGeneration() throws {
        let pasteboard = Self.makePasteboard()
        Self.replaceString("current-before-start", on: pasteboard)
        let observer = PasteboardObserver(
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            pollInterval: 60
        )
        var received: [String] = []

        observer.start { outcome in
            if let text = Self.completeText(in: outcome) {
                received.append(text)
            }
        }
        defer { observer.stop() }

        #expect(received == ["current-before-start"])
    }

    @Test("baseline restart excludes the stopped generation")
    @MainActor
    func baselineRestartExcludesStoppedGenerationAndAdmitsNextCopy() throws {
        let pasteboard = Self.makePasteboard()
        Self.replaceString("initial-start", on: pasteboard)
        let observer = PasteboardObserver(
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            pollInterval: 60
        )
        var received: [String] = []
        let receive: @MainActor (CaptureOutcome) -> Void = { outcome in
            if let text = Self.completeText(in: outcome) {
                received.append(text)
            }
        }

        observer.start(handler: receive)
        #expect(received == ["initial-start"])
        observer.stop()

        Self.replaceString("copied-while-stopped", on: pasteboard)
        observer.start(captureCurrent: false, handler: receive)
        defer { observer.stop() }

        // Drive the production poll synchronously. The generation was made
        // the restart baseline, so it cannot be delivered on the first tick.
        observer.pollForTesting()
        #expect(received == ["initial-start"])

        Self.replaceString("copied-after-restart", on: pasteboard)
        observer.pollForTesting()
        #expect(received == ["initial-start", "copied-after-restart"])
    }

    @MainActor
    private static func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(
            "com.clipy.observer-start-semantics." + UUID().uuidString
        ))
    }

    @MainActor
    private static func replaceString(
        _ value: String,
        on pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        pasteboard.setData(Data(value.utf8), forType: .string)
    }

    @MainActor
    private static func completeText(in outcome: CaptureOutcome) -> String? {
        guard case let .complete(value) = outcome,
              let representation = value.capture.representations.first(
                where: {
                    $0.typeIdentifier
                        == NSPasteboard.PasteboardType.string.rawValue
                }
              )
        else {
            Issue.record("expected one complete string pasteboard generation")
            return nil
        }
        return String(data: representation.bytes, encoding: .utf8)
    }
}
#endif
