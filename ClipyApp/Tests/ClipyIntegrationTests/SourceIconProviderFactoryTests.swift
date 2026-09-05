/// Real AppKit source-icon loading. The factory returns independent bounded
/// rasters; per-surface reuse and FIFO eviction belong to SourceIconStore's
/// owner tests, with no second process-wide icon retention in the factory.
import CoreGraphics
import PresentationUI
import Testing
@testable import ClipyApp

struct SourceIconProviderFactoryTests {
    @Test @MainActor
    func installedFinderProducesIndependent64PixelRasters() throws {
        let provider = SourceIconProviderFactory.makeProvider()
        let first = try #require(provider.loadIcon("com.apple.finder"))
        let second = try #require(provider.loadIcon("com.apple.finder"))

        #expect(first.width == 64)
        #expect(first.height == 64)
        #expect(second.width == 64)
        #expect(second.height == 64)
        #expect(first !== second)
    }

    @Test @MainActor
    func unknownApplicationHasNoSourceIcon() {
        let provider = SourceIconProviderFactory.makeProvider()
        #expect(provider.loadIcon("com.clipy.tests.uninstalled-source-icon") == nil)
    }
}
